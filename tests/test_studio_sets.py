from __future__ import annotations

import json
from pathlib import Path

import pytest

from quiz_harness.database import QuizDatabase
from quiz_harness.qwen_selection import QwenSelectionError
from quiz_harness.studio_sets import MAX_SETS_PER_DIFFICULTY, QuizSetError, QuizSetStore
from quiz_harness.visual_bank import (
    BankQuestion,
    VisualBankDocument,
    build_visual_quiz_set,
    load_bank,
    write_model,
)


def question(index: int, *, state: str = "available", set_id: str | None = None) -> dict:
    return {
        "question_id": f"birds_beginner_{index:03d}",
        "topic_key": f"bird_fact_{index:03d}",
        "difficulty": "beginner",
        "question": f"Which bird demonstrates test feature number {index}?",
        "choices": [
            {
                "choice_id": f"choice{choice}",
                "animal_key": f"bird_{index}_{choice}",
                "label": f"Bird {index} {choice}",
            }
            for choice in range(1, 5)
        ],
        "correct_choice_id": "choice1",
        "explanation": f"Bird {index} 1 demonstrates test feature number {index}.",
        "state": state,
        "set_id": set_id,
    }


def make_store(tmp_path: Path) -> tuple[QuizSetStore, QuizDatabase, Path]:
    database = QuizDatabase(tmp_path / "quiz.db")
    database.seed_catalog()
    root = tmp_path / "source"
    bank_path = root / "birds/banks/beginner/bank.json"
    bank_path.parent.mkdir(parents=True)
    bank_path.write_text(
        json.dumps(
            {
                "schema_version": "visual_bank_v1",
                "category": "Birds",
                "difficulty": "beginner",
                "source_provider": "openai",
                "source_model": "test-model",
                "source_response_id": "test-response",
                "generated_at_utc": "2026-08-05T00:00:00Z",
                "questions": [question(index) for index in range(1, 26)],
                "ingestion_rejections": [],
            }
        ),
        encoding="utf-8",
    )
    return QuizSetStore(root, database), database, bank_path


def test_set_catalog_reports_capacity_and_review(tmp_path: Path) -> None:
    store, database, bank_path = make_store(tmp_path)
    bank = load_bank(bank_path)
    selected = bank.questions[:10]
    quiz_set = build_visual_quiz_set(bank, selected, set_number=1, seed=19)
    for item in selected:
        item.state = "allocated"
        item.set_id = quiz_set.set_id
    write_model(bank_path, bank)
    write_model(
        tmp_path / "source/birds/sets/beginner/birds_beginner_001.json",
        quiz_set,
    )
    database.upsert_quiz_set_review(
        category_slug="birds",
        difficulty="beginner",
        set_id=quiz_set.set_id,
        status="approved",
        notes="Ready",
    )

    result = store.list_sets("birds")
    assert result["summary"]["total"] == 1
    assert result["summary"]["approved"] == 1
    assert result["summary"]["banks"]["beginner"]["available"] == 15
    assert result["summary"]["banks"]["beginner"]["selection_capacity"] == 1
    detail = store.set_detail("birds", "beginner", quiz_set.set_id)
    assert len(detail["questions"]) == 10
    assert detail["questions"][0]["correct_answer"]


def test_set_review_does_not_mutate_set_document(tmp_path: Path) -> None:
    store, _, bank_path = make_store(tmp_path)
    bank = load_bank(bank_path)
    quiz_set = build_visual_quiz_set(bank, bank.questions[:10], set_number=1, seed=7)
    path = tmp_path / "source/birds/sets/beginner/birds_beginner_001.json"
    write_model(path, quiz_set)
    before = path.read_bytes()

    reviewed = store.review_set(
        "birds",
        "beginner",
        quiz_set.set_id,
        status="needs_edit",
        notes="Review distractor variety",
    )
    assert reviewed["review_status"] == "needs_edit"
    assert path.read_bytes() == before


def test_partial_selection_keeps_completed_checkpoint(
    tmp_path: Path, monkeypatch
) -> None:
    store, _, bank_path = make_store(tmp_path)

    def partial_selection(**kwargs):
        bank = kwargs["source_bank"].model_copy(deep=True)
        selected = bank.questions[:10]
        quiz_set = build_visual_quiz_set(bank, selected, set_number=1, seed=13)
        for item in selected:
            item.state = "allocated"
            item.set_id = quiz_set.set_id
        kwargs["checkpoint"](bank, quiz_set)
        raise QwenSelectionError("beginner set 002 stopped after 3 candidate batches")

    monkeypatch.setattr(
        "quiz_harness.studio_sets.append_sets_with_qwen", partial_selection
    )
    result = store.select_sets(
        category_slug="birds",
        difficulty="beginner",
        count=2,
        client=object(),
        model="selector-model",
        seed=21,
        strictness="strict",
        provider_id="llm-default",
        progress=lambda *_: None,
    )
    assert result["status"] == "partial"
    assert result["created"] == ["birds_beginner_001"]
    assert result["next_set_number"] == 2
    assert (tmp_path / "source/birds/sets/beginner/birds_beginner_001.json").exists()
    assert sum(item.state == "allocated" for item in load_bank(bank_path).questions) == 10


def test_selection_is_capped_at_twenty_sets_per_difficulty(tmp_path: Path) -> None:
    store, _, bank_path = make_store(tmp_path)
    bank = load_bank(bank_path)
    sets_dir = tmp_path / "source/birds/sets/beginner"
    sets_dir.mkdir(parents=True)
    for set_number in range(1, MAX_SETS_PER_DIFFICULTY + 1):
        quiz_set = build_visual_quiz_set(
            bank, bank.questions[:10], set_number=set_number, seed=set_number
        )
        write_model(sets_dir / f"{quiz_set.set_id}.json", quiz_set)

    with pytest.raises(QuizSetError, match="at most 0"):
        store.select_sets(
            category_slug="birds",
            difficulty="beginner",
            count=1,
            client=object(),
            model="selector-model",
            seed=1,
            strictness="strict",
            provider_id="llm-default",
            progress=lambda *_: None,
        )
