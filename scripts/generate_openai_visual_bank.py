#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.openai_bank import (
    DEFAULT_OPENAI_MODEL,
    OpenAIBankError,
    generate_openai_bank,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate four-choice visual quiz banks with OpenAI."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument(
        "--difficulty",
        choices=("beginner", "intermediate", "all"),
        default="all",
    )
    parser.add_argument("--count", type=int, default=120)
    parser.add_argument("--model", default=DEFAULT_OPENAI_MODEL)
    parser.add_argument("--output-root", type=Path, default=Path("visual_quiz"))
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--max-invalid", type=int, default=5)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--reingest",
        action="store_true",
        help="rebuild bank.json from the saved OpenAI response without an API call",
    )
    args = parser.parse_args()
    if not 10 <= args.count <= 150:
        parser.error("--count must be between 10 and 150")
    if not 0 <= args.max_invalid <= 20:
        parser.error("--max-invalid must be between 0 and 20")

    category_slug = re.sub(
        r"[^a-z0-9]+", "_", args.category.casefold()
    ).strip("_")
    difficulties = (
        ("beginner", "intermediate")
        if args.difficulty == "all"
        else (args.difficulty,)
    )
    try:
        for difficulty in difficulties:
            output_dir = args.output_root / category_slug / "banks" / difficulty
            document, path = generate_openai_bank(
                category=args.category,
                difficulty=difficulty,
                count=args.count,
                output_dir=output_dir,
                model=args.model,
                timeout_seconds=args.timeout,
                max_invalid=args.max_invalid,
                force=args.force,
                reingest=args.reingest,
                progress=lambda message, level=difficulty: print(
                    f"[{level}] {message}", file=sys.stderr
                ),
            )
            print(f"{difficulty}: {len(document.questions)} questions -> {path}")
    except (OpenAIBankError, OSError, ValueError) as exc:
        print(f"Bank generation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
