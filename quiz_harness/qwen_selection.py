from __future__ import annotations

import json
import random
from pathlib import Path
from typing import Annotated, Callable, Literal

from pydantic import Field, ValidationError, model_validator

from .client import VLLMClient, VLLMError
from .models import Identifier, StrictModel
from .visual_bank import (
    BankQuestion,
    VisualBankDocument,
    VisualQuizSet,
    build_visual_quiz_set,
    write_model,
)


DEFAULT_QWEN_ENDPOINT = "http://10.8.0.5:8001/v1"


class ReturnedQuestion(StrictModel):
    question_id: Identifier
    reason_code: Literal[
        "factual_risk",
        "ambiguous_answer",
        "weak_distractor",
        "difficulty_mismatch",
        "duplicate_fact",
        "category_violation",
        "weak_wording",
        "set_diversity",
    ]
    rationale: Annotated[str, Field(min_length=8, max_length=260)]


class QwenBatchSelection(StrictModel):
    schema_version: Literal["1.0"]
    status: Literal["ready", "insufficient_quality"]
    selected_question_ids: Annotated[list[Identifier], Field(max_length=10)]
    returned_questions: Annotated[
        list[ReturnedQuestion], Field(min_length=5, max_length=15)
    ]
    summary: Annotated[str, Field(min_length=10, max_length=400)]

    @model_validator(mode="after")
    def validate_partition(self) -> QwenBatchSelection:
        selected = self.selected_question_ids
        returned = [item.question_id for item in self.returned_questions]
        if len(selected) != len(set(selected)) or len(returned) != len(set(returned)):
            raise ValueError("selection IDs must not repeat")
        if set(selected) & set(returned):
            raise ValueError("selected and returned IDs must be disjoint")
        if len(selected) + len(returned) != 15:
            raise ValueError("selection must partition all 15 candidates")
        if self.status == "ready" and len(selected) != 10:
            raise ValueError("ready selections require exactly ten questions")
        if self.status == "insufficient_quality" and len(selected) >= 10:
            raise ValueError("insufficient selections must contain fewer than ten")
        return self


class QwenSelectionError(RuntimeError):
    """Raised when Qwen cannot produce a complete, high-quality set."""


def _correct_answer(question: BankQuestion) -> str:
    return next(
        choice.label for choice in question.choices
        if choice.choice_id == question.correct_choice_id
    )


def selection_prompt(
    *,
    bank: VisualBankDocument,
    candidates: list[BankQuestion],
    prior_selected: list[BankQuestion],
    strictness: Literal["strict", "balanced"],
) -> str:
    candidate_payload = [
        question.model_dump(mode="json", exclude={"state", "set_id"})
        for question in candidates
    ]
    prior_payload = [
        {
            "question_id": question.question_id,
            "question": question.question,
            "correct_answer": _correct_answer(question),
        }
        for question in prior_selected
    ]
    strictness_rule = (
        "Be strict. Do not fill the quota with a questionable item. If fewer than "
        "ten candidates are sound, return status insufficient_quality and select "
        "only the sound candidates."
        if strictness == "strict"
        else
        "Reject material correctness, ambiguity, category, or duplicate problems. "
        "Accept minor wording or difficulty imperfections when the question remains "
        "clear, educational, and defensible."
    )
    return f"""Select the strongest ten questions for one children's visual quiz set.
Category: {bank.category}
Difficulty: {bank.difficulty}

{strictness_rule}

Requirements:
- exactly one answer choice must satisfy the clue;
- every choice must be a concrete, imageable subject within the category;
- facts and explanations must be accurate and deterministic;
- difficulty must be appropriate;
- avoid testing the same fact as a previously selected question;
- prefer variety in correct answers, facts, and category subtopics;
- do not rewrite questions or IDs.

When status is ready, select exactly ten IDs and return the remaining five with the
most important reason each was not selected. Partition all fifteen candidate IDs.

Previously selected questions:
{json.dumps(prior_payload, indent=2, ensure_ascii=True)}

Candidate questions:
{json.dumps(candidate_payload, indent=2, ensure_ascii=True)}
"""


