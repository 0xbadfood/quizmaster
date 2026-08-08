from __future__ import annotations

import json
import re
from collections import Counter
from datetime import datetime, timezone
from difflib import SequenceMatcher
from pathlib import Path
from typing import Any

from .question_models import ContentQuestion, FinalQuestionSet, normalize_text


STOP_WORDS = {
    "a", "an", "and", "animal", "animals", "are", "as", "at", "be", "by",
    "can", "correct", "do", "does", "for", "from", "has", "have", "how",
    "in", "instead", "is", "it", "its", "many", "most", "of", "on", "or",
    "primary", "that", "the", "their", "them", "these", "they", "this", "to",
    "what", "when", "where", "which", "why", "with",
}


def _tokens(value: str) -> set[str]:
    return set(normalize_text(value).split()) - STOP_WORDS


def _correct_answer(question: ContentQuestion) -> str:
    return next(
        choice.text
        for choice in question.choices
        if choice.choice_id == question.correct_choice_id
    )


def _concept_tokens(question: ContentQuestion) -> set[str]:
    return _tokens(
        f"{question.question} {_correct_answer(question)} "
        f"{question.topic_key.replace('_', ' ')}"
    )


def _jaccard(left: set[str], right: set[str]) -> float:
    union = left | right
    return len(left & right) / len(union) if union else 0.0


def compare_questions(
    left: ContentQuestion, right: ContentQuestion
) -> dict[str, Any]:
    left_text = normalize_text(left.question)
    right_text = normalize_text(right.question)
    wording_similarity = SequenceMatcher(None, left_text, right_text).ratio()
    left_question_tokens = _tokens(left.question)
    right_question_tokens = _tokens(right.question)
    shared_question_tokens = sorted(left_question_tokens & right_question_tokens)
    concept_similarity = _jaccard(
        _concept_tokens(left), _concept_tokens(right)
    )
    exact_question = left_text == right_text
    exact_topic = left.topic_key == right.topic_key
    likely_duplicate = (
        exact_question
        or wording_similarity >= 0.8
        or concept_similarity >= 0.42
        or (wording_similarity >= 0.6 and len(shared_question_tokens) >= 2)
    )
    return {
        "exact_question": exact_question,
        "exact_topic": exact_topic,
        "wording_similarity": round(wording_similarity, 4),
        "concept_similarity": round(concept_similarity, 4),
        "shared_question_tokens": shared_question_tokens,
        "likely_duplicate": likely_duplicate,
    }


def audit_category_sets(root: Path, category: str) -> dict[str, Any]:
    category_slug = re.sub(r"[^a-z0-9]+", "_", category.casefold()).strip("_")
    category_root = root / category_slug
    documents: list[tuple[Path, FinalQuestionSet]] = []
    for path in sorted(category_root.glob("*/*/final.json")):
        document = FinalQuestionSet.model_validate_json(path.read_text(encoding="utf-8"))
        documents.append((path, document))

    comparisons: list[dict[str, Any]] = []
    for left_index, (_, left_set) in enumerate(documents):
        for _, right_set in documents[left_index + 1 :]:
            if left_set.difficulty != right_set.difficulty:
                continue
            for left_question in left_set.questions:
                for right_question in right_set.questions:
                    evidence = compare_questions(left_question, right_question)
                    if not (evidence["likely_duplicate"] or evidence["exact_topic"]):
                        continue
                    comparisons.append(
                        {
                            "difficulty": left_set.difficulty,
                            "left_set_id": left_set.set_id,
                            "left_question_id": left_question.question_id,
                            "left_question": left_question.question,
                            "left_topic_key": left_question.topic_key,
                            "right_set_id": right_set.set_id,
                            "right_question_id": right_question.question_id,
                            "right_question": right_question.question,
                            "right_topic_key": right_question.topic_key,
                            **evidence,
                        }
                    )

    duplicate_counts = Counter(
        item["difficulty"]
        for item in comparisons
        if item["likely_duplicate"]
    )
    topic_counts = Counter(
        item["difficulty"]
        for item in comparisons
        if item["exact_topic"] and not item["likely_duplicate"]
    )
    return {
        "schema_version": "1.0",
        "category": category,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "set_count": len(documents),
        "question_count": sum(len(document.questions) for _, document in documents),
        "summary": {
            "likely_duplicate_pairs": sum(duplicate_counts.values()),
            "topic_collision_pairs": sum(topic_counts.values()),
            "duplicates_by_difficulty": dict(duplicate_counts),
            "topic_collisions_by_difficulty": dict(topic_counts),
        },
        "comparisons": comparisons,
    }


def write_audit_report(report: dict[str, Any], output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(report, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(output)
