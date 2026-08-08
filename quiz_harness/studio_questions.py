from __future__ import annotations

import hashlib
import json
import re
import threading
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Iterable, Literal

import httpx
from openai import APIStatusError, OpenAI
from pydantic import Field, ValidationError

from .database import QuizDatabase
from .models import StrictModel
from .visual_bank import BankQuestion


DIFFICULTIES = ("beginner", "intermediate")
REVIEW_STATUSES = ("unreviewed", "approved", "needs_edit", "rejected")
QUESTION_GENERATION_PROVIDER_TYPES = {
    "openai_compatible_llm",
    "openai_images",
}
BANK_WRITE_LOCK = threading.Lock()


class QuestionBankError(ValueError):
    """Raised when a Studio question-bank operation is invalid."""


class GeneratedStudioChoice(StrictModel):
    label: Annotated[str, Field(min_length=2, max_length=60)]
    object_key: Annotated[str, Field(min_length=1, max_length=80)]


class GeneratedStudioQuestion(StrictModel):
    question: Annotated[str, Field(min_length=12, max_length=180)]
    choices: Annotated[list[GeneratedStudioChoice], Field(min_length=4, max_length=4)]
    correct_choice_id: Literal["choice1", "choice2", "choice3", "choice4"]
    explanation: Annotated[str, Field(min_length=20, max_length=360)]


class GeneratedStudioBatch(StrictModel):
    questions: Annotated[
        list[GeneratedStudioQuestion], Field(min_length=1, max_length=50)
    ]


