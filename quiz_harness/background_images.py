from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from openai import APIError, OpenAI
from PIL import Image, ImageOps, UnidentifiedImageError

from .database import QuizDatabase
from .imagestudio import ImageStudioClient
from .secure_store import SecretStore
from .visual_bank import slugify


BACKGROUND_SIZE = (941, 1672)
IMAGESTUDIO_REQUEST_SIZE = (768, 1344)
SUPPORTED_PROVIDER_TYPES = {"openai_images", "imagestudio"}


class BackgroundGenerationError(RuntimeError):
    """Raised when a quiz background cannot be generated or normalized."""


def build_background_prompt(
    *,
    category: str,
    display_title: str,
    visual_brief: str | None = None,
    subtitle: str = "ADVENTURE",
) -> str:
    subject_guidance = (
        visual_brief.strip()
        if visual_brief and visual_brief.strip()
        else f"Use iconic places, objects, and atmosphere associated with {category}."
    )
    return f"""Create one polished portrait background for a children's {category} quiz.
The final image fills a tall mobile screen. Build one coherent, immersive scene rather
than a collage. Use a high-end family-friendly 3D animated illustration aesthetic,
rich natural color, cinematic light, appealing depth, and crisp readable silhouettes.

Visual direction: {subject_guidance}

Reserve the top 28 percent for a large dimensional title emblem. Keep the middle of
the image calmer and lower-contrast so Flutter question and answer controls remain
readable over it. Place supporting scenery mainly around the outer edges and lower
third. Keep all important content within generous portrait safe margins.

Render exactly these two text elements and spell them exactly:
1. Main title: "{display_title}"
2. Small ribbon subtitle: "{subtitle}"

Do not include any other words, dates, letters, numbers, captions, logos, watermarks,
interface controls, question cards, answer boxes, borders, collage panels, copyrighted
characters, named studio styles, living politicians, or modern political-party symbols.
The result must feel celebratory, educational, historically respectful, and suitable
for children ages 3 to 10."""


