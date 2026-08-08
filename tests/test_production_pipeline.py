from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from quiz_harness.production_pipeline import (
    CategoryProductionPipeline,
    CategoryPipelineMetadata,
    PipelineCheckpoint,
    load_pipeline_metadata,
)


def _metadata(**overrides: object) -> dict[str, object]:
    value: dict[str, object] = {
        "name": "Space and Astronomy",
        "slug": "space-and-astronomy",
        "display_title": "SPACE QUIZ",
        "display_tag": "Space",
        "description": "A visual quiz about space and astronomy.",
        "editorial_brief": (
            "Use deterministic astronomy facts and concrete visual answer choices."
        ),
        "age_min": 5,
        "age_max": 10,
    }
    value.update(overrides)
    return value


def test_pipeline_metadata_file_is_strict_and_supports_multiword_names(
    tmp_path: Path,
) -> None:
    path = tmp_path / "metadata.json"
    path.write_text(json.dumps(_metadata()), encoding="utf-8")

    metadata = load_pipeline_metadata(path)

    assert metadata.name == "Space and Astronomy"
    assert metadata.display_tag == "Space"


@pytest.mark.parametrize(
    ("field", "value"),
    (("display_tag", "More Than 12 Chars"), ("slug", "Not a safe slug")),
)
def test_pipeline_metadata_rejects_unsafe_identity_fields(
    field: str, value: str
) -> None:
    with pytest.raises(ValidationError):
        CategoryPipelineMetadata.model_validate(_metadata(**{field: value}))


def test_pipeline_checkpoint_merges_phase_updates_and_survives_reload(
    tmp_path: Path,
) -> None:
    path = tmp_path / "pipeline-run.json"
    checkpoint = PipelineCheckpoint(path, "space-and-astronomy")
    checkpoint.update(
        "question_banks",
        {"status": "running", "difficulties": {"beginner": {"total": 50}}},
    )
    checkpoint.update("question_banks", {"status": "complete"})

    reloaded = PipelineCheckpoint(path, "space-and-astronomy")
    phase = reloaded.phase("question_banks")

    assert phase["status"] == "complete"
    assert phase["difficulties"]["beginner"]["total"] == 50
    assert not path.with_suffix(".json.tmp").exists()


def test_bank_scheduler_uses_six_total_balanced_batches(monkeypatch: pytest.MonkeyPatch) -> None:
    totals = {"beginner": 0, "intermediate": 0}
    calls: list[str] = []

    class Database:
        @staticmethod
        def studio_categories() -> list[dict[str, object]]:
            return []

    class Questions:
        @staticmethod
        def import_questions(
            category: dict[str, object],
            difficulty: str,
            candidates: list[dict[str, object]],
            **_: object,
        ) -> dict[str, int]:
            totals[difficulty] += len(candidates)
            return {"accepted": len(candidates), "rejected": 0}

    class Checkpoint:
        updates: list[dict[str, object]] = []

        @staticmethod
        def phase(name: str) -> dict[str, object]:
            return {}

        def update(self, name: str, value: dict[str, object]) -> None:
            self.updates.append(value)

    def generate(**kwargs: object) -> tuple[list[dict[str, object]], str]:
        calls.append(str(kwargs["difficulty"]))
        return ([{}] * 50, "gpt-5.6-luna")

    monkeypatch.setattr("quiz_harness.production_pipeline.generate_questions", generate)
    pipeline = object.__new__(CategoryProductionPipeline)
    pipeline.config = SimpleNamespace(
        question_provider_id="openai-images",
        question_model="gpt-5.6-luna",
        target_questions=150,
        question_batch_size=50,
        max_question_batches=6,
    )
    pipeline.database = Database()
    pipeline.questions = Questions()
    pipeline.checkpoint = Checkpoint()
    pipeline._provider = lambda *_: {"id": "openai-images"}
    pipeline._secret = lambda *_: "secret"
    pipeline._bank_total = lambda _slug, difficulty: totals[difficulty]
    pipeline._log = lambda *_: None

    result = pipeline._generate_banks({"slug": "space", "name": "Space"})

    assert calls == [
        "beginner",
        "intermediate",
        "beginner",
        "intermediate",
        "beginner",
        "intermediate",
    ]
    assert result["beginner"]["total"] == 150
    assert result["intermediate"]["total"] == 150
    assert pipeline.checkpoint.updates[-1]["batches_used"] == 6
