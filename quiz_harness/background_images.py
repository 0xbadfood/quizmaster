from __future__ import annotations

import base64
import hashlib
import io
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Literal

from openai import APIError, OpenAI
from PIL import Image, ImageOps, UnidentifiedImageError
from pydantic import Field, ValidationError

from .client import VLLMClient, VLLMError
from .database import QuizDatabase
from .imagestudio import ImageStudioClient
from .models import StrictModel
from .secure_store import SecretStore
from .visual_bank import slugify


BACKGROUND_SIZE = (941, 1672)
IMAGESTUDIO_REQUEST_SIZE = (768, 1344)
SUPPORTED_PROVIDER_TYPES = {"openai_images", "imagestudio"}


class BackgroundGenerationError(RuntimeError):
    """Raised when a quiz background cannot be generated or normalized."""


class BackgroundPromptPlan(StrictModel):
    schema_version: Literal["quiz_background_prompt_plan_v1"]
    visual_summary: Annotated[str, Field(min_length=30, max_length=500)]
    scene_concept: Annotated[str, Field(min_length=60, max_length=800)]
    focal_elements: Annotated[
        list[Annotated[str, Field(min_length=3, max_length=140)]],
        Field(min_length=3, max_length=8),
    ]
    composition: Annotated[str, Field(min_length=60, max_length=600)]
    palette_and_lighting: Annotated[str, Field(min_length=40, max_length=400)]
    prompt: Annotated[str, Field(min_length=400, max_length=3500)]


def build_background_planning_prompt(
    *,
    category: str,
    display_title: str,
    subtitle: str,
    category_guidance: str | None = None,
) -> str:
    guidance = category_guidance.strip() if category_guidance else "None supplied."
    return f"""Plan and write the final text-to-image prompt for one children's quiz
runtime background.

Category: {category}
Main title that must be embedded exactly: {display_title}
Ribbon subtitle that must be embedded exactly: {subtitle}
Optional editorial guidance: {guidance}

Fixed production contract:
- The normalized Flutter asset is exactly 941x1672 pixels: a tall 9:16-like portrait.
- The image must be one coherent immersive scene, never a collage or separate panels.
- Use a polished high-end family-friendly 3D animated illustration aesthetic without
  naming or imitating a studio, franchise, film, character, or living artist.
- Reserve roughly the top 28 percent for a large dimensional title emblem containing
  the exact main title and a smaller ribbon containing the exact subtitle.
- Keep the central 30 to 72 percent calmer, lower contrast, and relatively uncluttered
  because Flutter places question and answer controls over that area.
- Put category storytelling, characters, landmarks, and decorative detail around the
  outer edges and lower third, with generous portrait safe margins.
- Represent the category broadly. Do not illustrate one particular quiz question or
  leak an answer.
- Make the scene culturally and historically accurate where relevant, celebratory,
  educational, and appropriate for children ages 3 to 10.
- The image must contain no text other than the exact main title and subtitle: no
  dates, captions, labels, signs, logos, watermarks, or readable writing on props.
- Exclude interface controls, question cards, answer boxes, borders, political-party
  symbols, modern campaign imagery, malformed anatomy, and duplicate subjects.

You decide the category-specific scene concept, focal elements, supporting subjects,
environment, palette, lighting, depth, and visual storytelling. Return a structured
plan and a complete final renderer prompt. The final prompt must restate all important
composition, style, exact-text, safe-area, and exclusion requirements so it can be
sent directly to either OpenAI Images or ImageStudio without another writing pass."""


def _validate_prompt_plan(
    plan: BackgroundPromptPlan, *, display_title: str, subtitle: str
) -> None:
    folded = plan.prompt.casefold()
    missing = [
        value
        for value in (display_title, subtitle)
        if value.casefold() not in folded
    ]
    if missing:
        raise ValueError(
            "background prompt omits exact text: " + ", ".join(missing)
        )
    banned = ("pixar", "disney", "dreamworks", "ghibli")
    named_style = next((name for name in banned if name in folded), None)
    if named_style:
        raise ValueError(f"background prompt names copyrighted style: {named_style}")
    if "portrait" not in folded:
        raise ValueError("background prompt must explicitly request portrait composition")


def _text(value: Any) -> str:
    return str(value or "").strip()


def _normalize_focal_elements(value: Any) -> list[str]:
    if isinstance(value, list):
        items = [_text(item) for item in value]
    else:
        items = [item.strip() for item in _text(value).replace(";", ",").split(",")]
    return [item for item in items if item][:8]


def _parse_prompt_plan(raw: str) -> BackgroundPromptPlan:
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("background plan response is not a JSON object")
    nested = value.get("scene_concept")
    scene = nested if isinstance(nested, dict) else {}
    scene_concept = _text(nested) if not scene else _text(
        scene.get("description") or scene.get("visual_storytelling")
    )
    prompt = _text(value.get("prompt") or value.get("final_renderer_prompt"))
    focal_elements = _normalize_focal_elements(
        value.get("focal_elements") or scene.get("focal_elements")
    )
    visual_summary = _text(value.get("visual_summary") or scene_concept)
    composition = _text(value.get("composition")) or (
        "Tall portrait composition with the title emblem in the upper section, a "
        "calm low-contrast central safe area, and category storytelling framing the "
        "outer edges and lower third."
    )
    palette = _text(value.get("palette_and_lighting"))
    if not palette:
        palette = "; ".join(
            item
            for item in (_text(scene.get("palette")), _text(scene.get("lighting")))
            if item
        )
    return BackgroundPromptPlan(
        schema_version="quiz_background_prompt_plan_v1",
        visual_summary=visual_summary[:500],
        scene_concept=scene_concept[:800],
        focal_elements=focal_elements,
        composition=composition[:600],
        palette_and_lighting=palette[:400],
        prompt=prompt,
    )


