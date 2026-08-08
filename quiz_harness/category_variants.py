from __future__ import annotations

import hashlib
import json
import tempfile
from pathlib import Path
from typing import Any
from zipfile import ZIP_DEFLATED, ZipFile


FREE_DIFFICULTY = "beginner"
FREE_LIMIT = 1


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _json_bytes(payload: dict[str, Any]) -> bytes:
    return (
        json.dumps(payload, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    ).encode("utf-8")


def _read_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return value


def _zip_json(bundle: ZipFile, name: str) -> dict[str, Any]:
    value = json.loads(bundle.read(name).decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"expected a JSON object at {name}")
    return value


def _manifest_entry(name: str, data: bytes) -> dict[str, Any]:
    return {"path": name, "bytes": len(data), "sha256": _sha256(data)}


def current_record_paths(root: Path) -> list[Path]:
    records: list[Path] = []
    if not root.is_dir():
        return records
    for category_root in sorted(item for item in root.iterdir() if item.is_dir()):
        pointer_path = category_root / "current.json"
        if not pointer_path.is_file():
            continue
        pointer = _read_json(pointer_path)
        record_file = str(pointer.get("record_file") or "")
        if not record_file.startswith("versions/"):
            continue
        record_path = category_root / record_file
        if record_path.is_file():
            records.append(record_path)
    return records


def _free_quizzes(category: dict[str, Any]) -> list[dict[str, Any]]:
    quizzes = [
        item for item in category.get("quizzes", []) if isinstance(item, dict)
    ]
    selected = [
        item
        for item in quizzes
        if str(item.get("difficulty") or "").strip().casefold() == FREE_DIFFICULTY
    ][:FREE_LIMIT]
    return selected or quizzes[:FREE_LIMIT]


def _free_paths(
    bundle: ZipFile,
    free_quizzes: list[dict[str, Any]],
) -> set[str]:
    names = set(bundle.namelist())
    keep = {
        name
        for name in names
        if name != "bundle.json"
        and not name.startswith("source/")
        and not name.startswith("quizzes/")
        and not name.startswith("assets/answers/")
        and not name.startswith("assets/audio/questions/")
        and not name.startswith("assets/audio/explanations/")
    }
    keep.add("category.json")
    for summary in free_quizzes:
        questions_file = str(summary.get("questions_file") or "")
        if not questions_file or questions_file not in names:
            raise ValueError(
                f"free quiz payload is missing from full bundle: {questions_file}"
            )
        keep.add(questions_file)
        quiz = _zip_json(bundle, questions_file)
        answer_assets = quiz.get("answer_assets", {})
        if not isinstance(answer_assets, dict):
            raise ValueError(f"quiz answer asset map is invalid: {questions_file}")
        for question in quiz.get("questions", []):
            if not isinstance(question, dict):
                continue
            audio = question.get("audio", {})
            if isinstance(audio, dict):
                for kind in ("question", "explanation"):
                    path = audio.get(kind)
                    if isinstance(path, str) and path in names:
                        keep.add(path)
            for choice in question.get("choices", []):
                if not isinstance(choice, dict):
                    continue
                path = answer_assets.get(str(choice.get("animal_key") or ""))
                if isinstance(path, str) and path in names:
                    keep.add(path)
    return keep


def _full_variant(record: dict[str, Any]) -> dict[str, Any]:
    excluded = {"free_variant", "access_variants"}
    variant = {key: value for key, value in record.items() if key not in excluded}
    variant.update(
        {
            "access_variant": "full_library",
            "source_content_hash": record["content_hash"],
            "available_quiz_count": int(record["quiz_count"]),
            "available_question_count": int(record["question_count"]),
        }
    )
    return variant


def _runtime_category(category: dict[str, Any]) -> dict[str, Any]:
    runtime = dict(category)
    runtime.pop("source_banks", None)
    runtime.pop("answer_assets", None)
    return runtime


def create_free_variant(record_path: Path, *, force: bool = False) -> dict[str, Any]:
    record_path = record_path.resolve()
    category_root = record_path.parents[2]
    record = _read_json(record_path)
    archive_file = str(record.get("archive_file") or "")
    if not archive_file.startswith("versions/"):
        raise ValueError(f"invalid archive path in {record_path}")
    source_archive = category_root / archive_file
    if not source_archive.is_file():
        raise ValueError(f"full archive is missing: {source_archive}")
    version = int(record["bundle_version"])
    bundle_id = str(record["bundle_id"])
    free_archive_file = (
        f"versions/{version:06d}/{bundle_id}-v{version:06d}-free.zip"
    )
    free_archive = category_root / free_archive_file
    existing = record.get("access_variants", {}).get("free")
    if not force and isinstance(existing, dict) and free_archive.is_file():
        return {"status": "reused", "record": record, "variant": existing}

    with ZipFile(source_archive, "r") as source:
        category = _zip_json(source, "category.json")
        selected = _free_quizzes(category)
        if not selected:
            raise ValueError(f"category has no quizzes: {bundle_id}")
        paths = _free_paths(source, selected)
        payloads = {name: source.read(name) for name in sorted(paths)}
        payloads["category.json"] = _json_bytes(_runtime_category(category))
        files = [_manifest_entry(name, data) for name, data in payloads.items()]
        free_ids = [str(item["quiz_id"]) for item in selected]
        content_hash = _sha256(
            json.dumps(
                {
                    "source_content_hash": record["content_hash"],
                    "access_variant": "free",
                    "free_quiz_ids": free_ids,
                    "files": files,
                },
                sort_keys=True,
                separators=(",", ":"),
            ).encode("utf-8")
        )
        bundle = _zip_json(source, "bundle.json")
        bundle.update(
            {
                "content_hash": content_hash,
                "access_variant": "free",
                "source_content_hash": record["content_hash"],
                "available_quiz_count": len(selected),
                "available_question_count": sum(
                    int(item.get("question_count") or 0) for item in selected
                ),
                "free_quiz_ids": free_ids,
                "files": files,
            }
        )

    free_archive.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        prefix=f"{bundle_id}-free-",
        suffix=".zip",
        dir=free_archive.parent,
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
    try:
        with ZipFile(temporary, "w", compression=ZIP_DEFLATED, compresslevel=6) as target:
            for name, data in payloads.items():
                target.writestr(name, data)
            target.writestr("bundle.json", _json_bytes(bundle))
        temporary.replace(free_archive)
    finally:
        if temporary.exists():
            temporary.unlink()

    free_variant = {
        **_full_variant(record),
        "content_hash": content_hash,
        "archive_file": free_archive_file,
        "archive_bytes": free_archive.stat().st_size,
        "archive_sha256": _sha256(free_archive.read_bytes()),
        "access_variant": "free",
        "source_content_hash": record["content_hash"],
        "available_quiz_count": len(selected),
        "available_question_count": sum(
            int(item.get("question_count") or 0) for item in selected
        ),
        "free_quiz_ids": free_ids,
        "files": files,
    }
    full_variant = _full_variant(record)
    record["free_variant"] = free_variant
    record["access_variants"] = {
        "free": free_variant,
        "full_library": full_variant,
    }
    record_path.write_text(
        json.dumps(record, ensure_ascii=True, indent=2) + "\n", encoding="utf-8"
    )
    return {"status": "created", "record": record, "variant": free_variant}
