#!/usr/bin/env python3
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.answer_images import generate_answer_images
from quiz_harness.imagestudio import ImageStudioClient
from quiz_harness.qwen_image_prompts import load_answer_prompt_overrides
from quiz_harness.visual_bank import AnimalCatalog


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate the canonical animal answer-image batch with ImageStudio."
    )
    parser.add_argument(
        "--catalog",
        type=Path,
        default=Path("visual_quiz_qwen/animals/animal_catalog.json"),
    )
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000")
    parser.add_argument("--model", default="ernie-turbo")
    parser.add_argument("--size", type=int, default=768)
    parser.add_argument("--steps", type=int, default=8)
    parser.add_argument("--cfg", type=float, default=1.0)
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--limit", type=int)
    parser.add_argument(
        "--animal-key",
        action="append",
        help="generate only this catalog animal; may be supplied more than once",
    )
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument(
        "--prompt-plan",
        type=Path,
        help=(
            "Qwen image-prompt plan; defaults to image-prompt-plan.json beside "
            "the catalog when present"
        ),
    )
    parser.add_argument(
        "--ignore-prompt-plan",
        action="store_true",
        help="use the built-in fallback prompts even when a Qwen plan exists",
    )
    parser.add_argument(
        "--use-pending-prompts",
        action="store_true",
        help="allow unapproved Qwen answer prompts (intended only for experiments)",
    )
    args = parser.parse_args()

    try:
        catalog = AnimalCatalog.model_validate_json(
            args.catalog.read_text(encoding="utf-8")
        )
        default_plan = args.catalog.parent / "image-prompt-plan.json"
        prompt_plan = args.prompt_plan or default_plan
        prompt_overrides = (
            {}
            if args.ignore_prompt_plan or not prompt_plan.exists()
            else load_answer_prompt_overrides(
                prompt_plan, include_pending=args.use_pending_prompts
            )
        )
        if prompt_overrides:
            print(
                f"loaded {len(prompt_overrides)} Qwen answer prompts from {prompt_plan}",
                flush=True,
            )
        with ImageStudioClient(
            args.endpoint, model=args.model, timeout_seconds=args.timeout
        ) as client:
            manifest = generate_answer_images(
                catalog=catalog,
                catalog_root=args.catalog.parent,
                client=client,
                endpoint=args.endpoint,
                model=args.model,
                width=args.size,
                height=args.size,
                steps=args.steps,
                cfg=args.cfg,
                base_seed=args.seed,
                force=args.force,
                limit=args.limit,
                animal_keys=set(args.animal_key) if args.animal_key else None,
                prompt_overrides=prompt_overrides,
                retries=args.retries,
                progress=lambda message: print(message, flush=True),
            )
    except (OSError, ValueError) as exc:
        print(f"Answer-image generation failed: {exc}", file=sys.stderr)
        return 1

    last_run = manifest["last_run"]
    print(
        "complete: "
        f"generated={last_run['generated']} reused={last_run['reused']} "
        f"failed={last_run['failed']}"
    )
    return 1 if last_run["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
