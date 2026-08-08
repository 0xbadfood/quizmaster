#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.image_inventory import (
    DEFAULT_OPENAI_IMAGE_MODEL,
    build_category_image_spec,
)
from quiz_harness.openai_images import (
    generate_openai_image_assets,
    load_or_create_image_spec,
    reconcile_manifest_assets,
    register_user_upload,
)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Prepare and generate OpenAI category images for a visual quiz."
    )
    parser.add_argument("--category", default="Animals")
    parser.add_argument("--display-title", default="ANIMAL QUIZ")
    parser.add_argument("--root", type=Path, default=Path("visual_quiz_qwen"))
    parser.add_argument("--background", type=Path)
    parser.add_argument("--model", default=DEFAULT_OPENAI_IMAGE_MODEL)
    parser.add_argument("--quality", choices=("low", "medium", "high", "auto"), default="medium")
    parser.add_argument("--asset-id", action="append")
    parser.add_argument("--prepare-only", action="store_true")
    parser.add_argument("--refresh-spec", action="store_true")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=900.0)
    args = parser.parse_args()

    category_slug = re.sub(r"[^a-z0-9]+", "_", args.category.casefold()).strip("_")
    category_root = args.root / category_slug
    spec_path = category_root / "category-image-spec.json"
    manifest_path = category_root / "category-image-manifest.json"
    background_target = category_root / "assets/category/runtime_background.png"
    try:
        proposed = build_category_image_spec(
            category=args.category,
            category_root=category_root,
            display_title=args.display_title,
            model=args.model,
            quality=args.quality,
            background_ready=args.background is not None or background_target.exists(),
        )
        document = load_or_create_image_spec(
            spec_path, proposed, refresh=args.refresh_spec
        )
        reconcile_manifest_assets(document=document, manifest_path=manifest_path)
        if args.background is not None:
            background_spec = next(
                asset for asset in document.assets if asset.role == "runtime_background"
            )
            register_user_upload(
                spec=background_spec,
                source=args.background,
                root=category_root,
                manifest_path=manifest_path,
                manifest_name=document.name,
            )
            print(f"imported background -> {background_target}")
        elif not background_target.exists():
            raise ValueError(
                "category background is missing; pass --background with the uploaded image"
            )

        print(f"spec={spec_path} assets={len(document.assets)}")
        if args.prepare_only:
            return 0
        manifest = generate_openai_image_assets(
            document=document,
            root=category_root,
            manifest_path=manifest_path,
            selected_asset_ids=set(args.asset_id) if args.asset_id else None,
            force=args.force,
            retries=args.retries,
            timeout_seconds=args.timeout,
            progress=lambda message: print(message, flush=True),
        )
    except (OSError, ValueError, RuntimeError) as exc:
        print(f"Category-image generation failed: {exc}", file=sys.stderr)
        return 1

    run = manifest["last_run"]
    print(
        f"complete: generated={run['generated']} reused={run['reused']} "
        f"failed={run['failed']}"
    )
    return 1 if run["failed"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
