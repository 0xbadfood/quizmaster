#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.client import VLLMClient, VLLMError
from quiz_harness.database import QuizDatabase
from quiz_harness.question_dedup import (
    discover_duplicates,
    discovery_prompt,
    largest_category,
    load_category_questions,
    normalize_category_slug,
    write_discovery_report,
)
from quiz_harness.secure_store import SecretStore


ROOT = Path(__file__).resolve().parents[1]


def write_run_metadata(
    output: Path,
    *,
    category: str,
    category_slug: str,
    question_count: int,
    provider_id: str,
    endpoint: str,
    model: str,
    seed: int,
    timeout_seconds: float,
    retries: int,
    prompt_characters: int,
    elapsed_seconds: float,
    attempt_records: list[dict[str, object]],
    status: str,
    error: str | None = None,
) -> None:
    payload: dict[str, object] = {
        "schema_version": "question_duplicate_discovery_run_v1",
        "status": status,
        "category": category,
        "category_slug": category_slug,
        "question_count": question_count,
        "provider_id": provider_id,
        "endpoint": endpoint,
        "model": model,
        "seed": seed,
        "timeout_seconds": timeout_seconds,
        "retries": retries,
        "prompt_characters": prompt_characters,
        "estimated_input_tokens": prompt_characters // 4,
        "llm_response_seconds": elapsed_seconds,
        "llm_attempts": attempt_records,
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    if error:
        payload["error"] = error
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(
        json.dumps(payload, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Experimentally discover semantic duplicates in a complete category bank."
    )
    parser.add_argument(
        "--category",
        default="largest",
        help="category slug/name, or 'largest' to inspect the largest current bank",
    )
    parser.add_argument(
        "--source-root", type=Path, default=ROOT / "visual_quiz_qwen"
    )
    parser.add_argument(
        "--output-root", type=Path, default=ROOT / "experiments/question-dedup"
    )
    parser.add_argument("--database", type=Path, default=ROOT / "data/quiz_harness.db")
    parser.add_argument("--provider", default="llm-default")
    parser.add_argument("--endpoint")
    parser.add_argument("--model")
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--retries", type=int, choices=range(0, 3), default=1)
    args = parser.parse_args()

    source_root = args.source_root.expanduser().resolve()
    category_slug = (
        largest_category(source_root)
        if args.category.casefold() == "largest"
        else normalize_category_slug(args.category)
    )
    category, questions = load_category_questions(source_root, category_slug)
    output_dir = args.output_root.expanduser().resolve() / category_slug
    prompt = discovery_prompt(category=category, questions=questions)

    database = QuizDatabase(args.database.expanduser().resolve())
    provider = database.provider_connection(args.provider)
    if provider["provider_type"] != "openai_compatible_llm":
        parser.error("the selected provider is not an OpenAI-compatible LLM")
    endpoint = args.endpoint or provider["base_url"]
    model = args.model or provider.get("default_model") or next(
        iter(provider.get("discovered_models") or []), None
    )
    if not model:
        parser.error("the selected provider has no model")
    secret = SecretStore(
        key=os.getenv("QUIZ_SECRET_KEY"),
        key_file=ROOT / "data/.provider_secret_key",
    ).decrypt(provider.get("secret_ciphertext"))

    print(
        f"Category: {category} ({category_slug}); questions={len(questions)}; "
        f"prompt_chars={len(prompt):,}; estimated_input_tokens≈{len(prompt) // 4:,}",
        file=sys.stderr,
    )
    print(f"Qwen: {model} at {endpoint}", file=sys.stderr)
    response_started = time.perf_counter()
    attempt_records: list[dict[str, object]] = []
    try:
        with VLLMClient(
            str(endpoint), timeout_seconds=args.timeout, api_key=secret
        ) as client:
            discovery = discover_duplicates(
                client=client,
                model=str(model),
                category=category,
                questions=questions,
                seed=args.seed,
                retries=args.retries,
                output_dir=output_dir,
                progress=lambda message: print(message, file=sys.stderr),
                attempt_records=attempt_records,
            )
    except (OSError, ValueError, VLLMError) as exc:
        response_seconds = round(time.perf_counter() - response_started, 3)
        write_run_metadata(
            output_dir / "run-metadata.json",
            category=category,
            category_slug=category_slug,
            question_count=len(questions),
            provider_id=str(provider["id"]),
            endpoint=str(endpoint),
            model=str(model),
            seed=args.seed,
            timeout_seconds=args.timeout,
            retries=args.retries,
            prompt_characters=len(prompt),
            elapsed_seconds=response_seconds,
            attempt_records=attempt_records,
            status="failed",
            error=str(exc)[:4000],
        )
        print(f"Duplicate discovery failed: {exc}", file=sys.stderr)
        return 1
    response_seconds = round(time.perf_counter() - response_started, 3)

    report = output_dir / "report.md"
    write_discovery_report(
        report, discovery=discovery, questions=questions
    )
    question_ids = {
        item
        for cluster in discovery.duplicate_clusters
        for item in (
            cluster.canonical_question_id,
            *cluster.duplicate_question_ids,
        )
    }
    cross_difficulty = sum(
        len(
            {
                next(q.difficulty for q in questions if q.question_id == item)
                for item in (
                    cluster.canonical_question_id,
                    *cluster.duplicate_question_ids,
                )
            }
        )
        > 1
        for cluster in discovery.duplicate_clusters
    )
    write_run_metadata(
        output_dir / "run-metadata.json",
        category=category,
        category_slug=category_slug,
        question_count=len(questions),
        provider_id=str(provider["id"]),
        endpoint=str(endpoint),
        model=str(model),
        seed=args.seed,
        timeout_seconds=args.timeout,
        retries=args.retries,
        prompt_characters=len(prompt),
        elapsed_seconds=response_seconds,
        attempt_records=attempt_records,
        status="completed",
    )
    print(
        f"clusters={len(discovery.duplicate_clusters)} "
        f"questions_flagged={len(question_ids)} "
        f"cross_difficulty={cross_difficulty} "
        f"llm_response_seconds={response_seconds:.3f} report={report}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
