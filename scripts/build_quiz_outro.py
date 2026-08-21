#!/usr/bin/env python3
from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.build_quiz_intro import concatenate_clips, discover_clip_sources


DEFAULT_OUTPUT = ROOT / "video_renderer/assets/quiz-outro-landscape.mp4"


def discover_outro_sources(root: Path, output: Path) -> list[Path]:
    return discover_clip_sources(root, output, ("quiz_end*.mp4",))


def build_landscape_outro(
    *, source_root: Path, output: Path, crf: int = 18
) -> Path:
    sources = discover_outro_sources(source_root, output)
    if not sources:
        raise ValueError(f"no quiz_end*.mp4 clips found in {source_root}")
    return concatenate_clips(sources, output, crf=crf)


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize and concatenate root quiz outro clips for landscape videos."
        )
    )
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--crf", type=int, choices=range(1, 52), default=18)
    args = parser.parse_args()
    try:
        output = build_landscape_outro(
            source_root=args.source_root.expanduser().resolve(),
            output=args.output.expanduser().resolve(),
            crf=args.crf,
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    print(f"Created landscape quiz outro: {output}")


if __name__ == "__main__":
    main()
