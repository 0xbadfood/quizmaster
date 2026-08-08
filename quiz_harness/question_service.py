from __future__ import annotations

import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, TypeVar

from pydantic import BaseModel, ValidationError

from .client import VLLMClient, VLLMError
from .question_audit import compare_questions
from .question_models import (
    CandidateQuestionPool,
    FinalQuestionSet,
    ContentQuestion,
    QuestionSetPayload,
    QuestionChoice,
    PerQuestionValidation,
    ReplacementQuestion,
    SetGenerationRequest,
    ValidationResult,
    normalize_text,
)
from .question_prompts import (
    DRAFTER_SYSTEM_PROMPT,
    VALIDATOR_SYSTEM_PROMPT,
    PER_QUESTION_VALIDATOR_SYSTEM_PROMPT,
    REPLACER_SYSTEM_PROMPT,
    build_drafter_prompt,
    build_validator_prompt,
    build_per_question_validator_prompt,
    build_replacement_prompt,
)
from .service import escape_json_string_controls


class QuestionSetGenerationError(RuntimeError):
    """Raised when drafting or independent validation cannot produce a valid set."""


ModelType = TypeVar("ModelType", bound=BaseModel)


def _write_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def _write_json(path: Path, value: BaseModel | dict[str, object]) -> None:
    if isinstance(value, BaseModel):
        content = value.model_dump_json(indent=2)
    else:
        content = json.dumps(value, indent=2, ensure_ascii=True)
    _write_text(path, content + "\n")


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_") or "quiz"


def set_identifier(request: SetGenerationRequest) -> str:
    return f"{_slug(request.category)}_{request.difficulty}_{request.set_number:03d}"


def set_output_directory(root: Path, request: SetGenerationRequest) -> Path:
    return root / _slug(request.category) / request.difficulty / set_identifier(request)


def balance_answer_positions(
    questions: list[ContentQuestion], *, seed: int
) -> list[ContentQuestion]:
    base_positions = [
        "choice1",
        "choice2",
        "choice3",
        "choice1",
        "choice2",
        "choice3",
        "choice1",
        "choice2",
        "choice3",
        "choice1",
    ]
    shift = seed % 3
    ids = ("choice1", "choice2", "choice3")
    targets = [ids[(ids.index(position) + shift) % 3] for position in base_positions]
    balanced: list[ContentQuestion] = []
    for question, target in zip(questions, targets, strict=True):
        correct = next(
            choice for choice in question.choices
            if choice.choice_id == question.correct_choice_id
        )
        distractors = [
            choice for choice in question.choices
            if choice.choice_id != question.correct_choice_id
        ]
        texts: list[str] = []
        distractor_index = 0
        for choice_id in ids:
            if choice_id == target:
                texts.append(correct.text)
            else:
                texts.append(distractors[distractor_index].text)
                distractor_index += 1
        balanced.append(
            question.model_copy(
                update={
                    "choices": [
                        QuestionChoice(choice_id=choice_id, text=text)
                        for choice_id, text in zip(ids, texts, strict=True)
                    ],
                    "correct_choice_id": target,
                }
            )
        )
    return balanced


def load_question_bank(
    output_root: Path, request: SetGenerationRequest
) -> list[ContentQuestion]:
    category_root = output_root / _slug(request.category) / request.difficulty
    bank: list[ContentQuestion] = []
    current_id = set_identifier(request)
    for path in sorted(category_root.glob("*/final.json")):
        document = FinalQuestionSet.model_validate_json(
            path.read_text(encoding="utf-8")
        )
        if document.set_id == current_id:
            continue
        bank.extend(document.questions)
    return bank


def question_bank_prompt(
    questions: list[ContentQuestion]
) -> list[dict[str, str]]:
    return [
        {
            "question_id": question.question_id,
            "question": question.question,
            "correct_answer": _correct_answer(question),
            "topic_key": question.topic_key,
        }
        for question in questions
    ]


def _correct_answer(question: ContentQuestion) -> str:
    return next(
        choice.text
        for choice in question.choices
        if choice.choice_id == question.correct_choice_id
    )


