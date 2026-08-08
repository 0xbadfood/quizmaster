from __future__ import annotations

import copy

import pytest
from pydantic import ValidationError

from quiz_harness.question_models import (
    CandidateQuestionPool,
    PerQuestionValidation,
    QuestionSetPayload,
    ValidationResult,
)
from quiz_harness.question_service import balance_answer_positions


def question(index: int, correct: str = "choice1") -> dict:
    answer = {
        "choice1": f"Correct answer {index}",
        "choice2": f"Distractor alpha {index}",
        "choice3": f"Distractor beta {index}",
    }[correct]
    return {
        "question_id": f"candidate_{index:02d}",
        "topic_key": f"topic_{index:02d}",
        "question": f"Which factual statement answers animal question number {index}?",
        "choices": [
            {"choice_id": "choice1", "text": f"Correct answer {index}"},
            {"choice_id": "choice2", "text": f"Distractor alpha {index}"},
            {"choice_id": "choice3", "text": f"Distractor beta {index}"},
        ],
        "correct_choice_id": correct,
        "explanation": f"{answer} is correct because this is verified test content.",
    }


def final_questions() -> list[dict]:
    positions = ["choice1"] * 4 + ["choice2"] * 3 + ["choice3"] * 3
    return [question(index, positions[index - 1]) for index in range(1, 11)]


def test_candidate_pool_requires_fourteen_questions() -> None:
    payload = {
        "schema_version": "1.0",
        "category": "Animals",
        "difficulty": "beginner",
        "questions": [question(index) for index in range(1, 15)],
    }
    assert len(CandidateQuestionPool.model_validate(payload).questions) == 14
    payload["questions"].pop()
    with pytest.raises(ValidationError):
        CandidateQuestionPool.model_validate(payload)


def test_final_set_requires_balanced_answer_positions() -> None:
    payload = {
        "schema_version": "1.0",
        "category": "Animals",
        "difficulty": "beginner",
        "questions": final_questions(),
    }
    assert len(QuestionSetPayload.model_validate(payload).questions) == 10
    unbalanced = copy.deepcopy(payload)
    for item in unbalanced["questions"]:
        item["correct_choice_id"] = "choice1"
        item["explanation"] = (
            f"{item['choices'][0]['text']} is correct because it is verified."
        )
    with pytest.raises(ValidationError, match="choice position"):
        QuestionSetPayload.model_validate(unbalanced)


def test_explanation_may_use_a_clear_paraphrase() -> None:
    data = question(1)
    data["explanation"] = "This response is correct for a well established reason."
    pool = CandidateQuestionPool.model_validate(
        {
            "schema_version": "1.0",
            "category": "Animals",
            "difficulty": "beginner",
            "questions": [data] + [question(index) for index in range(2, 15)],
        }
    )
    assert pool.questions[0].explanation.startswith("This response")


def test_validation_reviews_all_fourteen_candidates() -> None:
    payload = {
        "schema_version": "1.0",
        "status": "approved",
        "reviews": [
            {
                "question_id": f"candidate_{index:02d}",
                "decision": "selected" if index <= 10 else "rejected",
                "issue_codes": ["none"] if index <= 10 else ["weak_distractor"],
                "rationale": "Sound question" if index <= 10 else "A weaker candidate",
            }
            for index in range(1, 15)
        ],
        "final_set": {
            "schema_version": "1.0",
            "category": "Animals",
            "difficulty": "beginner",
            "questions": final_questions(),
        },
    }
    result = ValidationResult.model_validate(payload)
    assert sum(review.decision == "selected" for review in result.reviews) == 10


