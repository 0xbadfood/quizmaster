from __future__ import annotations

import hashlib
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

from quiz_harness.category_variants import create_free_variant


def _write_full_release(root: Path) -> Path:
    category_root = root / "animals"
    version_root = category_root / "versions/000001"
    archive = version_root / "animals-v000001.zip"
    archive.parent.mkdir(parents=True)
    category = {
        "source_banks": [
            {"difficulty": "beginner", "file": "source/banks/beginner.json"}
        ],
        "answer_assets": {
            "lion": "assets/answers/lion.webp",
            "tiger": "assets/answers/tiger.webp",
        },
        "quizzes": [
            {
                "quiz_id": "animals_beginner_001",
                "difficulty": "beginner",
                "question_count": 10,
                "tile_asset": "assets/tiles/beginner_01.webp",
                "questions_file": "quizzes/beginner/animals_beginner_001.json",
            },
            {
                "quiz_id": "animals_intermediate_001",
                "difficulty": "intermediate",
                "question_count": 10,
                "tile_asset": "assets/tiles/intermediate_01.webp",
                "questions_file": "quizzes/intermediate/animals_intermediate_001.json",
            },
        ]
    }

    def quiz(question_id: str, answer: str) -> dict[str, object]:
        return {
            "questions": [
                {
                    "question_id": question_id,
                    "choices": [{"animal_key": answer}],
                    "audio": {
                        "question": f"assets/audio/questions/{question_id}.mp3",
                        "explanation": f"assets/audio/explanations/{question_id}.mp3",
                    },
                }
            ],
            "answer_assets": {answer: f"assets/answers/{answer}.webp"},
        }

    payloads: dict[str, bytes] = {
        "category.json": json.dumps(category).encode(),
        "bundle.json": json.dumps(
            {
                "bundle_id": "animals",
                "bundle_version": 1,
                "content_hash": "full-content",
                "quiz_count": 2,
                "question_count": 20,
                "files": [],
            }
        ).encode(),
        "assets/category/selector.webp": b"selector",
        "assets/tiles/beginner_01.webp": b"beginner-tile",
        "assets/tiles/intermediate_01.webp": b"intermediate-tile",
        "quizzes/beginner/animals_beginner_001.json": json.dumps(
            quiz("beginner_q1", "lion")
        ).encode(),
        "quizzes/intermediate/animals_intermediate_001.json": json.dumps(
            quiz("intermediate_q1", "tiger")
        ).encode(),
        "assets/answers/lion.webp": b"lion",
        "assets/answers/tiger.webp": b"tiger",
        "assets/audio/questions/beginner_q1.mp3": b"beginner question",
        "assets/audio/explanations/beginner_q1.mp3": b"beginner explanation",
        "assets/audio/questions/intermediate_q1.mp3": b"locked question",
        "assets/audio/explanations/intermediate_q1.mp3": b"locked explanation",
        "source/banks/intermediate.json": b"locked source bank",
    }
    with ZipFile(archive, "w", compression=ZIP_DEFLATED) as bundle:
        for name, data in payloads.items():
            bundle.writestr(name, data)
    record = {
        "schema_version": "category_bundle_v1",
        "bundle_id": "animals",
        "bundle_version": 1,
        "content_hash": "full-content",
        "minimum_renderer_version": 1,
        "category": {"id": "animals", "name": "Animals"},
        "quiz_count": 2,
        "question_count": 20,
        "generated_at_utc": "2026-08-08T00:00:00+00:00",
        "entrypoint": "category.json",
        "files": [],
        "archive_file": "versions/000001/animals-v000001.zip",
        "archive_bytes": archive.stat().st_size,
        "archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(),
        "record_file": "versions/000001/record.json",
    }
    record_path = version_root / "record.json"
    record_path.write_text(json.dumps(record), encoding="utf-8")
    return record_path


def test_free_variant_keeps_catalog_tiles_and_only_playable_dependencies(
    tmp_path: Path,
) -> None:
    record_path = _write_full_release(tmp_path)

    result = create_free_variant(record_path)
    variant = result["variant"]
    archive = record_path.parents[2] / variant["archive_file"]

    with ZipFile(archive) as bundle:
        names = set(bundle.namelist())
        metadata = json.loads(bundle.read("bundle.json"))
        category = json.loads(bundle.read("category.json"))

    assert "category.json" in names
    assert "assets/tiles/beginner_01.webp" in names
    assert "assets/tiles/intermediate_01.webp" in names
    assert "quizzes/beginner/animals_beginner_001.json" in names
    assert "quizzes/intermediate/animals_intermediate_001.json" not in names
    assert "assets/answers/lion.webp" in names
    assert "assets/answers/tiger.webp" not in names
    assert "assets/audio/questions/beginner_q1.mp3" in names
    assert "assets/audio/questions/intermediate_q1.mp3" not in names
    assert not any(name.startswith("source/") for name in names)
    assert "source_banks" not in category
    assert "answer_assets" not in category
    assert {item["path"] for item in metadata["files"]} == names - {"bundle.json"}
    assert metadata["free_quiz_ids"] == ["animals_beginner_001"]

    record = json.loads(record_path.read_text())
    assert record["access_variants"]["free"]["archive_sha256"] == variant[
        "archive_sha256"
    ]
    assert record["access_variants"]["full_library"]["archive_file"].endswith(
        "animals-v000001.zip"
    )
