#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.category_variants import create_free_variant, current_record_paths


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Create compatibility access variants for published quiz bundles."
    )
    parser.add_argument(
        "--root", type=Path, default=Path("dist/category_bundles")
    )
    parser.add_argument("--category", action="append", default=[])
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    selected = set(args.category)
    records = [
        path
        for path in current_record_paths(args.root.resolve())
        if not selected or path.parents[2].name in selected
    ]
    if not records:
        print("No published category records found.", file=sys.stderr)
        return 1
    created = 0
    for index, record_path in enumerate(records, start=1):
        result = create_free_variant(record_path, force=args.force)
        variant = result["variant"]
        created += result["status"] == "created"
        print(
            f"[{index}/{len(records)}] {record_path.parents[2].name}: "
            f"{result['status']} {variant['available_quiz_count']} quiz(es), "
            f"{variant['archive_bytes']} bytes"
        )
    print(f"complete: created={created} reused={len(records) - created}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
