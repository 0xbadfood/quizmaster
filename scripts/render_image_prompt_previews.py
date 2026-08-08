#!/usr/bin/env python3
from __future__ import annotations

import argparse
import io
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from quiz_harness.imagestudio import ImageStudioClient
from quiz_harness.qwen_image_prompts import ImagePromptPlan, PlannedImagePrompt


DEFAULT_PREVIEWS = (
    "animals_category_selector",
    "tile_beginner_03",
    "tile_intermediate_01",
    "answer_african_elephant",
    "answer_alligator",
)
DEFAULT_NEGATIVE = (
    "misspelled text, extra text, letters, numbers, caption, logo, watermark, border, "
    "collage, duplicate subject, duplicate head, extra head, two heads, extra limbs, "
    "malformed anatomy, body paint, decorative markings, jewelry, clothing, blur"
)


def _safe_name(value: str) -> str:
    return re.sub(r"[^a-z0-9_]+", "_", value.casefold()).strip("_")


def _preview_prompt(
    asset: PlannedImagePrompt,
    *,
    category: str,
    use_pending_answer_prompts: bool,
) -> str:
    if (
        asset.role == "answer_image"
        and asset.review_status != "approved"
        and not use_pending_answer_prompts
    ):
        if not asset.source_labels:
            raise ValueError(f"{asset.asset_id} has no exact answer label")
        label = asset.source_labels[0]
        return (
            f"Create an accurate, reference-faithful picture of exactly one {label} "
            f"for a children's {category} quiz. The subject must be immediately "
            "recognizable specifically as the named answer, with correct real-world "
            "identity, form, proportions, colors, materials, and defining visible "
            "features appropriate to the subject. Show the complete subject centered "
            "with a strong silhouette and comfortable square margins. Use polished "
            "high-end 3D animated family-film artwork, bright cinematic lighting, and "
            "a simple softly blurred category-appropriate context. No text, labels, "
            "logo, watermark, border, duplicate subject, or unrelated objects."
        )
    return asset.prompt


def _write_webp(data: bytes, path: Path, size: int) -> None:
    with Image.open(io.BytesIO(data)) as source:
        source.load()
        image = source.convert("RGB")
        if image.size != (size, size):
            image = image.resize((size, size), Image.Resampling.LANCZOS)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp.webp")
    image.save(temporary, format="WEBP", quality=92, method=6)
    temporary.replace(path)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Render isolated ImageStudio previews from a Qwen image-prompt plan."
    )
    parser.add_argument(
        "--plan",
        type=Path,
        default=Path("visual_quiz_qwen/animals/image-prompt-plan.json"),
    )
    parser.add_argument("--endpoint", default="http://127.0.0.1:8000")
    parser.add_argument("--model", default="ernie-turbo")
    parser.add_argument("--asset-id", action="append")
    parser.add_argument("--size", type=int, default=768)
    parser.add_argument("--steps", type=int, default=8)
    parser.add_argument("--cfg", type=float, default=1.0)
    parser.add_argument(
        "--seed-offset",
        type=int,
        default=0,
        help="add this value to planned seeds when testing regeneration variants",
    )
    parser.add_argument("--timeout", type=float, default=600.0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument(
        "--use-pending-answer-prompts",
        action="store_true",
        help="render unapproved Qwen answer descriptions instead of safe fallbacks",
    )
    args = parser.parse_args()
    selected_ids = args.asset_id or list(DEFAULT_PREVIEWS)

    try:
        plan = ImagePromptPlan.model_validate_json(
            args.plan.read_text(encoding="utf-8")
        )
        assets = {asset.asset_id: asset for asset in plan.assets}
        missing = [asset_id for asset_id in selected_ids if asset_id not in assets]
        if missing:
            raise ValueError(f"asset IDs not found in prompt plan: {', '.join(missing)}")
        output_root = args.plan.parent / "prompt-previews" / _safe_name(args.model)
        manifest_path = output_root / "preview-manifest.json"
        if manifest_path.exists():
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        else:
            manifest = {
                "schema_version": "image_prompt_preview_v1",
                "provider": "imagestudio",
                "model": args.model,
                "assets": {},
            }

        with ImageStudioClient(
            args.endpoint, model=args.model, timeout_seconds=args.timeout
        ) as client:
            client.require_ready()
            for index, asset_id in enumerate(selected_ids, start=1):
                asset = assets[asset_id]
                output = output_root / f"{asset_id}.webp"
                if output.exists() and not args.force:
                    print(f"Preview {index}/{len(selected_ids)}: reusing {asset_id}")
                    continue
                prompt = _preview_prompt(
                    asset,
                    category=plan.category,
                    use_pending_answer_prompts=args.use_pending_answer_prompts,
                )
                negative = ", ".join(
                    value for value in (asset.negative_prompt, DEFAULT_NEGATIVE) if value
                )
                seed = (asset.seed + args.seed_offset) & 0x7FFFFFFF
                print(f"Preview {index}/{len(selected_ids)}: generating {asset_id}", flush=True)
                data, metadata = client.generate(
                    prompt=prompt,
                    negative_prompt=negative,
                    width=args.size,
                    height=args.size,
                    steps=args.steps,
                    cfg=args.cfg,
                    seed=seed,
                )
                _write_webp(data, output, args.size)
                manifest["assets"][asset_id] = {
                    "asset_id": asset_id,
                    "role": asset.role,
                    "file": str(output.relative_to(args.plan.parent)),
                    "seed": metadata.get("seed", seed),
                    "seed_offset": args.seed_offset,
                    "prompt": prompt,
                    "used_pending_prompt": (
                        asset.role == "answer_image"
                        and asset.review_status != "approved"
                        and args.use_pending_answer_prompts
                    ),
                    "elapsed_sec": metadata.get("elapsed_sec"),
                    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
                }
                manifest_path.parent.mkdir(parents=True, exist_ok=True)
                temporary = manifest_path.with_suffix(".tmp")
                temporary.write_text(
                    json.dumps(manifest, indent=2, ensure_ascii=True) + "\n",
                    encoding="utf-8",
                )
                temporary.replace(manifest_path)
    except (OSError, ValueError, RuntimeError, json.JSONDecodeError) as exc:
        print(f"Image prompt preview failed: {exc}", file=sys.stderr)
        return 1

    print(f"previews={output_root} count={len(selected_ids)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
