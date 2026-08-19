#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import subprocess
from pathlib import Path

from scripts.prepare_remotion_quiz import (
    RENDERER_ROOT,
    parse_question_selection,
    prepare,
)


ROOT = Path(__file__).resolve().parents[1]


def _output_name(
    *,
    category: str,
    difficulty: str,
    set_number: int,
    orientation: str,
    questions: list[int],
) -> str:
    safe_category = re.sub(r"[^a-z0-9]+", "-", category.lower()).strip("-")
    if questions == list(range(questions[0], questions[-1] + 1)):
        question_tag = f"q{questions[0]:02d}-{questions[-1]:02d}"
    else:
        question_tag = "q" + "-".join(f"{number:02d}" for number in questions)
    return (
        f"{safe_category}-{difficulty}-set-{set_number:02d}-"
        f"{orientation}-{question_tag}.mp4"
    )


def create_video(
    *,
    category: str,
    difficulty: str,
    set_number: int,
    orientation: str,
    questions: list[int],
    output_dir: Path,
    scale: float = 1.0,
    concurrency: int = 4,
    crf: int = 18,
) -> dict[str, object]:
    if set_number < 1:
        raise ValueError("--set must be at least 1")
    if not questions:
        raise ValueError("--questions selected no questions")
    remotion = RENDERER_ROOT / "node_modules/.bin/remotion"
    if not remotion.is_file():
        raise RuntimeError(
            "Remotion dependencies are missing; run 'npm install' in video_renderer"
        )

    prepared = prepare(
        category,
        difficulty,
        set_number,
        orientation=orientation,
        question_numbers=questions,
    )
    output_dir = output_dir.expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    output = output_dir / _output_name(
        category=category,
        difficulty=difficulty,
        set_number=set_number,
        orientation=orientation,
        questions=questions,
    )
    command = [
        str(remotion),
        "render",
        "src/index.ts",
        "QuizVideo",
        str(output),
        "--codec=h264",
        f"--crf={crf}",
        f"--concurrency={concurrency}",
        "--overwrite",
    ]
    if scale != 1.0:
        command.append(f"--scale={scale}")
    subprocess.run(command, cwd=RENDERER_ROOT, check=True)
    result: dict[str, object] = {
        "status": "complete",
        "category": category,
        "difficulty": difficulty,
        "set": set_number,
        "orientation": orientation,
        "questions": questions,
        "input": str(prepared),
        "output": str(output),
        "bytes": output.stat().st_size,
    }
    print(json.dumps(result, indent=2))
    return result


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="create_video",
        description="Render a published Quizmaster set as an MP4 video.",
    )
    parser.add_argument("--category", required=True, help="Published category slug.")
    parser.add_argument(
        "--difficulty",
        choices=("beginner", "intermediate"),
        default="beginner",
    )
    orientation = parser.add_mutually_exclusive_group(required=True)
    orientation.add_argument(
        "--portrait", action="store_const", const="portrait", dest="orientation"
    )
    orientation.add_argument(
        "--landscape", action="store_const", const="landscape", dest="orientation"
    )
    parser.add_argument("--set", dest="set_number", type=int, required=True)
    parser.add_argument(
        "--questions",
        default="1-10",
        help="Question range or list, for example 1-10 or 1,3-5.",
    )
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument(
        "--scale",
        type=float,
        choices=(0.25, 0.5, 0.75, 1.0),
        default=1.0,
        help="Render scale. Production default: 1.0.",
    )
    parser.add_argument("--concurrency", type=int, choices=range(1, 17), default=4)
    parser.add_argument("--crf", type=int, choices=range(1, 52), default=18)
    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        selected = parse_question_selection(args.questions)
        create_video(
            category=args.category,
            difficulty=args.difficulty,
            set_number=args.set_number,
            orientation=args.orientation,
            questions=selected,
            output_dir=args.output_dir,
            scale=args.scale,
            concurrency=args.concurrency,
            crf=args.crf,
        )
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))


if __name__ == "__main__":
    main()
