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


BackgroundLayout = Literal["portrait", "landscape"]

BACKGROUND_SIZE = (941, 1672)
LANDSCAPE_BACKGROUND_SIZE = (1920, 1080)
BACKGROUND_SIZES: dict[BackgroundLayout, tuple[int, int]] = {
    "portrait": BACKGROUND_SIZE,
    "landscape": LANDSCAPE_BACKGROUND_SIZE,
}
OPENAI_REQUEST_SIZES: dict[BackgroundLayout, str] = {
    "portrait": "1024x1536",
    "landscape": "1536x1024",
}
IMAGESTUDIO_REQUEST_SIZES: dict[BackgroundLayout, tuple[int, int]] = {
    "portrait": (768, 1344),
    "landscape": (1344, 768),
}
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
    layout: BackgroundLayout = "portrait",
) -> str:
    guidance = category_guidance.strip() if category_guidance else "None supplied."
    if layout == "landscape":
        production_contract = """- The normalized video asset is exactly 1920x1080 pixels in a true 16:9 landscape composition.
- HARD HEADER LIMIT: render only the main title inside one shallow banner near the
  top. Do not add a subtitle or ribbon. Leave at least 4 percent clear space above the
  banner so no border or letter touches the top edge. The complete title banner must
  fit inside y=4% to y=18% of the final frame. Scale the lettering down as needed,
  center it, and keep it within roughly 70 percent of the frame width; never let the
  banner expand into the quiz content area or touch the side edges.
- Keep y=20% to y=52% calm and open for one large, wide question panel.
- Keep y=52% to y=96% calm and open for four horizontal answer panels arranged as a
  two-by-two grid: two wide choices per row and two rows. Do not plan one row of four.
- Outside the shallow header, use a high-key, light-toned, low-contrast background:
  pale sky colors, soft cool neutrals, restrained pastels, and diffuse daylight.
  Avoid dominant navy, black, saturated neon, dramatic contrast, heavy vignettes,
  bright central glows, and busy textures so the quiz panels remain the focal point.
- Keep category storytelling small, subtle, and mainly within the outer 12 percent,
  corners, or distant background. Do not place large characters, landmarks, planets,
  or other focal subjects behind the question and answer safe regions.
- Keep all critical content inside a centered 16:9 crop with expendable scenery at
  the extreme top and bottom because some providers return a wider 3:2 source."""
        subtitle_requirement = "Subtitle: omit it entirely; render no subtitle or ribbon."
        allowed_text = "the exact main title"
    else:
        production_contract = """- The normalized Flutter asset is exactly 941x1672 pixels: a tall 9:16-like portrait.
- Reserve roughly the top 28 percent for a large dimensional title emblem containing
  the exact main title and a smaller ribbon containing the exact subtitle.
- Keep the central 30 to 72 percent calmer, lower contrast, and relatively uncluttered
  because Flutter places question and answer controls over that area.
- Put category storytelling, characters, landmarks, and decorative detail around the
  outer edges and lower third, with generous portrait safe margins."""
        subtitle_requirement = f"Ribbon subtitle that must be embedded exactly: {subtitle}"
        allowed_text = "the exact main title and subtitle"
    return f"""Plan and write the final text-to-image prompt for one children's quiz
{layout} background.

Category: {category}
Main title that must be embedded exactly: {display_title}
{subtitle_requirement}
Optional editorial guidance: {guidance}

Fixed production contract:
{production_contract}
- The image must be one coherent immersive scene, never a collage or separate panels.
- Use a polished high-end family-friendly 3D animated illustration aesthetic without
  naming or imitating a studio, franchise, film, character, or living artist.
- Represent the category broadly. Do not illustrate one particular quiz question or
  leak an answer.
- Make the scene culturally and historically accurate where relevant, celebratory,
  educational, and appropriate for children ages 3 to 10.
- The image must contain no text other than {allowed_text}: no
  dates, captions, labels, signs, logos, watermarks, or readable writing on props.
- Exclude interface controls, question cards, answer boxes, borders, political-party
  symbols, modern campaign imagery, malformed anatomy, and duplicate subjects.

You decide the category-specific scene concept, focal elements, supporting subjects,
environment, palette, lighting, depth, and visual storytelling. Return a structured
plan and a complete final renderer prompt. The final prompt must restate all important
composition, style, exact-text, safe-area, and exclusion requirements so it can be
sent directly to either OpenAI Images or ImageStudio without another writing pass."""


