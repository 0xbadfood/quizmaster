#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import re
import sys
from contextlib import nullcontext
from pathlib import Path

import httpx

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.vibevoice_audio import (
    DEFAULT_REFERENCE_TRANSCRIPT,
    VibeVoiceChunkClient,
    ensure_global_quiz_audio,
    generate_category_quiz_audio,
    sync_global_audio_to_flutter,
)
from quiz_harness.audio_audit import (
    DEFAULT_WHISPER_MODEL,
    AudioAuditConfig,
    WhisperAuditClient,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Generate resumable quiz narration and reusable feedback sounds."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument("--source-root", type=Path, default=Path("visual_quiz_qwen"))
    parser.add_argument("--endpoint", default="http://127.0.0.1:8092")
    parser.add_argument("--reference-audio", type=Path, default=Path("amit.wav"))
    parser.add_argument("--reference-transcript", default=DEFAULT_REFERENCE_TRANSCRIPT)
    parser.add_argument("--correct-sfx", type=Path, default=Path("correct.wav"))
    parser.add_argument("--incorrect-sfx", type=Path, default=Path("incorrect.wav"))
    parser.add_argument("--lang-key", default="en_indian")
    parser.add_argument("--cfg-scale", type=float, default=1.3)
    parser.add_argument("--timeout", type=float, default=900)
    parser.add_argument(
        "--limit-questions",
        type=int,
        help="Generate only the first N questions for a voice-quality probe.",
    )
    parser.add_argument("--skip-global", action="store_true")
    parser.add_argument("--flutter-app-root", type=Path, default=Path("Storyvault_app"))
    parser.add_argument("--skip-flutter-sync", action="store_true")
    parser.add_argument("--skip-audio-audit", action="store_true")
    parser.add_argument("--whisper-python", type=Path)
    parser.add_argument("--whisper-model", default=DEFAULT_WHISPER_MODEL)
    parser.add_argument("--whisper-device", default="cuda")
    parser.add_argument("--whisper-compute-type", default="float16")
    parser.add_argument("--audit-repairs", type=int, default=2)
    parser.add_argument("--audit-score-threshold", type=float, default=0.90)
    parser.add_argument("--audit-coverage-threshold", type=float, default=0.82)
    parser.add_argument("--audit-wer-threshold", type=float, default=0.18)
    args = parser.parse_args()

    category_slug = re.sub(r"[^a-z0-9]+", "_", args.category.casefold()).strip("_")
    audit_context = (
        nullcontext(None)
        if args.skip_audio_audit
        else WhisperAuditClient(
            cache_root=args.source_root / category_slug / "audio/audits/cache",
            python_path=args.whisper_python,
            model=args.whisper_model,
            device=args.whisper_device,
            compute_type=args.whisper_compute_type,
            config=AudioAuditConfig(
                score_threshold=args.audit_score_threshold,
                coverage_threshold=args.audit_coverage_threshold,
                wer_threshold=args.audit_wer_threshold,
            ),
        )
    )
    try:
        with audit_context as auditor:
            client = VibeVoiceChunkClient(
                endpoint=args.endpoint,
                reference_audio=args.reference_audio,
                lang_key=args.lang_key,
                cfg_scale=args.cfg_scale,
                timeout_seconds=args.timeout,
                auditor=auditor,
                max_audit_repairs=args.audit_repairs,
            )
            health = client.health()
            global_manifest = None
            if not args.skip_global:
                global_manifest = ensure_global_quiz_audio(
                    global_root=args.source_root / "global",
                    client=client,
                    reference_transcript=args.reference_transcript,
                    correct_sfx_source=args.correct_sfx,
                    incorrect_sfx_source=args.incorrect_sfx,
                )
            flutter_manifest = None
            if not args.skip_flutter_sync:
                if global_manifest is None:
                    raise ValueError("Flutter audio sync requires global audio generation")
                flutter_manifest = sync_global_audio_to_flutter(
                    global_root=args.source_root / "global",
                    flutter_root=args.flutter_app_root,
                )
            category_manifest = generate_category_quiz_audio(
                category_root=args.source_root / category_slug,
                category=args.category,
                client=client,
                reference_transcript=args.reference_transcript,
                limit_questions=args.limit_questions,
                progress=lambda completed, total: print(
                    f"Rendered {completed}/{total} pending narration clips",
                    file=sys.stderr,
                    flush=True,
                ),
            )
    except (OSError, ValueError, RuntimeError, TimeoutError, httpx.HTTPError) as exc:
        print(f"Quiz audio generation failed: {exc}", file=sys.stderr)
        return 1

    result = {
        "health": health,
        "global_correct_feedback_clips": len(
            (global_manifest or {}).get("correct_feedback_clips", [])
        ),
        "global_incorrect_feedback_clips": len(
            (global_manifest or {}).get("incorrect_feedback_clips", [])
        ),
        "flutter_correct_feedback_clips": len(
            (flutter_manifest or {}).get("correct_feedback_clips", [])
        ),
        "flutter_incorrect_feedback_clips": len(
            (flutter_manifest or {}).get("incorrect_feedback_clips", [])
        ),
        "category_questions": len(category_manifest.get("questions", {})),
        "category_manifest": str(
            args.source_root / category_slug / "audio/audio-manifest.json"
        ),
    }
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
