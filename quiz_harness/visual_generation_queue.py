from __future__ import annotations

import hashlib
import json
import threading
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


QUEUE_SCHEMA = "visual_generation_queue_v1"
JOB_SCHEMA = "visual_generation_job_v1"
TERMINAL_STATUSES = {"complete", "failed"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


class VisualGenerationQueue:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)
        self.jobs_root = self.root / "jobs"
        self.producer_path = self.root / "producer.json"
        self._lock = threading.RLock()
        self._wake = threading.Event()
        self.jobs_root.mkdir(parents=True, exist_ok=True)

    def start_run(self, *, force: bool = False) -> None:
        with self._lock:
            for path in self._job_paths():
                job = _read_json(path)
                status = str(job.get("status") or "")
                if status == "running" or status == "failed" or (
                    force and status == "complete"
                ):
                    job.update(
                        {
                            "status": "queued",
                            "error": None,
                            "result": None,
                            "updated_at_utc": _now(),
                        }
                    )
                    _write_json(path, job)
            _write_json(
                self.producer_path,
                {
                    "schema_version": QUEUE_SCHEMA,
                    "status": "planning",
                    "error": None,
                    "updated_at_utc": _now(),
                },
            )
            self._wake.set()

    def enqueue(
        self,
        *,
        provider_id: str,
        model: str | None,
        asset_ids: set[str],
    ) -> dict[str, Any] | None:
        if not asset_ids:
            return None
        with self._lock:
            covered = {
                str(asset_id)
                for path in self._job_paths()
                for asset_id in _read_json(path).get("asset_ids", [])
            }
            pending = sorted(asset_ids - covered)
            if not pending:
                return None
            identity = json.dumps(
                [provider_id, model or "", pending], separators=(",", ":")
            )
            job_id = hashlib.sha256(identity.encode()).hexdigest()[:20]
            path = self.jobs_root / f"{job_id}.json"
            existing = _read_json(path)
            if existing:
                return existing
            created = _now()
            job = {
                "schema_version": JOB_SCHEMA,
                "id": job_id,
                "status": "queued",
                "provider_id": provider_id,
                "model": model,
                "asset_ids": pending,
                "attempts": 0,
                "error": None,
                "result": None,
                "created_at_utc": created,
                "updated_at_utc": created,
            }
            _write_json(path, job)
            self._wake.set()
            return job

    def finish_planning(self, error: str | None = None) -> None:
        with self._lock:
            _write_json(
                self.producer_path,
                {
                    "schema_version": QUEUE_SCHEMA,
                    "status": "failed" if error else "complete",
                    "error": error,
                    "updated_at_utc": _now(),
                },
            )
            self._wake.set()

    def requeue_missing(self, generated_asset_ids: set[str]) -> int:
        requeued = 0
        with self._lock:
            for path in self._job_paths():
                job = _read_json(path)
                if job.get("status") != "complete":
                    continue
                if all(
                    str(asset_id) in generated_asset_ids
                    for asset_id in job.get("asset_ids", [])
                ):
                    continue
                job.update(
                    {
                        "status": "queued",
                        "error": None,
                        "result": None,
                        "updated_at_utc": _now(),
                    }
                )
                _write_json(path, job)
                requeued += 1
            if requeued:
                self._wake.set()
        return requeued

    def claim(self) -> dict[str, Any] | None:
        with self._lock:
            for path in self._job_paths():
                job = _read_json(path)
                if job.get("status") != "queued":
                    continue
                job.update(
                    {
                        "status": "running",
                        "attempts": int(job.get("attempts", 0)) + 1,
                        "started_at_utc": _now(),
                        "updated_at_utc": _now(),
                    }
                )
                _write_json(path, job)
                return job
            self._wake.clear()
            return None

    def complete(self, job_id: str, result: dict[str, Any]) -> None:
        self._finish(job_id, status="complete", result=result, error=None)

    def fail(self, job_id: str, error: str) -> None:
        self._finish(job_id, status="failed", result=None, error=error)

    def _finish(
        self,
        job_id: str,
        *,
        status: str,
        result: dict[str, Any] | None,
        error: str | None,
    ) -> None:
        with self._lock:
            path = self.jobs_root / f"{job_id}.json"
            job = _read_json(path)
            if not job:
                raise KeyError(job_id)
            job.update(
                {
                    "status": status,
                    "result": result,
                    "error": error,
                    "completed_at_utc": _now(),
                    "updated_at_utc": _now(),
                }
            )
            _write_json(path, job)
            self._wake.set()

    def wait(self, timeout: float = 0.5) -> None:
        self._wake.wait(timeout)

    def producer(self) -> dict[str, Any]:
        with self._lock:
            return _read_json(self.producer_path)

    def jobs(self) -> list[dict[str, Any]]:
        with self._lock:
            return [_read_json(path) for path in self._job_paths()]

    def summary(self) -> dict[str, Any]:
        jobs = self.jobs()
        counts = {
            status: sum(job.get("status") == status for job in jobs)
            for status in ("queued", "running", "complete", "failed")
        }
        asset_counts = {
            status: sum(
                len(job.get("asset_ids", []))
                for job in jobs
                if job.get("status") == status
            )
            for status in ("queued", "running", "complete", "failed")
        }
        return {
            "producer": self.producer(),
            "jobs": counts,
            "assets": asset_counts,
            "total_jobs": len(jobs),
            "total_assets": sum(len(job.get("asset_ids", [])) for job in jobs),
            "errors": [
                {"job_id": job.get("id"), "error": job.get("error")}
                for job in jobs
                if job.get("status") == "failed"
            ],
        }

    def _job_paths(self) -> list[Path]:
        return sorted(self.jobs_root.glob("*.json"))
