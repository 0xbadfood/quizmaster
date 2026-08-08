#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.image_inventory import (
    DEFAULT_OPENAI_IMAGE_MODEL,
    build_global_image_spec,
    build_progress_style,
)
from quiz_harness.openai_images import (
    generate_openai_image_assets,
    load_or_create_image_spec,
    reconcile_manifest_assets,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare and generate shared OpenAI presentation images."
    )
    parser.add_argument("--root", type=Path, default=Path("visual_quiz_qwen/global"))
    parser.add_argument("--model", default=DEFAULT_OPENAI_IMAGE_MODEL)
    parser.add_argument("--quality", choices=("low", "medium", "high", "auto"), default="medium")
    parser.add_argument("--asset-id", action="append")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--refresh-spec", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=900.0)
    args = parser.parse_args()

    spec_path = args.root / "global-image-spec.json"
    manifest_path = args.root / "global-image-manifest.json"
    try:
        document = load_or_create_image_spec(
            spec_path,
            build_global_image_spec(model=args.model, quality=args.quality),
            refresh=args.refresh_spec,
        )
        reconcile_manifest_assets(document=document, manifest_path=manifest_path)
        progress_style_path = args.root / "progress-style.json"
        progress_style_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = progress_style_path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(build_progress_style(), indent=2) + "\n", encoding="utf-8"
        )
        temporary.replace(progress_style_path)
        print(f"spec={spec_path} assets={len(document.assets)}")
        print(f"progress_style={progress_style_path}")
        if args.prepare_only:
            return 0
        manifest = generate_openai_image_assets(
            document=document,
            root=args.root,
            manifest_path=manifest_path,
            selected_asset_ids=set(args.asset_id) if args.asset_id else None,
            force=args.force,
            retries=args.retries,
            timeout_seconds=args.timeout,
            progress=lambda message: print(message, flush=True),
        )
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Global-image generation failed: {exc}", file=sys.stderr)
        return 1

    run = manifest["last_run"]
    print(
        f"complete: generated={run['generated']} reused={run['reused']} "
        f"failed={run['failed']}"
    )
    return 1 if run["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