def plan_quiz_background_prompt(
    *,
    category: str,
    display_title: str,
    subtitle: str,
    provider_id: str,
    database_path: Path,
    secret_key_file: Path,
    output: Path,
    model_override: str | None = None,
    category_guidance: str | None = None,
    seed: int = 20260805,
    retries: int = 2,
    timeout_seconds: float = 900.0,
    force: bool = False,
) -> dict[str, Any]:
    database = QuizDatabase(database_path)
    database.migrate()
    try:
        provider = database.provider_connection(provider_id)
    except KeyError as exc:
        raise BackgroundGenerationError(f"provider does not exist: {provider_id}") from exc
    if not provider["enabled"]:
        raise BackgroundGenerationError(f"provider is disabled: {provider_id}")
    if provider["provider_type"] != "openai_compatible_llm":
        raise BackgroundGenerationError(
            f"planner {provider_id} must be an OpenAI-compatible LLM"
        )
    model = _model(provider, model_override)
    planning_prompt = build_background_planning_prompt(
        category=category,
        display_title=display_title,
        subtitle=subtitle,
        category_guidance=category_guidance,
    )
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and not force:
        try:
            cached = BackgroundPromptPlan.model_validate_json(
                output.read_text(encoding="utf-8")
            )
            _validate_prompt_plan(
                cached, display_title=display_title, subtitle=subtitle
            )
            return {
                "plan": cached,
                "provider_id": provider_id,
                "model": model,
                "file": str(output),
                "reused": True,
            }
        except (OSError, ValidationError, ValueError):
            pass

    if not force:
        pattern = f"{output.stem}.attempt-*.raw.txt"
        for raw_path in sorted(output.parent.glob(pattern), reverse=True):
            try:
                recovered = _parse_prompt_plan(raw_path.read_text(encoding="utf-8"))
                _validate_prompt_plan(
                    recovered, display_title=display_title, subtitle=subtitle
                )
                temporary = output.with_suffix(output.suffix + ".tmp")
                temporary.write_text(
                    recovered.model_dump_json(indent=2) + "\n", encoding="utf-8"
                )
                temporary.replace(output)
                return {
                    "plan": recovered,
                    "provider_id": provider_id,
                    "model": model,
                    "file": str(output),
                    "reused": True,
                    "recovered_from": str(raw_path),
                }
            except (OSError, ValidationError, ValueError):
                continue

    output.with_suffix(".prompt.txt").write_text(planning_prompt, encoding="utf-8")
    secrets = SecretStore(
        key=os.getenv("QUIZ_SECRET_KEY"), key_file=secret_key_file
    )
    secret = secrets.decrypt(provider.get("secret_ciphertext"))
    messages = [
        {
            "role": "system",
            "content": (
                "You are an expert children's quiz art director and text-to-image "
                "prompt writer. Return only strict JSON matching the supplied schema."
            ),
        },
        {"role": "user", "content": planning_prompt},
    ]
    last_error = "unknown response error"
    with VLLMClient(
        str(provider["base_url"]),
        timeout_seconds=timeout_seconds,
        api_key=secret,
    ) as client:
        for attempt in range(1, retries + 2):
            raw: str | None = None
            try:
                raw = client.generate_json(
                    model=model,
                    messages=messages,
                    schema=BackgroundPromptPlan.model_json_schema(),
                    schema_name="quiz_background_prompt_plan",
                    seed=seed + attempt - 1,
                    temperature=0.65,
                    max_tokens=5000,
                )
                output.with_suffix(f".attempt-{attempt:02d}.raw.txt").write_text(
                    raw, encoding="utf-8"
                )
                plan = _parse_prompt_plan(raw)
                _validate_prompt_plan(
                    plan, display_title=display_title, subtitle=subtitle
                )
                temporary = output.with_suffix(output.suffix + ".tmp")
                temporary.write_text(
                    plan.model_dump_json(indent=2) + "\n", encoding="utf-8"
                )
                temporary.replace(output)
                return {
                    "plan": plan,
                    "provider_id": provider_id,
                    "model": model,
                    "file": str(output),
                    "reused": False,
                }
            except (OSError, ValidationError, VLLMError, ValueError) as exc:
                last_error = str(exc)
                if attempt > retries:
                    break
                messages.extend(
                    [
                        {"role": "assistant", "content": raw or "No complete response."},
                        {
                            "role": "user",
                            "content": (
                                "Regenerate the complete JSON. The prior response "
                                f"failed validation: {last_error[:1500]}"
                            ),
                        },
                    ]
                )
    raise BackgroundGenerationError(f"Qwen background planning failed: {last_error}")


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
    planning_metadata: dict[str, Any] | None = None,
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
        "planning": planning_metadata,
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