def normalize_text(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


def slugify(value: str) -> str:
    value = re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_")
    if not value or not value[0].isalpha():
        value = f"item_{value}" if value else "item"
    return value[:64]


def question_generation_prompt(
    *,
    category: dict[str, Any],
    sibling_names: list[str],
    difficulty: str,
    count: int,
) -> str:
    age_guidance = (
        f"children aged about {category['age_min']} to {category['age_max']}"
    )
    siblings = ", ".join(sibling_names) or "none"
    return f"""Create exactly {count} independent four-choice identification questions.

Category: {category['name']}
Editorial brief: {category['editorial_brief'] or category['description']}
Difficulty: {difficulty}
Audience: {age_guidance}
Separate sibling categories: {siblings}

Stay strictly inside the category and editorial brief. Do not borrow subjects that
clearly belong to a sibling category. Every question must use one deterministic,
well-established factual clue, exactly four distinct concrete answer choices, one
defensible answer, and a concise explanation that explicitly names the answer.
Avoid opinions, vague clues, disputed records, trick questions, and time-sensitive
claims. Choices must be visually representable as individual images.
Keep every choice label between 2 and 50 characters and every explanation between
20 and 320 characters.

Return one JSON object only with this shape:
{{
  "questions": [
    {{
      "question": "Which ...?",
      "choices": [
        {{"label": "...", "object_key": "lowercase_snake_case"}},
        {{"label": "...", "object_key": "lowercase_snake_case"}},
        {{"label": "...", "object_key": "lowercase_snake_case"}},
        {{"label": "...", "object_key": "lowercase_snake_case"}}
      ],
      "correct_choice_id": "choice1",
      "explanation": "..."
    }}
  ]
}}
The choices are ordered choice1 through choice4. Do not add image prompts, layout,
audio, markdown, or commentary."""


class QuestionBankStore:
    def __init__(self, root: Path, database: QuizDatabase) -> None:
        self.root = root
        self.database = database

    def bank_path(self, category_slug: str, difficulty: str) -> Path:
        self._difficulty(difficulty)
        return self.root / category_slug / "banks" / difficulty / "bank.json"

    @staticmethod
    def _difficulty(value: str) -> str:
        if value not in DIFFICULTIES:
            raise QuestionBankError("difficulty must be beginner or intermediate")
        return value

    @staticmethod
    def _read(path: Path) -> dict[str, Any]:
        if not path.exists():
            return {}
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise QuestionBankError(f"question bank is unreadable: {path}") from exc
        if not isinstance(payload, dict) or not isinstance(payload.get("questions"), list):
            raise QuestionBankError(f"question bank has an invalid document shape: {path}")
        return payload

    @staticmethod
    def _write(path: Path, document: dict[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(document, indent=2, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )
        temporary.replace(path)

    @staticmethod
    def _api_question(item: dict[str, Any]) -> dict[str, Any]:
        result = {key: value for key, value in item.items() if key != "choices"}
        result["choices"] = [
            {
                "choice_id": choice.get("choice_id", f"choice{index}"),
                "object_key": choice.get("object_key") or choice.get("animal_key"),
                "label": choice.get("label", ""),
            }
            for index, choice in enumerate(item.get("choices", []), start=1)
            if isinstance(choice, dict)
        ]
        return result

    @staticmethod
    def _stored_question(
        candidate: dict[str, Any],
        *,
        question_id: str,
        difficulty: str,
        state: str = "available",
        set_id: str | None = None,
    ) -> dict[str, Any]:
        choices = []
        for index, choice in enumerate(candidate["choices"], start=1):
            label = str(choice.get("label", "")).strip()
            object_key = str(
                choice.get("object_key") or choice.get("animal_key") or slugify(label)
            )
            choices.append(
                {
                    "choice_id": f"choice{index}",
                    # Keep the v1 bundle contract while the Studio exposes a generic name.
                    "animal_key": slugify(object_key),
                    "label": label,
                }
            )
        question_text = str(candidate["question"]).strip()
        correct_choice_id = str(candidate["correct_choice_id"])
        correct = next(
            choice for choice in choices if choice["choice_id"] == correct_choice_id
        )
        clue = "_".join(normalize_text(question_text).split()[:5])
        fingerprint = hashlib.sha1(question_text.encode("utf-8")).hexdigest()[:8]
        return {
            "question_id": question_id,
            "topic_key": slugify(f"{correct['animal_key']}_{clue}_{fingerprint}"),
            "difficulty": difficulty,
            "question": question_text,
            "choices": choices,
            "correct_choice_id": correct_choice_id,
            "explanation": str(candidate["explanation"]).strip(),
            "state": state,
            "set_id": set_id,
        }

    @staticmethod
    def validate_candidate(candidate: dict[str, Any]) -> list[str]:
        issues: list[str] = []
        question = str(candidate.get("question", "")).strip()
        explanation = str(candidate.get("explanation", "")).strip()
        choices = candidate.get("choices", [])
        correct_id = str(candidate.get("correct_choice_id", ""))
        if len(question) < 12 or len(question) > 180 or not question.endswith("?"):
            issues.append("Question must be 12-180 characters and end with a question mark.")
        if not isinstance(choices, list) or len(choices) != 4:
            issues.append("Exactly four choices are required.")
            return issues
        labels = [str(choice.get("label", "")).strip() for choice in choices]
        if any(len(label) < 2 or len(label) > 50 for label in labels):
            issues.append("Every choice needs a 2-50 character label.")
        if len({normalize_text(label) for label in labels}) != 4:
            issues.append("All four choice labels must be distinct.")
        if correct_id not in {f"choice{index}" for index in range(1, 5)}:
            issues.append("Correct answer must reference choice1 through choice4.")
        if len(explanation) < 20 or len(explanation) > 320:
            issues.append("Explanation must be 20-320 characters.")
        if correct_id in {f"choice{index}" for index in range(1, 5)}:
            answer = labels[int(correct_id[-1]) - 1]
            if normalize_text(answer) not in normalize_text(explanation):
                issues.append("Explanation must explicitly name the correct answer.")
        return issues

    def quarantine_contract_invalid(
        self, category_slug: str, difficulty: str
    ) -> dict[str, Any]:
        """Remove unallocated records that cannot satisfy the runtime bank schema."""
        self._difficulty(difficulty)
        path = self.bank_path(category_slug, difficulty)
        if not path.exists():
            return {"quarantined": 0, "question_ids": []}
        quarantined: list[str] = []
        with BANK_WRITE_LOCK:
            document = self._read(path)
            valid: list[dict[str, Any]] = []
            rejections = list(document.get("ingestion_rejections", []))
            for index, item in enumerate(document["questions"], start=1):
                try:
                    BankQuestion.model_validate(item)
                except ValidationError as exc:
                    question_id = str(item.get("question_id") or f"invalid_{index}")
                    if item.get("state") == "allocated":
                        raise QuestionBankError(
                            f"Allocated question {question_id} violates the runtime contract."
                        ) from exc
                    reasons = [
                        f"{'.'.join(str(part) for part in error['loc'])}: "
                        f"{error['msg']}"
                        for error in exc.errors()[:8]
                    ]
                    rejections.append(
                        {
                            "question_index": index,
                            "source_question_id": slugify(question_id),
                            "reasons": reasons,
                        }
                    )
                    quarantined.append(question_id)
                    continue
                valid.append(item)
            if quarantined:
                document["questions"] = valid
                document["ingestion_rejections"] = rejections
                self._write(path, document)
        return {"quarantined": len(quarantined), "question_ids": quarantined}

    def _documents(self, category_slug: str) -> dict[str, dict[str, Any]]:
        return {
            difficulty: self._read(self.bank_path(category_slug, difficulty))
            for difficulty in DIFFICULTIES
        }

    def list_questions(
        self,
        category_slug: str,
        *,
        difficulty: str = "all",
        state: str = "all",
        review: str = "all",
        query: str = "",
        page: int = 1,
        page_size: int = 30,
    ) -> dict[str, Any]:
        if difficulty != "all":
            self._difficulty(difficulty)
        if state not in {"all", "available", "allocated", "rejected"}:
            raise QuestionBankError("invalid bank state filter")
        if review not in {"all", *REVIEW_STATUSES}:
            raise QuestionBankError("invalid review filter")
        documents = self._documents(category_slug)
        reviews = self.database.question_reviews(category_slug)
        all_items: list[dict[str, Any]] = []
        normalized_seen: Counter[str] = Counter()
        for document in documents.values():
            for item in document.get("questions", []):
                if isinstance(item, dict):
                    normalized_seen[normalize_text(str(item.get("question", "")))] += 1
        for level, document in documents.items():
            for raw in document.get("questions", []):
                if not isinstance(raw, dict):
                    continue
                item = self._api_question(raw)
                item_review = reviews.get(item.get("question_id"), {})
                item["review_status"] = item_review.get("status", "unreviewed")
                item["review_notes"] = item_review.get("notes", "")
                item["reviewed_at"] = item_review.get("reviewed_at")
                issues = self.validate_candidate(item)
                if normalized_seen[normalize_text(item.get("question", ""))] > 1:
                    issues.append("Duplicate question text exists in this category.")
                item["validation_issues"] = issues
                item["locked"] = item.get("state") == "allocated"
                item["difficulty"] = level
                all_items.append(item)

        summary = self._summary(all_items)
        needle = normalize_text(query)
        filtered = [
            item
            for item in all_items
            if (difficulty == "all" or item["difficulty"] == difficulty)
            and (state == "all" or item.get("state") == state)
            and (review == "all" or item["review_status"] == review)
            and (
                not needle
                or needle in normalize_text(item.get("question", ""))
                or needle in normalize_text(item.get("question_id", ""))
                or any(
                    needle in normalize_text(choice.get("label", ""))
                    for choice in item.get("choices", [])
                )
            )
        ]
        filtered.sort(key=lambda item: (item["difficulty"], item["question_id"]))
        page = max(1, page)
        page_size = max(10, min(page_size, 100))
        start = (page - 1) * page_size
        pages = max(1, (len(filtered) + page_size - 1) // page_size)
        return {
            "summary": summary,
            "questions": filtered[start : start + page_size],
            "pagination": {
                "page": min(page, pages),
                "page_size": page_size,
                "pages": pages,
                "total": len(filtered),
            },
        }

    @staticmethod
    def _summary(items: list[dict[str, Any]]) -> dict[str, Any]:
        review_counts = Counter(item["review_status"] for item in items)
        state_counts = Counter(item.get("state", "available") for item in items)
        difficulty_counts = Counter(item["difficulty"] for item in items)
        return {
            "total": len(items),
            "usable": len(items) - state_counts["rejected"],
            "target": 240,
            "beginner": difficulty_counts["beginner"],
            "intermediate": difficulty_counts["intermediate"],
            "allocated": state_counts["allocated"],
            "available": state_counts["available"],
            "rejected": state_counts["rejected"],
            "unreviewed": review_counts["unreviewed"],
            "approved": review_counts["approved"],
            "needs_edit": review_counts["needs_edit"],
            "review_rejected": review_counts["rejected"],
            "validation_issues": sum(bool(item["validation_issues"]) for item in items),
        }

    def question(self, category_slug: str, difficulty: str, question_id: str) -> dict[str, Any]:
        item = None
        for page in (1, 2):
            payload = self.list_questions(
                category_slug,
                difficulty=difficulty,
                page=page,
                page_size=100,
            )
            item = next(
                (
                    question
                    for question in payload["questions"]
                    if question["question_id"] == question_id
                ),
                None,
            )
            if item is not None or page >= payload["pagination"]["pages"]:
                break
        if item is None:
            raise KeyError(question_id)
        item["revisions"] = self.database.question_revisions(
            category_slug, difficulty, question_id
        )
        return item

    def update_question(
        self,
        category_slug: str,
        difficulty: str,
        question_id: str,
        candidate: dict[str, Any],
    ) -> dict[str, Any]:
        self._difficulty(difficulty)
        issues = self.validate_candidate(candidate)
        if issues:
            raise QuestionBankError(" ".join(issues))
        path = self.bank_path(category_slug, difficulty)
        with BANK_WRITE_LOCK:
            document = self._read(path)
            index = next(
                (
                    index
                    for index, item in enumerate(document["questions"])
                    if item.get("question_id") == question_id
                ),
                None,
            )
            if index is None:
                raise KeyError(question_id)
            before = document["questions"][index]
            if before.get("state") == "allocated":
                raise QuestionBankError(
                    "Allocated questions are locked because published sets reference them."
                )
            after = self._stored_question(
                candidate,
                question_id=question_id,
                difficulty=difficulty,
                state=before.get("state", "available"),
                set_id=before.get("set_id"),
            )
            duplicate = next(
                (
                    item
                    for item in document["questions"]
                    if item.get("question_id") != question_id
                    and normalize_text(item.get("question", ""))
                    == normalize_text(after["question"])
                ),
                None,
            )
            other_difficulty = next(
                level for level in DIFFICULTIES if level != difficulty
            )
            other_document = self._read(
                self.bank_path(category_slug, other_difficulty)
            )
            duplicate = duplicate or next(
                (
                    item
                    for item in other_document.get("questions", [])
                    if normalize_text(item.get("question", ""))
                    == normalize_text(after["question"])
                ),
                None,
            )
            if duplicate:
                raise QuestionBankError(
                    f"Question duplicates {duplicate['question_id']}."
                )
            document["questions"][index] = after
            self._write(path, document)
        self.database.record_question_revision(
            category_slug=category_slug,
            difficulty=difficulty,
            question_id=question_id,
            action="edited",
            before=before,
            after=after,
        )
        return self.question(category_slug, difficulty, question_id)

    def review_question(
        self,
        category_slug: str,
        difficulty: str,
        question_id: str,
        *,
        status: str,
        notes: str = "",
    ) -> dict[str, Any]:
        if status not in REVIEW_STATUSES:
            raise QuestionBankError("invalid review status")
        self._difficulty(difficulty)
        path = self.bank_path(category_slug, difficulty)
        before: dict[str, Any] | None = None
        after: dict[str, Any] | None = None
        with BANK_WRITE_LOCK:
            document = self._read(path)
            item = next(
                (
                    candidate
                    for candidate in document["questions"]
                    if candidate.get("question_id") == question_id
                ),
                None,
            )
            if item is None:
                raise KeyError(question_id)
            before = dict(item)
            if status == "rejected":
                if item.get("state") == "allocated":
                    raise QuestionBankError(
                        "Allocated questions cannot be rejected until their set is replaced."
                    )
                item["state"] = "rejected"
                item["set_id"] = None
            elif status == "approved" and item.get("state") == "rejected":
                item["state"] = "available"
            after = dict(item)
            if before != after:
                self._write(path, document)
        review = self.database.upsert_question_review(
            category_slug=category_slug,
            difficulty=difficulty,
            question_id=question_id,
            status=status,
            notes=notes.strip()[:1000],
        )
        self.database.record_question_revision(
            category_slug=category_slug,
            difficulty=difficulty,
            question_id=question_id,
            action="reviewed",
            before=before,
            after={"question": after, "review": review},
        )
        return self.question(category_slug, difficulty, question_id)

    def bulk_review(
        self,
        category_slug: str,
        difficulty: str,
        question_ids: Iterable[str],
        *,
        status: str,
    ) -> dict[str, int]:
        updated = 0
        failed = 0
        for question_id in dict.fromkeys(question_ids):
            try:
                self.review_question(
                    category_slug,
                    difficulty,
                    question_id,
                    status=status,
                )
                updated += 1
            except (KeyError, QuestionBankError):
                failed += 1
        return {"updated": updated, "failed": failed}

    def import_questions(
        self,
        category: dict[str, Any],
        difficulty: str,
        candidates: list[dict[str, Any]],
        *,
        action: str = "imported",
        source_provider: str | None = None,
        source_model: str | None = None,
        limit: int | None = None,
    ) -> dict[str, Any]:
        self._difficulty(difficulty)
        path = self.bank_path(category["slug"], difficulty)
        accepted: list[dict[str, Any]] = []
        rejected: list[dict[str, Any]] = []
        with BANK_WRITE_LOCK:
            document = self._read(path) or {
                "schema_version": "visual_bank_v1",
                "category": category["name"],
                "difficulty": difficulty,
                "source_provider": "openai",
                "source_model": source_model or "manual_import",
                "source_response_id": f"studio_{action}",
                "generated_at_utc": datetime.now(timezone.utc).isoformat(),
                "questions": [],
                "ingestion_rejections": [],
            }
            existing_questions = document["questions"]
            existing_text = {
                normalize_text(item.get("question", "")) for item in existing_questions
            }
            other_difficulty = next(
                level for level in DIFFICULTIES if level != difficulty
            )
            other_document = self._read(
                self.bank_path(category["slug"], other_difficulty)
            )
            existing_text.update(
                normalize_text(item.get("question", ""))
                for item in other_document.get("questions", [])
                if isinstance(item, dict)
            )
            used_ids = {item.get("question_id") for item in existing_questions}
            number = 1
            for index, candidate in enumerate(candidates, start=1):
                if limit is not None and len(accepted) >= limit:
                    break
                if not isinstance(candidate, dict):
                    rejected.append({"index": index, "reasons": ["Question must be an object."]})
                    continue
                issues = self.validate_candidate(candidate)
                normalized = normalize_text(str(candidate.get("question", "")))
                if normalized in existing_text:
                    issues.append("Question duplicates an existing bank entry.")
                if issues:
                    rejected.append({"index": index, "reasons": issues})
                    continue
                while True:
                    question_id = slugify(
                        f"{category['slug']}_{difficulty}_{number:03d}"
                    )
                    number += 1
                    if question_id not in used_ids:
                        break
                item = self._stored_question(
                    candidate,
                    question_id=question_id,
                    difficulty=difficulty,
                )
                existing_questions.append(item)
                used_ids.add(question_id)
                existing_text.add(normalized)
                accepted.append(item)
            if len(existing_questions) > 150:
                raise QuestionBankError("A difficulty bank cannot exceed 150 questions.")
            if accepted:
                self._write(path, document)
        for item in accepted:
            self.database.record_question_revision(
                category_slug=category["slug"],
                difficulty=difficulty,
                question_id=item["question_id"],
                action=action,
                before=None,
                after=item,
                source_provider=source_provider,
                source_model=source_model,
            )
        return {
            "accepted": len(accepted),
            "rejected": len(rejected),
            "accepted_questions": [self._api_question(item) for item in accepted],
            "rejections": rejected,
        }


def generate_questions(
    *,
    category: dict[str, Any],
    sibling_names: list[str],
    difficulty: str,
    count: int,
    provider: dict[str, Any],
    secret: str | None,
    progress: Any,
    candidate_count: int | None = None,
) -> tuple[list[dict[str, Any]], str]:
    request_count = (
        min(50, candidate_count)
        if candidate_count is not None
        else min(30, count + max(2, min(5, count // 3)))
    )
    if request_count < 1:
        raise QuestionBankError("candidate count must be at least one")
    prompt = question_generation_prompt(
        category=category,
        sibling_names=sibling_names,
        difficulty=difficulty,
        count=request_count,
    )
    model = provider.get("default_model")
    if not model:
        models = provider.get("discovered_models", [])
        model = models[0] if models else None
    if not model:
        raise QuestionBankError("Choose or discover a default model before generation.")
    headers = {"Authorization": f"Bearer {secret}"} if secret else {}
    progress(f"Requesting {request_count} candidates from {model}", 0.2)
    if provider["provider_type"] == "openai_images":
        try:
            with OpenAI(
                api_key=secret,
                base_url=provider["base_url"],
                timeout=900,
            ) as client:
                response = client.responses.parse(
                    model=model,
                    instructions=(
                        "You create accurate children's quiz banks. Follow the "
                        "supplied schema exactly and prefer deterministic, "
                        "well-established facts."
                    ),
                    input=prompt,
                    text_format=GeneratedStudioBatch,
                    reasoning={"effort": "low"},
                    max_output_tokens=max(4000, request_count * 350),
                    store=False,
                )
        except APIStatusError as exc:
            detail = exc.response.text[:800]
            raise QuestionBankError(
                f"OpenAI Responses API failed ({exc.status_code}): {detail}"
            ) from exc
        parsed = response.output_parsed
        if parsed is None:
            raise QuestionBankError("OpenAI returned no parsed question batch.")
        progress("Validating generated candidates", 0.72)
        return [
            question.model_dump(mode="json") for question in parsed.questions
        ], str(model)

    with httpx.Client(timeout=900, headers=headers) as client:
        response = client.post(
            f"{provider['base_url'].rstrip('/')}/chat/completions",
            json={
                "model": model,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "You create accurate children's quiz banks and return "
                            "strict JSON without markdown."
                        ),
                    },
                    {"role": "user", "content": prompt},
                ],
                "temperature": 0.35,
                "max_tokens": max(4000, request_count * 350),
                "response_format": {"type": "json_object"},
            },
        )
        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise QuestionBankError(
                f"LLM request failed ({response.status_code}): {response.text[:800]}"
            ) from exc
        payload = response.json()
    progress("Validating generated candidates", 0.72)
    content = payload["choices"][0]["message"]["content"]
    if isinstance(content, list):
        content = "".join(
            str(item.get("text", "")) for item in content if isinstance(item, dict)
        )
    serialized = str(content).strip()
    if serialized.startswith("```"):
        serialized = re.sub(r"^```(?:json)?\s*|\s*```$", "", serialized)
    parsed = json.loads(serialized)
    questions = parsed.get("questions", []) if isinstance(parsed, dict) else []
    if not isinstance(questions, list):
        raise QuestionBankError("Model response does not contain a questions array.")
    return questions, str(model)
