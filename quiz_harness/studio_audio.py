from __future__ import annotations

import hashlib
import json
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .audio_audit import AudioAuditConfig, WhisperAuditClient
from .vibevoice_audio import VibeVoiceChunkClient, generate_category_quiz_audio


class StudioAudioError(ValueError):
    pass


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        raise StudioAudioError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise StudioAudioError(f"expected a JSON object in {path}")
    return value


def _text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


class StudioAudioStore:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    def category_root(self, category_slug: str) -> Path:
        return self.root / category_slug

    @staticmethod
    def blocked_inventory(reason: str) -> dict[str, Any]:
        return {
            "ready": False,
            "blocked_reason": reason,
            "questions": [],
            "summary": {
                "questions": 0,
                "clips_total": 0,
                "generated": 0,
                "passed": 0,
                "missing": 0,
                "failed": 0,
                "stale": 0,
                "unaudited": 0,
                "attention": 0,
                "question_statuses": {},
            },
            "narrator": None,
            "last_run": None,
            "generated_at_utc": None,
        }

    def _questions(self, category_slug: str) -> list[dict[str, Any]]:
        root = self.category_root(category_slug)
        questions: dict[str, dict[str, Any]] = {}
        for path in sorted((root / "sets").glob("*/*.json")):
            document = _read_json(path)
            difficulty = str(document.get("difficulty") or path.parent.name)
            set_id = str(document.get("set_id") or path.stem)
            for position, question in enumerate(document.get("questions", []), start=1):
                if not isinstance(question, dict):
                    continue
                question_id = str(question.get("question_id") or "").strip()
                if not question_id:
                    raise StudioAudioError(f"question without an ID in {path}")
                existing = questions.get(question_id)
                content = {
                    "question_id": question_id,
                    "difficulty": str(question.get("difficulty") or difficulty),
                    "question": str(question.get("question") or "").strip(),
                    "explanation": str(question.get("explanation") or "").strip(),
                }
                if existing is not None:
                    if any(existing[key] != content[key] for key in content if key != "question_id"):
                        raise StudioAudioError(
                            f"question ID has conflicting content: {question_id}"
                        )
                    existing["sets"].append({"set_id": set_id, "position": position})
                    continue
                questions[question_id] = {
                    **content,
                    "sets": [{"set_id": set_id, "position": position}],
                }
        if not questions:
            raise StudioAudioError("select at least one quiz set before generating audio")
        order = {"beginner": 0, "intermediate": 1}
        return sorted(
            questions.values(),
            key=lambda item: (order.get(item["difficulty"], 9), item["question_id"]),
        )

    def _clip(
        self,
        *,
        category_slug: str,
        category_root: Path,
        record: dict[str, Any],
        kind: str,
        expected_text: str,
    ) -> dict[str, Any]:
        relative = str(record.get(kind) or "")
        path = category_root / relative if relative else None
        exists = bool(path and path.is_file())
        audit = record.get(f"{kind}_audit")
        expected_hash = _text_hash(expected_text)
        current_hash = record.get(f"{kind}_sha256")
        if current_hash and current_hash != expected_hash:
            status = "stale"
        elif isinstance(audit, dict) and audit.get("status") == "failed":
            status = "failed"
        elif not exists:
            status = "missing"
        elif isinstance(audit, dict) and audit.get("status") == "passed":
            status = "passed"
        else:
            status = "unaudited"
        return {
            "clip_id": f"{record.get('question_id', '')}/{kind}",
            "kind": kind,
            "status": status,
            "file": relative or None,
            "audio_url": (
                f"/studio-assets/{category_slug}/{relative}" if exists else None
            ),
            "audit": audit if isinstance(audit, dict) else None,
        }

    def inventory(self, category: dict[str, Any]) -> dict[str, Any]:
        slug = str(category["slug"])
        root = self.category_root(slug)
        try:
            sources = self._questions(slug)
        except StudioAudioError as exc:
            if str(exc) == "select at least one quiz set before generating audio":
                return self.blocked_inventory(str(exc))
            raise
        manifest = _read_json(root / "audio/audio-manifest.json")
        records = manifest.get("questions", {})
        if not isinstance(records, dict):
            records = {}
        questions = []
        clip_statuses: Counter[str] = Counter()
        question_statuses: Counter[str] = Counter()
        for source in sources:
            question_id = source["question_id"]
            record = records.get(question_id, {})
            if not isinstance(record, dict):
                record = {}
            record = {**record, "question_id": question_id}
            question_clip = self._clip(
                category_slug=slug,
                category_root=root,
                record=record,
                kind="question",
                expected_text=source["question"],
            )
            explanation_clip = self._clip(
                category_slug=slug,
                category_root=root,
                record=record,
                kind="explanation",
                expected_text=source["explanation"],
            )
            statuses = {question_clip["status"], explanation_clip["status"]}
            if "failed" in statuses:
                status = "failed"
            elif "stale" in statuses:
                status = "stale"
            elif statuses == {"passed"}:
                status = "passed"
            elif "missing" in statuses:
                status = "missing" if statuses == {"missing"} else "partial"
            else:
                status = "unaudited"
            clip_statuses.update([question_clip["status"], explanation_clip["status"]])
            question_statuses[status] += 1
            questions.append(
                {
                    **source,
                    "status": status,
                    "question_audio": question_clip,
                    "explanation_audio": explanation_clip,
                }
            )
        total_clips = len(questions) * 2
        attention = (
            clip_statuses["failed"]
            + clip_statuses["stale"]
            + clip_statuses["unaudited"]
        )
        return {
            "ready": True,
            "blocked_reason": None,
            "questions": questions,
            "summary": {
                "questions": len(questions),
                "clips_total": total_clips,
                "generated": total_clips - clip_statuses["missing"],
                "passed": clip_statuses["passed"],
                "missing": clip_statuses["missing"],
                "failed": clip_statuses["failed"],
                "stale": clip_statuses["stale"],
                "unaudited": clip_statuses["unaudited"],
                "attention": attention,
                "question_statuses": dict(question_statuses),
            },
            "narrator": manifest.get("narrator"),
            "last_run": manifest.get("last_run"),
            "generated_at_utc": manifest.get("generated_at_utc"),
        }

    def review_clip(
        self,
        *,
        category: dict[str, Any],
        clip_id: str,
        decision: str,
    ) -> dict[str, Any]:
        try:
            question_id, kind = clip_id.rsplit("/", 1)
        except ValueError as exc:
            raise StudioAudioError(f"invalid audio clip ID: {clip_id}") from exc
        if not question_id or kind not in {"question", "explanation"}:
            raise StudioAudioError(f"invalid audio clip ID: {clip_id}")
        if decision not in {"accept", "reset"}:
            raise StudioAudioError(f"invalid audio review decision: {decision}")

        slug = str(category["slug"])
        source = next(
            (item for item in self._questions(slug) if item["question_id"] == question_id),
            None,
        )
        if source is None:
            raise StudioAudioError(f"unknown audio clip: {clip_id}")
        root = self.category_root(slug)
        manifest_path = root / "audio/audio-manifest.json"
        manifest = _read_json(manifest_path)
        records = manifest.get("questions", {})
        record = records.get(question_id) if isinstance(records, dict) else None
        if not isinstance(record, dict):
            raise StudioAudioError(f"audio clip has not been generated: {clip_id}")
        expected_text = str(source[kind])
        if record.get(f"{kind}_sha256") != _text_hash(expected_text):
            raise StudioAudioError("regenerate this clip because its source text changed")
        relative = str(record.get(kind) or "")
        if not relative or not (root / relative).is_file():
            raise StudioAudioError(f"audio file is missing: {clip_id}")
        field = f"{kind}_audit"
        audit = record.get(field)
        if not isinstance(audit, dict):
            raise StudioAudioError("run the Whisper audit before reviewing this clip")

        if decision == "accept":
            if audit.get("status") != "failed":
                raise StudioAudioError("only a failed Whisper audit can be manually accepted")
            record[field] = {
                **audit,
                "status": "passed",
                "automatic_status": "failed",
                "manual_review": {
                    "status": "accepted",
                    "reviewed_at_utc": _now(),
                },
            }
        else:
            manual_review = audit.get("manual_review")
            if not isinstance(manual_review, dict) or manual_review.get("status") != "accepted":
                raise StudioAudioError("this clip has no manual review to reset")
            restored = dict(audit)
            restored["status"] = str(restored.pop("automatic_status", "failed"))
            restored.pop("manual_review", None)
            record[field] = restored

        manifest["generated_at_utc"] = _now()
        _write_json(manifest_path, manifest)
        inventory = self.inventory(category)
        reviewed_question = next(
            item for item in inventory["questions"] if item["question_id"] == question_id
        )
        return {
            "clip_id": clip_id,
            "decision": decision,
            "clip": reviewed_question[f"{kind}_audio"],
            "summary": inventory["summary"],
        }

    def generate(
        self,
        *,
        category: dict[str, Any],
        provider: dict[str, Any],
        clip_ids: set[tuple[str, str]] | None,
        force: bool,
        audit_repairs: int,
        duration_fallback_seconds: float | None = None,
        max_duration_repairs: int | None = 0,
        progress: Callable[..., None],
    ) -> dict[str, Any]:
        if provider.get("provider_type") != "vibevoice":
            raise StudioAudioError("audio generation requires a VibeVoice provider")
        settings = provider.get("settings", {})
        reference_audio = Path(str(settings.get("reference_audio_path") or ""))
        if not reference_audio.is_file():
            raise StudioAudioError("upload a valid VibeVoice reference WAV in Admin")
        if clip_ids:
            valid = {
                (item["question_id"], kind)
                for item in self._questions(category["slug"])
                for kind in ("question", "explanation")
            }
            invalid = sorted(clip_ids - valid)
            if invalid:
                raise StudioAudioError(f"unknown audio clip: {invalid[0][0]}/{invalid[0][1]}")
        root = self.category_root(category["slug"])
        progress("Checking narrator service", 0.02)
        with WhisperAuditClient(cache_root=root / "audio/audits/cache") as auditor:
            client = VibeVoiceChunkClient(
                endpoint=provider["base_url"],
                reference_audio=reference_audio,
                lang_key=str(settings.get("language") or "en_indian"),
                cfg_scale=float(settings.get("cfg_scale") or 1.3),
                timeout_seconds=900,
                auditor=auditor,
                max_audit_repairs=audit_repairs,
                duration_fallback_seconds=duration_fallback_seconds,
                max_duration_repairs=max_duration_repairs,
            )
            client.health()
            progress("Narrator ready", 0.05)

            def report(completed: int, total: int) -> None:
                ratio = completed / float(total or 1)
                progress(
                    f"Processed {completed}/{total} audio clips",
                    0.06 + ratio * 0.9,
                )

            manifest = generate_category_quiz_audio(
                category_root=root,
                category=category["name"],
                client=client,
                reference_transcript=str(settings.get("reference_transcript") or ""),
                clip_ids=clip_ids,
                force=force,
                progress=report,
            )
        failed = int(manifest.get("last_run", {}).get("failed", 0))
        progress("Audio inventory updated", 0.98)
        return {
            "status": "partial" if failed else "complete",
            "category_slug": category["slug"],
            "provider_id": provider["id"],
            "requested_clips": int(manifest.get("last_run", {}).get("requested", 0)),
            "audited_existing_clips": int(
                manifest.get("last_run", {}).get("audited_existing", 0)
            ),
            "failed_clips": failed,
            "failed_task_ids": manifest.get("last_run", {}).get("failed_task_ids", []),
        }
