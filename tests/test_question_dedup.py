from pathlib import Path

import pytest

from quiz_harness.question_dedup import (
    DuplicateCluster,
    DuplicateDiscovery,
    compact_question_payload,
    validate_discovery,
    write_discovery_report,
)
from quiz_harness.visual_bank import BankQuestion


def question(question_id: str, difficulty: str, text: str) -> BankQuestion:
    return BankQuestion.model_validate(
        {
            "question_id": question_id,
            "topic_key": f"topic_{question_id}",
            "difficulty": difficulty,
            "question": text,
            "choices": [
                {
                    "choice_id": f"choice{index}",
                    "animal_key": value.casefold(),
                    "label": value,
                }
                for index, value in enumerate(
                    ("Mars", "Venus", "Earth", "Jupiter"), start=1
                )
            ],
            "correct_choice_id": "choice1",
            "explanation": "Mars appears red because of iron minerals on its surface.",
            "state": "available",
        }
    )


def question_with_answer(
    question_id: str, difficulty: str, text: str, answer: str
) -> BankQuestion:
    item = question(question_id, difficulty, text)
    values = (answer, "Venus", "Earth", "Jupiter")
    return item.model_copy(
        update={
            "choices": [
                choice.model_copy(update={"animal_key": value.casefold(), "label": value})
                for choice, value in zip(item.choices, values, strict=True)
            ]
        }
    )


def test_compact_payload_contains_only_discovery_fields() -> None:
    item = question("space_beginner_001", "beginner", "Which is the Red Planet?")
    assert compact_question_payload([item]) == [
        {
            "question_id": "space_beginner_001",
            "difficulty": "beginner",
            "question": "Which is the Red Planet?",
            "correct_answer": "Mars",
        }
    ]


def test_discovery_validation_and_report_cover_cross_difficulty_cluster(
    tmp_path: Path,
) -> None:
    questions = [
        question("space_beginner_001", "beginner", "Which is the Red Planet?"),
        question(
            "space_intermediate_004",
            "intermediate",
            "Which planet is commonly called the Red Planet?",
        ),
    ]
    discovery = DuplicateDiscovery(
        schema_version="question_duplicate_discovery_v1",
        category="Space",
        input_question_count=2,
        duplicate_clusters=[
            DuplicateCluster(
                fact_summary="Mars is known as the Red Planet",
                canonical_question_id="space_beginner_001",
                duplicate_question_ids=["space_intermediate_004"],
                confidence=0.98,
                reason="Both questions ask for the planet sharing the same nickname.",
            )
        ],
    )

    validate_discovery(discovery, category="Space", questions=questions)
    report = tmp_path / "report.md"
    write_discovery_report(report, discovery=discovery, questions=questions)

    text = report.read_text(encoding="utf-8")
    assert "beginner, intermediate" in text
    assert "space_intermediate_004" in text


def test_discovery_rejects_unknown_or_overlapping_ids() -> None:
    questions = [
        question("space_beginner_001", "beginner", "Which is the Red Planet?"),
        question("space_beginner_002", "beginner", "Can you name the Red Planet?"),
        question("space_beginner_003", "beginner", "Which planet appears red?"),
    ]
    discovery = DuplicateDiscovery(
        schema_version="question_duplicate_discovery_v1",
        category="Space",
        input_question_count=3,
        duplicate_clusters=[
            DuplicateCluster(
                fact_summary="Mars is the Red Planet",
                canonical_question_id="space_beginner_001",
                duplicate_question_ids=["space_beginner_002"],
                confidence=0.9,
                reason="These questions test the same common planetary nickname.",
            ),
            DuplicateCluster(
                fact_summary="Mars appears red",
                canonical_question_id="space_beginner_002",
                duplicate_question_ids=["space_beginner_003"],
                confidence=0.7,
                reason="These questions may test the same identifying visual fact.",
            ),
        ],
    )

    with pytest.raises(ValueError, match="multiple clusters"):
        validate_discovery(discovery, category="Space", questions=questions)


def test_discovery_rejects_cluster_with_different_correct_answers() -> None:
    questions = [
        question_with_answer(
            "space_beginner_001", "beginner", "Which is the Red Planet?", "Mars"
        ),
        question_with_answer(
            "space_beginner_002", "beginner", "Which planet is hottest?", "Venus"
        ),
    ]
    discovery = DuplicateDiscovery(
        schema_version="question_duplicate_discovery_v1",
        category="Space",
        input_question_count=2,
        duplicate_clusters=[
            DuplicateCluster(
                fact_summary="Planets with distinctive properties",
                canonical_question_id="space_beginner_001",
                duplicate_question_ids=["space_beginner_002"],
                confidence=0.8,
                reason="The response incorrectly grouped two different planet facts.",
            )
        ],
    )

    with pytest.raises(ValueError, match="conflicting correct answers"):
        validate_discovery(discovery, category="Space", questions=questions)
