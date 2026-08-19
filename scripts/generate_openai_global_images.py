#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.image_inventory import (
    DEFAULT_OPENAI_IMAGE_MODEL,
    build_global_image_spec,
    build_progress_style,
    build_video_presentation_inventory,
)
from quiz_harness.database import QuizDatabase
from quiz_harness.openai_images import (
    generate_openai_image_assets,
    load_or_create_image_spec,
    reconcile_manifest_assets,
)
from quiz_harness.secure_store import SecretStore


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare and generate shared OpenAI presentation images."
    )
    parser.add_argument("--root", type=Path, default=Path("visual_quiz_qwen/global"))
    parser.add_argument("--provider", default="openai-images")
    parser.add_argument("--model")
    parser.add_argument(
        "--database", type=Path, default=ROOT / "data/quiz_harness.db"
    )
    parser.add_argument(
        "--secret-key-file", type=Path, default=ROOT / "data/.provider_secret_key"
    )
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
        database = QuizDatabase(args.database)
        database.migrate()
        provider = database.provider_connection(args.provider)
        if not provider["enabled"] or provider["provider_type"] != "openai_images":
            raise ValueError(
                f"provider {args.provider} must be an enabled OpenAI Images connection"
            )
        model = (
            args.model
            or provider.get("default_model")
            or next(iter(provider.get("discovered_models") or []), None)
            or DEFAULT_OPENAI_IMAGE_MODEL
        )
        document = load_or_create_image_spec(
            spec_path,
            build_global_image_spec(model=str(model), quality=args.quality),
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
        video_inventory_path = args.root / "video-presentation-inventory.json"
        video_inventory_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = video_inventory_path.with_suffix(".json.tmp")
        temporary.write_text(
            json.dumps(build_video_presentation_inventory(), indent=2) + "\n",
            encoding="utf-8",
        )
        temporary.replace(video_inventory_path)
        print(f"spec={spec_path} assets={len(document.assets)}")
        print(f"progress_style={progress_style_path}")
        print(f"video_inventory={video_inventory_path}")
        if args.prepare_only:
            return 0
        secrets = SecretStore(
            key=os.getenv("QUIZ_SECRET_KEY"), key_file=args.secret_key_file
        )
        api_key = secrets.decrypt(provider.get("secret_ciphertext"))
        if not api_key:
            raise ValueError(f"provider {args.provider} has no API key")
        manifest = generate_openai_image_assets(
            document=document,
            root=args.root,
            manifest_path=manifest_path,
            selected_asset_ids=set(args.asset_id) if args.asset_id else None,
            force=args.force,
            retries=args.retries,
            timeout_seconds=args.timeout,
            api_key=api_key,
            base_url=str(provider["base_url"]),
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