def _request_selection(
    *,
    client: VLLMClient,
    model: str,
    prompt: str,
    candidate_ids: set[str],
    seed: int,
    output_dir: Path,
    label: str,
    retries: int,
    force: bool,
    progress: Callable[[str], None] | None,
) -> QwenBatchSelection:
    decision_path = output_dir / f"{label}.json"
    if decision_path.exists() and not force:
        decision = QwenBatchSelection.model_validate_json(
            decision_path.read_text(encoding="utf-8")
        )
        if progress:
            progress(f"{label}: reusing saved Qwen decision")
        return decision

    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / f"{label}.prompt.txt").write_text(prompt, encoding="utf-8")
    last_error = "unknown response error"
    messages = [
        {
            "role": "system",
            "content": (
                "You are a strict children's quiz editor. Return only the requested "
                "JSON and never invent or rewrite candidate IDs."
            ),
        },
        {"role": "user", "content": prompt},
    ]
    for attempt in range(1, retries + 2):
        if progress:
            progress(f"{label}: Qwen attempt {attempt}/{retries + 1}")
        raw: str | None = None
        try:
            raw = client.generate_json(
                model=model,
                messages=messages,
                schema=QwenBatchSelection.model_json_schema(),
                schema_name="visual_quiz_selection",
                seed=seed + attempt - 1,
                temperature=0.1,
                max_tokens=4_000,
            )
            (output_dir / f"{label}.attempt-{attempt:02d}.raw.txt").write_text(
                raw, encoding="utf-8"
            )
            decision = QwenBatchSelection.model_validate_json(raw)
            output_ids = set(decision.selected_question_ids) | {
                item.question_id for item in decision.returned_questions
            }
            if output_ids != candidate_ids:
                raise ValueError("Qwen response does not cover the exact candidate IDs")
            write_model(decision_path, decision)
            return decision
        except (ValidationError, VLLMError, ValueError) as exc:
            last_error = str(exc)
            if attempt > retries:
                break
            messages.extend(
                [
                    {"role": "assistant", "content": raw or "No complete response."},
                    {
                        "role": "user",
                        "content": (
                            "Regenerate the full JSON. The previous response failed: "
                            + last_error[:2000]
                        ),
                    },
                ]
            )
    raise QwenSelectionError(f"{label} failed: {last_error}")


def select_sets_with_qwen(
    *,
    source_bank: VisualBankDocument,
    client: VLLMClient,
    model: str,
    output_root: Path,
    set_count: int,
    seed: int,
    strictness: Literal["strict", "balanced"] = "strict",
    retries: int = 2,
    force: bool = False,
    progress: Callable[[str], None] | None = None,
) -> tuple[VisualBankDocument, list[VisualQuizSet]]:
    bank = source_bank.model_copy(deep=True)
    for question in bank.questions:
        question.state = "available"
        question.set_id = None

    rng = random.Random(seed)
    queue = list(bank.questions)
    rng.shuffle(queue)
    selected_history: list[BankQuestion] = []
    quiz_sets: list[VisualQuizSet] = []
    decision_dir = output_root / "selections" / bank.difficulty
    set_dir = output_root / "sets" / bank.difficulty

    for set_number in range(1, set_count + 1):
        if len(queue) < 15:
            break
        candidates = queue[:15]
        queue = queue[15:]
        label = f"selection_{set_number:03d}"
        prompt = selection_prompt(
            bank=bank,
            candidates=candidates,
            prior_selected=selected_history,
            strictness=strictness,
        )
        decision = _request_selection(
            client=client,
            model=model,
            prompt=prompt,
            candidate_ids={item.question_id for item in candidates},
            seed=seed + set_number * 10_007,
            output_dir=decision_dir,
            label=label,
            retries=retries,
            force=force,
            progress=progress,
        )
        if decision.status != "ready":
            raise QwenSelectionError(
                f"{bank.difficulty} set {set_number:03d} has only "
                f"{len(decision.selected_question_ids)} strict selections; "
                "rerun with --strictness balanced only after reviewing the decision"
            )
        by_id = {question.question_id: question for question in candidates}
        selected = [by_id[item] for item in decision.selected_question_ids]
        returned = [by_id[item.question_id] for item in decision.returned_questions]
        queue.extend(returned)
        quiz_set = build_visual_quiz_set(
            bank,
            selected,
            set_number=set_number,
            seed=seed + set_number * 20_011,
            selection_model=model,
        )
        for question in selected:
            question.state = "allocated"
            question.set_id = quiz_set.set_id
        selected_history.extend(selected)
        quiz_sets.append(quiz_set)
        write_model(set_dir / f"{quiz_set.set_id}.json", quiz_set)
        if progress:
            progress(
                f"{label}: selected 10, returned 5, stack now {len(queue)}"
            )

    if len(quiz_sets) != set_count:
        raise QwenSelectionError(
            f"created {len(quiz_sets)} of {set_count} requested {bank.difficulty} sets"
        )
    bank_path = output_root / "banks" / bank.difficulty / "bank.json"
    write_model(bank_path, bank)
    return bank, quiz_sets


