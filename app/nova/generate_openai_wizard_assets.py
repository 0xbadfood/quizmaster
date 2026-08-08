#!/usr/bin/env python3
"""Generate StoryVault wizard image assets from an inventory JSON via OpenAI.

The script mirrors generate_gemini_wizard_assets.py but uses OpenAI's image
generation endpoint through direct HTTPS calls. It defaults to one asset so we
can curate pilot batches before spending on a full persona inventory.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import re
import shlex
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_INVENTORY = SCRIPT_DIR / "space_adventure_captain_asset_inventory.json"
DEFAULT_OUTPUT_ROOT = SCRIPT_DIR / "generated_openai"
DEFAULT_MODEL = "gpt-image-2"
DEFAULT_IMAGES_ENDPOINT = "https://api.openai.com/v1/images/generations"


def log(message: str) -> None:
    print(f"[openai-assets] {message}", flush=True)


def load_profile_env(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    if not path.exists():
        return values
    for raw_line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export ") :].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key = key.strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        value = value.strip()
        if "#" in value and not value.startswith(("'", '"')):
            value = value.split("#", 1)[0].strip()
        try:
            parsed = shlex.split(value)
            value = parsed[0] if parsed else ""
        except ValueError:
            value = value.strip("'\"")
        values[key] = value
    return values


def get_api_key(profile_path: Path) -> str:
    for name in ("OPENAI_API_KEY", "OPENAI_TOKEN"):
        key = os.environ.get(name, "").strip()
        if key:
            return key
    profile_values = load_profile_env(profile_path)
    for name in ("OPENAI_API_KEY", "OPENAI_TOKEN"):
        key = profile_values.get(name, "").strip()
        if key:
            return key
    return ""


def load_inventory(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload.get("assets"), list):
        raise ValueError(f"Inventory has no assets list: {path}")
    return payload


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", value.strip()).strip("_")
    return slug or "asset"


def preferred_extension(output_format: str) -> str:
    fmt = output_format.strip().lower()
    if fmt in {"jpeg", "jpg"}:
        return ".jpg"
    if fmt == "webp":
        return ".webp"
    return ".png"


def image_extension(data: bytes, fallback: str) -> str:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return ".png"
    if data.startswith(b"\xff\xd8\xff"):
        return ".jpg"
    if data.startswith(b"RIFF") and b"WEBP" in data[:16]:
        return ".webp"
    return fallback


def asset_output_path(output_root: Path, asset: dict[str, Any], output_format: str) -> Path:
    target_path = str(asset.get("target_path") or "").strip()
    fallback_ext = preferred_extension(output_format)
    if target_path:
        parts = Path(target_path).parts
        if "story_wizards" in parts:
            idx = parts.index("story_wizards")
            path = output_root.joinpath(*parts[idx:])
            return path.with_suffix(fallback_ext)
    persona_id = str(asset.get("persona_id") or "unknown_persona")
    step_id = str(asset.get("step_id") or "misc")
    name = str(asset.get("persona_specific_name") or asset.get("general_name") or "asset")
    return output_root / "story_wizards" / persona_id / step_id / f"{name}{fallback_ext}"


def select_assets(
    inventory: dict[str, Any],
    *,
    step_id: str | None,
    asset_name: str | None,
    usage: str | None,
    limit: int | None,
    all_assets: bool,
) -> list[dict[str, Any]]:
    assets = [item for item in inventory["assets"] if isinstance(item, dict)]
    if step_id:
        assets = [item for item in assets if str(item.get("step_id") or "") == step_id]
    if usage:
        assets = [item for item in assets if str(item.get("usage") or "") == usage]
    if asset_name:
        wanted = asset_name.strip()
        assets = [
            item
            for item in assets
            if wanted
            in {
                str(item.get("general_name") or ""),
                str(item.get("persona_specific_name") or ""),
                str(item.get("label") or ""),
            }
        ]
    if not all_assets:
        limit = 1 if limit is None else limit
    if limit is not None and limit >= 0:
        assets = assets[:limit]
    return assets


def build_prompt(inventory: dict[str, Any], asset: dict[str, Any], *, tile_mode: bool) -> str:
    art = inventory.get("art_direction") or {}
    size = str(asset.get("size") or "").strip() or "1024x1024"
    label = str(asset.get("label") or "").strip()
    persona_name = str(inventory.get("persona_display_name") or "the wizard")
    usage = str(asset.get("usage") or "")
    asset_name = str(asset.get("persona_specific_name") or asset.get("general_name") or "")
    is_persona_asset = usage.startswith("wizard_character") or usage == "speaking_avatar" or asset_name.startswith("persona_")
    if tile_mode:
        background_instruction = (
            "Create a polished rounded-square storybook choice tile. Use a clean dark navy "
            "or cosmic background inside the tile and keep the main subject centered with "
            "comfortable padding. Do not include a text label."
        )
    else:
        background_instruction = (
            "Create a single isolated app asset centered in the image. Use a clean plain "
            "dark navy background if transparent output is not supported."
        )
    no_text = (
        "Do not include any readable text, letters, numbers, captions, logos, "
        "watermarks, labels, UI text, or signage inside the image."
    )
    return "\n".join(
        [
            "Create one production-ready image asset for the StoryVault mobile app.",
            f"Persona: {persona_name} ({inventory.get('persona_id')}).",
            f"Asset name: {asset.get('persona_specific_name') or asset.get('general_name')}.",
            f"Asset label for prompt context only: {label}.",
            f"Step: {asset.get('step_id')}.",
            f"Usage: {asset.get('usage')}.",
            f"Target size/aspect intent: {size}.",
            "",
            "Image description:",
            str(asset.get("image_description") or "").strip(),
            "",
            "Art direction:",
            f"- Style: {art.get('style')}",
            f"- Palette: {art.get('palette')}",
            f"- Lighting: {art.get('lighting')}",
            f"- Character consistency: {art.get('character_consistency')}",
            f"- Safety: {art.get('safety')}",
            "",
            "Hard requirements:",
            f"- {no_text}",
            f"- {background_instruction}",
            (
                f"- Include {persona_name} only because this is a persona/avatar asset."
                if is_persona_asset
                else f"- Do not include {persona_name}, astronauts, children, guides, or mascot characters. Show only the requested asset subject."
            ),
            "- Use a premium children storybook look with soft 3D forms.",
            "- Use kid-safe, cheerful expressions and rounded shapes.",
            "- Avoid horror, weapons, realistic danger, aggressive expressions, or adult themes.",
            "- Output a single image asset, not a collage and not a phone UI mockup.",
        ]
    )


def decode_image_item(item: dict[str, Any], headers: dict[str, str], timeout: float) -> bytes:
    b64 = item.get("b64_json") or item.get("image_base64") or item.get("data")
    if isinstance(b64, str) and b64.strip():
        return base64.b64decode(b64)
    url = item.get("url") or item.get("image_url")
    if isinstance(url, str) and url.strip():
        request = urllib.request.Request(url, headers=headers, method="GET")
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    raise RuntimeError(f"Image response item has neither b64_json nor url: {item.keys()}")


def call_openai_images(
    *,
    endpoint: str,
    api_key: str,
    model: str,
    prompt: str,
    size: str,
    quality: str,
    output_format: str,
    background: str,
    timeout: float,
    extra: dict[str, Any],
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "model": model,
        "prompt": prompt,
        "size": size,
        "n": 1,
    }
    if quality:
        payload["quality"] = quality
    if output_format:
        payload["output_format"] = output_format
    if background:
        payload["background"] = background
    payload.update(extra)
    request = urllib.request.Request(
        endpoint,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Authorization": f"Bearer {api_key}",
            "Content-Type": "application/json",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            raw = response.read().decode("utf-8")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"OpenAI image request failed HTTP {exc.code}: {body}") from exc
    return json.loads(raw)


def generate_one(api_key: str, args: argparse.Namespace, inventory: dict[str, Any], asset: dict[str, Any]) -> dict[str, Any]:
    prompt = build_prompt(inventory, asset, tile_mode=args.tile_mode)
    planned_path = asset_output_path(args.output_root, asset, args.output_format)
    debug_dir = args.debug_dir / safe_slug(str(asset.get("persona_specific_name") or asset.get("general_name") or "asset"))
    prompt_path = debug_dir / "prompt.txt"
    request_path = debug_dir / "request.json"
    response_path = debug_dir / "response.json"
    error_path = debug_dir / "error.json"
    if planned_path.exists() and not args.force:
        log(f"skip existing {asset.get('persona_specific_name')} -> {planned_path}")
        return {"status": "skipped", "asset": asset.get("persona_specific_name"), "path": str(planned_path)}
    extra: dict[str, Any] = {}
    if args.extra_json:
        extra = json.loads(args.extra_json)
        if not isinstance(extra, dict):
            raise ValueError("--extra-json must be a JSON object")
    if args.dry_run:
        log(f"dry-run {asset.get('persona_specific_name')} -> {planned_path}")
        log(prompt)
        return {"status": "dry_run", "asset": asset.get("persona_specific_name"), "path": str(planned_path)}

    debug_dir.mkdir(parents=True, exist_ok=True)
    prompt_path.write_text(prompt, encoding="utf-8")
    request_path.write_text(
        json.dumps(
            {
                "endpoint": args.endpoint,
                "model": args.model,
                "size": args.size,
                "quality": args.quality,
                "output_format": args.output_format,
                "background": args.background,
                "extra": extra,
                "prompt": prompt,
            },
            indent=2,
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    log(f"request {asset.get('persona_specific_name')} usage={asset.get('usage')} size={args.size} quality={args.quality}")
    try:
        response = call_openai_images(
            endpoint=args.endpoint,
            api_key=api_key,
            model=args.model,
            prompt=prompt,
            size=args.size,
            quality=args.quality,
            output_format=args.output_format,
            background=args.background,
            timeout=args.timeout,
            extra=extra,
        )
    except Exception as exc:
        error_path.write_text(
            json.dumps(
                {
                    "asset": asset.get("persona_specific_name") or asset.get("general_name"),
                    "error_type": type(exc).__name__,
                    "error": str(exc),
                },
                indent=2,
                ensure_ascii=False,
            ),
            encoding="utf-8",
        )
        raise
    response_path.write_text(json.dumps(response, indent=2, ensure_ascii=False), encoding="utf-8")
    data = response.get("data")
    if not isinstance(data, list) or not data:
        raise RuntimeError(f"OpenAI response has no data images; debug={response_path}")
    headers = {"Authorization": f"Bearer {api_key}"}
    image = decode_image_item(data[0], headers=headers, timeout=args.timeout)
    ext = image_extension(image, planned_path.suffix or preferred_extension(args.output_format))
    out_path = planned_path.with_suffix(ext)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(image)
    log(f"wrote {out_path} bytes={out_path.stat().st_size}")
    return {"status": "generated", "asset": asset.get("persona_specific_name"), "path": str(out_path)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate StoryVault wizard assets from OpenAI image models.")
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--debug-dir", type=Path, default=SCRIPT_DIR / "openai_debug")
    parser.add_argument("--profile", type=Path, default=Path.home() / ".profile")
    parser.add_argument("--endpoint", default=DEFAULT_IMAGES_ENDPOINT)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--step-id", default="", help="Only generate assets for this step_id.")
    parser.add_argument("--usage", default="", help="Only generate assets matching this usage.")
    parser.add_argument("--asset-name", default="", help="Match general_name, persona_specific_name, or label.")
    parser.add_argument("--limit", type=int, default=None, help="Max assets to generate. Defaults to 1 unless --all is set.")
    parser.add_argument("--all", action="store_true", help="Generate all selected assets instead of the default first asset only.")
    parser.add_argument("--force", action="store_true", help="Overwrite existing image files.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--sleep-seconds", type=float, default=1.0)
    parser.add_argument("--timeout", type=float, default=180.0)
    parser.add_argument("--size", default="1024x1024")
    parser.add_argument("--quality", default="medium", help="Use OpenAI-supported values such as low, medium, high, or auto.")
    parser.add_argument("--output-format", default="png", choices=("png", "jpeg", "webp"))
    parser.add_argument("--background", default="", help="Optional OpenAI background value if supported by the selected model.")
    parser.add_argument("--extra-json", default="", help="Provider-specific JSON object merged into the image request.")
    parser.add_argument("--tile-mode", action=argparse.BooleanOptionalAction, default=True, help="Prompt for polished choice tiles instead of isolated cutout icons.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.inventory = args.inventory.resolve()
    args.output_root = args.output_root.resolve()
    args.debug_dir = args.debug_dir.resolve()

    inventory = load_inventory(args.inventory)
    assets = select_assets(
        inventory,
        step_id=args.step_id.strip() or None,
        asset_name=args.asset_name.strip() or None,
        usage=args.usage.strip() or None,
        limit=args.limit,
        all_assets=args.all,
    )
    if not assets:
        raise RuntimeError("No assets matched the requested filters.")
    log(f"inventory={args.inventory}")
    log(f"output_root={args.output_root}")
    log(f"model={args.model} selected={len(assets)} dry_run={args.dry_run} force={args.force}")

    api_key = ""
    if not args.dry_run:
        api_key = get_api_key(args.profile)
        if not api_key:
            raise RuntimeError(f"OPENAI_API_KEY/OPENAI_TOKEN not found in environment or {args.profile}")

    results: list[dict[str, Any]] = []
    for index, asset in enumerate(assets, start=1):
        log(f"[{index}/{len(assets)}] {asset.get('persona_specific_name')} ({asset.get('step_id')})")
        try:
            results.append(generate_one(api_key, args, inventory, asset))
        except Exception as exc:
            log(f"ERROR {asset.get('persona_specific_name')}: {type(exc).__name__}: {exc}")
            results.append(
                {
                    "status": "failed",
                    "asset": asset.get("persona_specific_name"),
                    "error": f"{type(exc).__name__}: {exc}",
                }
            )
        if index < len(assets) and args.sleep_seconds > 0:
            time.sleep(args.sleep_seconds)

    succeeded = sum(1 for item in results if item.get("status") == "generated")
    skipped = sum(1 for item in results if item.get("status") == "skipped")
    failed = sum(1 for item in results if item.get("status") == "failed")
    log(f"complete generated={succeeded} skipped={skipped} failed={failed}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