def duplicate_matches(
    candidate: ContentQuestion,
    bank: list[ContentQuestion],
) -> list[dict[str, str]]:
    matches: list[dict[str, str]] = []
    for existing in bank:
        evidence = compare_questions(existing, candidate)
        if not evidence["likely_duplicate"]:
            continue
        matches.append(
            {
                "question_id": existing.question_id,
                "question": existing.question,
                "topic_key": existing.topic_key,
                "evidence": (
                    "exact"
                    if evidence["exact_question"]
                    else f"wording={evidence['wording_similarity']}, "
                    f"concept={evidence['concept_similarity']}"
                ),
            }
        )
    return matches


def _request_model(
    *,
    stage: str,
    client: VLLMClient,
    model: str,
    messages: list[dict[str, str]],
    response_model: type[ModelType],
    seed: int,
    temperature: float,
    max_tokens: int,
    retries: int,
    output_dir: Path,
    progress: Callable[[str], None] | None,
) -> tuple[ModelType, int]:
    last_error = "unknown validation error"
    conversation = list(messages)
    for attempt in range(1, retries + 2):
        if progress:
            progress(f"{stage}: attempt {attempt}/{retries + 1}")
        raw: str | None = None
        try:
            raw = client.generate_json(
                model=model,
                messages=conversation,
                schema=response_model.model_json_schema(),
                schema_name=f"quiz_{stage}",
                seed=seed + attempt - 1,
                temperature=temperature,
                max_tokens=max_tokens,
            )
            _write_text(
                output_dir / f"{stage}-attempt-{attempt:02d}.raw.txt", raw
            )
            normalized, _ = escape_json_string_controls(raw)
            result = response_model.model_validate_json(normalized)
            if progress:
                progress(f"{stage}: structured response accepted")
            return result, attempt
        except (ValidationError, VLLMError) as exc:
            last_error = str(exc)
            if raw is None:
                _write_text(
                    output_dir / f"{stage}-attempt-{attempt:02d}.error.txt",
                    last_error + "\n",
                )
            if progress:
                progress(f"{stage}: rejected: {' '.join(last_error.split())[:220]}")
            if attempt > retries:
                break
            conversation.extend(
                [
                    {
                        "role": "assistant",
                        "content": raw or "The previous response did not complete.",
                    },
                    {
                        "role": "user",
                        "content": (
                            "Regenerate the complete JSON document. The prior response "
                            f"failed validation:\n{last_error[:5000]}\nCorrect every issue."
                        ),
                    },
                ]
            )
    raise QuestionSetGenerationError(
        f"{stage} failed after {retries + 1} attempts: {last_error}"
    )


