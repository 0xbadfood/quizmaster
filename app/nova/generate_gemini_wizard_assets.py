#!/usr/bin/env python3
"""Generate StoryVault wizard image assets from an inventory JSON via Gemini.

The script intentionally defaults to one asset at a time unless --limit/--all is
given. Image generation is paid and outputs need curation, so resumability and
small batches are safer than a single 70+ image blast.
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
from pathlib import Path
from typing import Any


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_INVENTORY = SCRIPT_DIR / "space_adventure_captain_asset_inventory.json"
DEFAULT_OUTPUT_ROOT = SCRIPT_DIR / "generated"
DEFAULT_MODEL = "models/gemini-3.1-flash-image"


def log(message: str) -> None:
    print(f"[gemini-assets] {message}", flush=True)


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
    key = os.environ.get("GEMINI_API_KEY", "").strip()
    if key:
        return key
    return load_profile_env(profile_path).get("GEMINI_API_KEY", "").strip()


def load_inventory(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        payload = json.load(handle)
    if not isinstance(payload.get("assets"), list):
        raise ValueError(f"Inventory has no assets list: {path}")
    return payload


def asset_output_path(output_root: Path, asset: dict[str, Any]) -> Path:
    target_path = str(asset.get("target_path") or "").strip()
    if target_path:
        parts = Path(target_path).parts
        if "story_wizards" in parts:
            idx = parts.index("story_wizards")
            return output_root.joinpath(*parts[idx:])
    persona_id = str(asset.get("persona_id") or "unknown_persona")
    step_id = str(asset.get("step_id") or "misc")
    name = str(asset.get("persona_specific_name") or asset.get("general_name") or "asset")
    return output_root / "story_wizards" / persona_id / step_id / f"{name}.png"


def safe_slug(value: str) -> str:
    slug = re.sub(r"[^a-zA-Z0-9._-]+", "_", value.strip()).strip("_")
    return slug or "asset"


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


def build_prompt(inventory: dict[str, Any], asset: dict[str, Any]) -> str:
    art = inventory.get("art_direction") or {}
    transparent = bool(asset.get("transparent"))
    size = str(asset.get("size") or "").strip() or "1024x1024"
    label = str(asset.get("label") or "").strip()
    persona_name = str(inventory.get("persona_display_name") or "the wizard")
    background_instruction = (
        "Use a transparent background if the image format supports alpha. "
        "If true alpha is not possible, use a clean plain dark navy background "
        "with the object fully isolated and centered."
        if transparent
        else "Use a complete polished background composition."
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
            "- Keep the subject centered with comfortable padding for a rounded choice card.",
            "- Use a kid-safe, cheerful expression and soft forms.",
            "- Avoid horror, weapons, realistic danger, or aggressive expressions.",
            "- Output a single image asset, not a collage or mock phone screenshot.",
        ]
    )


def object_to_debug_json(value: Any) -> Any:
    for method_name in ("model_dump", "to_json_dict", "to_dict"):
        method = getattr(value, method_name, None)
        if callable(method):
            try:
                return method()
            except Exception:
                pass
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, bytes):
        return f"<bytes:{len(value)}>"
    if isinstance(value, dict):
        return {str(k): object_to_debug_json(v) for k, v in value.items()}
    if isinstance(value, (list, tuple)):
        return [object_to_debug_json(v) for v in value]
    if hasattr(value, "__dict__"):
        return {
            str(k): object_to_debug_json(v)
            for k, v in vars(value).items()
            if not str(k).startswith("_")
        }
    return repr(value)


def walk_values(value: Any) -> list[Any]:
    out = [value]
    if isinstance(value, dict):
        for nested in value.values():
            out.extend(walk_values(nested))
    elif isinstance(value, (list, tuple)):
        for nested in value:
            out.extend(walk_values(nested))
    elif hasattr(value, "__dict__") and not isinstance(value, (str, bytes)):
        try:
            for nested in vars(value).values():
                out.extend(walk_values(nested))
        except Exception:
            pass
    return out


def maybe_decode_base64(value: str) -> bytes | None:
    text = value.strip()
    if not text:
        return None
    if text.startswith("data:image/"):
        text = text.split(",", 1)[-1]
    if len(text) < 64:
        return None
    if not re.fullmatch(r"[A-Za-z0-9+/=\s_-]+", text):
        return None
    try:
        data = base64.b64decode(text, validate=False)
    except Exception:
        return None
    if data.startswith(b"\x89PNG\r\n\x1a\n") or data.startswith(b"\xff\xd8\xff") or data.startswith(b"RIFF"):
        return data
    return None


def extract_image_bytes(response: Any) -> list[bytes]:
    images: list[bytes] = []
    for value in walk_values(response):
        data = getattr(value, "data", None)
        mime_type = str(getattr(value, "mime_type", "") or getattr(value, "mimeType", "") or "")
        if isinstance(data, bytes) and (mime_type.startswith("image/") or data.startswith((b"\x89PNG", b"\xff\xd8"))):
            images.append(data)
        elif isinstance(data, str) and mime_type.startswith("image/"):
            decoded = maybe_decode_base64(data)
            if decoded:
                images.append(decoded)
        elif isinstance(value, dict):
            mime = str(value.get("mime_type") or value.get("mimeType") or "")
            data_value = value.get("data") or value.get("bytes") or value.get("b64_json")
            if isinstance(data_value, bytes) and (mime.startswith("image/") or data_value.startswith((b"\x89PNG", b"\xff\xd8"))):
                images.append(data_value)
            elif isinstance(data_value, str) and (mime.startswith("image/") or len(data_value) > 64):
                decoded = maybe_decode_base64(data_value)
                if decoded:
                    images.append(decoded)
        elif isinstance(value, str):
            decoded = maybe_decode_base64(value)
            if decoded:
                images.append(decoded)
    deduped: list[bytes] = []
    seen: set[bytes] = set()
    for image in images:
        digest = image[:128] + str(len(image)).encode("ascii")
        if digest not in seen:
            seen.add(digest)
            deduped.append(image)
    return deduped


def create_interaction(client: Any, args: argparse.Namespace, prompt: str) -> Any:
    tools = [{"type": "google_search"}] if args.google_search else None
    generation_config: dict[str, Any] = {
        "temperature": args.temperature,
        "max_output_tokens": args.max_output_tokens,
        "top_p": args.top_p,
        "thinking_level": args.thinking_level,
        "image_config": {
            "image_size": args.image_size,
        },
    }
    kwargs: dict[str, Any] = {
        "model": args.model,
        "input": prompt,
        "generation_config": generation_config,
        "response_modalities": ["image", "text"],
    }
    if tools:
        kwargs["tools"] = tools
    interactions = getattr(client, "interactions", None)
    if interactions is None or not hasattr(interactions, "create"):
        raise RuntimeError("Installed google-genai SDK does not expose client.interactions.create")
    return interactions.create(**kwargs)


def generate_one(client: Any, args: argparse.Namespace, inventory: dict[str, Any], asset: dict[str, Any]) -> dict[str, Any]:
    prompt = build_prompt(inventory, asset)
    out_path = asset_output_path(args.output_root, asset)
    debug_dir = args.debug_dir / safe_slug(str(asset.get("persona_specific_name") or asset.get("general_name") or "asset"))
    prompt_path = debug_dir / "prompt.txt"
    response_path = debug_dir / "response.json"
    error_path = debug_dir / "error.json"
    if out_path.exists() and not args.force:
        log(f"skip existing {asset.get('persona_specific_name')} -> {out_path}")
        return {"status": "skipped", "asset": asset.get("persona_specific_name"), "path": str(out_path)}
    if args.dry_run:
        log(f"dry-run {asset.get('persona_specific_name')} -> {out_path}")
        log(prompt)
        return {"status": "dry_run", "asset": asset.get("persona_specific_name"), "path": str(out_path)}

    debug_dir.mkdir(parents=True, exist_ok=True)
    prompt_path.write_text(prompt, encoding="utf-8")
    log(f"request {asset.get('persona_specific_name')} usage={asset.get('usage')} size={asset.get('size')}")
    try:
        response = create_interaction(client, args, prompt)
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
    response_path.write_text(
        json.dumps(object_to_debug_json(response), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )
    images = extract_image_bytes(response)
    if not images:
        raise RuntimeError(f"Gemini response had no extractable image bytes; debug={response_path}")
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(images[0])
    log(f"wrote {out_path} bytes={out_path.stat().st_size}")
    if len(images) > 1:
        for idx, image in enumerate(images[1:], start=2):
            sibling = out_path.with_name(f"{out_path.stem}_{idx}{out_path.suffix}")
            sibling.write_bytes(image)
            log(f"wrote extra {sibling} bytes={sibling.stat().st_size}")
    return {"status": "generated", "asset": asset.get("persona_specific_name"), "path": str(out_path)}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate StoryVault wizard assets from Gemini image models.")
    parser.add_argument("--inventory", type=Path, default=DEFAULT_INVENTORY)
    parser.add_argument("--output-root", type=Path, default=DEFAULT_OUTPUT_ROOT)
    parser.add_argument("--debug-dir", type=Path, default=SCRIPT_DIR / "gemini_debug")
    parser.add_argument("--profile", type=Path, default=Path.home() / ".profile")
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--step-id", default="", help="Only generate assets for this step_id.")
    parser.add_argument("--usage", default="", help="Only generate assets matching this usage.")
    parser.add_argument("--asset-name", default="", help="Match general_name, persona_specific_name, or label.")
    parser.add_argument("--limit", type=int, default=None, help="Max assets to generate. Defaults to 1 unless --all is set.")
    parser.add_argument("--all", action="store_true", help="Generate all selected assets instead of the default first asset only.")
    parser.add_argument("--force", action="store_true", help="Overwrite existing image files.")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--sleep-seconds", type=float, default=1.0)
    parser.add_argument("--temperature", type=float, default=1.0)
    parser.add_argument("--top-p", type=float, default=0.95)
    parser.add_argument("--max-output-tokens", type=int, default=65536)
    parser.add_argument("--thinking-level", default="low", choices=("low", "high"))
    parser.add_argument("--image-size", default="1K")
    parser.add_argument("--google-search", action="store_true", help="Attach google_search tool, matching Gemini sample code.")
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

    client = None
    if not args.dry_run:
        api_key = get_api_key(args.profile)
        if not api_key:
            raise RuntimeError(f"GEMINI_API_KEY not found in environment or {args.profile}")
        try:
            from google import genai  # type: ignore
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "Missing dependency google-genai. Install with: python3 -m pip install google-genai"
            ) from exc
        client = genai.Client(api_key=api_key)

    results: list[dict[str, Any]] = []
    for index, asset in enumerate(assets, start=1):
        log(f"[{index}/{len(assets)}] {asset.get('persona_specific_name')} ({asset.get('step_id')})")
        try:
            results.append(generate_one(client, args, inventory, asset))
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
