from __future__ import annotations

import json
import time
from pathlib import Path
from typing import Annotated, Any, Callable, Literal

from pydantic import Field, model_validator

from .client import VLLMClient, VLLMError
from .models import Identifier, StrictModel
from .visual_bank import BankQuestion, load_bank, slugify


class DuplicateCluster(StrictModel):
    fact_summary: Annotated[str, Field(min_length=8, max_length=240)]
    canonical_question_id: Identifier
    duplicate_question_ids: Annotated[
        list[Identifier], Field(min_length=1, max_length=12)
    ]
    confidence: Annotated[float, Field(ge=0, le=1)]
    reason: Annotated[str, Field(min_length=10, max_length=400)]

    @model_validator(mode="after")
    def validate_cluster(self) -> DuplicateCluster:
        duplicates = self.duplicate_question_ids
        if len(duplicates) != len(set(duplicates)):
            raise ValueError("duplicate question IDs must not repeat within a cluster")
        if self.canonical_question_id in duplicates:
            raise ValueError("canonical question cannot also be a duplicate")
        return self


class DuplicateDiscovery(StrictModel):
    schema_version: Literal["question_duplicate_discovery_v1"]
    category: Annotated[str, Field(min_length=2, max_length=120)]
    input_question_count: Annotated[int, Field(ge=1)]
    duplicate_clusters: Annotated[
        list[DuplicateCluster], Field(default_factory=list, max_length=160)
    ]


def _correct_answer(question: BankQuestion) -> str:
    return next(
        choice.label
        for choice in question.choices
        if choice.choice_id == question.correct_choice_id
    )


def category_bank_sizes(source_root: Path) -> dict[str, int]:
    totals: dict[str, int] = {}
    for bank_path in source_root.glob("*/banks/*/bank.json"):
        bank = load_bank(bank_path)
        slug = bank_path.parents[2].name
        totals[slug] = totals.get(slug, 0) + len(bank.questions)
    return totals


def largest_category(source_root: Path) -> str:
    totals = category_bank_sizes(source_root)
    if not totals:
        raise ValueError(f"no question banks found under {source_root}")
    return min(totals, key=lambda slug: (-totals[slug], slug))


def load_category_questions(
    source_root: Path, category_slug: str
) -> tuple[str, list[BankQuestion]]:
    bank_paths = sorted((source_root / category_slug / "banks").glob("*/bank.json"))
    if not bank_paths:
        raise ValueError(f"no question banks found for category: {category_slug}")
    category = ""
    questions: list[BankQuestion] = []
    seen: set[str] = set()
    for bank_path in bank_paths:
        bank = load_bank(bank_path)
        if category and bank.category != category:
            raise ValueError(f"category name mismatch in {bank_path}")
        category = bank.category
        for question in bank.questions:
            if question.question_id in seen:
                raise ValueError(f"question ID repeats across banks: {question.question_id}")
            seen.add(question.question_id)
            questions.append(question)
    return category, questions


def compact_question_payload(questions: list[BankQuestion]) -> list[dict[str, str]]:
    return [
        {
            "question_id": question.question_id,
            "difficulty": question.difficulty,
            "question": question.question,
            "correct_answer": _correct_answer(question),
        }
        for question in questions
    ]


def discovery_prompt(*, category: str, questions: list[BankQuestion]) -> str:
    payload = compact_question_payload(questions)
    return f"""Find suspected semantic duplicate questions across this complete quiz
bank, including duplicates that cross difficulty levels.

Category: {category}
Question count: {len(payload)}

A duplicate cluster tests the same underlying fact or learning objective and expects
the same factual answer, even when wording differs. Shared subjects are not enough.
For example, a question about where bats live is not a duplicate of a question about
how bats navigate. A simpler and harder formulation of the same fact is a duplicate.

Return only suspected duplicate clusters. For each cluster:
- choose the clearest, most deterministic question as canonical;
- include every other question testing that same fact in duplicate_question_ids;
- summarize the shared fact and explain the match;
- use confidence to express uncertainty, but favor recall in this discovery pass;
- never invent, rewrite, or omit characters from a question ID;
- never place one question ID in more than one cluster.
- be exhaustive: inspect every question and return every qualifying cluster, not
  merely a few examples;
- the correct_answer values in a cluster must match exactly. Similar wording with
  different correct answers is not a duplicate.

Questions:
{json.dumps(payload, indent=2, ensure_ascii=True)}
"""