def generate_question_set(
    *,
    request: SetGenerationRequest,
    drafter_client: VLLMClient,
    drafter_endpoint: str,
    drafter_model: str,
    validator_client: VLLMClient,
    validator_endpoint: str,
    validator_model: str,
    output_root: Path,
    retries: int,
    force: bool,
    progress: Callable[[str], None] | None = None,
) -> tuple[FinalQuestionSet, Path]:
    output_dir = set_output_directory(output_root, request)
    final_path = output_dir / "final.json"
    if final_path.exists() and not force:
        existing = FinalQuestionSet.model_validate_json(
            final_path.read_text(encoding="utf-8")
        )
        if (
            normalize_text(existing.category) != normalize_text(request.category)
            or existing.difficulty != request.difficulty
            or existing.language != request.language
        ):
            raise QuestionSetGenerationError(
                f"existing set at {final_path} does not match the request"
            )
        if progress:
            progress("set: reusing completed final JSON")
        return existing, final_path
    output_dir.mkdir(parents=True, exist_ok=True)
    _write_json(output_dir / "request.json", request)

    draft_prompt = build_drafter_prompt(request)
    _write_json(
        output_dir / "drafter-input.json",
        {
            "system": DRAFTER_SYSTEM_PROMPT,
            "user": draft_prompt,
            "endpoint": drafter_endpoint,
            "model": drafter_model,
        },
    )
    draft_path = output_dir / "draft.json"
    if draft_path.exists() and not force:
        candidate = CandidateQuestionPool.model_validate_json(
            draft_path.read_text(encoding="utf-8")
        )
        draft_attempts = 0
        if progress:
            progress("draft: reusing accepted candidate pool")
    else:
        candidate, draft_attempts = _request_model(
            stage="draft",
            client=drafter_client,
            model=drafter_model,
            messages=[
                {"role": "system", "content": DRAFTER_SYSTEM_PROMPT},
                {"role": "user", "content": draft_prompt},
            ],
            response_model=CandidateQuestionPool,
            seed=request.seed,
            temperature=0.75,
            max_tokens=10_000,
            retries=retries,
            output_dir=output_dir,
            progress=progress,
        )
    if normalize_text(candidate.category) != normalize_text(request.category):
        raise QuestionSetGenerationError("drafter returned the wrong category")
    if candidate.difficulty != request.difficulty:
        raise QuestionSetGenerationError("drafter returned the wrong difficulty")
    _write_json(draft_path, candidate)

    validator_prompt = build_validator_prompt(request, candidate)
    _write_json(
        output_dir / "validator-input.json",
        {
            "system": VALIDATOR_SYSTEM_PROMPT,
            "user": validator_prompt,
            "endpoint": validator_endpoint,
            "model": validator_model,
        },
    )
    validation_path = output_dir / "validation.json"
    raw_validations = sorted(output_dir.glob("validation-attempt-*.raw.txt"))
    validation: ValidationResult | None = None
    validator_attempts = 0
    if not force:
        if validation_path.exists():
            validation = ValidationResult.model_validate_json(
                validation_path.read_text(encoding="utf-8")
            )
            if progress:
                progress("validation: reusing accepted review")
        elif raw_validations:
            try:
                validation = ValidationResult.model_validate_json(
                    raw_validations[-1].read_text(encoding="utf-8")
                )
                validator_attempts = int(raw_validations[-1].stem.split("-")[-1])
                if progress:
                    progress("validation: resuming structurally accepted review")
            except (OSError, ValueError, ValidationError):
                validation = None
    if validation is None:
        validation, validator_attempts = _request_model(
            stage="validation",
            client=validator_client,
            model=validator_model,
            messages=[
                {"role": "system", "content": VALIDATOR_SYSTEM_PROMPT},
                {"role": "user", "content": validator_prompt},
            ],
            response_model=ValidationResult,
            seed=request.seed + 100_000,
            temperature=0.2,
            max_tokens=14_000,
            retries=retries,
            output_dir=output_dir,
            progress=progress,
        )
    reviewed_payload = validation.final_set
    final_payload = QuestionSetPayload(
        schema_version="1.0",
        category=reviewed_payload.category,
        difficulty=reviewed_payload.difficulty,
        questions=balance_answer_positions(
            reviewed_payload.questions, seed=request.seed
        ),
    )
    if normalize_text(final_payload.category) != normalize_text(request.category):
        raise QuestionSetGenerationError("validator returned the wrong category")
    if final_payload.difficulty != request.difficulty:
        raise QuestionSetGenerationError("validator returned the wrong difficulty")
    candidate_ids = {question.question_id for question in candidate.questions}
    reviewed_ids = {review.question_id for review in validation.reviews}
    if reviewed_ids != candidate_ids:
        raise QuestionSetGenerationError(
            "validator reviews do not cover the candidate question IDs"
        )
    final_ids = {question.question_id for question in final_payload.questions}
    for review in validation.reviews:
        if review.question_id in final_ids and review.decision == "rejected":
            raise QuestionSetGenerationError(
                "validator included a rejected candidate in final_set"
            )
    normalized_reviews = [
        review.model_copy(
            update={
                "decision": (
                    "selected"
                    if review.question_id in final_ids
                    else "reserve"
                    if review.decision == "selected"
                    else review.decision
                )
            }
        )
        for review in validation.reviews
    ]
    validation = validation.model_copy(update={"reviews": normalized_reviews})
    selected_ids = {
        review.question_id
        for review in validation.reviews
        if review.decision == "selected"
    }
    replacement_count = len(final_ids - candidate_ids)
    if validation.status == "approved" and replacement_count:
        raise QuestionSetGenerationError(
            "validator marked an output approved despite adding replacements"
        )
    if validation.status == "revised" and replacement_count == 0:
        raise QuestionSetGenerationError(
            "validator marked an output revised without adding replacements"
        )
    _write_json(validation_path, validation)

    set_id = set_identifier(request)
    questions = [
        question.model_copy(update={"question_id": f"{set_id}_q{index:02d}"})
        for index, question in enumerate(final_payload.questions, start=1)
    ]
    final_set = FinalQuestionSet(
        schema_version="1.0",
        set_id=set_id,
        category=request.category,
        difficulty=request.difficulty,
        language=request.language,
        questions=questions,
    )
    _write_json(final_path, final_set)
    _write_json(
        output_dir / "run.json",
        {
            "set_id": set_id,
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "seed": request.seed,
            "drafter": {
                "endpoint": drafter_endpoint,
                "model": drafter_model,
                "attempts": draft_attempts,
            },
            "validator": {
                "endpoint": validator_endpoint,
                "model": validator_model,
                "attempts": validator_attempts,
                "status": validation.status,
                "selected_candidates": len(selected_ids),
                "reserve_candidates": sum(
                    review.decision == "reserve" for review in validation.reviews
                ),
                "rejected_candidates": sum(
                    review.decision == "rejected" for review in validation.reviews
                ),
                "replacements": replacement_count,
            },
            "deduplication": "deferred_to_phase_2",
        },
    )
    return final_set, final_path


