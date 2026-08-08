from quiz_harness.question_audit import compare_questions
from quiz_harness.question_models import ContentQuestion
from quiz_harness.question_service import duplicate_matches


def make_question(
    question: str, answer: str, topic_key: str
) -> ContentQuestion:
    return ContentQuestion.model_validate(
        {
            "question_id": "sample_question",
            "topic_key": topic_key,
            "question": question,
            "choices": [
                {"choice_id": "choice1", "text": answer},
                {"choice_id": "choice2", "text": "Wrong option one"},
                {"choice_id": "choice3", "text": "Wrong option two"},
            ],
            "correct_choice_id": "choice1",
            "explanation": f"{answer} is correct for this factual question.",
        }
    )


def test_detects_reworded_duplicate() -> None:
    left = make_question(
        "How do fish breathe underwater?", "Through gills", "fish_respiration"
    )
    right = make_question(
        "What do fish use to breathe underwater?", "Gills", "aquatic_respiration"
    )
    result = compare_questions(left, right)
    assert result["likely_duplicate"] is True
    assert result["exact_question"] is False


def test_topic_collision_does_not_automatically_mean_duplicate() -> None:
    left = make_question(
        "Why does an octopus have three hearts?",
        "To pump blood through its gills and body",
        "cephalopod_physiology",
    )
    right = make_question(
        "Why is octopus blood blue?",
        "Its blood uses copper-based hemocyanin",
        "cephalopod_physiology",
    )
    result = compare_questions(left, right)
    assert result["exact_topic"] is True
    assert result["likely_duplicate"] is False


def test_duplicate_gate_returns_existing_question_evidence() -> None:
    existing = make_question(
        "How do fish breathe underwater?", "Through gills", "fish_respiration"
    )
    candidate = make_question(
        "What do fish use to breathe underwater?", "Gills", "aquatic_respiration"
    )
    matches = duplicate_matches(candidate, [existing])
    assert len(matches) == 1
    assert matches[0]["question_id"] == "sample_question"
