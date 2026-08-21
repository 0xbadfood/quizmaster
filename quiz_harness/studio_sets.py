from __future__ import annotations

import hashlib
import re
from collections import Counter
from pathlib import Path
from typing import Any, Callable, Literal

from .client import VLLMClient
from .database import QuizDatabase
from .qwen_selection import QwenSelectionError, append_sets_with_qwen
from .studio_questions import BANK_WRITE_LOCK
from .visual_bank import VisualQuizSet, load_bank, write_model


DIFFICULTIES = ("beginner", "intermediate")
SET_REVIEW_STATUSES = ("unreviewed", "approved", "needs_edit", "rejected")
MAX_SETS_PER_DIFFICULTY = 20


class QuizSetError(ValueError):
    """Raised when a Studio quiz-set operation is invalid."""


def _set_number(set_id: str) -> int:
    match = re.search(r"_(\d+)$", set_id)
    return int(match.group(1)) if match else 0


def _answer_label(question: Any) -> str:
    return next(
        choice.label
        for choice in question.choices
        if choice.choice_id == question.correct_choice_id
    )


class QuizSetStore:
    def __init__(self, root: Path, database: QuizDatabase) -> None:
        self.root = Path(root)
        self.database = database

    def _category_root(self, category_slug: str) -> Path:
        return self.root / category_slug

    def _bank_path(self, category_slug: str, difficulty: str) -> Path:
        if difficulty not in DIFFICULTIES:
            raise QuizSetError(f"unsupported difficulty: {difficulty}")
        return self._category_root(category_slug) / "banks" / difficulty / "bank.json"

    def _set_path(
        self, category_slug: str, difficulty: str, set_id: str
    ) -> Path:
        return self._category_root(category_slug) / "sets" / difficulty / f"{set_id}.json"

    def _load_sets(self, category_slug: str) -> tuple[list[VisualQuizSet], list[str]]:
        documents: list[VisualQuizSet] = []
        issues: list[str] = []
        category_root = self._category_root(category_slug)
        for difficulty in DIFFICULTIES:
            for path in sorted((category_root / "sets" / difficulty).glob("*.json")):
                try:
                    document = VisualQuizSet.model_validate_json(
                        path.read_text(encoding="utf-8")
                    )
                except (OSError, ValueError) as exc:
                    issues.append(f"{path.name}: {exc}")
                    continue
                if document.difficulty != difficulty:
                    issues.append(f"{path.name}: difficulty does not match its folder")
                    continue
                documents.append(document)
        documents.sort(key=lambda item: (DIFFICULTIES.index(item.difficulty), _set_number(item.set_id)))
        return documents, issues

    def _bank_inventory(self, category_slug: str) -> dict[str, dict[str, int]]:
        inventory: dict[str, dict[str, int]] = {}
        for difficulty in DIFFICULTIES:
            path = self._bank_path(category_slug, difficulty)
            if not path.exists():
                inventory[difficulty] = {
                    "total": 0,
                    "available": 0,
                    "allocated": 0,
                    "rejected": 0,
                    "selection_capacity": 0,
                }
                continue
            try:
                bank = load_bank(path)
            except (OSError, ValueError) as exc:
                raise QuizSetError(f"cannot read {difficulty} question bank: {exc}") from exc
            counts = Counter(question.state for question in bank.questions)
            available = counts["available"]
            inventory[difficulty] = {
                "total": len(bank.questions),
                "available": available,
                "allocated": counts["allocated"],
                "rejected": counts["rejected"],
                "selection_capacity": max(0, (available - 5) // 10),
            }
        return inventory

    def list_sets(self, category_slug: str, difficulty: str = "all") -> dict[str, Any]:
        if difficulty not in (*DIFFICULTIES, "all"):
            raise QuizSetError(f"unsupported difficulty: {difficulty}")
        documents, validation_issues = self._load_sets(category_slug)
        reviews = self.database.quiz_set_reviews(category_slug)
        counts = Counter(item.difficulty for item in documents)
        review_counts = Counter(
            reviews.get(item.set_id, {}).get("status", "unreviewed")
            for item in documents
        )
        banks = self._bank_inventory(category_slug)
        filtered = [
            item for item in documents
            if difficulty == "all" or item.difficulty == difficulty
        ]
        sets = []
        for document in filtered:
            review = reviews.get(document.set_id, {})
            sets.append(
                {
                    "set_id": document.set_id,
                    "set_number": _set_number(document.set_id),
                    "difficulty": document.difficulty,
                    "question_count": len(document.questions),
                    "source_model": document.source_model,
                    "selection_model": document.selection_model,
                    "review_status": review.get("status", "unreviewed"),
                    "review_notes": review.get("notes", ""),
                    "reviewed_at": review.get("reviewed_at"),
                    "answers": [_answer_label(question) for question in document.questions],
                }
            )
        return {
            "sets": sets,
            "summary": {
                "total": len(documents),
                "recommended_target": MAX_SETS_PER_DIFFICULTY * len(DIFFICULTIES),
                "maximum_per_difficulty": MAX_SETS_PER_DIFFICULTY,
                "beginner": counts["beginner"],
                "intermediate": counts["intermediate"],
                "approved": review_counts["approved"],
                "unreviewed": review_counts["unreviewed"],
                "needs_edit": review_counts["needs_edit"],
                "rejected": review_counts["rejected"],
                "banks": banks,
                "selection_slots": {
                    name: max(0, MAX_SETS_PER_DIFFICULTY - counts[name])
                    for name in DIFFICULTIES
                },
                "validation_issues": validation_issues,
            },
        }

    def set_detail(
        self, category_slug: str, difficulty: str, set_id: str
    ) -> dict[str, Any]:
        path = self._set_path(category_slug, difficulty, set_id)
        if not path.exists():
            raise KeyError(set_id)
        try:
            document = VisualQuizSet.model_validate_json(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise QuizSetError(f"cannot read quiz set {set_id}: {exc}") from exc
        review = self.database.quiz_set_reviews(category_slug, difficulty).get(set_id, {})
        payload = document.model_dump(mode="json")
        for question in payload["questions"]:
            question["correct_answer"] = next(
                choice["label"]
                for choice in question["choices"]
                if choice["choice_id"] == question["correct_choice_id"]
            )
        return {
            **payload,
            "set_number": _set_number(set_id),
            "review_status": review.get("status", "unreviewed"),
            "review_notes": review.get("notes", ""),
            "reviewed_at": review.get("reviewed_at"),
            "revisions": self.database.quiz_set_revisions(
                category_slug, difficulty, set_id
            ),
        }

    def review_set(
        self,
        category_slug: str,
        difficulty: str,
        set_id: str,
        *,
        status: str,
        notes: str = "",
    ) -> dict[str, Any]:
        if status not in SET_REVIEW_STATUSES:
            raise QuizSetError(f"unsupported review status: {status}")
        before = self.set_detail(category_slug, difficulty, set_id)
        self.database.upsert_quiz_set_review(
            category_slug=category_slug,
            difficulty=difficulty,
            set_id=set_id,
            status=status,
            notes=notes.strip(),
        )
        after = self.set_detail(category_slug, difficulty, set_id)
        self.database.record_quiz_set_revision(
            category_slug=category_slug,
            difficulty=difficulty,
            set_id=set_id,
            action="reviewed",
            before={"status": before["review_status"], "notes": before["review_notes"]},
            after={"status": status, "notes": notes.strip()},
        )
        return after

    def select_sets(
        self,
        *,
        category_slug: str,
        difficulty: str,
        count: int,
        client: VLLMClient,
        model: str,
        seed: int,
        strictness: Literal["strict", "balanced"],
        provider_id: str,
        progress: Callable[..., None],
    ) -> dict[str, Any]:
        bank_path = self._bank_path(category_slug, difficulty)
        if not bank_path.exists():
            raise QuizSetError(f"{difficulty} question bank does not exist")
        before_bytes = bank_path.read_bytes()
        expected_hash = hashlib.sha256(before_bytes).hexdigest()
        bank = load_bank(bank_path)
        existing, _ = self._load_sets(category_slug)
        difficulty_sets = [item for item in existing if item.difficulty == difficulty]
        remaining = max(0, MAX_SETS_PER_DIFFICULTY - len(difficulty_sets))
        available = sum(question.state == "available" for question in bank.questions)
        capacity = max(0, (available - 5) // 10)
        allowed = min(remaining, capacity)
        if count < 1 or count > allowed:
            raise QuizSetError(
                f"request {count} set(s), but {difficulty} can create at most {allowed} "
                f"from {available} available questions"
            )
        used_numbers = {_set_number(item.set_id) for item in difficulty_sets}
        first_number = next(
            number
            for number in range(1, MAX_SETS_PER_DIFFICULTY + 1)
            if number not in used_numbers
        )
        expected_numbers = list(range(first_number, first_number + count))
        if any(
            number in used_numbers or number > MAX_SETS_PER_DIFFICULTY
            for number in expected_numbers
        ):
            raise QuizSetError("existing set numbering has a gap that prevents safe append")

        def selection_progress(message: str) -> None:
            match = re.search(r"selection_(\d+)", message)
            offset = max(0, int(match.group(1)) - first_number) if match else 0
            fraction = 1 if ": selected" in message else 0.15
            progress(
                message,
                min(0.82, 0.08 + ((offset + fraction) / count) * 0.72),
            )

        committed: list[str] = []

        def checkpoint(current_bank: Any, quiz_set: VisualQuizSet) -> None:
            nonlocal expected_hash
            set_path = self._set_path(category_slug, difficulty, quiz_set.set_id)
            with BANK_WRITE_LOCK:
                current_hash = hashlib.sha256(bank_path.read_bytes()).hexdigest()
                if current_hash != expected_hash:
                    raise QuizSetError(
                        "question bank changed during selection; current set was not committed"
                    )
                if set_path.exists():
                    raise QuizSetError(f"quiz set {quiz_set.set_id} already exists")
                write_model(set_path, quiz_set)
                write_model(bank_path, current_bank)
                expected_hash = hashlib.sha256(bank_path.read_bytes()).hexdigest()
            self.database.record_quiz_set_revision(
                category_slug=category_slug,
                difficulty=difficulty,
                set_id=quiz_set.set_id,
                action="selected",
                before=None,
                after=quiz_set.model_dump(mode="json"),
                source_provider=provider_id,
                source_model=model,
            )
            committed.append(quiz_set.set_id)
            progress(f"Committed {quiz_set.set_id}", 0.1 + len(committed) / count * 0.76)

        progress("Loading reserve questions", 0.04)
        warning: str | None = None
        try:
            append_sets_with_qwen(
                source_bank=bank,
                client=client,
                model=model,
                output_root=self._category_root(category_slug),
                set_count=count,
                first_set_number=first_number,
                seed=seed,
                strictness=strictness,
                force=True,
                persist=False,
                checkpoint=checkpoint,
                progress=selection_progress,
            )
        except QwenSelectionError as exc:
            if not committed:
                raise
            warning = str(exc)
            progress(
                f"Partial selection complete: {len(committed)} set(s) committed",
                0.94,
            )
        return {
            "category_slug": category_slug,
            "difficulty": difficulty,
            "status": "partial" if warning else "complete",
            "created": committed,
            "created_count": len(committed),
            "requested_count": count,
            "next_set_number": first_number + len(committed),
            "warning": warning,
            "model": model,
            "seed": seed,
            "strictness": strictness,
        }
