#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def resolve_model(model: str, cache_dir: Path) -> str:
    candidate = Path(model).expanduser()
    if candidate.exists():
        return str(candidate.resolve())
    snapshots = (
        cache_dir
        / "hub"
        / ("models--" + model.replace("/", "--"))
        / "snapshots"
    )
    if snapshots.is_dir():
        available = sorted(
            (item for item in snapshots.iterdir() if item.is_dir()),
            key=lambda item: item.stat().st_mtime,
            reverse=True,
        )
        if available:
            return str(available[0])
    return model


def audio_duration(path: Path) -> float:
    try:
        import av

        with av.open(str(path)) as container:
            return float(container.duration or 0) / float(av.time_base)
    except Exception:
        return 0.0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--device", default="cuda")
    parser.add_argument("--compute-type", default="float16")
    parser.add_argument("--cache-dir", type=Path, required=True)
    args = parser.parse_args()

    from faster_whisper import WhisperModel

    model = WhisperModel(
        resolve_model(args.model, args.cache_dir),
        device=args.device,
        compute_type=args.compute_type,
        download_root=str(args.cache_dir),
        local_files_only=True,
    )
    for line in sys.stdin:
        try:
            request = json.loads(line)
            if request.get("command") == "close":
                return 0
            path = Path(request["audio_path"])
            segments, _ = model.transcribe(
                str(path),
                language="en",
                task="transcribe",
                beam_size=5,
                vad_filter=False,
                condition_on_previous_text=False,
            )
            text: list[str] = []
            first_start: float | None = None
            last_end: float | None = None
            for segment in segments:
                value = " ".join(str(segment.text or "").split())
                if not value:
                    continue
                text.append(value)
                first_start = float(
                    segment.start if first_start is None else min(first_start, segment.start)
                )
                last_end = float(
                    segment.end if last_end is None else max(last_end, segment.end)
                )
            span = (
                0.0
                if first_start is None or last_end is None
                else max(0.0, last_end - first_start)
            )
            response = {
                "text": " ".join(text),
                "speech_span_seconds": span,
                "audio_duration_seconds": audio_duration(path),
            }
        except Exception as exc:
            response = {"error": str(exc)}
        print(json.dumps(response, ensure_ascii=True), flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
