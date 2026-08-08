from __future__ import annotations

import hashlib
import json
import threading
from pathlib import Path
from typing import Any, Callable

from .category_bundle import (
    activate_category_bundle_version,
    build_category_bundle,
)
from .studio_catalog import category_metadata_status
from .visual_bank import AnimalCatalog, VisualQuizSet


class StudioPublishError(ValueError):
    pass


def _read_json(path: Path, *, required: bool = False) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        if required:
            raise StudioPublishError(f"required production file is missing: {path}")
        return {}
    except (OSError, json.JSONDecodeError) as exc:
        raise StudioPublishError(f"cannot read {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise StudioPublishError(f"expected a JSON object in {path}")
    return value


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _gate(
    gate_id: str,
    label: str,
    *,
    current: int,
    target: int,
    detail: str,
    ready: bool,
) -> dict[str, Any]:
    return {
        "id": gate_id,
        "label": label,
        "current": current,
        "target": target,
        "detail": detail,
        "status": "ready" if ready else "blocked",
    }


class StudioPublishStore:
    def __init__(self, source_root: Path, output_root: Path) -> None:
        self.source_root = Path(source_root)
        self.output_root = Path(output_root)
        self._lock = threading.Lock()

    def category_root(self, category_slug: str) -> Path:
        return self.source_root / category_slug

    def category_output(self, category_slug: str) -> Path:
        return self.output_root / category_slug

    def _sets(self, category_slug: str) -> list[VisualQuizSet]:
        paths = sorted(self.category_root(category_slug).glob("sets/*/*.json"))
        try:
            return [
                VisualQuizSet.model_validate_json(path.read_text(encoding="utf-8"))
                for path in paths
            ]
        except (OSError, ValueError) as exc:
            raise StudioPublishError(f"quiz set validation failed: {exc}") from exc

    def _versions(self, category_slug: str) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
        output = self.category_output(category_slug)
        pointer = _read_json(output / "current.json")
        current_version = int(pointer.get("bundle_version", 0))
        versions_root = output / "versions"
        records = []
        if versions_root.exists():
            for path in sorted(
                (item for item in versions_root.iterdir() if item.is_dir()),
                reverse=True,
            ):
                record = _read_json(path / "record.json")
                if not record:
                    continue
                version = int(record.get("bundle_version", 0))
                archive = output / str(record.get("archive_file") or "")
                records.append(
                    {
                        "bundle_id": record.get("bundle_id"),
                        "bundle_version": version,
                        "content_hash": record.get("content_hash"),
                        "minimum_renderer_version": record.get(
                            "minimum_renderer_version"
                        ),
                        "quiz_count": record.get("quiz_count"),
                        "question_count": record.get("question_count"),
                        "generated_at_utc": record.get("generated_at_utc"),
                        "archive_file": record.get("archive_file"),
                        "archive_bytes": record.get("archive_bytes"),
                        "archive_sha256": record.get("archive_sha256"),
                        "is_current": version == current_version,
                        "archive_exists": archive.is_file(),
                        "category": record.get("category", {}),
                        "download_url": (
                            f"/api/studio/categories/{category_slug}/publish/"
                            f"versions/{version}/download"
                        ),
                    }
                )
        current = next(
            (item for item in records if item["is_current"]),
            None,
        )
        return current, records

    def inventory(self, category: dict[str, Any]) -> dict[str, Any]:
        slug = str(category["slug"])
        root = self.category_root(slug)
        global_root = self.source_root / "global"
        warnings: list[str] = []
        gates: list[dict[str, Any]] = []

        metadata = category_metadata_status(category)
        gates.append(
            _gate(
                "metadata",
                "Category metadata",
                current=metadata["current"],
                target=metadata["target"],
                detail=(
                    "Identity, audience, and editorial boundaries"
                    if metadata["ready"]
                    else "Missing " + ", ".join(metadata["missing"])
                ),
                ready=metadata["ready"],
            )
        )

        quiz_sets = self._sets(slug)
        set_ids = [item.set_id for item in quiz_sets]
        question_ids = [
            question.question_id for quiz_set in quiz_sets for question in quiz_set.questions
        ]
        sets_ready = bool(quiz_sets) and len(set_ids) == len(set(set_ids)) and all(
            len(item.questions) == 10 for item in quiz_sets
        ) and len(question_ids) == len(set(question_ids))
        gates.append(
            _gate(
                "sets",
                "Quiz sets",
                current=sum(len(item.questions) == 10 for item in quiz_sets),
                target=len(quiz_sets) or 1,
                detail=(
                    f"{len(quiz_sets)} sets / {len(question_ids)} unique questions"
                    if len(question_ids) == len(set(question_ids))
                    else "Question IDs repeat across quiz sets"
                ),
                ready=sets_ready,
            )
        )

        category_spec = _read_json(root / "category-image-spec.json")
        category_manifest = _read_json(root / "category-image-manifest.json")
        spec_assets = category_spec.get("assets", [])
        manifest_assets = category_manifest.get("assets", {})
        if not isinstance(spec_assets, list):
            spec_assets = []
        if not isinstance(manifest_assets, dict):
            manifest_assets = {}
        category_ready = 0
        pending_review = 0
        for asset in spec_assets:
            if not isinstance(asset, dict):
                continue
            asset_id = str(asset.get("asset_id") or "")
            output = root / str(asset.get("file") or "")
            record = manifest_assets.get(asset_id, {})
            if output.is_file() and isinstance(record, dict):
                category_ready += 1
                pending_review += record.get("status") == "generated_pending_review"
        if pending_review:
            warnings.append(f"{pending_review} category visuals are awaiting review")
        gates.append(
            _gate(
                "category_visuals",
                "Category visuals",
                current=category_ready,
                target=len(spec_assets),
                detail=f"{pending_review} awaiting review",
                ready=bool(spec_assets) and category_ready == len(spec_assets),
            )
        )

        try:
            catalog = AnimalCatalog.model_validate_json(
                (root / "animal_catalog.json").read_text(encoding="utf-8")
            )
            answer_total = len(catalog.animals)
            answer_ready = sum(
                (root / item.image_path).is_file() for item in catalog.animals
            )
        except (OSError, ValueError):
            answer_total = answer_ready = 0
        gates.append(
            _gate(
                "answer_visuals",
                "Answer visuals",
                current=answer_ready,
                target=answer_total or 1,
                detail=f"{answer_ready} reusable answer images",
                ready=bool(answer_total) and answer_ready == answer_total,
            )
        )

        global_spec = _read_json(global_root / "global-image-spec.json")
        global_manifest = _read_json(global_root / "global-image-manifest.json")
        global_assets = global_spec.get("assets", [])
        global_records = global_manifest.get("assets", {})
        if not isinstance(global_assets, list):
            global_assets = []
        if not isinstance(global_records, dict):
            global_records = {}
        global_ready = sum(
            isinstance(asset, dict)
            and (global_root / str(asset.get("file") or "")).is_file()
            and str(asset.get("asset_id") or "") in global_records
            for asset in global_assets
        )
        progress_ready = (global_root / "progress-style.json").is_file()
        global_target = len(global_assets) + 1
        gates.append(
            _gate(
                "presentation",
                "Presentation assets",
                current=global_ready + int(progress_ready),
                target=global_target,
                detail="Shared controls and progress style",
                ready=bool(global_assets) and global_ready + int(progress_ready) == global_target,
            )
        )

        audio_manifest = _read_json(root / "audio/audio-manifest.json")
        audio_records = audio_manifest.get("questions", {})
        if not isinstance(audio_records, dict):
            audio_records = {}
        audio_passed = 0
        audio_target = len(set(question_ids)) * 2
        for question_id in set(question_ids):
            record = audio_records.get(question_id, {})
            if not isinstance(record, dict):
                continue
            for kind in ("question", "explanation"):
                relative = str(record.get(kind) or "")
                audit = record.get(f"{kind}_audit", {})
                if (
                    relative
                    and (root / relative).is_file()
                    and isinstance(audit, dict)
                    and audit.get("status") == "passed"
                ):
                    audio_passed += 1
        gates.append(
            _gate(
                "audio",
                "Audited narration",
                current=audio_passed,
                target=audio_target or 1,
                detail="Question and explanation clips",
                ready=bool(audio_target) and audio_passed == audio_target,
            )
        )

        current, versions = self._versions(slug)
        released_category = (current or {}).get("category", {})
        if not isinstance(released_category, dict):
            released_category = {}
        redeploy_required = bool(current) and any(
            str(released_category.get(key) or "").strip()
            != str(category.get(key) or "").strip()
            for key in ("name", "display_title", "display_tag")
        )
        if redeploy_required:
            warnings.append("Category metadata changed; publish a new version")
        ready = all(item["status"] == "ready" for item in gates)
        return {
            "ready": ready,
            "gates": gates,
            "warnings": warnings,
            "current": current,
            "versions": versions,
            "redeploy_required": redeploy_required,
            "summary": {
                "quiz_sets": len(quiz_sets),
                "questions": len(set(question_ids)),
                "visual_assets": category_ready + answer_ready,
                "audited_clips": audio_passed,
                "release_count": len(versions),
            },
        }

    def publish(
        self,
        *,
        category: dict[str, Any],
        force_new_version: bool,
        progress: Callable[..., None],
    ) -> dict[str, Any]:
        with self._lock:
            readiness = self.inventory(category)
            if not readiness["ready"]:
                blocked = ", ".join(
                    item["label"]
                    for item in readiness["gates"]
                    if item["status"] != "ready"
                )
                raise StudioPublishError(f"category is not ready to publish: {blocked}")
            previous_version = int((readiness.get("current") or {}).get("bundle_version", 0))
            progress("Validating release inputs", 0.12)
            record = build_category_bundle(
                category=category["name"],
                category_root=self.category_root(category["slug"]),
                global_root=self.source_root / "global",
                output_root=self.output_root,
                display_title=category["display_title"],
                display_tag=category["display_tag"],
                force_new_version=force_new_version,
            )
            progress("Verifying release archive", 0.9)
            archive = self.category_output(category["slug"]) / record["archive_file"]
            if not archive.is_file() or _sha256(archive) != record["archive_sha256"]:
                raise StudioPublishError("published archive verification failed")
            version = int(record["bundle_version"])
            return {
                "status": "complete",
                "category_slug": category["slug"],
                "bundle_version": version,
                "content_hash": record["content_hash"],
                "archive_bytes": record["archive_bytes"],
                "archive_sha256": record["archive_sha256"],
                "reused_existing_version": version == previous_version,
            }

    def activate(self, *, category: dict[str, Any], version: int) -> dict[str, Any]:
        with self._lock:
            record = activate_category_bundle_version(
                output_root=self.output_root,
                category=category["name"],
                version=version,
            )
            return {
                "category_slug": category["slug"],
                "bundle_version": record["bundle_version"],
                "content_hash": record["content_hash"],
            }

    def archive(self, category_slug: str, version: int) -> tuple[Path, dict[str, Any]]:
        record = _read_json(
            self.category_output(category_slug)
            / "versions"
            / f"{version:06d}"
            / "record.json",
            required=True,
        )
        archive = self.category_output(category_slug) / str(record.get("archive_file") or "")
        if not archive.is_file():
            raise StudioPublishError("bundle archive is missing")
        return archive, record