def test_review_allows_sound_reserve_candidates() -> None:
    payload = {
        "schema_version": "1.0",
        "status": "approved",
        "reviews": [
            {
                "question_id": f"candidate_{index:02d}",
                "decision": "selected" if index <= 10 else "reserve",
                "issue_codes": ["none"],
                "rationale": "Sound candidate question",
            }
            for index in range(1, 15)
        ],
        "final_set": {
            "schema_version": "1.0",
            "category": "Animals",
            "difficulty": "beginner",
            "questions": final_questions(),
        },
    }
    result = ValidationResult.model_validate(payload)
    assert sum(review.decision == "reserve" for review in result.reviews) == 4


def test_answer_positions_are_balanced_deterministically() -> None:
    source = QuestionSetPayload.model_validate(
        {
            "schema_version": "1.0",
            "category": "Animals",
            "difficulty": "beginner",
            "questions": final_questions(),
        }
    )
    balanced = balance_answer_positions(source.questions, seed=12)
    counts = {
        choice_id: sum(item.correct_choice_id == choice_id for item in balanced)
        for choice_id in ("choice1", "choice2", "choice3")
    }
    assert counts == {"choice1": 4, "choice2": 3, "choice3": 3}
    for before, after in zip(source.questions, balanced, strict=True):
        before_answer = next(
            choice.text for choice in before.choices
            if choice.choice_id == before.correct_choice_id
        )
        after_answer = next(
            choice.text for choice in after.choices
            if choice.choice_id == after.correct_choice_id
        )
        assert after_answer == before_answer


def test_per_question_acceptance_requires_high_scores() -> None:
    payload = {
        "schema_version": "1.0",
        "candidate_question_id": "candidate_01",
        "decision": "accepted",
        "issue_codes": ["none"],
        "factual_confidence": 5,
        "difficulty_assessment": "too_easy",
        "distractor_quality": 5,
        "selection_score": 80,
        "choice_assessments": [
            {"choice_id": "choice1", "verdict": "correct", "rationale": "The declared answer is correct."},
            {"choice_id": "choice2", "verdict": "incorrect", "rationale": "This does not answer the question."},
            {"choice_id": "choice3", "verdict": "incorrect", "rationale": "This does not answer the question."},
        ],
        "rationale": "The question is factual but too easy for the requested level.",
    }
    with pytest.raises(ValidationError, match="align with difficulty"):
        PerQuestionValidation.model_validate(payload)


def test_per_question_rejection_requires_specific_issue() -> None:
    payload = {
        "schema_version": "1.0",
        "candidate_question_id": "candidate_01",
        "decision": "rejected",
        "issue_codes": ["none"],
        "factual_confidence": 2,
        "difficulty_assessment": "aligned",
        "distractor_quality": 5,
        "selection_score": 50,
        "choice_assessments": [
            {"choice_id": "choice1", "verdict": "ambiguous", "rationale": "The answer cannot be established."},
            {"choice_id": "choice2", "verdict": "incorrect", "rationale": "This does not answer the question."},
            {"choice_id": "choice3", "verdict": "incorrect", "rationale": "This does not answer the question."},
        ],
        "rationale": "The factual claim is not sufficiently well established.",
    }
    with pytest.raises(ValidationError, match="cannot use the none"):
        PerQuestionValidation.model_validate(payload)


def test_per_question_acceptance_rejects_ambiguous_distractor() -> None:
    payload = {
        "schema_version": "1.0",
        "candidate_question_id": "candidate_01",
        "decision": "accepted",
        "issue_codes": ["none"],
        "factual_confidence": 5,
        "difficulty_assessment": "aligned",
        "distractor_quality": 5,
        "selection_score": 80,
        "choice_assessments": [
            {"choice_id": "choice1", "verdict": "correct", "rationale": "The declared answer is correct."},
            {"choice_id": "choice2", "verdict": "ambiguous", "rationale": "This could also explain the observation."},
            {"choice_id": "choice3", "verdict": "incorrect", "rationale": "This does not answer the question."},
        ],
        "rationale": "A distractor is independently defensible and makes the question ambiguous.",
    }
    with pytest.raises(ValidationError, match="cannot have ambiguous choices"):
        PerQuestionValidation.model_validate(payload)
