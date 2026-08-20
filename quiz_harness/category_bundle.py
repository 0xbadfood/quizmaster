from __future__ import annotations

import hashlib
import json
import re
import shutil
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .visual_bank import AnimalCatalog, VisualBankDocument, VisualQuizSet


CATEGORY_BUNDLE_SCHEMA = "category_bundle_v1"
MINIMUM_RENDERER_VERSION = 1


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def category_bundle_slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "quiz"


def _slug(value: str) -> str:
    return category_bundle_slug(value)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def _copy(source: Path, destination: Path) -> None:
    if not source.is_file():
        raise ValueError(f"required bundle source is missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def _load_sets(category_root: Path) -> list[VisualQuizSet]:
    paths = sorted((category_root / "sets").glob("*/*.json"))
    if not paths:
        raise ValueError(f"no quiz sets found under {category_root / 'sets'}")
    sets = [
        VisualQuizSet.model_validate_json(path.read_text(encoding="utf-8"))
        for path in paths
    ]
    ids = [quiz_set.set_id for quiz_set in sets]
    if len(ids) != len(set(ids)):
        raise ValueError("quiz set IDs must be unique")
    return sets


def _file_inventory(root: Path) -> list[dict[str, Any]]:
    files = []
    for path in sorted(item for item in root.rglob("*") if item.is_file()):
        relative = path.relative_to(root).as_posix()
        if relative == "bundle.json":
            continue
        files.append(
            {
                "path": relative,
                "bytes": path.stat().st_size,
                "sha256": _sha256(path),
            }
        )
    return files


def _content_hash(files: list[dict[str, Any]]) -> str:
    digest = hashlib.sha256()
    for item in files:
        digest.update(item["path"].encode("utf-8"))
        digest.update(b"\0")
        digest.update(item["sha256"].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def _read_json(path: Path) -> dict[str, Any]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"could not read {path}: {exc}") from exc
    if not isinstance(data, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return data


def _current_record(category_output: Path) -> dict[str, Any] | None:
    pointer = category_output / "current.json"
    if not pointer.exists():
        return None
    current = _read_json(pointer)
    record_path = category_output / current["record_file"]
    return _read_json(record_path)


def _record_with_content_hash(
    category_output: Path, content_hash: str
) -> dict[str, Any] | None:
    versions_root = category_output / "versions"
    if not versions_root.exists():
        return None
    for path in sorted(
        (item for item in versions_root.iterdir() if item.is_dir()), reverse=True
    ):
        record_path = path / "record.json"
        if not record_path.is_file():
            continue
        record = _read_json(record_path)
        if record.get("content_hash") == content_hash:
            return record
    return None


def _next_version(category_output: Path) -> int:
    versions_root = category_output / "versions"
    versions = [
        int(path.name)
        for path in versions_root.iterdir()
        if path.is_dir() and path.name.isdigit()
    ] if versions_root.exists() else []
    return max(versions, default=0) + 1


def _tile_asset_id(quiz_set: VisualQuizSet) -> str:
    number = int(quiz_set.set_id.rsplit("_", 1)[-1])
    return f"tile_{quiz_set.difficulty}_{number:02d}"


def _required_category_asset_id(
    category_assets: dict[str, dict[str, Any]], *, role: str
) -> str:
    matches = [
        asset_id
        for asset_id, asset in category_assets.items()
        if asset.get("role") == role
    ]
    if len(matches) != 1:
        detail = "missing" if not matches else "ambiguous"
        raise ValueError(f"category {role} asset is {detail}")
    return matches[0]


def _optional_category_asset_id(
    category_assets: dict[str, dict[str, Any]], *, role: str
) -> str | None:
    matches = [
        asset_id
        for asset_id, asset in category_assets.items()
        if asset.get("role") == role
    ]
    if len(matches) > 1:
        raise ValueError(f"category {role} asset is ambiguous")
    return matches[0] if matches else None


def _build_payload(
    *,
    staging: Path,
    category: str,
    category_root: Path,
    global_root: Path,
    display_title: str,
    display_tag: str,
) -> dict[str, Any]:
    category_slug = _slug(category)
    quiz_sets = _load_sets(category_root)
    animal_catalog = AnimalCatalog.model_validate_json(
        (category_root / "animal_catalog.json").read_text(encoding="utf-8")
    )
    banks = [
        VisualBankDocument.model_validate_json(path.read_text(encoding="utf-8"))
        for path in sorted((category_root / "banks").glob("*/bank.json"))
    ]
    if not banks:
        raise ValueError(f"no source banks found under {category_root / 'banks'}")

    category_spec = _read_json(category_root / "category-image-spec.json")
    category_manifest = _read_json(category_root / "category-image-manifest.json")
    global_spec = _read_json(global_root / "global-image-spec.json")
    global_manifest = _read_json(global_root / "global-image-manifest.json")
    progress_style = _read_json(global_root / "progress-style.json")
    category_audio_path = category_root / "audio/audio-manifest.json"
    has_audio = category_audio_path.exists()
    category_audio = _read_json(category_audio_path) if has_audio else {}

    category_assets = {item["asset_id"]: item for item in category_spec["assets"]}
    global_assets = {item["asset_id"]: item for item in global_spec["assets"]}
    for asset_id, asset in category_assets.items():
        if (
            asset_id not in category_manifest.get("assets", {})
            and asset.get("role")
            not in {"video_background_portrait", "video_background_landscape"}
        ):
            raise ValueError(f"category asset has no manifest record: {asset_id}")
    for asset_id in global_assets:
        if asset_id not in global_manifest.get("assets", {}):
            raise ValueError(f"global asset has no manifest record: {asset_id}")

    background_id = _required_category_asset_id(
        category_assets, role="runtime_background"
    )
    selector_id = _required_category_asset_id(
        category_assets, role="category_selector"
    )
    landscape_background_id = _optional_category_asset_id(
        category_assets, role="video_background_landscape"
    )
    portrait_video_background_id = _optional_category_asset_id(
        category_assets, role="video_background_portrait"
    )
    if portrait_video_background_id and (
        portrait_video_background_id not in category_manifest.get("assets", {})
        or not (
            category_root / category_assets[portrait_video_background_id]["file"]
        ).is_file()
    ):
        portrait_video_background_id = None
    if landscape_background_id and (
        landscape_background_id not in category_manifest.get("assets", {})
        or not (category_root / category_assets[landscape_background_id]["file"]).is_file()
    ):
        landscape_background_id = None

    presentation_files: dict[str, str] = {}
    for asset_id in (
        background_id,
        selector_id,
        *(
            [portrait_video_background_id]
            if portrait_video_background_id
            else []
        ),
        *([landscape_background_id] if landscape_background_id else []),
    ):
        spec = category_assets[asset_id]
        suffix = Path(spec["file"]).suffix
        target = f"assets/category/{asset_id}{suffix}"
        _copy(category_root / spec["file"], staging / target)
        presentation_files[asset_id] = target

    global_files: dict[str, str] = {}
    for asset_id, spec in sorted(global_assets.items()):
        suffix = Path(spec["file"]).suffix
        target = f"assets/global/{asset_id}{suffix}"
        _copy(global_root / spec["file"], staging / target)
        global_files[asset_id] = target
    _write_json(staging / "runtime/progress-style.json", progress_style)
    video_inventory_source = global_root / "video-presentation-inventory.json"
    if video_inventory_source.is_file():
        _copy(
            video_inventory_source,
            staging / "runtime/video-presentation-inventory.json",
        )

    question_audio: dict[str, dict[str, str]] = {}
    if has_audio:
        for question_id, item in category_audio.get("questions", {}).items():
            safe_id = _slug(question_id).replace("-", "_")
            question_suffix = Path(item["question"]).suffix
            explanation_suffix = Path(item["explanation"]).suffix
            question_target = f"assets/audio/questions/{safe_id}{question_suffix}"
            explanation_target = (
                f"assets/audio/explanations/{safe_id}{explanation_suffix}"
            )
            _copy(category_root / item["question"], staging / question_target)
            _copy(category_root / item["explanation"], staging / explanation_target)
            question_audio[str(question_id)] = {
                "question": question_target,
                "explanation": explanation_target,
            }

    animal_files: dict[str, str] = {}
    for animal in animal_catalog.animals:
        source = category_root / animal.image_path
        target = f"assets/answers/{animal.animal_key}.webp"
        _copy(source, staging / target)
        animal_files[animal.animal_key] = target

    quizzes = []
    for quiz_set in quiz_sets:
        number = int(quiz_set.set_id.rsplit("_", 1)[-1])
        tile_id = _tile_asset_id(quiz_set)
        tile_spec = category_assets.get(tile_id)
        if tile_spec is None:
            raise ValueError(f"tile spec is missing for {quiz_set.set_id}")
        tile_target = f"assets/tiles/{quiz_set.difficulty}_{number:02d}.webp"
        _copy(category_root / tile_spec["file"], staging / tile_target)
        questions_target = f"quizzes/{quiz_set.difficulty}/{quiz_set.set_id}.json"
        questions = quiz_set.model_dump(mode="json")["questions"]
        if has_audio:
            for question in questions:
                question_id = question["question_id"]
                if question_id not in question_audio:
                    raise ValueError(f"question audio is missing: {question_id}")
                question["audio"] = question_audio[question_id]
        _write_json(
            staging / questions_target,
            {
                **quiz_set.model_dump(mode="json"),
                "questions": questions,
                "answer_assets": {
                    animal_key: animal_files[animal_key]
                    for animal_key in sorted(
                        {
                            choice.animal_key
                            for question in quiz_set.questions
                            for choice in question.choices
                        }
                    )
                },
            },
        )
        quizzes.append(
            {
                "quiz_id": quiz_set.set_id,
                "number": number,
                "difficulty": quiz_set.difficulty,
                "title": f"{display_title} {number}",
                "question_count": len(quiz_set.questions),
                "tile_asset": tile_target,
                "questions_file": questions_target,
            }
        )

    bank_summary = []
    for bank in banks:
        target = f"source/banks/{bank.difficulty}.json"
        _write_json(staging / target, bank.model_dump(mode="json"))
        bank_summary.append(
            {
                "difficulty": bank.difficulty,
                "question_count": len(bank.questions),
                "file": target,
            }
        )
    _write_json(
        staging / "source/animal-catalog.json", animal_catalog.model_dump(mode="json")
    )
    for source_path, target in (
        (category_root / "category-image-spec.json", "source/category-image-spec.json"),
        (
            category_root / "category-image-manifest.json",
            "source/category-image-manifest.json",
        ),
        (
            category_root / "answer-image-manifest.json",
            "source/answer-image-manifest.json",
        ),
    ):
        _copy(source_path, staging / target)

    difficulties = []
    for difficulty in ("beginner", "intermediate"):
        count = sum(item["difficulty"] == difficulty for item in quizzes)
        if count:
            difficulties.append(
                {
                    "id": difficulty,
                    "label": difficulty.title(),
                    "quiz_count": count,
                }
            )
    category_document = {
        "schema_version": CATEGORY_BUNDLE_SCHEMA,
        "minimum_renderer_version": MINIMUM_RENDERER_VERSION,
        "category": {
            "id": category_slug,
            "name": category,
            "display_title": display_title,
            "display_tag": display_tag,
            "selector_asset": presentation_files[selector_id],
        },
        "presentation": {
            "runtime_background": presentation_files[background_id],
            **(
                {
                    "video_background_portrait": presentation_files[
                        portrait_video_background_id
                    ]
                }
                if portrait_video_background_id
                else {}
            ),
            **(
                {
                    "video_background_landscape": presentation_files[
                        landscape_background_id
                    ]
                }
                if landscape_background_id
                else {}
            ),
            "settings_button": global_files["settings_button"],
            "speaker_on_button": global_files["speaker_on_button"],
            "speaker_muted_button": global_files["speaker_muted_button"],
            "progress_style": "runtime/progress-style.json",
            **(
                {
                    "video_presentation_inventory": (
                        "runtime/video-presentation-inventory.json"
                    ),
                    "video_progress_plaque": global_files["video_progress_plaque"],
                    "video_question_frame": global_files["video_question_frame"],
                    "video_answer_frame": global_files["video_answer_frame"],
                    "video_explanation_frame": global_files[
                        "video_explanation_frame"
                    ],
                    "video_badges": {
                        color: global_files[f"video_badge_{color}"]
                        for color in ("purple", "green", "orange", "blue")
                    },
                }
                if all(
                    asset_id in global_files
                    for asset_id in (
                        "video_progress_plaque",
                        "video_question_frame",
                        "video_answer_frame",
                        "video_explanation_frame",
                        "video_badge_purple",
                        "video_badge_green",
                        "video_badge_orange",
                        "video_badge_blue",
                    )
                )
                and video_inventory_source.is_file()
                else {}
            ),
        },
        "difficulties": difficulties,
        "quizzes": sorted(
            quizzes, key=lambda item: (item["difficulty"], item["number"])
        ),
        "answer_assets": animal_files,
        "source_banks": bank_summary,
        "review_policy": "pilot_assume_generated_assets_approved",
    }
    _write_json(staging / "category.json", category_document)
    if has_audio:
        _copy(category_audio_path, staging / "source/category-audio-manifest.json")
    return category_document


def _archive_content(content_dir: Path, archive: Path) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary = archive.with_suffix(".zip.tmp")
    with zipfile.ZipFile(
        temporary, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=6
    ) as handle:
        for path in sorted(item for item in content_dir.rglob("*") if item.is_file()):
            handle.write(path, path.relative_to(content_dir).as_posix())
    temporary.replace(archive)


def build_category_bundle(
    *,
    category: str,
    category_root: Path,
    global_root: Path,
    output_root: Path,
    display_title: str,
    display_tag: str | None = None,
    force_new_version: bool = False,
    activate: bool = True,
) -> dict[str, Any]:
    category_slug = _slug(category)
    category_output = output_root / category_slug
    category_output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=f"{category_slug}-bundle-", dir=output_root
    ) as temporary:
        staging = Path(temporary) / "content"
        staging.mkdir(parents=True)
        resolved_display_tag = (display_tag or category).strip()
        if not 1 <= len(resolved_display_tag) <= 12:
            raise ValueError("display tag must contain 1 to 12 characters")
        category_document = _build_payload(
            staging=staging,
            category=category,
            category_root=category_root,
            global_root=global_root,
            display_title=display_title,
            display_tag=resolved_display_tag,
        )
        payload_files = _file_inventory(staging)
        content_hash = _content_hash(payload_files)
        current = _current_record(category_output)
        matching = _record_with_content_hash(category_output, content_hash)
        if matching is not None and not force_new_version:
            if activate and (
                current is None
                or current.get("bundle_version") != matching.get("bundle_version")
            ):
                activate_category_bundle_version(
                    output_root=output_root,
                    category=category,
                    version=int(matching["bundle_version"]),
                )
            return matching

        version = _next_version(category_output)
        version_name = f"{version:06d}"
        version_root = category_output / "versions" / version_name
        content_root = version_root / "content"
        if version_root.exists():
            raise ValueError(f"bundle version already exists: {version_root}")
        version_root.mkdir(parents=True)
        bundle_metadata = {
            "schema_version": CATEGORY_BUNDLE_SCHEMA,
            "bundle_id": category_slug,
            "bundle_version": version,
            "content_hash": content_hash,
            "minimum_renderer_version": MINIMUM_RENDERER_VERSION,
            "category": category_document["category"],
            "quiz_count": len(category_document["quizzes"]),
            "question_count": sum(
                item["question_count"] for item in category_document["quizzes"]
            ),
            "generated_at_utc": _now(),
            "entrypoint": "category.json",
            "files": payload_files,
        }
        _write_json(staging / "bundle.json", bundle_metadata)
        shutil.move(str(staging), content_root)
        archive_name = f"{category_slug}-v{version_name}.zip"
        archive = version_root / archive_name
        _archive_content(content_root, archive)
        record_file = f"versions/{version_name}/record.json"
        record = {
            **bundle_metadata,
            "archive_file": f"versions/{version_name}/{archive_name}",
            "archive_bytes": archive.stat().st_size,
            "archive_sha256": _sha256(archive),
            "record_file": record_file,
        }
        _write_json(version_root / "record.json", record)
        if activate:
            _write_json(
                category_output / "current.json",
                {
                    "schema_version": "category_bundle_pointer_v1",
                    "category_id": category_slug,
                    "bundle_version": version,
                    "content_hash": content_hash,
                    "record_file": record_file,
                    "updated_at_utc": _now(),
                },
            )
        return record


def activate_category_bundle_version(
    *, output_root: Path, category: str, version: int
) -> dict[str, Any]:
    category_slug = _slug(category)
    category_output = output_root / category_slug
    version_name = f"{version:06d}"
    record_file = f"versions/{version_name}/record.json"
    record = _read_json(category_output / record_file)
    _write_json(
        category_output / "current.json",
        {
            "schema_version": "category_bundle_pointer_v1",
            "category_id": category_slug,
            "bundle_version": version,
            "content_hash": record["content_hash"],
            "record_file": record_file,
            "updated_at_utc": _now(),
        },
    )
    return record
