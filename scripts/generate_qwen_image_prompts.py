#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.client import VLLMClient
from quiz_harness.qwen_image_prompts import (
    DEFAULT_PROMPT_SEED,
    DEFAULT_QWEN_IMAGE_PROMPT_ENDPOINT,
    apply_category_prompt_plan,
    generate_qwen_image_prompt_plan,
    load_prompt_subjects,
    tile_requests_from_sets,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate webapp-editable category image prompts with Qwen."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument("--display-title", default="ANIMAL QUIZ")
    parser.add_argument(
        "--category-guidance",
        default="",
        help="editable category boundaries and art guidance supplied to every call",
    )
    parser.add_argument("--root", type=Path, default=Path("visual_quiz_qwen"))
    parser.add_argument("--catalog", type=Path)
    parser.add_argument("--endpoint", default=DEFAULT_QWEN_IMAGE_PROMPT_ENDPOINT)
    parser.add_argument("--model")
    parser.add_argument(
        "--role",
        action="append",
        choices=("selector", "tiles", "answers"),
        help="role to generate; repeat as needed (default: all three)",
    )
    parser.add_argument("--tile-asset-id", action="append")
    parser.add_argument("--answer-key", action="append")
    parser.add_argument("--answer-limit", type=int)
    parser.add_argument("--answer-batch-size", type=int, default=20)
    parser.add_argument("--seed", type=int, default=DEFAULT_PROMPT_SEED)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--refresh-tile-briefs",
        action="store_true",
        help="regenerate the coordinated 20-tile scene brief plan",
    )
    parser.add_argument(
        "--skip-answer-review",
        action="store_true",
        help="skip the conservative second Qwen pass over answer descriptions",
    )
    parser.add_argument(
        "--no-apply",
        action="store_true",
        help="do not copy selector/tile prompts into category-image-spec.json",
    )
    args = parser.parse_args()
    if not 1 <= args.answer_batch_size <= 25:
        parser.error("--answer-batch-size must be between 1 and 25")
    if args.answer_limit is not None and args.answer_limit < 1:
        parser.error("--answer-limit must be positive")

    slug = re.sub(r"[^a-z0-9]+", "_", args.category.casefold()).strip("_")
    category_root = args.root / slug
    catalog_path = args.catalog
    if catalog_path is None:
        catalog_path = next(
            (
                path
                for name in (
                    "subject_catalog.json",
                    "object_catalog.json",
                    "animal_catalog.json",
                )
                if (path := category_root / name).exists()
            ),
            category_root / "subject_catalog.json",
        )
    try:
        subjects = load_prompt_subjects(catalog_path)
        with VLLMClient(args.endpoint, timeout_seconds=args.timeout) as client:
            model = args.model or client.discover_model()
            print(f"Qwen model={model} endpoint={args.endpoint}", flush=True)
            plan = generate_qwen_image_prompt_plan(
                category=args.category,
                display_title=args.display_title,
                category_guidance=args.category_guidance,
                category_root=category_root,
                subjects=subjects,
                client=client,
                endpoint=args.endpoint,
                model=model,
                roles=set(args.role or ("selector", "tiles", "answers")),
                base_seed=args.seed,
                answer_batch_size=args.answer_batch_size,
                answer_limit=args.answer_limit,
                answer_keys=set(args.answer_key) if args.answer_key else None,
                tile_asset_ids=(
                    set(args.tile_asset_id) if args.tile_asset_id else None
                ),
                tile_requests=tile_requests_from_sets(category_root),
                review_answers=not args.skip_answer_review,
                refresh_tile_briefs=args.refresh_tile_briefs,
                retries=args.retries,
                force=args.force,
                progress=lambda message: print(message, flush=True),
            )
        spec_path = category_root / "category-image-spec.json"
        if not args.no_apply and spec_path.exists():
            apply_category_prompt_plan(plan=plan, category_spec_path=spec_path)
            print(f"applied category prompts -> {spec_path}")
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Image-prompt planning failed: {exc}", file=sys.stderr)
        return 1

    counts = {
        role: sum(asset.role == role for asset in plan.assets)
        for role in ("category_selector", "quiz_tile", "answer_image")
    }
    print(
        f"plan={category_root / 'image-prompt-plan.json'} "
        f"selector={counts['category_selector']} tiles={counts['quiz_tile']} "
        f"answers={counts['answer_image']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
