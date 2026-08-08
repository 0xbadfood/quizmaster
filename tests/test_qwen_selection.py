from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from quiz_harness.qwen_selection import (
    QwenBatchSelection,
    QwenSelectionError,
    ReturnedQuestion,
    append_sets_with_qwen,
    selection_prompt,
)
from quiz_harness.visual_bank import VisualBankDocument


def payload(*, selected_count: int = 10, status: str = "ready") -> dict:
    return {
        "schema_version": "1.0",
        "status": status,
        "selected_question_ids": [
            f"question_{index:02d}" for index in range(1, selected_count + 1)
        ],
        "returned_questions": [
            {
                "question_id": f"question_{index:02d}",
                "reason_code": "set_diversity",
                "rationale": "Another candidate adds stronger variety to this set.",
            }
            for index in range(selected_count + 1, 16)
        ],
        "summary": "The selected questions are accurate, clear, and varied.",
    }


def test_ready_selection_partitions_ten_and_five() -> None:
    selection = QwenBatchSelection.model_validate(payload())
    assert len(selection.selected_question_ids) == 10
    assert len(selection.returned_questions) == 5


def test_strict_selection_can_report_insufficient_quality() -> None:
    selection = QwenBatchSelection.model_validate(
        payload(selected_count=8, status="insufficient_quality")
    )
    assert len(selection.selected_question_ids) == 8
    assert len(selection.returned_questions) == 7


def test_ready_selection_rejects_short_quota() -> None:
    with pytest.raises(ValidationError, match="exactly ten"):
        QwenBatchSelection.model_validate(payload(selected_count=9))


def bird_bank(count: int = 25) -> VisualBankDocument:
    return VisualBankDocument.model_validate(
        {
            "schema_version": "visual_bank_v1",
            "category": "Birds",
            "difficulty": "beginner",
            "source_provider": "openai",
            "source_model": "draft-model",
            "source_response_id": "response-1",
            "generated_at_utc": "2026-08-05T00:00:00Z",
            "questions": [
                {
                    "question_id": f"birds_beginner_{index:03d}",
                    "topic_key": f"bird_topic_{index:03d}",
                    "difficulty": "beginner",
                    "question": f"Which bird demonstrates feature number {index}?",
                    "choices": [
                        {
                            "choice_id": f"choice{choice}",
                            "animal_key": f"bird_{index}_{choice}",
                            "label": f"Bird {index} {choice}",
                        }
                        for choice in range(1, 5)
                    ],
                    "correct_choice_id": "choice1",
                    "explanation": f"Bird {index} 1 demonstrates feature number {index}.",
                }
                for index in range(1, count + 1)
            ],
        }
    )


def test_selection_prompt_is_category_neutral() -> None:
    bank = bird_bank()
    prompt = selection_prompt(
        bank=bank,
        candidates=bank.questions[:15],
        prior_selected=[],
        strictness="strict",
    )
    assert "Category: Birds" in prompt
    assert "concrete, imageable subject within the category" in prompt
    assert "no birds" not in prompt.casefold()


def test_append_selection_preserves_existing_allocations(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bank = bird_bank(35)
    for item in bank.questions[:10]:
        item.state = "allocated"
        item.set_id = "birds_beginner_001"

    def select(**kwargs: object) -> QwenBatchSelection:
        candidate_ids = sorted(kwargs["candidate_ids"])
        return QwenBatchSelection(
            schema_version="1.0",
            status="ready",
            selected_question_ids=candidate_ids[:10],
            returned_questions=[
                ReturnedQuestion(
                    question_id=item,
                    reason_code="set_diversity",
                    rationale="Another candidate provides stronger variety here.",
                )
                for item in candidate_ids[10:]
            ],
            summary="Selected ten clear and varied questions for this quiz set.",
        )

    monkeypatch.setattr("quiz_harness.qwen_selection._request_selection", select)
    updated, sets = append_sets_with_qwen(
        source_bank=bank,
        client=object(),
        model="selector-model",
        output_root=tmp_path,
        set_count=1,
        first_set_number=2,
        seed=11,
        persist=False,
    )
    assert sets[0].set_id == "birds_beginner_002"
    assert all(
        item.state == "allocated" and item.set_id == "birds_beginner_001"
        for item in updated.questions[:10]
    )
    assert sum(item.set_id == "birds_beginner_002" for item in updated.questions) == 10
    assert not (tmp_path / "banks/beginner/bank.json").exists()


def test_append_checkpoints_ready_sets_before_later_batch_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bank = bird_bank(25)
    calls = 0
    checkpoints: list[tuple[str, int]] = []

    def select(**kwargs: object) -> QwenBatchSelection:
        nonlocal calls
        calls += 1
        candidate_ids = sorted(kwargs["candidate_ids"])
        if calls == 1:
            return QwenBatchSelection(
                schema_version="1.0",
                status="ready",
                selected_question_ids=candidate_ids[:10],
                returned_questions=[
                    ReturnedQuestion(
                        question_id=item,
                        reason_code="set_diversity",
                        rationale="Another candidate provides stronger variety here.",
                    )
                    for item in candidate_ids[10:]
                ],
                summary="Selected ten clear and varied questions for this quiz set.",
            )
        return QwenBatchSelection(
            schema_version="1.0",
            status="insufficient_quality",
            selected_question_ids=candidate_ids[:8],
            returned_questions=[
                ReturnedQuestion(
                    question_id=item,
                    reason_code="factual_risk",
                    rationale="This candidate needs another factual review before use.",
                )
                for item in candidate_ids[8:]
            ],
            summary="The batch does not contain ten questions meeting strict quality.",
        )

    monkeypatch.setattr("quiz_harness.qwen_selection._request_selection", select)
    with pytest.raises(QwenSelectionError, match="set 002 stopped"):
        append_sets_with_qwen(
            source_bank=bank,
            client=object(),
            model="selector-model",
            output_root=tmp_path,
            set_count=2,
            first_set_number=1,
            seed=11,
            persist=False,
            checkpoint=lambda current, quiz_set: checkpoints.append(
                (
                    quiz_set.set_id,
                    sum(item.state == "allocated" for item in current.questions),
                )
            ),
        )
    assert calls == 4
    assert checkpoints == [("birds_beginner_001", 10)]
