#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.visual_bank import allocate_sets, load_bank, write_model


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Allocate deterministic ten-question sets from visual banks."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument(
        "--difficulty",
        choices=("beginner", "intermediate", "all"),
        default="all",
    )
    parser.add_argument("--sets", type=int, default=10)
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument("--root", type=Path, default=Path("visual_quiz"))
    args = parser.parse_args()
    if not 1 <= args.sets <= 20:
        parser.error("--sets must be between 1 and 20")

    category_slug = re.sub(
        r"[^a-z0-9]+", "_", args.category.casefold()
    ).strip("_")
    difficulties = (
        ("beginner", "intermediate")
        if args.difficulty == "all"
        else (args.difficulty,)
    )
    try:
        for difficulty_index, difficulty in enumerate(difficulties):
            bank_path = args.root / category_slug / "banks" / difficulty / "bank.json"
            bank = load_bank(bank_path)
            set_dir = args.root / category_slug / "sets" / difficulty
            existing = sorted(set_dir.glob("*.json")) if set_dir.exists() else []
            first_set_number = len(existing) + 1
            remaining_slots = max(0, args.sets - len(existing))
            created = allocate_sets(
                bank,
                seed=args.seed + difficulty_index * 1_000_003,
                first_set_number=first_set_number,
                max_sets=remaining_slots,
            )
            for quiz_set in created:
                write_model(set_dir / f"{quiz_set.set_id}.json", quiz_set)
            write_model(bank_path, bank)
            available = sum(
                question.state == "available" for question in bank.questions
            )
            print(
                f"{difficulty}: existing={len(existing)} created={len(created)} "
                f"available={available} sets_dir={set_dir}"
            )
    except (OSError, ValueError) as exc:
        print(f"Set allocation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
