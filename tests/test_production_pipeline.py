from __future__ import annotations

import json
import threading
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
        def quarantine_contract_invalid(
            category_slug: str, difficulty: str
        ) -> dict[str, object]:
            return {"quarantined": 0, "question_ids": []}

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


def test_existing_background_is_reused_without_planning(tmp_path: Path) -> None:
    runtime = tmp_path / "space" / "assets/category/runtime_background.png"
    runtime.parent.mkdir(parents=True)
    from PIL import Image

    Image.new("RGB", (941, 1672), "navy").save(runtime)

    class Visuals:
        @staticmethod
        def category_root(slug: str) -> Path:
            return tmp_path / slug

    class Checkpoint:
        updates: list[tuple[str, dict[str, object]]] = []

        def update(self, name: str, value: dict[str, object]) -> None:
            self.updates.append((name, value))

    pipeline = object.__new__(CategoryProductionPipeline)
    pipeline.config = SimpleNamespace(
        background=None,
        force_background=False,
        refresh_background_plan=False,
    )
    pipeline.visuals = Visuals()
    pipeline.checkpoint = Checkpoint()
    pipeline._log = lambda *_: None

    result = pipeline._ensure_background({"slug": "space"})

    assert result["reused"] is True
    assert pipeline.checkpoint.updates[-1][1]["source"] == "existing"


def test_missing_background_is_planned_rendered_and_registered(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: dict[str, dict[str, object]] = {}

    class Plan:
        prompt = "A complete portrait renderer prompt long enough for the image model."

        @staticmethod
        def model_dump(*, mode: str) -> dict[str, object]:
            assert mode == "json"
            return {"prompt": Plan.prompt}

    class Visuals:
        uploaded: bytes | None = None

        @staticmethod
        def category_root(slug: str) -> Path:
            return tmp_path / slug

        def upload_background(
            self, category: dict[str, object], data: bytes, content_type: str
        ) -> dict[str, str]:
            assert category["slug"] == "space"
            assert content_type == "image/png"
            self.uploaded = data
            return {"asset_id": "runtime_background", "status": "approved"}

    class Checkpoint:
        def update(self, _name: str, _value: dict[str, object]) -> None:
            return None

    def plan(**kwargs: object) -> dict[str, object]:
        calls["plan"] = kwargs
        return {
            "plan": Plan(),
            "provider_id": "llm-default",
            "model": "qwen",
            "file": str(kwargs["output"]),
            "reused": False,
        }

    def generate(**kwargs: object) -> dict[str, object]:
        calls["generate"] = kwargs
        output = Path(str(kwargs["output"]))
        output.parent.mkdir(parents=True, exist_ok=True)
        from PIL import Image

        Image.new("RGB", (941, 1672), "navy").save(output)
        return {"image": {"file": str(output)}, "reused": False}

    monkeypatch.setattr(
        "quiz_harness.production_pipeline.plan_quiz_background_prompt", plan
    )
    monkeypatch.setattr(
        "quiz_harness.production_pipeline.generate_quiz_background", generate
    )
    pipeline = object.__new__(CategoryProductionPipeline)
    pipeline.config = SimpleNamespace(
        background=None,
        force_background=False,
        refresh_background_plan=False,
        background_guidance="Include an observatory.",
        background_provider_id="openai-images",
        background_model=None,
        qwen_provider_id="llm-default",
        qwen_model=None,
        database_path=tmp_path / "quiz.db",
        secret_key_file=tmp_path / "secret.key",
        image_quality="medium",
        seed=42,
    )
    pipeline.visuals = Visuals()
    pipeline.checkpoint = Checkpoint()
    pipeline._log = lambda *_: None

    result = pipeline._ensure_background(
        {
            "slug": "space",
            "name": "Space",
            "display_title": "SPACE QUIZ",
            "editorial_brief": "Use concrete astronomy subjects.",
        }
    )

    assert result["source"] == "generated"
    assert pipeline.visuals.uploaded
    assert calls["plan"]["provider_id"] == "llm-default"
    assert "Include an observatory." in str(calls["plan"]["category_guidance"])
    assert calls["generate"]["provider_id"] == "openai-images"
    assert calls["generate"]["prompt_override"] == Plan.prompt


def test_visual_generation_consumes_committed_batch_before_planning_finishes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    generated = threading.Event()
    planner_observed_generation = False

    class Client:
        def __init__(self, *_args: object, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> "Client":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

    class Visuals:
        def plan_prompts(self, **kwargs: object) -> dict[str, object]:
            nonlocal planner_observed_generation
            callback = kwargs["on_batch_planned"]
            assert callable(callback)
            callback({"tile_beginner_01"})
            planner_observed_generation = generated.wait(2)
            return {"asset_count": 1}

        @staticmethod
        def inventory(_category: dict[str, object]) -> dict[str, object]:
            count = int(generated.is_set())
            return {
                "assets": [
                    {
                        "asset_id": "tile_beginner_01",
                        "role": "quiz_tile",
                        "image_url": "asset" if count else None,
                    }
                ],
                "summary": {"total": 1, "generated": count},
            }

    class Publisher:
        @staticmethod
        def category_root(slug: str) -> Path:
            return tmp_path / slug

    class Checkpoint:
        def update(self, _name: str, _value: dict[str, object]) -> None:
            return None

    monkeypatch.setattr("quiz_harness.production_pipeline.VLLMClient", Client)
    pipeline = object.__new__(CategoryProductionPipeline)
    pipeline.config = SimpleNamespace(
        qwen_provider_id="qwen",
        qwen_model=None,
        tile_provider_id="imagestudio",
        tile_model="ernie",
        answer_provider_id="imagestudio",
        answer_model="ernie",
        seed=42,
        force_media=False,
    )
    pipeline.publisher = Publisher()
    pipeline.visuals = Visuals()
    pipeline.checkpoint = Checkpoint()
    pipeline._ensure_background = lambda _category: {"status": "approved"}
    pipeline._provider = lambda *_args: {"base_url": "http://qwen", "id": "qwen"}
    pipeline._model = lambda *_args: "qwen-model"
    pipeline._secret = lambda *_args: None
    pipeline._log = lambda *_args: None

    def generate(**_kwargs: object) -> dict[str, object]:
        generated.set()
        return {"requested": 1, "generated": 1, "reused": 0, "failed": 0}

    pipeline._generate_visual_group = generate

    result = pipeline._visual_branch(
        {
            "slug": "space",
            "name": "Space",
            "display_title": "SPACE QUIZ",
            "editorial_brief": "Use concrete astronomy subjects.",
        }
    )

    assert planner_observed_generation is True
    assert result["summary"]["generated"] == 1
    assert result["queue"]["jobs"]["complete"] == 1