def validate_discovery(
    discovery: DuplicateDiscovery,
    *,
    category: str,
    questions: list[BankQuestion],
) -> None:
    if discovery.category.casefold() != category.casefold():
        raise ValueError(
            f"discovery category {discovery.category!r} does not match {category!r}"
        )
    if discovery.input_question_count != len(questions):
        raise ValueError(
            "discovery question count does not match the supplied bank"
        )
    by_id = {question.question_id: question for question in questions}
    known = set(by_id)
    used: set[str] = set()
    for cluster in discovery.duplicate_clusters:
        cluster_ids = {
            cluster.canonical_question_id,
            *cluster.duplicate_question_ids,
        }
        unknown = sorted(cluster_ids - known)
        if unknown:
            raise ValueError(
                "discovery returned unknown question IDs: " + ", ".join(unknown)
            )
        overlap = sorted(cluster_ids & used)
        if overlap:
            raise ValueError(
                "question IDs appear in multiple clusters: " + ", ".join(overlap)
            )
        answers = {
            _correct_answer(by_id[item]).strip().casefold() for item in cluster_ids
        }
        if len(answers) != 1:
            rendered = ", ".join(
                f"{item}={_correct_answer(by_id[item])!r}"
                for item in sorted(cluster_ids)
            )
            raise ValueError(
                "duplicate cluster has conflicting correct answers: " + rendered
            )
        used.update(cluster_ids)


def discover_duplicates(
    *,
    client: VLLMClient,
    model: str,
    category: str,
    questions: list[BankQuestion],
    seed: int,
    retries: int,
    output_dir: Path,
    progress: Callable[[str], None] | None = None,
    attempt_records: list[dict[str, Any]] | None = None,
) -> DuplicateDiscovery:
    prompt = discovery_prompt(category=category, questions=questions)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / "discovery.prompt.txt").write_text(prompt, encoding="utf-8")
    messages = [
        {
            "role": "system",
            "content": (
                "You are a rigorous quiz-bank semantic auditor. Return only the "
                "requested JSON and preserve every supplied question ID exactly."
            ),
        },
        {"role": "user", "content": prompt},
    ]
    known_ids = {question.question_id for question in questions}
    last_error = "unknown response error"
    for attempt in range(1, retries + 2):
        if progress:
            progress(f"Qwen discovery attempt {attempt}/{retries + 1}")
        raw: str | None = None
        attempt_started = time.perf_counter()
        try:
            raw = client.generate_json(
                model=model,
                messages=messages,
                schema=DuplicateDiscovery.model_json_schema(),
                schema_name="question_duplicate_discovery",
                seed=seed + attempt - 1,
                temperature=0.1,
                max_tokens=12_000,
            )
            (output_dir / f"discovery.attempt-{attempt:02d}.raw.json").write_text(
                raw, encoding="utf-8"
            )
            discovery = DuplicateDiscovery.model_validate_json(raw)
            validate_discovery(
                discovery, category=category, questions=questions
            )
            (output_dir / "discovery.json").write_text(
                discovery.model_dump_json(indent=2) + "\n", encoding="utf-8"
            )
            if attempt_records is not None:
                attempt_records.append(
                    {
                        "attempt": attempt,
                        "elapsed_seconds": round(
                            time.perf_counter() - attempt_started, 3
                        ),
                        "status": "accepted",
                    }
                )
            return discovery
        except (OSError, ValueError, VLLMError) as exc:
            last_error = str(exc)
            if attempt_records is not None:
                attempt_records.append(
                    {
                        "attempt": attempt,
                        "elapsed_seconds": round(
                            time.perf_counter() - attempt_started, 3
                        ),
                        "status": "rejected",
                        "error": last_error[:2000],
                    }
                )
            if attempt > retries:
                break
            messages.extend(
                [
                    {"role": "assistant", "content": raw or "No complete response."},
                    {
                        "role": "user",
                        "content": (
                            "Regenerate the complete JSON. The prior response failed "
                            f"validation: {last_error[:2000]}. Use only these IDs: "
                            + ", ".join(sorted(known_ids))
                        ),
                    },
                ]
            )
    raise VLLMError(f"duplicate discovery failed: {last_error}")


def write_discovery_report(
    output: Path,
    *,
    discovery: DuplicateDiscovery,
    questions: list[BankQuestion],
) -> None:
    by_id = {question.question_id: question for question in questions}
    lines = [
        f"# {discovery.category} Duplicate Discovery",
        "",
        f"Questions audited: {discovery.input_question_count}",
        f"Suspected clusters: {len(discovery.duplicate_clusters)}",
        "",
    ]
    for index, cluster in enumerate(discovery.duplicate_clusters, start=1):
        ids = [cluster.canonical_question_id, *cluster.duplicate_question_ids]
        difficulties = sorted({by_id[item].difficulty for item in ids})
        lines.extend(
            [
                f"## {index}. {cluster.fact_summary}",
                "",
                f"Confidence: {cluster.confidence:.0%}",
                f"Difficulties: {', '.join(difficulties)}",
                f"Reason: {cluster.reason}",
                "",
            ]
        )
        for question_id in ids:
            question = by_id[question_id]
            label = "canonical" if question_id == cluster.canonical_question_id else "duplicate"
            lines.append(
                f"- **{label}** `{question_id}` ({question.difficulty}): "
                f"{question.question} — **{_correct_answer(question)}**"
            )
        lines.append("")
    output.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def normalize_category_slug(value: str) -> str:
    return slugify(value).replace("_", "-")
