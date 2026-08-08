from __future__ import annotations

import hashlib
import json
from pathlib import Path

from quiz_harness.studio_audio import StudioAudioStore


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode()).hexdigest()


def test_empty_category_audio_inventory_is_blocked_not_exceptional(
    tmp_path: Path,
) -> None:
    result = StudioAudioStore(tmp_path / "source").inventory(
        {"slug": "ancient-civilizations", "name": "Ancient Civilizations"}
    )

    assert result["ready"] is False
    assert result["questions"] == []
    assert result["blocked_reason"] == "select at least one quiz set before generating audio"


def test_audio_inventory_reports_clip_level_audit_states(tmp_path: Path) -> None:
    root = tmp_path / "source/animals"
    set_path = root / "sets/beginner/animals_beginner_001.json"
    set_path.parent.mkdir(parents=True)
    set_path.write_text(
        json.dumps(
            {
                "set_id": "animals_beginner_001",
                "difficulty": "beginner",
                "questions": [
                    {
                        "question_id": "animal_001",
                        "question": "Which animal has a long trunk?",
                        "explanation": "An elephant uses its trunk to grasp and drink.",
                    },
                    {
                        "question_id": "animal_002",
                        "question": "Which animal has black and white stripes?",
                        "explanation": "A zebra has black and white stripes.",
                    },
                ],
            }
        ),
        encoding="utf-8",
    )
    question_file = root / "audio/questions/animal_001.mp3"
    explanation_file = root / "audio/explanations/animal_001.mp3"
    legacy_file = root / "audio/questions/animal_002.mp3"
    for path in (question_file, explanation_file, legacy_file):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"mp3")
    manifest = {
        "questions": {
            "animal_001": {
                "question": "audio/questions/animal_001.mp3",
                "explanation": "audio/explanations/animal_001.mp3",
                "question_sha256": _hash("Which animal has a long trunk?"),
                "explanation_sha256": _hash(
                    "An elephant uses its trunk to grasp and drink."
                ),
                "question_audit": {"status": "passed", "wer": 0.0},
                "explanation_audit": {
                    "status": "failed",
                    "wer": 0.4,
                    "reasons": ["text_mismatch"],
                },
            },
            "animal_002": {
                "question": "audio/questions/animal_002.mp3",
                "explanation": "audio/explanations/animal_002.mp3",
                "question_sha256": _hash(
                    "Which animal has black and white stripes?"
                ),
                "explanation_sha256": _hash(
                    "A zebra has black and white stripes."
                ),
            },
        }
    }
    manifest_path = root / "audio/audio-manifest.json"
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    store = StudioAudioStore(tmp_path / "source")
    category = {"slug": "animals", "name": "Animals"}
    inventory = store.inventory(category)

    assert inventory["summary"] == {
        "questions": 2,
        "clips_total": 4,
        "generated": 3,
        "passed": 1,
        "missing": 1,
        "failed": 1,
        "stale": 0,
        "unaudited": 1,
        "attention": 2,
        "question_statuses": {"failed": 1, "partial": 1},
    }
    first = inventory["questions"][0]
    assert first["question_audio"]["status"] == "passed"
    assert first["explanation_audio"]["status"] == "failed"
    assert first["question_audio"]["audio_url"].endswith(
        "/audio/questions/animal_001.mp3"
    )

    accepted = store.review_clip(
        category=category,
        clip_id="animal_001/explanation",
        decision="accept",
    )
    assert accepted["clip"]["status"] == "passed"
    assert accepted["clip"]["audit"]["automatic_status"] == "failed"
    assert accepted["clip"]["audit"]["manual_review"]["status"] == "accepted"
    assert accepted["summary"]["passed"] == 2
    assert accepted["summary"]["attention"] == 1

    reset = store.review_clip(
        category=category,
        clip_id="animal_001/explanation",
        decision="reset",
    )
    assert reset["clip"]["status"] == "failed"
    assert "manual_review" not in reset["clip"]["audit"]
    assert "automatic_status" not in reset["clip"]["audit"]
    assert reset["summary"]["passed"] == 1
    assert reset["summary"]["attention"] == 2
