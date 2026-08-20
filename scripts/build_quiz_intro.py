#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUTPUT = ROOT / "video_renderer/assets/quiz-intro-landscape.mp4"


def discover_intro_sources(root: Path, output: Path) -> list[Path]:
    candidates = {
        path.resolve()
        for pattern in ("quiz_intro_*.mp4", "quiz_into_*.mp4")
        for path in root.glob(pattern)
        if path.is_file() and path.resolve() != output.resolve()
    }
    def source_order(path: Path) -> tuple[int, str]:
        match = re.search(r"_(\d+)\.mp4$", path.name, flags=re.IGNORECASE)
        return (int(match.group(1)) if match else 2**31, path.name.casefold())

    return sorted(candidates, key=source_order)


def build_landscape_intro(
    *, source_root: Path, output: Path, crf: int = 18
) -> Path:
    sources = discover_intro_sources(source_root, output)
    if not sources:
        raise ValueError(
            f"no quiz_intro_*.mp4 or quiz_into_*.mp4 clips found in {source_root}"
        )
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp.mp4")
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y"]
    for source in sources:
        command.extend(["-i", str(source)])
    filters: list[str] = []
    concat_inputs: list[str] = []
    for index in range(len(sources)):
        filters.extend(
            [
                f"[{index}:v]scale=1920:1080:force_original_aspect_ratio=decrease,"
                f"pad=1920:1080:(ow-iw)/2:(oh-ih)/2:black,fps=30,"
                f"format=yuv420p,setsar=1[v{index}]",
                f"[{index}:a]aresample=48000,aformat=sample_fmts=fltp:"
                f"channel_layouts=stereo[a{index}]",
            ]
        )
        concat_inputs.extend([f"[v{index}]", f"[a{index}]"])
    filters.append(
        "".join(concat_inputs)
        + f"concat=n={len(sources)}:v=1:a=1[outv][outa]"
    )
    command.extend(
        [
            "-filter_complex",
            ";".join(filters),
            "-map",
            "[outv]",
            "-map",
            "[outa]",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            str(crf),
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
            str(temporary),
        ]
    )
    try:
        subprocess.run(command, check=True)
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)
    return output


def main() -> None:
    parser = argparse.ArgumentParser(
        description=(
            "Normalize and concatenate root quiz intro clips for landscape videos."
        )
    )
    parser.add_argument("--source-root", type=Path, default=ROOT)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--crf", type=int, choices=range(1, 52), default=18)
    args = parser.parse_args()
    try:
        output = build_landscape_intro(
            source_root=args.source_root.expanduser().resolve(),
            output=args.output.expanduser().resolve(),
            crf=args.crf,
        )
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    print(f"Created landscape quiz intro: {output}")


if __name__ == "__main__":
    main()
