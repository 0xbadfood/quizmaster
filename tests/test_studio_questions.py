from __future__ import annotations

import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from quiz_harness.database import QuizDatabase
from quiz_harness.studio_questions import (
    GeneratedStudioBatch,
    QUESTION_GENERATION_PROVIDER_TYPES,
    QuestionBankError,
    QuestionBankStore,
    generate_questions,
    question_generation_prompt,
    slugify,
)


def candidate(index: int, *, state: str = "available") -> dict:
    return {
        "question_id": f"animals_beginner_{index:03d}",
        "topic_key": f"animal_fact_{index:03d}",
        "difficulty": "beginner",
        "question": f"Which animal demonstrates test feature number {index}?",
        "choices": [
            {
                "choice_id": f"choice{choice}",
                "animal_key": f"animal_{index}_{choice}",
                "label": f"Animal {index} {choice}",
            }
            for choice in range(1, 5)
        ],
        "correct_choice_id": "choice1",
        "explanation": f"Animal {index} 1 demonstrates test feature number {index}.",
        "state": state,
        "set_id": "animals_beginner_001" if state == "allocated" else None,
    }


def store(tmp_path: Path) -> tuple[QuestionBankStore, QuizDatabase]:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.seed_catalog()
    root = tmp_path / "source"
    path = root / "animals/banks/beginner/bank.json"
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "schema_version": "visual_bank_v1",
                "category": "Animals",
                "difficulty": "beginner",
                "questions": [candidate(1, state="allocated"), candidate(2)],
            }
        ),
        encoding="utf-8",
    )
    return QuestionBankStore(root, database), database


def test_bank_listing_filters_and_enriches_reviews(tmp_path: Path) -> None:
    bank, database = store(tmp_path)
    database.upsert_question_review(
        category_slug="animals",
        difficulty="beginner",
        question_id="animals_beginner_002",
        status="approved",
        notes="Good reserve",
    )
    result = bank.list_questions(
        "animals", difficulty="beginner", review="approved"
    )
    assert result["pagination"]["total"] == 1
    assert result["questions"][0]["question_id"] == "animals_beginner_002"
    assert result["questions"][0]["choices"][0]["object_key"] == "animal_2_1"
    assert result["summary"]["allocated"] == 1
    assert result["summary"]["approved"] == 1


def test_allocated_questions_are_locked_but_reviewable(tmp_path: Path) -> None:
    bank, _ = store(tmp_path)
    item = bank.question("animals", "beginner", "animals_beginner_001")
    with pytest.raises(QuestionBankError, match="locked"):
        bank.update_question("animals", "beginner", item["question_id"], item)
    approved = bank.review_question(
        "animals",
        "beginner",
        item["question_id"],
        status="approved",
    )
    assert approved["review_status"] == "approved"
    with pytest.raises(QuestionBankError, match="cannot be rejected"):
        bank.review_question(
            "animals",
            "beginner",
            item["question_id"],
            status="rejected",
        )


def test_edit_and_import_are_atomic_and_audited(tmp_path: Path) -> None:
    bank, database = store(tmp_path)
    item = bank.question("animals", "beginner", "animals_beginner_002")
    item["question"] = "Which animal demonstrates a newly edited feature?"
    item["explanation"] = "Animal 2 1 demonstrates the newly edited feature."
    updated = bank.update_question(
        "animals", "beginner", "animals_beginner_002", item
    )
    assert "newly edited" in updated["question"]

    valid = {
        "question": "Which animal demonstrates another deterministic feature?",
        "choices": [
            {"label": f"New Animal {index}", "object_key": f"new_animal_{index}"}
            for index in range(1, 5)
        ],
        "correct_choice_id": "choice2",
        "explanation": "New Animal 2 demonstrates another deterministic feature.",
    }
    invalid = {**valid, "question": "This is not a question"}
    result = bank.import_questions(
        database.studio_category("animals"),
        "beginner",
        [valid, invalid],
        source_provider="manual_import",
    )
    assert result["accepted"] == 1
    assert result["rejected"] == 1
    assert bank.list_questions("animals")["summary"]["total"] == 3
    assert database.question_revisions(
        "animals", "beginner", "animals_beginner_003"
    )[0]["action"] == "imported"

    cross_difficulty = bank.import_questions(
        database.studio_category("animals"),
        "intermediate",
        [valid],
        source_provider="manual_import",
    )
    assert cross_difficulty["accepted"] == 0
    assert "duplicates" in cross_difficulty["rejections"][0]["reasons"][0]