def generate_question_set_phase2(
    *,
    request: SetGenerationRequest,
    drafter_client: VLLMClient,
    drafter_endpoint: str,
    drafter_model: str,
    validator_client: VLLMClient,
    validator_endpoint: str,
    validator_model: str,
    output_root: Path,
    retries: int,
    force: bool,
    progress: Callable[[str], None] | None = None,
) -> tuple[FinalQuestionSet, Path]:
    output_dir = set_output_directory(output_root, request)
    final_path = output_dir / "final.json"
    if final_path.exists() and not force:
        existing = FinalQuestionSet.model_validate_json(
            final_path.read_text(encoding="utf-8")
        )
        if progress:
            progress("set: reusing completed final JSON")
        return existing, final_path

    output_dir.mkdir(parents=True, exist_ok=True)
    _write_json(output_dir / "request.json", request)
    prior_bank = load_question_bank(output_root, request)
    prior_bank_payload = question_bank_prompt(prior_bank)
    draft_prompt = build_drafter_prompt(request, prior_bank_payload)
    _write_json(
        output_dir / "drafter-input.json",
        {
            "system": DRAFTER_SYSTEM_PROMPT,
            "user": draft_prompt,
            "endpoint": drafter_endpoint,
            "model": drafter_model,
            "phase": "2.0",
        },
    )
    draft_path = output_dir / "draft.json"
    if draft_path.exists() and not force:
        candidate_pool = CandidateQuestionPool.model_validate_json(
            draft_path.read_text(encoding="utf-8")
        )
        draft_attempts = 0
        if progress:
            progress("draft: reusing accepted candidate pool")
    else:
        candidate_pool = None
        raw_drafts = sorted(output_dir.glob("draft-attempt-*.raw.txt"))
        if raw_drafts and not force:
            try:
                candidate_pool = CandidateQuestionPool.model_validate_json(
                    raw_drafts[-1].read_text(encoding="utf-8")
                )
                draft_attempts = int(raw_drafts[-1].stem.split("-")[-1])
                if progress:
                    progress("draft: resuming structurally accepted raw pool")
            except (OSError, ValueError, ValidationError):
                candidate_pool = None
        if candidate_pool is None:
            candidate_pool, draft_attempts = _request_model(
                stage="draft",
                client=drafter_client,
                model=drafter_model,
                messages=[
                    {"role": "system", "content": DRAFTER_SYSTEM_PROMPT},
                    {"role": "user", "content": draft_prompt},
                ],
                response_model=CandidateQuestionPool,
                seed=request.seed,
                temperature=0.75,
                max_tokens=10_000,
                retries=retries,
                output_dir=output_dir,
                progress=progress,
            )
    if normalize_text(candidate_pool.category) != normalize_text(request.category):
        raise QuestionSetGenerationError("drafter returned the wrong category")
    if candidate_pool.difficulty != request.difficulty:
        raise QuestionSetGenerationError("drafter returned the wrong difficulty")
    _write_json(draft_path, candidate_pool)

    provisional_bank = list(prior_bank)
    accepted: list[dict[str, Any]] = []
    records: list[dict[str, Any]] = []
    total_validator_attempts = 0

    for index, candidate in enumerate(candidate_pool.questions, start=1):
        matches = duplicate_matches(candidate, provisional_bank)
        if matches:
            records.append(
                {
                    "candidate_index": index,
                    "candidate_question_id": candidate.question_id,
                    "decision": "rejected",
                    "source": "local_duplicate_gate",
                    "issue_codes": ["duplicate"],
                    "duplicate_matches": matches,
                    "question": candidate.model_dump(mode="json"),
                }
            )
            if progress:
                progress(
                    f"candidate {index}/14: local duplicate rejected "
                    f"({matches[0]['question'][:80]})"
                )
            continue

        review_path = output_dir / f"phase2-review-{index:02d}.json"
        review: PerQuestionValidation | None = None
        review_attempts = 0
        if review_path.exists() and not force:
            saved_review = json.loads(review_path.read_text(encoding="utf-8"))
            saved_review.pop("question", None)  # Compatibility with early phase2 runs.
            review = PerQuestionValidation.model_validate(saved_review)
            if progress:
                progress(f"candidate {index}/14: reusing Laguna review")
        if review is None:
            prompt = build_per_question_validator_prompt(
                request,
                candidate,
                question_bank_prompt(provisional_bank),
                [],
            )
            review, review_attempts = _request_model(
                stage=f"phase2-review-{index:02d}",
                client=validator_client,
                model=validator_model,
                messages=[
                    {
                        "role": "system",
                        "content": PER_QUESTION_VALIDATOR_SYSTEM_PROMPT,
                    },
                    {"role": "user", "content": prompt},
                ],
                response_model=PerQuestionValidation,
                seed=request.seed + 200_000 + index * 101,
                temperature=0.1,
                max_tokens=3_000,
                retries=retries,
                output_dir=output_dir,
                progress=progress,
            )
            _write_json(review_path, review)
        total_validator_attempts += review_attempts
        assessed_correct = [
            item.choice_id
            for item in review.choice_assessments
            if item.verdict == "correct"
        ]
        protocol_mismatch = (
            review.candidate_question_id != candidate.question_id
            or (
                review.decision == "accepted"
                and assessed_correct != [candidate.correct_choice_id]
            )
        )
        record = {
            "candidate_index": index,
            "source": "laguna_per_question",
            **review.model_dump(mode="json"),
            "question": candidate.model_dump(mode="json"),
        }
        if protocol_mismatch:
            record.update(
                {
                    "decision": "rejected",
                    "issue_codes": ["ambiguous_answer"],
                    "protocol_mismatch": True,
                }
            )
        records.append(record)
        if review.decision == "accepted" and not protocol_mismatch:
            score = (
                review.selection_score
            )
            accepted.append(
                {"question": candidate, "score": score, "candidate_index": index}
            )
            provisional_bank.append(candidate)
            if progress:
                progress(f"candidate {index}/14: accepted (score {score}/100)")
            if len(accepted) == 10:
                if progress:
                    progress("candidate pool: secured 10 validated questions")
                break
        elif progress:
            progress(
                f"candidate {index}/14: rejected "
                f"({', '.join(record['issue_codes'])})"
            )

    accepted.sort(key=lambda item: (-item["score"], item["candidate_index"]))
    selected = accepted[:10]
    rejected_summary = [
        {
            "question": record["question"]["question"],
            "issue_codes": record["issue_codes"],
        }
        for record in records
        if record["decision"] == "rejected"
    ]
    replacement_attempts = 0
    replacement_limit = 20
    while len(selected) < 10 and replacement_attempts < replacement_limit:
        replacement_attempts += 1
        slot = len(selected) + 1
        if progress:
            progress(
                f"replacement {replacement_attempts}: filling final slot {slot}/10"
            )
        replacement_prompt = build_replacement_prompt(
            request,
            question_bank_prompt(provisional_bank),
            rejected_summary,
            replacement_attempts,
        )
        replacement, replacement_generation_attempts = _request_model(
            stage=f"phase2-replacement-{replacement_attempts:02d}",
            client=validator_client,
            model=validator_model,
            messages=[
                {"role": "system", "content": REPLACER_SYSTEM_PROMPT},
                {"role": "user", "content": replacement_prompt},
            ],
            response_model=ReplacementQuestion,
            seed=request.seed + 400_000 + replacement_attempts * 211,
            temperature=0.55,
            max_tokens=2_500,
            retries=retries,
            output_dir=output_dir,
            progress=progress,
        )
        total_validator_attempts += replacement_generation_attempts
        matches = duplicate_matches(replacement.question, provisional_bank)
        if matches:
            rejected_summary.append(
                {
                    "question": replacement.question.question,
                    "issue_codes": ["duplicate"],
                }
            )
            records.append(
                {
                    "source": "laguna_replacement",
                    "decision": "rejected",
                    "issue_codes": ["duplicate"],
                    "duplicate_matches": matches,
                    "question": replacement.question.model_dump(mode="json"),
                }
            )
            continue

        review_prompt = build_per_question_validator_prompt(
            request,
            replacement.question,
            question_bank_prompt(provisional_bank),
            [],
        )
        replacement_review, replacement_review_attempts = _request_model(
            stage=f"phase2-replacement-review-{replacement_attempts:02d}",
            client=validator_client,
            model=validator_model,
            messages=[
                {
                    "role": "system",
                    "content": PER_QUESTION_VALIDATOR_SYSTEM_PROMPT,
                },
                {"role": "user", "content": review_prompt},
            ],
            response_model=PerQuestionValidation,
            seed=request.seed + 500_000 + replacement_attempts * 307,
            temperature=0.1,
            max_tokens=3_000,
            retries=retries,
            output_dir=output_dir,
            progress=progress,
        )
        total_validator_attempts += replacement_review_attempts
        records.append(
            {
                "source": "laguna_replacement",
                "replacement_rationale": replacement.rationale,
                **replacement_review.model_dump(mode="json"),
                "question": replacement.question.model_dump(mode="json"),
            }
        )
        replacement_correct = [
            item.choice_id
            for item in replacement_review.choice_assessments
            if item.verdict == "correct"
        ]
        replacement_protocol_mismatch = (
            replacement_review.candidate_question_id
            != replacement.question.question_id
            or (
                replacement_review.decision == "accepted"
                and replacement_correct != [replacement.question.correct_choice_id]
            )
        )
        if replacement_review.decision != "accepted" or replacement_protocol_mismatch:
            rejected_summary.append(
                {
                    "question": replacement.question.question,
                    "issue_codes": (
                        ["ambiguous_answer"]
                        if replacement_protocol_mismatch
                        else replacement_review.issue_codes
                    ),
                }
            )
            continue
        score = (
            replacement_review.selection_score
        )
        selected.append(
            {
                "question": replacement.question,
                "score": score,
                "candidate_index": 100 + replacement_attempts,
            }
        )
        provisional_bank.append(replacement.question)

    _write_json(
        output_dir / "phase2-validation.json",
        {
            "schema_version": "1.0",
            "prior_bank_question_count": len(prior_bank),
            "candidate_count": 14,
            "accepted_candidate_count": len(accepted),
            "records": records,
        },
    )
    if len(selected) < 10:
        raise QuestionSetGenerationError(
            f"phase 2 produced only {len(selected)} accepted questions after "
            f"{replacement_attempts} replacement attempts"
        )

    balanced = balance_answer_positions(
        [item["question"] for item in selected[:10]], seed=request.seed
    )
    payload = QuestionSetPayload(
        schema_version="1.0",
        category=request.category,
        difficulty=request.difficulty,
        questions=balanced,
    )
    set_id = set_identifier(request)
    final_set = FinalQuestionSet(
        schema_version="1.0",
        set_id=set_id,
        category=request.category,
        difficulty=request.difficulty,
        language=request.language,
        questions=[
            question.model_copy(
                update={"question_id": f"{set_id}_q{index:02d}"}
            )
            for index, question in enumerate(payload.questions, start=1)
        ],
    )
    _write_json(final_path, final_set)
    _write_json(
        output_dir / "run.json",
        {
            "set_id": set_id,
            "phase": "2.0",
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "seed": request.seed,
            "prior_bank_question_count": len(prior_bank),
            "drafter": {
                "endpoint": drafter_endpoint,
                "model": drafter_model,
                "attempts": draft_attempts,
                "candidate_count": 14,
            },
            "validator": {
                "endpoint": validator_endpoint,
                "model": validator_model,
                "attempts": total_validator_attempts,
                "local_duplicate_rejections": sum(
                    record["source"] == "local_duplicate_gate"
                    for record in records
                ),
                "llm_rejections": sum(
                    record["decision"] == "rejected"
                    and record["source"] != "local_duplicate_gate"
                    for record in records
                ),
                "accepted_candidates": len(accepted),
                "replacement_attempts": replacement_attempts,
            },
            "deduplication": "phase_2_bank_aware",
        },
    )
    return final_set, final_path
