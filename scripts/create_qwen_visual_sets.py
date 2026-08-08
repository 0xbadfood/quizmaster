#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.client import VLLMClient, VLLMError
from quiz_harness.qwen_selection import (
    DEFAULT_QWEN_ENDPOINT,
    QwenSelectionError,
    select_sets_with_qwen,
)
from quiz_harness.visual_bank import load_bank


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create visual quiz sets by asking Qwen to select 10 of each 15."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument(
        "--difficulty",
        choices=("beginner", "intermediate", "all"),
        default="all",
    )
    parser.add_argument("--sets", type=int, default=10)
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument("--source-root", type=Path, default=Path("visual_quiz"))
    parser.add_argument("--output-root", type=Path, default=Path("visual_quiz_qwen"))
    parser.add_argument("--endpoint", default=DEFAULT_QWEN_ENDPOINT)
    parser.add_argument("--model")
    parser.add_argument(
        "--strictness", choices=("strict", "balanced"), default="strict"
    )
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--retries", type=int, default=2, choices=range(0, 5))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()
    if not 1 <= args.sets <= 10:
        parser.error("--sets must be between 1 and 10")

    category_slug = re.sub(
        r"[^a-z0-9]+", "_", args.category.casefold()
    ).strip("_")
    difficulties = (
        ("beginner", "intermediate")
        if args.difficulty == "all"
        else (args.difficulty,)
    )
    try:
        with VLLMClient(args.endpoint, timeout_seconds=args.timeout) as client:
            model = args.model or client.discover_model()
            print(f"Qwen selector: {model} at {args.endpoint}", file=sys.stderr)
            for difficulty_index, difficulty in enumerate(difficulties):
                source = (
                    args.source_root
                    / category_slug
                    / "banks"
                    / difficulty
                    / "bank.json"
                )
                bank = load_bank(source)
                output = args.output_root / category_slug
                selected_bank, quiz_sets = select_sets_with_qwen(
                    source_bank=bank,
                    client=client,
                    model=model,
                    output_root=output,
                    set_count=args.sets,
                    seed=args.seed + difficulty_index * 1_000_003,
                    strictness=args.strictness,
                    retries=args.retries,
                    force=args.force,
                    progress=lambda message, level=difficulty: print(
                        f"[{level}] {message}", file=sys.stderr
                    ),
                )
                available = sum(
                    item.state == "available" for item in selected_bank.questions
                )
                print(
                    f"{difficulty}: sets={len(quiz_sets)} "
                    f"available={available} -> {output}"
                )
    except (OSError, ValueError, VLLMError, QwenSelectionError) as exc:
        print(f"Qwen set selection failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