def normalize_background(data: bytes, output: Path) -> dict[str, Any]:
    try:
        with Image.open(io.BytesIO(data)) as source:
            source.load()
            image = ImageOps.fit(
                source.convert("RGB"),
                BACKGROUND_SIZE,
                method=Image.Resampling.LANCZOS,
                centering=(0.5, 0.5),
            )
    except (OSError, UnidentifiedImageError) as exc:
        raise BackgroundGenerationError(
            f"provider returned invalid image data: {exc}"
        ) from exc

    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    image.save(temporary, format="PNG", optimize=True)
    temporary.replace(output)
    payload = output.read_bytes()
    return {
        "file": str(output),
        "width": BACKGROUND_SIZE[0],
        "height": BACKGROUND_SIZE[1],
        "format": "png",
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _model(provider: dict[str, Any], override: str | None) -> str:
    value = override or provider.get("default_model") or next(
        iter(provider.get("discovered_models") or []), None
    )
    if not value:
        raise BackgroundGenerationError(
            f"provider has no configured or discovered model: {provider['id']}"
        )
    return str(value)


def _openai_image(
    *,
    provider: dict[str, Any],
    secret: str | None,
    model: str,
    prompt: str,
    quality: str,
    retries: int,
    timeout_seconds: float,
) -> tuple[bytes, dict[str, Any]]:
    if not secret:
        raise BackgroundGenerationError(
            f"OpenAI image provider has no API key: {provider['id']}"
        )
    last_error: Exception | None = None
    with OpenAI(
        api_key=secret,
        base_url=str(provider["base_url"]),
        timeout=timeout_seconds,
    ) as client:
        for attempt in range(1, retries + 2):
            try:
                response = client.images.generate(
                    model=model,
                    prompt=prompt,
                    n=1,
                    quality=quality,
                    size="1024x1536",
                    background="opaque",
                    output_format="png",
                    moderation="auto",
                )
                item = response.data[0]
                if not item.b64_json:
                    raise BackgroundGenerationError(
                        "OpenAI response did not contain base64 image data"
                    )
                return base64.b64decode(item.b64_json, validate=True), {
                    "created": response.created,
                    "usage": (
                        response.usage.model_dump(mode="json")
                        if response.usage is not None
                        else None
                    ),
                    "request_size": "1024x1536",
                }
            except (APIError, ValueError, BackgroundGenerationError) as exc:
                last_error = exc
                if attempt <= retries:
                    time.sleep(min(2**attempt, 10))
    raise BackgroundGenerationError(f"OpenAI image generation failed: {last_error}")


def _imagestudio_image(
    *,
    provider: dict[str, Any],
    model: str,
    prompt: str,
    seed: int,
    timeout_seconds: float,
) -> tuple[bytes, dict[str, Any]]:
    negative_prompt = (
        "unwanted text, misspelled text, extra letters, dates, numbers, watermark, "
        "logo, interface, question card, answer box, collage, border, cropped title, "
        "duplicate subject, blur, distortion, malformed anatomy, political party logo"
    )
    with ImageStudioClient(
        str(provider["base_url"]), model=model, timeout_seconds=timeout_seconds
    ) as client:
        client.require_ready()
        data, metadata = client.generate(
            prompt=prompt,
            negative_prompt=negative_prompt,
            width=IMAGESTUDIO_REQUEST_SIZE[0],
            height=IMAGESTUDIO_REQUEST_SIZE[1],
            steps=8,
            cfg=1.0,
            seed=seed,
        )
    return data, {
        "seed": metadata.get("seed", seed),
        "elapsed_seconds": metadata.get("elapsed_sec"),
        "request_size": f"{IMAGESTUDIO_REQUEST_SIZE[0]}x{IMAGESTUDIO_REQUEST_SIZE[1]}",
    }


def generate_quiz_background(
    *,
    category: str,
    display_title: str,
    provider_id: str,
    database_path: Path,
    secret_key_file: Path,
    output: Path,
    model_override: str | None = None,
    quality: str = "medium",
    seed: int = 20260805,
    visual_brief: str | None = None,
    subtitle: str = "ADVENTURE",
    prompt_override: str | None = None,
    retries: int = 2,
    timeout_seconds: float = 900.0,
) -> dict[str, Any]:
    database = QuizDatabase(database_path)
    database.migrate()
    try:
        provider = database.provider_connection(provider_id)
    except KeyError as exc:
        raise BackgroundGenerationError(f"provider does not exist: {provider_id}") from exc
    if not provider["enabled"]:
        raise BackgroundGenerationError(f"provider is disabled: {provider_id}")
    if provider["provider_type"] not in SUPPORTED_PROVIDER_TYPES:
        raise BackgroundGenerationError(
            f"provider {provider_id} must be OpenAI Images or ImageStudio"
        )

    model = _model(provider, model_override)
    prompt = prompt_override.strip() if prompt_override else build_background_prompt(
        category=category,
        display_title=display_title,
        visual_brief=visual_brief,
        subtitle=subtitle,
    )
    if len(prompt) < 100:
        raise BackgroundGenerationError("background prompt must contain at least 100 characters")

    if provider["provider_type"] == "openai_images":
        secrets = SecretStore(
            key=os.getenv("QUIZ_SECRET_KEY"), key_file=secret_key_file
        )
        secret = secrets.decrypt(provider.get("secret_ciphertext"))
        data, generation = _openai_image(
            provider=provider,
            secret=secret,
            model=model,
            prompt=prompt,
            quality=quality,
            retries=retries,
            timeout_seconds=timeout_seconds,
        )
    else:
        data, generation = _imagestudio_image(
            provider=provider,
            model=model,
            prompt=prompt,
            seed=seed,
            timeout_seconds=timeout_seconds,
        )

    image = normalize_background(data, output)
    result = {
        "schema_version": "quiz_background_generation_v1",
        "category": category,
        "category_slug": slugify(category),
        "display_title": display_title,
        "subtitle": subtitle,
        "provider_id": provider["id"],
        "provider_type": provider["provider_type"],
        "model": model,
        "quality": quality if provider["provider_type"] == "openai_images" else None,
        "prompt": prompt,
        "generation": generation,
        "image": image,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    manifest = output.expanduser().resolve().with_suffix(".generation.json")
    temporary = manifest.with_suffix(manifest.suffix + ".tmp")
    temporary.write_text(
        json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(manifest)
    return {**result, "manifest": str(manifest)}
