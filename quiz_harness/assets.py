from __future__ import annotations

import hashlib
import json
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from PIL import Image, ImageDraw, UnidentifiedImageError

from .image_adapters import ImageGeneratorAdapter
from .mageflow import write_validated_png
from .models import AssetSpec, PlanDocument


POSTPROCESS_VERSION = "edge-alpha-1"


def generation_dimensions(
    asset: AssetSpec, provider: str = "mageflow"
) -> tuple[int, int]:
    if provider == "imagestudio":
        if asset.role == "background":
            return 768, 1344
        if asset.role in {"answer_button_frame", "progress_track"}:
            return 1280, 512
        if asset.role in {"progress_marker", "feedback_decoration"}:
            return 512, 512
        ratio = asset.width_px / asset.height_px
        if ratio > 1.25:
            return 1344, 768
        if ratio < 0.8:
            return 768, 1344
        return 768, 768
    if asset.role == "background":
        return 720, 1280
    if asset.role in {"answer_button_frame", "progress_track"}:
        return 2048, 512
    if asset.role in {"progress_marker", "feedback_decoration"}:
        return 512, 512
    ratio = asset.width_px / asset.height_px
    if ratio > 1.25:
        return 1280, 720
    if ratio < 0.8:
        return 720, 1280
    return 1024, 1024


def _fingerprint(
    asset: AssetSpec,
    *,
    prompt: str,
    width: int,
    height: int,
    steps: int,
    cfg: float,
    seed: int,
    provider: str,
) -> str:
    payload = {
        "asset": asset.model_dump(),
        "effective_prompt": prompt,
        "width": width,
        "height": height,
        "steps": steps,
        "cfg": cfg,
        "seed": seed,
        "provider": provider,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def effective_generation_prompt(asset: AssetSpec) -> str:
    prompt = asset.generation_prompt
    if asset.role not in {
        "answer_button_frame",
        "progress_track",
        "progress_marker",
    }:
        return prompt
    prompt = re.sub(r"(?i)the aspect ratio is[^.]*\.", "", prompt)
    prompt = re.sub(r"(?i)\([^)]*\bpx\b[^)]*\)", "", prompt)
    prompt = re.sub(r"(?i)\b\d+\s*px\b", "", prompt)
    prompt = " ".join(prompt.split())
    return (
        f"{prompt} Render one isolated UI object only, centered and filling the "
        "canvas. Do not render measurements, ratios, captions, labels, annotations, "
        "guides, or a design-sheet presentation."
    )


def make_edge_background_transparent(path: Path, *, threshold: int = 36) -> None:
    with Image.open(path) as source:
        image = source.convert("RGBA")
    corners = [
        (0, 0),
        (image.width - 1, 0),
        (0, image.height - 1),
        (image.width - 1, image.height - 1),
    ]
    for corner in corners:
        red, green, blue, alpha = image.getpixel(corner)
        if alpha == 0:
            continue
        ImageDraw.floodfill(
            image,
            corner,
            value=(red, green, blue, 0),
            thresh=threshold,
        )
    temporary = path.with_suffix(path.suffix + ".tmp")
    image.save(temporary, format="PNG", optimize=True)
    temporary.replace(path)


def _valid_cached_image(path: Path) -> bool:
    try:
        with Image.open(path) as image:
            image.verify()
        return True
    except (OSError, UnidentifiedImageError):
        return False


def _load_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema_version": "1.0", "assets": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"schema_version": "1.0", "assets": {}}
    if not isinstance(data, dict) or not isinstance(data.get("assets"), dict):
        return {"schema_version": "1.0", "assets": {}}
    return data


def _write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def generate_assets(
    *,
    document: PlanDocument,
    client: ImageGeneratorAdapter,
    endpoint: str,
    bundle_dir: Path,
    steps: int,
    cfg: float,
    force: bool,
    progress: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    status = client.require_ready()
    manifest_path = bundle_dir / "asset-manifest.json"
    manifest = _load_manifest(manifest_path)
    manifest.update(
        {
            "schema_version": "1.0",
            "endpoint": endpoint,
            "provider": client.provider_id,
            "model": status.get("model", "unknown"),
            "steps": steps,
            "cfg": cfg,
        }
    )
    assets_dir = bundle_dir / "assets"
    total = len(document.plan.assets)

    for index, asset in enumerate(document.plan.assets, start=1):
        width, height = generation_dimensions(asset, client.provider_id)
        seed = document.request.seed + index * 1009
        prompt = effective_generation_prompt(asset)
        fingerprint = _fingerprint(
            asset,
            prompt=prompt,
            width=width,
            height=height,
            steps=steps,
            cfg=cfg,
            seed=seed,
            provider=client.provider_id,
        )
        relative_file = f"assets/{asset.asset_id}.png"
        output = bundle_dir / relative_file
        cached = manifest["assets"].get(asset.asset_id)
        if (
            not force
            and isinstance(cached, dict)
            and cached.get("fingerprint") == fingerprint
            and output.exists()
            and _valid_cached_image(output)
        ):
            if (
                asset.transparent_background
                and cached.get("postprocess_version") != POSTPROCESS_VERSION
            ):
                make_edge_background_transparent(output)
                cached["mode"] = "RGBA"
                cached["postprocess_version"] = POSTPROCESS_VERSION
                _write_manifest(manifest_path, manifest)
            if progress:
                progress(f"Asset {index}/{total}: reusing {asset.asset_id}")
            continue

        if progress:
            progress(
                f"Asset {index}/{total}: generating {asset.asset_id} "
                f"({width}x{height}, seed {seed})"
            )
        image_data, response_metadata = client.generate(
            prompt=prompt,
            negative_prompt=(
                asset.negative_prompt
                + ", measurements, ratio text, captions, annotations, design sheet"
            ),
            width=width,
            height=height,
            steps=steps,
            cfg=cfg,
            seed=seed,
        )
        actual_width, actual_height, mode = write_validated_png(image_data, output)
        if asset.transparent_background:
            make_edge_background_transparent(output)
            mode = "RGBA"
        manifest["assets"][asset.asset_id] = {
            "asset_id": asset.asset_id,
            "role": asset.role,
            "file": relative_file,
            "fingerprint": fingerprint,
            "seed": response_metadata.get("seed", seed),
            "width": actual_width,
            "height": actual_height,
            "mode": mode,
            "postprocess_version": (
                POSTPROCESS_VERSION if asset.transparent_background else None
            ),
            "elapsed_sec": response_metadata.get("elapsed_sec"),
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        }
        _write_manifest(manifest_path, manifest)

    return manifest
