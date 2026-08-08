#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.visual_bank import (
    extract_animal_catalog,
    load_bank,
    write_model,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract the canonical animal image catalog from visual banks."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument("--root", type=Path, default=Path("visual_quiz"))
    parser.add_argument(
        "--include-available",
        action="store_true",
        help="include unallocated reserve questions as well as allocated sets",
    )
    args = parser.parse_args()
    category_slug = re.sub(
        r"[^a-z0-9]+", "_", args.category.casefold()
    ).strip("_")
    try:
        bank_root = args.root / category_slug / "banks"
        bank_paths = sorted(bank_root.glob("*/bank.json"))
        if not bank_paths:
            raise ValueError(f"no banks found under {bank_root}")
        banks = [load_bank(path) for path in bank_paths]
        states = {"allocated", "available"} if args.include_available else {"allocated"}
        catalog = extract_animal_catalog(
            banks, category=args.category, include_states=states
        )
        output = args.root / category_slug / "animal_catalog.json"
        write_model(output, catalog)
    except (OSError, ValueError) as exc:
        print(f"Animal extraction failed: {exc}", file=sys.stderr)
        return 1
    print(f"animals={len(catalog.animals)} -> {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
