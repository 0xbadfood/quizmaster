from __future__ import annotations

import json
import zipfile
from pathlib import Path

from quiz_harness.category_bundle import (
    activate_category_bundle_version,
    build_category_bundle,
)
from quiz_harness.studio_publish import StudioPublishStore


def _write_json(path: Path, payload: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload), encoding="utf-8")


def _question(index: int) -> dict[str, object]:
    correct_ids = ["choice1"] * 3 + ["choice2"] * 3 + ["choice3"] * 2 + ["choice4"] * 2
    correct_id = correct_ids[index]
    choices = [
        {"choice_id": "choice1", "animal_key": "lion", "label": "Lion"},
        {"choice_id": "choice2", "animal_key": "tiger", "label": "Tiger"},
        {"choice_id": "choice3", "animal_key": "zebra", "label": "Zebra"},
        {"choice_id": "choice4", "animal_key": "elephant", "label": "Elephant"},
    ]
    answer = choices[int(correct_id[-1]) - 1]["label"]
    return {
        "question_id": f"animals_beginner_{index + 1:03d}",
        "topic_key": f"topic_{index + 1:03d}",
        "difficulty": "beginner",
        "question": f"Which animal matches clue number {index + 1}?",
        "choices": choices,
        "correct_choice_id": correct_id,
        "explanation": f"The correct animal is {answer}, which matches this test clue.",
    }


def _source_tree(root: Path) -> tuple[Path, Path]:
    category_root = root / "animals"
    global_root = root / "global"
    questions = [_question(index) for index in range(10)]
    quiz_set = {
        "schema_version": "visual_quiz_v1",
        "set_id": "animals_beginner_001",
        "category": "Animals",
        "difficulty": "beginner",
        "source_model": "test-model",
        "selection_model": "test-selector",
        "questions": questions,
    }
    _write_json(category_root / "sets/beginner/animals_beginner_001.json", quiz_set)
    _write_json(
        category_root / "banks/beginner/bank.json",
        {
            "schema_version": "visual_bank_v1",
            "category": "Animals",
            "difficulty": "beginner",
            "source_provider": "openai",
            "source_model": "test-model",
            "source_response_id": "test-response",
            "generated_at_utc": "2026-08-05T00:00:00+00:00",
            "questions": [{**question, "state": "available", "set_id": None} for question in questions],
            "ingestion_rejections": [],
        },
    )
    animal_labels = {"lion": "Lion", "tiger": "Tiger", "zebra": "Zebra", "elephant": "Elephant"}
    _write_json(
        category_root / "animal_catalog.json",
        {
            "schema_version": "animal_catalog_v1",
            "category": "Animals",
            "generated_at_utc": "2026-08-05T00:00:00+00:00",
            "animals": [
                {
                    "animal_key": key,
                    "label": label,
                    "aliases": [],
                    "image_path": f"assets/animals/{key}.webp",
                    "image_status": "pending",
                    "choice_count": 10,
                    "correct_answer_count": 2,
                    "question_ids": [question["question_id"] for question in questions],
                }
                for key, label in animal_labels.items()
            ],
        },
    )
    for key in animal_labels:
        path = category_root / f"assets/animals/{key}.webp"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(f"image-{key}".encode())

    category_assets = [
        {
            "asset_id": "animals_runtime_background",
            "role": "runtime_background",
            "file": "assets/category/background.png",
        },
        {
            "asset_id": "animals_category_selector",
            "role": "category_selector",
            "file": "assets/category/selector.webp",
        },
        {
            "asset_id": "tile_beginner_01",
            "role": "quiz_tile",
            "file": "assets/category/tiles/beginner_01.webp",
        },
    ]
    for asset in category_assets:
        path = category_root / asset["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(asset["asset_id"].encode())
    _write_json(category_root / "category-image-spec.json", {"assets": category_assets})
    _write_json(
        category_root / "category-image-manifest.json",
        {"assets": {asset["asset_id"]: {"status": "generated"} for asset in category_assets}},
    )
    _write_json(category_root / "answer-image-manifest.json", {"animals": {}})

    global_assets = [
        {"asset_id": "settings_button", "file": "assets/settings.webp"},
        {"asset_id": "speaker_on_button", "file": "assets/speaker-on.webp"},
        {"asset_id": "speaker_muted_button", "file": "assets/speaker-muted.webp"},
    ]
    for asset in global_assets:
        path = global_root / asset["file"]
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(asset["asset_id"].encode())
    _write_json(global_root / "global-image-spec.json", {"assets": global_assets})
    _write_json(
        global_root / "global-image-manifest.json",
        {"assets": {asset["asset_id"]: {"status": "generated"} for asset in global_assets}},
    )
    _write_json(global_root / "progress-style.json", {"schema_version": "test", "question_count": 10})
    return category_root, global_root


def test_build_resolves_multiword_category_assets_by_role(tmp_path: Path) -> None:
    category_root, global_root = _source_tree(tmp_path / "source")
    spec_path = category_root / "category-image-spec.json"
    spec = json.loads(spec_path.read_text())
    renames = {
        "animals_runtime_background": "world_history_runtime_background",
        "animals_category_selector": "world_history_category_selector",
    }
    for asset in spec["assets"]:
        asset["asset_id"] = renames.get(asset["asset_id"], asset["asset_id"])
    _write_json(spec_path, spec)

    manifest_path = category_root / "category-image-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    manifest["assets"] = {
        renames.get(asset_id, asset_id): record
        for asset_id, record in manifest["assets"].items()
    }
    _write_json(manifest_path, manifest)

    record = build_category_bundle(
        category="World History",
        category_root=category_root,
        global_root=global_root,
        output_root=tmp_path / "dist",
        display_title="WORLD HISTORY QUIZ",
        display_tag="History",
    )

    content = tmp_path / "dist/world-history/versions/000001/content"
    category = json.loads((content / "category.json").read_text())
    assert record["bundle_id"] == "world-history"
    assert category["category"]["display_tag"] == "History"
    assert category["category"]["selector_asset"].endswith(
        "world_history_category_selector.webp"
    )


