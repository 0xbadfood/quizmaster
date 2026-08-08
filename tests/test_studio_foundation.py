import json
from pathlib import Path

from quiz_harness.database import QuizDatabase
from quiz_harness.studio_catalog import category_production_summary


def test_provider_connections_and_jobs_are_persistent(tmp_path: Path) -> None:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.migrate()
    database.seed_provider_connections(
        [
            {
                "id": "llm-one",
                "provider_type": "openai_compatible_llm",
                "name": "Local LLM",
                "base_url": "http://127.0.0.1:8001/v1",
            }
        ]
    )
    provider = database.provider_connection("llm-one")
    assert provider["health_status"] == "unchecked"

    updated = database.update_provider_health(
        "llm-one",
        status="healthy",
        message="Connected",
        checked_at="2026-08-05T12:00:00+00:00",
        models=["qwen-test"],
    )
    assert updated["default_model"] == "qwen-test"
    assert updated["discovered_models"] == ["qwen-test"]

    database.create_studio_job(
        {
            "id": "job-one",
            "kind": "provider_test",
            "status": "queued",
            "message": "Queued",
            "progress": 0,
            "context": {"provider_id": "llm-one"},
            "created_at": "2026-08-05T12:01:00+00:00",
            "updated_at": "2026-08-05T12:01:00+00:00",
        }
    )
    completed = database.update_studio_job(
        "job-one",
        status="complete",
        message="Complete",
        progress=1,
        result={"sample": "Quiz Studio ready"},
        updated_at="2026-08-05T12:02:00+00:00",
    )
    assert completed["result"]["sample"] == "Quiz Studio ready"
    assert len(database.studio_job_events("job-one")) == 2

    reopened = QuizDatabase(tmp_path / "quiz.db")
    assert reopened.studio_job("job-one")["status"] == "complete"


def test_empty_draft_category_reports_metadata_and_pipeline_gates(tmp_path: Path) -> None:
    category = {
        "id": 9,
        "slug": "ancient-civilizations",
        "name": "Ancient Civilizations",
        "display_title": "",
        "display_tag": "",
        "editorial_brief": "",
        "description": "",
        "age_min": 7,
        "age_max": 10,
        "production_status": "draft",
    }

    summary = category_production_summary(
        category,
        source_root=tmp_path / "source",
        bundle_root=tmp_path / "bundles",
    )
    stages = {item["id"]: item for item in summary["stages"]}

    assert summary["metadata"]["ready"] is False
    assert summary["workspace_available"] is False
    assert stages["metadata"]["status"] == "attention"
    assert stages["questions"]["current"] == 0
    assert stages["sets"]["status"] == "blocked"
    assert summary["next_action"]["id"] == "metadata"

def test_category_summary_reads_real_production_artifacts(tmp_path: Path) -> None:
    source = tmp_path / "source/road-and-emergency-vehicles"
    for difficulty in ("beginner", "intermediate"):
        bank = source / "banks" / difficulty / "bank.json"
        bank.parent.mkdir(parents=True, exist_ok=True)
        bank.write_text(
            json.dumps(
                {
                    "questions": [
                        {"question_id": f"{difficulty}-{index}", "state": "allocated"}
                        for index in range(120)
                    ]
                }
            ),
            encoding="utf-8",
        )
        set_root = source / "sets" / difficulty
        set_root.mkdir(parents=True, exist_ok=True)
        for index in range(10):
            (set_root / f"set-{index}.json").write_text("{}", encoding="utf-8")
    (source / "answer-image-manifest.json").write_text(
        json.dumps(
            {
                "assets": {
                    "fire_truck": {"status": "generated_pending_review"},
                    "ambulance": {"status": "approved"},
                }
            }
        ),
        encoding="utf-8",
    )
    bundle_root = tmp_path / "bundles/road-and-emergency-vehicles"
    bundle_root.mkdir(parents=True)
    (bundle_root / "current.json").write_text(
        json.dumps({"bundle_version": 2}), encoding="utf-8"
    )

    summary = category_production_summary(
        {
            "id": 7,
            "slug": "road-and-emergency-vehicles",
            "name": "Road and Emergency Vehicles",
        },
        source_root=tmp_path / "source",
        bundle_root=tmp_path / "bundles",
    )

    assert summary["bank"] == {
        "beginner": 120,
        "intermediate": 120,
        "allocated": 240,
    }
    assert summary["sets"] == {"beginner": 10, "intermediate": 10}
    assert summary["answer_images"]["generated"] == 2
    assert summary["bundle"]["bundle_version"] == 2


def test_category_pipeline_uses_actual_set_count_not_ten_set_gate(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source/birds"
    set_root = source / "sets/beginner"
    set_root.mkdir(parents=True)
    for index in range(1, 4):
        (set_root / f"birds_beginner_{index:03d}.json").write_text(
            "{}", encoding="utf-8"
        )
    audio_root = source / "audio"
    audio_root.mkdir(parents=True)
    (audio_root / "audio-manifest.json").write_text(
        json.dumps(
            {
                "questions": {
                    f"birds_beginner_{index:03d}": {}
                    for index in range(1, 31)
                }
            }
        ),
        encoding="utf-8",
    )

    summary = category_production_summary(
        {"id": 2, "slug": "birds", "name": "Birds"},
        source_root=tmp_path / "source",
        bundle_root=tmp_path / "bundles",
    )
    stages = {item["id"]: item for item in summary["stages"]}
    assert stages["sets"]["status"] == "ready"
    assert stages["sets"]["target"] is None
    assert stages["sets"]["recommended_target"] == 20
    assert stages["audio"]["target"] == 30
    assert stages["audio"]["status"] == "ready"