def _validate_prompt_plan(
    plan: BackgroundPromptPlan,
    *,
    display_title: str,
    subtitle: str,
    layout: BackgroundLayout = "portrait",
) -> None:
    folded = plan.prompt.casefold()
    folded_compact = " ".join(folded.split())
    required_text = (
        (display_title,) if layout == "landscape" else (display_title, subtitle)
    )
    missing = [value for value in required_text if value.casefold() not in folded]
    if missing:
        raise ValueError(
            "background prompt omits exact text: " + ", ".join(missing)
        )
    banned = ("pixar", "disney", "dreamworks", "ghibli")
    named_style = next((name for name in banned if name in folded), None)
    if named_style:
        raise ValueError(f"background prompt names copyrighted style: {named_style}")
    if layout == "landscape":
        forbidden_subtitles = {
            value.casefold() for value in (subtitle, "ADVENTURE") if value
        }
        if any(value in folded for value in forbidden_subtitles):
            raise ValueError("landscape background prompt must omit the subtitle")
        landscape = "landscape" in folded_compact or any(
            marker in folded_compact
            for marker in ("16:9", "1920x1080", "wide screen")
        )
        if not landscape:
            raise ValueError(
                "background prompt must explicitly request landscape composition"
            )
        shallow_header = "banner" in folded_compact and any(
            marker in folded_compact
            for marker in (
                "y=4% to y=18%",
                "y=4% through y=18%",
                "4% to 18%",
                "4 percent to 18 percent",
            )
        )
        if not shallow_header:
            raise ValueError(
                "landscape background prompt must confine the title banner to y=4%-18%"
            )
        light_field = any(
            marker in folded_compact
            for marker in ("high-key", "light-toned", "pale", "soft pastel")
        ) and any(
            marker in folded_compact
            for marker in ("low-contrast", "low contrast", "restrained contrast")
        )
        if not light_field:
            raise ValueError(
                "landscape background prompt must request a light, low-contrast content field"
            )
        answer_grid = any(
            marker in folded_compact
            for marker in ("two-by-two", "two by two", "2x2", "two rows")
        )
        if not answer_grid:
            raise ValueError(
                "landscape background prompt must reserve a two-by-two answer grid"
            )
    else:
        vertical_mobile = "vertical" in folded and any(
            marker in folded
            for marker in ("9:16", "941x1672", "mobile screen", "tall screen")
        )
        if "portrait" not in folded and not vertical_mobile:
            raise ValueError(
                "background prompt must explicitly request portrait composition"
            )


def _text(value: Any) -> str:
    return str(value or "").strip()


def _compact_text(value: str, limit: int) -> str:
    if len(value) <= limit:
        return value
    shortened = value[: limit - 3].rsplit(" ", 1)[0].rstrip(" ,;:.-")
    return f"{shortened}..."


def _normalize_focal_elements(
    value: Any, *, fallbacks: tuple[Any, ...] = ()
) -> list[str]:
    if isinstance(value, list):
        items = [_text(item) for item in value]
    else:
        items = [item.strip() for item in _text(value).replace(";", ",").split(",")]
    for fallback in fallbacks:
        if len([item for item in items if item]) >= 3:
            break
        items.extend(
            item.strip()
            for item in _text(fallback).replace(";", ",").split(",")
        )
    normalized: list[str] = []
    seen: set[str] = set()
    for item in items:
        item = _compact_text(item.strip(), 140)
        key = item.casefold()
        if len(item) < 3 or key in seen:
            continue
        seen.add(key)
        normalized.append(item)
    return normalized[:8]