def test_build_reuses_unchanged_content_and_can_activate_old_version(tmp_path: Path) -> None:
    category_root, global_root = _source_tree(tmp_path / "source")
    output_root = tmp_path / "dist"
    kwargs = {
        "category": "Animals",
        "category_root": category_root,
        "global_root": global_root,
        "output_root": output_root,
        "display_title": "ANIMAL QUIZ",
        "display_tag": "Animals",
    }

    first = build_category_bundle(**kwargs)
    unchanged = build_category_bundle(**kwargs)
    assert first["bundle_version"] == unchanged["bundle_version"] == 1
    assert first["content_hash"] == unchanged["content_hash"]
    assert first["quiz_count"] == 1
    assert first["question_count"] == 10

    archive = output_root / "animals" / first["archive_file"]
    with zipfile.ZipFile(archive) as bundle:
        names = set(bundle.namelist())
    assert "bundle.json" in names
    assert "category.json" in names
    assert "quizzes/beginner/animals_beginner_001.json" in names
    assert "assets/answers/lion.webp" in names

    _write_json(global_root / "progress-style.json", {"schema_version": "test", "question_count": 10, "changed": True})
    second = build_category_bundle(**kwargs)
    assert second["bundle_version"] == 2
    assert second["content_hash"] != first["content_hash"]

    activated = activate_category_bundle_version(
        output_root=output_root, category="Animals", version=1
    )
    current = json.loads((output_root / "animals/current.json").read_text())
    assert activated["bundle_version"] == current["bundle_version"] == 1


