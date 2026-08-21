from __future__ import annotations

import pytest
from pydantic import ValidationError

from quiz_harness.openai_bank import bank_prompt
from quiz_harness.visual_bank import (
    GeneratedVisualBank,
    VisualBankDocument,
    VisualQuestion,
    allocate_sets,
    extract_animal_catalog,
    slugify,
)


def question(index: int, difficulty: str = "beginner") -> dict:
    answer_index = index * 4
    labels = [
        f"Animal {answer_index + offset}"
        for offset in range(4)
    ]
    return {
        "question_id": f"animals_{difficulty}_{index:03d}",
        "topic_key": f"distinct_fact_{difficulty}_{index:03d}",
        "difficulty": difficulty,
        "question": f"Which animal demonstrates distinctive feature number {index}?",
        "choices": [
            {
                "choice_id": f"choice{offset + 1}",
                "animal_key": f"animal_{answer_index + offset}",
                "label": label,
            }
            for offset, label in enumerate(labels)
        ],
        "correct_choice_id": "choice1",
        "explanation": f"{labels[0]} demonstrates distinctive feature number {index}.",
    }


def generated_bank(count: int = 120) -> GeneratedVisualBank:
    return GeneratedVisualBank.model_validate(
        {
            "schema_version": "1.0",
            "category": "Animals",
            "difficulty": "beginner",
            "questions": [question(index) for index in range(1, count + 1)],
        }
    )


def bank_document(count: int = 120) -> VisualBankDocument:
    return VisualBankDocument.from_generated(
        generated_bank(count),
        source_model="gpt-5.6-luna",
        source_response_id="response_test",
    )


def test_prompt_excludes_birds_and_requests_four_choices() -> None:
    prompt = bank_prompt(category="Animals", difficulty="beginner", count=120)
    assert "exactly 120" in prompt
    assert "exactly four distinct named animals" in prompt
    assert "Do not create\nquestions about birds" in prompt


def test_name_an_animal_is_a_supported_visual_question_style() -> None:
    payload = question(1)
    payload["question"] = "Name an animal with a distinctive test feature?"
    GeneratedVisualBank.model_validate(
        {
            "schema_version": "1.0",
            "category": "Animals",
            "difficulty": "beginner",
            "questions": [
                payload,
                *[question(index) for index in range(2, 11)],
            ],
        }
    )


def test_category_appropriate_question_stems_are_supported() -> None:
    payload = question(1)
    payload["question"] = "Who is represented by Animal 4?"

    VisualQuestion.model_validate(payload)


def test_slugify_prefixes_identifiers_that_begin_with_a_digit() -> None:
    assert slugify("1950s Passenger Train") == "item_1950s_passenger_train"


def test_allocator_creates_ten_sets_and_keeps_twenty_reserves() -> None:
    bank = bank_document()
    sets = allocate_sets(bank, seed=42, max_sets=10)
    assert len(sets) == 10
    assert sum(question.state == "allocated" for question in bank.questions) == 100
    assert sum(question.state == "available" for question in bank.questions) == 20
    assert all(len(quiz_set.questions) == 10 for quiz_set in sets)
    for quiz_set in sets:
        positions = [
            sum(question.correct_choice_id == choice_id for question in quiz_set.questions)
            for choice_id in ("choice1", "choice2", "choice3", "choice4")
        ]
        assert sorted(positions) == [2, 2, 3, 3]


def _large_bank_document(count: int) -> VisualBankDocument:
    return VisualBankDocument.model_validate(
        {
            "schema_version": "visual_bank_v1",
            "category": "Animals",
            "difficulty": "beginner",
            "source_provider": "openai",
            "source_model": "gpt-5.6-luna",
            "source_response_id": "response_test",
            "generated_at_utc": "2026-08-05T00:00:00Z",
            "questions": [question(index) for index in range(1, count + 1)],
        }
    )


def test_stored_bank_document_allows_five_hundred_questions_but_not_more() -> None:
    assert len(_large_bank_document(500).questions) == 500
    with pytest.raises(ValidationError):
        _large_bank_document(501)


def test_ingestion_canonicalizes_repeated_model_topic_keys() -> None:
    generated = generated_bank(10)
    generated.questions[1].topic_key = generated.questions[0].topic_key
    bank = VisualBankDocument.from_generated(
        generated,
        source_model="gpt-5.6-luna",
        source_response_id="response_duplicate",
    )
    assert len(bank.questions) == 10
    assert bank.questions[0].question_id == "animals_beginner_001"
    assert bank.questions[1].question_id == "animals_beginner_002"
    assert bank.questions[0].topic_key != bank.questions[1].topic_key
    assert not bank.ingestion_rejections


def test_ingestion_rejects_duplicate_question_text() -> None:
    generated = generated_bank(10)
    generated.questions[1].question = generated.questions[0].question
    bank = VisualBankDocument.from_generated(
        generated,
        source_model="gpt-5.6-luna",
        source_response_id="response_duplicate",
    )
    assert len(bank.questions) == 9
    assert bank.ingestion_rejections[0].question_index == 2


def test_ingestion_rejects_bird_choices_but_allows_hummingbird_bat() -> None:
    generated = generated_bank(10)
    generated.questions[0].choices[3].animal_key = "penguin"
    generated.questions[0].choices[3].label = "Penguin"
    generated.questions[1].choices[3].animal_key = "hummingbird_bat"
    generated.questions[1].choices[3].label = "Hummingbird bat"
    bank = VisualBankDocument.from_generated(
        generated,
        source_model="gpt-5.6-luna",
        source_response_id="response_bird",
    )
    assert len(bank.questions) == 9
    assert bank.ingestion_rejections[0].question_index == 1
    assert "Penguin" in bank.ingestion_rejections[0].reasons[0]


def test_animal_catalog_defaults_to_allocated_questions() -> None:
    bank = bank_document(20)
    allocate_sets(bank, seed=7, max_sets=1)
    catalog = extract_animal_catalog([bank], category="Animals")
    allocated_keys = {
        choice.animal_key
        for question in bank.questions
        if question.state == "allocated"
        for choice in question.choices
    }
    assert {animal.animal_key for animal in catalog.animals} == allocated_keys
    assert all(animal.image_status == "pending" for animal in catalog.animals)