def append_sets_with_qwen(
    *,
    source_bank: VisualBankDocument,
    client: VLLMClient,
    model: str,
    output_root: Path,
    set_count: int,
    first_set_number: int,
    seed: int,
    strictness: Literal["strict", "balanced"] = "strict",
    retries: int = 2,
    force: bool = False,
    persist: bool = True,
    checkpoint: Callable[[VisualBankDocument, VisualQuizSet], None] | None = None,
    candidate_batch_retries: int = 3,
    progress: Callable[[str], None] | None = None,
) -> tuple[VisualBankDocument, list[VisualQuizSet]]:
    if set_count < 1:
        raise ValueError("set_count must be at least one")
    if first_set_number < 1:
        raise ValueError("first_set_number must be at least one")
    if candidate_batch_retries < 1:
        raise ValueError("candidate_batch_retries must be at least one")
    bank = source_bank.model_copy(deep=True)
    available = [question for question in bank.questions if question.state == "available"]
    capacity = max(0, (len(available) - 5) // 10)
    if set_count > capacity:
        raise QwenSelectionError(
            f"{bank.difficulty} has capacity for {capacity} additional set(s); "
            f"{len(available)} available questions cannot support {set_count} "
            "independent 15-candidate selections"
        )

    rng = random.Random(seed)
    queue = list(available)
    rng.shuffle(queue)
    selected_history = [
        question for question in bank.questions if question.state == "allocated"
    ]
    quiz_sets: list[VisualQuizSet] = []
    decision_dir = output_root / "selections" / bank.difficulty
    set_dir = output_root / "sets" / bank.difficulty

    for offset in range(set_count):
        set_number = first_set_number + offset
        decision: QwenBatchSelection | None = None
        candidates: list[BankQuestion] = []
        label = f"selection_{set_number:03d}"
        for batch_attempt in range(1, candidate_batch_retries + 1):
            candidates = queue[:15]
            queue = queue[15:]
            attempt_label = (
                label if batch_attempt == 1 else f"{label}_batch_{batch_attempt:02d}"
            )
            decision = _request_selection(
                client=client,
                model=model,
                prompt=selection_prompt(
                    bank=bank,
                    candidates=candidates,
                    prior_selected=selected_history,
                    strictness=strictness,
                ),
                candidate_ids={item.question_id for item in candidates},
                seed=seed + set_number * 10_007 + (batch_attempt - 1) * 97,
                output_dir=decision_dir,
                label=attempt_label,
                retries=retries,
                force=force,
                progress=progress,
            )
            if decision.status == "ready":
                break
            # No question is consumed by an incomplete selection. Rotate the full
            # batch so the next attempt starts with fresh reserve material.
            queue.extend(candidates)
            if progress:
                progress(
                    f"{attempt_label}: insufficient quality; moved batch to queue end"
                )
        if decision is None or decision.status != "ready":
            selected_count = len(decision.selected_question_ids) if decision else 0
            raise QwenSelectionError(
                f"{bank.difficulty} set {set_number:03d} stopped after "
                f"{candidate_batch_retries} candidate batches; best final batch had "
                f"{selected_count} strict selections"
            )
        by_id = {question.question_id: question for question in candidates}
        selected = [by_id[item] for item in decision.selected_question_ids]
        returned = [by_id[item.question_id] for item in decision.returned_questions]
        queue.extend(returned)
        quiz_set = build_visual_quiz_set(
            bank,
            selected,
            set_number=set_number,
            seed=seed + set_number * 20_011,
            selection_model=model,
        )
        for question in selected:
            question.state = "allocated"
            question.set_id = quiz_set.set_id
        selected_history.extend(selected)
        quiz_sets.append(quiz_set)
        if checkpoint:
            checkpoint(bank.model_copy(deep=True), quiz_set)
        if progress:
            progress(
                f"{label}: selected 10, returned 5, stack now {len(queue)}"
            )

    # Decisions are retained while bank and set documents are committed only after
    # every requested selection succeeds.
    if persist:
        for quiz_set in quiz_sets:
            write_model(set_dir / f"{quiz_set.set_id}.json", quiz_set)
        write_model(output_root / "banks" / bank.difficulty / "bank.json", bank)
    return bank, quiz_sets