def test_build_includes_only_category_specific_audio(tmp_path: Path) -> None:
    category_root, global_root = _source_tree(tmp_path / "source")
    praise_clips = []
    for index in range(1, 6):
        relative = f"audio/praise/praise_{index:02d}.mp3"
        path = global_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"praise")
        praise_clips.append(
            {
                "id": f"praise_{index:02d}",
                "text": f"Praise {index}",
                "file": relative,
            }
        )
    for relative in ("audio/correct_chime.mp3", "audio/incorrect_buzzer.mp3"):
        path = global_root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"effect")
    _write_json(
        global_root / "audio/audio-manifest.json",
        {
            "correct_sfx": "audio/correct_chime.mp3",
            "incorrect_sfx": "audio/incorrect_buzzer.mp3",
            "praise_clips": praise_clips,
        },
    )

    question_audio = {}
    for index in range(10):
        question_id = f"animals_beginner_{index + 1:03d}"
        question_file = f"audio/questions/{question_id}.mp3"
        explanation_file = f"audio/explanations/{question_id}.mp3"
        for relative in (question_file, explanation_file):
            path = category_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(b"speech")
        question_audio[question_id] = {
            "question": question_file,
            "explanation": explanation_file,
        }
    _write_json(
        category_root / "audio/audio-manifest.json",
        {"questions": question_audio},
    )

    record = build_category_bundle(
        category="Animals",
        category_root=category_root,
        global_root=global_root,
        output_root=tmp_path / "dist",
        display_title="ANIMAL QUIZ",
    )
    content = tmp_path / "dist/animals/versions/000001/content"
    category = json.loads((content / "category.json").read_text())
    quiz = json.loads(
        (content / "quizzes/beginner/animals_beginner_001.json").read_text()
    )

    assert "audio" not in category["presentation"]
    assert quiz["questions"][0]["audio"]["question"].endswith(".mp3")
    assert not (content / "assets/audio/global").exists()
    assert record["bundle_version"] == 1


def test_studio_publish_requires_audited_audio_and_tracks_releases(
    tmp_path: Path,
) -> None:
    source_root = tmp_path / "source"
    category_root, _ = _source_tree(source_root)
    output_root = tmp_path / "dist"
    store = StudioPublishStore(source_root, output_root)
    category = {
        "slug": "animals",
        "name": "Animals",
        "display_title": "ANIMAL QUIZ",
        "display_tag": "Animals",
        "editorial_brief": "Animal identification, habitats, adaptations, and behavior.",
        "age_min": 5,
        "age_max": 8,
    }

    blocked = store.inventory(category)
    assert blocked["ready"] is False
    assert next(item for item in blocked["gates"] if item["id"] == "audio")[
        "current"
    ] == 0

    audio_questions = {}
    for index in range(10):
        question_id = f"animals_beginner_{index + 1:03d}"
        record = {}
        for kind in ("question", "explanation"):
            relative = f"audio/{kind}s/{question_id}.mp3"
            path = category_root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(f"{question_id}-{kind}".encode())
            record[kind] = relative
            record[f"{kind}_audit"] = {"status": "passed", "wer": 0.0}
        audio_questions[question_id] = record
    _write_json(
        category_root / "audio/audio-manifest.json",
        {"questions": audio_questions},
    )

    ready = store.inventory(category)
    assert ready["ready"] is True
    assert ready["summary"]["audited_clips"] == 20
    messages = []
    first = store.publish(
        category=category,
        force_new_version=False,
        progress=lambda message, progress: messages.append((message, progress)),
    )
    assert first["bundle_version"] == 1
    assert first["reused_existing_version"] is False
    assert messages[-1][0] == "Verifying release archive"

    unchanged = store.publish(
        category=category,
        force_new_version=False,
        progress=lambda *_: None,
    )
    assert unchanged["bundle_version"] == 1
    assert unchanged["reused_existing_version"] is True

    inventory = store.inventory(category)
    assert inventory["current"]["bundle_version"] == 1
    assert inventory["versions"][0]["archive_exists"] is True
    archive, record = store.archive("animals", 1)
    assert archive.is_file()
    assert record["archive_sha256"] == first["archive_sha256"]

    activated = store.activate(category=category, version=1)
    assert activated["bundle_version"] == 1

    changed_category = {**category, "display_tag": "Animal Fun"}
    stale = store.inventory(changed_category)
    assert stale["redeploy_required"] is True
    assert any("publish a new version" in warning for warning in stale["warnings"])

    redeployed = store.publish(
        category=changed_category,
        force_new_version=False,
        progress=lambda *_: None,
    )
    assert redeployed["bundle_version"] == 2
    assert redeployed["reused_existing_version"] is False