def _parse_prompt_plan(raw: str) -> BackgroundPromptPlan:
    value = json.loads(raw)
    if not isinstance(value, dict):
        raise ValueError("background plan response is not a JSON object")
    nested = value.get("scene_concept")
    scene = nested if isinstance(nested, dict) else {}
    scene_concept = _text(nested) if not scene else _text(
        scene.get("description") or scene.get("visual_storytelling")
    )
    prompt = _text(
        value.get("prompt")
        or value.get("final_renderer_prompt")
        or value.get("final_prompt")
    )
    focal_elements = _normalize_focal_elements(
        value.get("focal_elements") or scene.get("focal_elements"),
        fallbacks=(
            scene.get("supporting_subjects"),
            scene.get("environment"),
            scene_concept,
        ),
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
    layout: BackgroundLayout = "portrait",
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
        layout=layout,
    )
    output = output.expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    if output.exists() and not force:
        try:
            cached = BackgroundPromptPlan.model_validate_json(
                output.read_text(encoding="utf-8")
            )
            _validate_prompt_plan(
                cached,
                display_title=display_title,
                subtitle=subtitle,
                layout=layout,
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
                    recovered,
                    display_title=display_title,
                    subtitle=subtitle,
                    layout=layout,
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
                    plan,
                    display_title=display_title,
                    subtitle=subtitle,
                    layout=layout,
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
    layout: BackgroundLayout = "portrait",
) -> str:
    subject_guidance = (
        visual_brief.strip()
        if visual_brief and visual_brief.strip()
        else f"Use iconic places, objects, and atmosphere associated with {category}."
    )
    if layout == "landscape":
        layout_direction = """The final image is a true 16:9 landscape video background. Confine the exact
main title to one shallow banner. Render no subtitle and no subtitle ribbon. Leave
the upper 4 percent completely clear and fit the entire title banner inside y=4% to
y=18%, with no border or letter touching the top edge. Center it within roughly 70
percent of the frame width rather than stretching it edge to edge. Keep y=20% to
y=52% open for a wide question panel and y=52% to y=96% open for four horizontal answer panels in a two-by-two grid.
Outside the header, use a high-key, light-toned, low-contrast field with pale sky
colors, soft cool neutrals, restrained pastels, and diffuse daylight. Avoid dominant
dark colors, saturated neon, dramatic contrast, heavy vignettes, and bright central
glows. Keep supporting scenery small and subtle at the far edges and corners."""
        style_direction = """Use a polished family-friendly 3D animated illustration
aesthetic with clean soft depth, restrained color, diffuse high-key lighting, and
crisp but unobtrusive edge details."""
        text_elements = f'''Render exactly one text element and spell it exactly:
Main title: "{display_title}"

Do not render a subtitle or subtitle ribbon.'''
    else:
        layout_direction = """The final image fills a tall mobile screen. Reserve the top 28 percent for the
title and keep the middle calmer and lower-contrast for Flutter question and answer
controls. Place supporting scenery mainly around the outer edges and lower third."""
        style_direction = """Use a high-end family-friendly 3D animated illustration
aesthetic, rich natural color, cinematic light, appealing depth, and crisp readable
silhouettes."""
        text_elements = f'''Render exactly these two text elements and spell them exactly:
1. Main title: "{display_title}"
2. Small ribbon subtitle: "{subtitle}"'''
    return f"""Create one polished {layout} background for a children's {category} quiz.
{layout_direction} Build one coherent, immersive scene rather
than a collage. {style_direction}

Visual direction: {subject_guidance}

Keep all important content within generous safe margins.

{text_elements}

Do not include any other words, dates, letters, numbers, captions, logos, watermarks,
interface controls, question cards, answer boxes, borders, collage panels, copyrighted
characters, named studio styles, living politicians, or modern political-party symbols.
The result must feel celebratory, educational, historically respectful, and suitable
for children ages 3 to 10."""