def test_generation_prompt_uses_category_brief_and_sibling_boundaries() -> None:
    prompt = question_generation_prompt(
        category={
            "name": "World Geography",
            "description": "",
            "editorial_brief": "Landforms, maps, countries, and landmarks.",
            "age_min": 7,
            "age_max": 10,
        },
        sibling_names=["Animals", "Birds", "World History"],
        difficulty="intermediate",
        count=12,
    )
    assert "World Geography" in prompt
    assert "Landforms, maps, countries, and landmarks" in prompt
    assert "World History" in prompt
    assert "exactly 12" in prompt
    assert QUESTION_GENERATION_PROVIDER_TYPES == {
        "openai_compatible_llm",
        "openai_images",
    }
    assert "2 and 50 characters" in prompt


def test_import_rejects_values_outside_runtime_bank_contract(tmp_path: Path) -> None:
    bank, database = store(tmp_path)
    valid = {
        "question": "Which animal demonstrates another deterministic feature?",
        "choices": [
            {"label": f"New Animal {index}", "object_key": f"new_animal_{index}"}
            for index in range(1, 5)
        ],
        "correct_choice_id": "choice1",
        "explanation": "New Animal 1 demonstrates another deterministic feature.",
    }
    overlong = {
        **valid,
        "choices": [
            {**valid["choices"][0], "label": "A" * 51},
            *valid["choices"][1:],
        ],
    }

    result = bank.import_questions(
        database.studio_category("animals"), "beginner", [overlong]
    )

    assert result["accepted"] == 0
    assert result["rejected"] == 1
    assert "2-50" in result["rejections"][0]["reasons"][0]


def test_quarantine_removes_only_unallocated_contract_invalid_records(
    tmp_path: Path,
) -> None:
    bank, _ = store(tmp_path)
    path = bank.bank_path("animals", "beginner")
    document = json.loads(path.read_text(encoding="utf-8"))
    document["questions"][1]["choices"][0]["label"] = "A" * 51
    path.write_text(json.dumps(document), encoding="utf-8")

    result = bank.quarantine_contract_invalid("animals", "beginner")
    repaired = json.loads(path.read_text(encoding="utf-8"))

    assert result == {
        "quarantined": 1,
        "question_ids": ["animals_beginner_002"],
    }
    assert [item["question_id"] for item in repaired["questions"]] == [
        "animals_beginner_001"
    ]
    assert repaired["ingestion_rejections"][0]["source_question_id"] == (
        "animals_beginner_002"
    )


def test_direct_import_accepts_category_appropriate_question_stems() -> None:
    candidate = {
        "question": "Who painted the Mona Lisa?",
        "choices": [
            {"label": "Leonardo da Vinci", "object_key": "leonardo_da_vinci"},
            {"label": "Vincent van Gogh", "object_key": "vincent_van_gogh"},
            {"label": "Pablo Picasso", "object_key": "pablo_picasso"},
            {"label": "Claude Monet", "object_key": "claude_monet"},
        ],
        "correct_choice_id": "choice1",
        "explanation": "Leonardo da Vinci painted the Mona Lisa during the Renaissance.",
    }

    assert QuestionBankStore.validate_candidate(candidate) == []


def test_import_slugifies_digit_leading_object_keys_to_valid_identifiers() -> None:
    assert slugify("1950s Passenger Train") == "item_1950s_passenger_train"


def test_openai_provider_uses_responses_api_with_typed_output(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    generated = GeneratedStudioBatch.model_validate(
        {
            "questions": [
                {
                    "question": "Which bird has a wide flat bill for filtering water?",
                    "choices": [
                        {"label": "Duck", "object_key": "duck"},
                        {"label": "Eagle", "object_key": "eagle"},
                        {"label": "Owl", "object_key": "owl"},
                        {"label": "Hawk", "object_key": "hawk"},
                    ],
                    "correct_choice_id": "choice1",
                    "explanation": "A Duck has a wide flat bill that helps filter food from water.",
                }
            ]
        }
    )
    calls: list[dict] = []

    class FakeResponses:
        def parse(self, **kwargs: object) -> SimpleNamespace:
            calls.append(kwargs)
            return SimpleNamespace(output_parsed=generated)

    class FakeClient:
        responses = FakeResponses()

        def __enter__(self) -> "FakeClient":
            return self

        def __exit__(self, *_: object) -> None:
            return None

    monkeypatch.setattr(
        "quiz_harness.studio_questions.OpenAI", lambda **_: FakeClient()
    )
    questions, model = generate_questions(
        category={
            "name": "Birds",
            "description": "Bird identification",
            "editorial_brief": "Bird identification and behavior.",
            "age_min": 5,
            "age_max": 8,
        },
        sibling_names=["Animals"],
        difficulty="beginner",
        count=1,
        provider={
            "provider_type": "openai_images",
            "base_url": "https://api.openai.com/v1",
            "default_model": "gpt-5.6-luna",
        },
        secret="test-secret",
        progress=lambda *_: None,
    )
    assert model == "gpt-5.6-luna"
    assert questions[0]["choices"][0]["object_key"] == "duck"
    assert calls[0]["text_format"] is GeneratedStudioBatch
    assert calls[0]["reasoning"] == {"effort": "low"}
