#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.background_images import (
    BackgroundGenerationError,
    generate_quiz_background,
    plan_quiz_background_prompt,
)


ROOT = Path(__file__).resolve().parents[1]
DATABASE_PATH = Path(os.getenv("QUIZ_DATABASE_PATH", ROOT / "data/quiz_harness.db"))


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "quiz"


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate a production-shaped portrait background for a quiz category."
    )
    parser.add_argument("--category", required=True)
    parser.add_argument("--display-title")
    parser.add_argument("--subtitle", default="ADVENTURE")
    parser.add_argument(
        "--layout", choices=("portrait", "landscape"), default="portrait"
    )
    parser.add_argument(
        "--provider",
        default="openai-images",
        help="enabled OpenAI Images or ImageStudio connection ID",
    )
    parser.add_argument("--model")
    parser.add_argument(
        "--quality", choices=("low", "medium", "high", "auto"), default="medium"
    )
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument(
        "--planner-provider",
        default="llm-default",
        help="enabled OpenAI-compatible LLM connection ID",
    )
    parser.add_argument("--planner-model")
    parser.add_argument("--category-guidance")
    parser.add_argument(
        "--visual-brief",
        help="skip LLM planning and use this brief with the fixed fallback template",
    )
    parser.add_argument("--prompt", help="skip LLM planning and use this exact prompt")
    parser.add_argument("--plan-output", type=Path)
    parser.add_argument("--plan-only", action="store_true")
    parser.add_argument("--refresh-plan", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--database", type=Path, default=DATABASE_PATH)
    parser.add_argument(
        "--secret-key-file", type=Path, default=Path("data/.provider_secret_key")
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument("--retries", type=int, choices=range(0, 5), default=2)
    parser.add_argument("--timeout", type=float, default=900.0)
    args = parser.parse_args()

    display_title = (args.display_title or f"{args.category} QUIZ").strip().upper()
    output = args.output or (
        Path("background_previews")
        / _slug(args.category)
        / _slug(args.provider)
        / (
            "runtime_background.png"
            if args.layout == "portrait"
            else "video_background_landscape.png"
        )
    )
    plan_output = args.plan_output or (
        Path("background_previews")
        / _slug(args.category)
        / f"background-prompt-plan-{args.layout}.json"
    )
    try:
        planning = None
        prompt = args.prompt
        if prompt is None and args.visual_brief is None:
            planned = plan_quiz_background_prompt(
                category=args.category,
                display_title=display_title,
                subtitle=args.subtitle.strip().upper(),
                provider_id=args.planner_provider,
                model_override=args.planner_model,
                category_guidance=args.category_guidance,
                database_path=args.database,
                secret_key_file=args.secret_key_file,
                output=plan_output,
                seed=args.seed,
                retries=args.retries,
                timeout_seconds=args.timeout,
                force=args.refresh_plan,
                layout=args.layout,
            )
            prompt = planned["plan"].prompt
            planning = {
                "provider_id": planned["provider_id"],
                "model": planned["model"],
                "file": planned["file"],
                "reused": planned["reused"],
                "visual_summary": planned["plan"].visual_summary,
            }
            if planned.get("recovered_from"):
                planning["recovered_from"] = planned["recovered_from"]
            if args.plan_only:
                print(
                    json.dumps(
                        {
                            **planning,
                            "plan": planned["plan"].model_dump(mode="json"),
                        },
                        indent=2,
                        ensure_ascii=True,
                    )
                )
                return 0
        elif args.plan_only:
            raise BackgroundGenerationError(
                "--plan-only cannot be combined with --prompt or --visual-brief"
            )
        result = generate_quiz_background(
            category=args.category,
            display_title=display_title,
            subtitle=args.subtitle.strip().upper(),
            provider_id=args.provider,
            model_override=args.model,
            quality=args.quality,
            seed=args.seed,
            visual_brief=args.visual_brief,
            prompt_override=prompt,
            planning_metadata=planning,
            database_path=args.database,
            secret_key_file=args.secret_key_file,
            output=output,
            retries=args.retries,
            timeout_seconds=args.timeout,
            force=args.force,
            layout=args.layout,
        )
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Background generation failed: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