def normalize_background(
    data: bytes,
    output: Path,
    *,
    layout: BackgroundLayout = "portrait",
) -> dict[str, Any]:
    target_size = BACKGROUND_SIZES[layout]
    try:
        with Image.open(io.BytesIO(data)) as source:
            source.load()
            centering = (0.5, 0.45) if layout == "landscape" else (0.5, 0.5)
            image = ImageOps.fit(
                source.convert("RGB"),
                target_size,
                method=Image.Resampling.LANCZOS,
                centering=centering,
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
        "width": target_size[0],
        "height": target_size[1],
        "format": "png",
        "bytes": len(payload),
        "sha256": hashlib.sha256(payload).hexdigest(),
    }


def _valid_background(
    path: Path, *, layout: BackgroundLayout = "portrait"
) -> bool:
    try:
        with Image.open(path) as image:
            image.load()
            return image.format == "PNG" and image.size == BACKGROUND_SIZES[layout]
    except (OSError, UnidentifiedImageError):
        return False


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
    request_size: str,
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
                    size=request_size,
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
                    "request_size": request_size,
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
    request_size: tuple[int, int],
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
            width=request_size[0],
            height=request_size[1],
            steps=8,
            cfg=1.0,
            seed=seed,
        )
    return data, {
        "seed": metadata.get("seed", seed),
        "elapsed_seconds": metadata.get("elapsed_sec"),
        "request_size": f"{request_size[0]}x{request_size[1]}",
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
    force: bool = False,
    layout: BackgroundLayout = "portrait",
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
    effective_subtitle = "" if layout == "landscape" else subtitle
    prompt = prompt_override.strip() if prompt_override else build_background_prompt(
        category=category,
        display_title=display_title,
        visual_brief=visual_brief,
        subtitle=effective_subtitle,
        layout=layout,
    )
    if len(prompt) < 100:
        raise BackgroundGenerationError("background prompt must contain at least 100 characters")

    output = output.expanduser().resolve()
    manifest = output.with_suffix(".generation.json")
    fingerprint = hashlib.sha256(
        json.dumps(
            {
                "provider_id": provider["id"],
                "provider_type": provider["provider_type"],
                "model": model,
                "quality": quality,
                "seed": seed if provider["provider_type"] == "imagestudio" else None,
                "prompt": prompt,
                "size": BACKGROUND_SIZES[layout],
                "layout": layout,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
    ).hexdigest()
    if not force and manifest.is_file() and _valid_background(output, layout=layout):
        try:
            cached = json.loads(manifest.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            cached = None
        if isinstance(cached, dict) and cached.get("fingerprint") == fingerprint:
            return {**cached, "manifest": str(manifest), "reused": True}

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
            request_size=OPENAI_REQUEST_SIZES[layout],
        )
    else:
        data, generation = _imagestudio_image(
            provider=provider,
            model=model,
            prompt=prompt,
            seed=seed,
            timeout_seconds=timeout_seconds,
            request_size=IMAGESTUDIO_REQUEST_SIZES[layout],
        )

    image = normalize_background(data, output, layout=layout)
    result = {
        "schema_version": "quiz_background_generation_v1",
        "category": category,
        "category_slug": slugify(category),
        "display_title": display_title,
        "subtitle": effective_subtitle or None,
        "layout": layout,
        "provider_id": provider["id"],
        "provider_type": provider["provider_type"],
        "model": model,
        "quality": quality if provider["provider_type"] == "openai_images" else None,
        "prompt": prompt,
        "planning": planning_metadata,
        "fingerprint": fingerprint,
        "reused": False,
        "generation": generation,
        "image": image,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    temporary = manifest.with_suffix(manifest.suffix + ".tmp")
    temporary.write_text(
        json.dumps(result, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(manifest)
    return {**result, "manifest": str(manifest)}
