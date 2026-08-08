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
        "--provider",
        default="openai-images",
        help="enabled OpenAI Images or ImageStudio connection ID",
    )
    parser.add_argument("--model")
    parser.add_argument(
        "--quality", choices=("low", "medium", "high", "auto"), default="medium"
    )
    parser.add_argument("--seed", type=int, default=20260805)
    parser.add_argument("--visual-brief")
    parser.add_argument("--prompt")
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
        / "runtime_background.png"
    )
    try:
        result = generate_quiz_background(
            category=args.category,
            display_title=display_title,
            subtitle=args.subtitle.strip().upper(),
            provider_id=args.provider,
            model_override=args.model,
            quality=args.quality,
            seed=args.seed,
            visual_brief=args.visual_brief,
            prompt_override=args.prompt,
            database_path=args.database,
            secret_key_file=args.secret_key_file,
            output=output,
            retries=args.retries,
            timeout_seconds=args.timeout,
        )
    except (OSError, RuntimeError, ValueError) as exc:
        print(f"Background generation failed: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
