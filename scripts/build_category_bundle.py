#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.category_bundle import (
    activate_category_bundle_version,
    build_category_bundle,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build or activate an immutable native quiz category bundle."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument("--display-title", default="ANIMAL QUIZ")
    parser.add_argument("--source-root", type=Path, default=Path("visual_quiz_qwen"))
    parser.add_argument(
        "--output-root", type=Path, default=Path("dist/category_bundles")
    )
    parser.add_argument("--force-new-version", action="store_true")
    parser.add_argument("--activate-version", type=int)
    args = parser.parse_args()
    category_slug = re.sub(
        r"[^a-z0-9]+", "_", args.category.casefold()
    ).strip("_")
    try:
        if args.activate_version is not None:
            record = activate_category_bundle_version(
                output_root=args.output_root,
                category=args.category,
                version=args.activate_version,
            )
        else:
            record = build_category_bundle(
                category=args.category,
                category_root=args.source_root / category_slug,
                global_root=args.source_root / "global",
                output_root=args.output_root,
                display_title=args.display_title,
                force_new_version=args.force_new_version,
            )
    except (OSError, ValueError, KeyError) as exc:
        print(f"Category bundle failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(record, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
