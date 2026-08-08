from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path

from .openai_images import OpenAIImageAssetSpec, OpenAIImageSpecDocument
from .visual_bank import VisualQuizSet, slugify


DEFAULT_OPENAI_IMAGE_MODEL = "gpt-image-2"


def _load_quiz_sets(category_root: Path) -> list[VisualQuizSet]:
    paths = sorted((category_root / "sets").glob("*/*.json"))
    if not paths:
        raise ValueError(f"no quiz sets found under {category_root / 'sets'}")
    return [
        VisualQuizSet.model_validate_json(path.read_text(encoding="utf-8"))
        for path in paths
    ]


def _tile_prompt(
    *,
    category: str,
    display_title: str,
    difficulty: str,
    set_number: int,
) -> str:
    if difficulty == "beginner":
        mascot = (
            "one cheerful child explorer mascot aged 3 to 5, with a warm, playful "
            "expression and age-appropriate proportions"
        )
    else:
        mascot = (
            "one confident older child explorer mascot aged 8 to 10, curious and "
            "adventurous, with age-appropriate proportions"
        )
    title = f"{display_title} {set_number}"
    return f"""Create a polished square mobile quiz cover tile for the {category} category.
Use a rich, high-end 3D animated family-adventure style with an immersive setting
appropriate to {category}, cinematic lighting, clear silhouettes, vivid natural
colors, and excellent readability at small thumbnail size.

Show {mascot} together with a friendly, balanced group of four to six diverse,
iconic subjects that clearly represent {category}. Choose the subjects independently
from the quiz questions; this cover must represent the category as a whole and must
not reveal any answer. Keep every subject recognizable and compose them as one
coherent ensemble, not separate panels. Leave enough visual separation around the
lettering.

Render exactly these two text elements and spell them exactly:
1. Main title: "{title}"
2. Difficulty ribbon: "{difficulty.upper()}"

The main title must be large, dimensional, centered, and fully readable. The
difficulty must appear once on a distinct banner. Include no other words, letters,
numbers, logos, or watermarks. Keep all important content inside generous safe
margins for square cropping."""


def build_category_image_spec(
    *,
    category: str,
    category_root: Path,
    display_title: str,
    model: str = DEFAULT_OPENAI_IMAGE_MODEL,
    quality: str = "medium",
    background_ready: bool = False,
) -> OpenAIImageSpecDocument:
    quiz_sets = _load_quiz_sets(category_root)
    category_slug = slugify(category)
    assets = [
        OpenAIImageAssetSpec(
            asset_id=f"{category_slug}_runtime_background",
            scope="category",
            role="runtime_background",
            source="user_upload",
            output_width=941,
            output_height=1672,
            background="opaque",
            file="assets/category/runtime_background.png",
            prompt=(
                "User-supplied portrait quiz background with embedded category title "
                "and safe regions for Flutter controls and quiz content."
            ),
            exact_text=[display_title],
            review_status="approved" if background_ready else "awaiting_upload",
        ),
        OpenAIImageAssetSpec(
            asset_id=f"{category_slug}_category_selector",
            scope="category",
            role="category_selector",
            source="openai",
            provider="openai",
            model=model,
            quality=quality,
            api_size="1024x1024",
            output_width=512,
            output_height=512,
            background="opaque",
            file="assets/category/category_selector.webp",
            prompt=(
                f"Create a square category selector image for a children's {category} "
                f"quiz. Show a friendly, diverse group of four to six iconic {category} "
                f"subjects in an immersive setting naturally associated with {category}. "
                "Choose only subjects that unambiguously belong to this category. "
                "Polished high-end 3D animated family-adventure style, cinematic light, "
                "vivid natural colors, clean strong silhouettes, centered composition "
                "that remains clear when cropped into a circle. No child, no text, no "
                "letters, no logo, no border, no watermark."
            ),
            exact_text=[],
            review_status="pending_generation",
        ),
    ]

    for quiz_set in quiz_sets:
        number = int(quiz_set.set_id.rsplit("_", 1)[-1])
        asset_id = f"tile_{quiz_set.difficulty}_{number:02d}"
        title = f"{display_title} {number}"
        assets.append(
            OpenAIImageAssetSpec(
                asset_id=asset_id,
                scope="category",
                role="quiz_tile",
                source="openai",
                provider="openai",
                model=model,
                quality=quality,
                api_size="1024x1024",
                output_width=768,
                output_height=768,
                background="opaque",
                file=f"assets/category/tiles/{quiz_set.difficulty}_{number:02d}.webp",
                prompt=_tile_prompt(
                    category=category,
                    display_title=display_title,
                    difficulty=quiz_set.difficulty,
                    set_number=number,
                ),
                exact_text=[title, quiz_set.difficulty.upper()],
                review_status="pending_generation",
            )
        )

    return OpenAIImageSpecDocument(
        schema_version="openai_image_spec_v1",
        name=f"{category_slug}_category_images",
        category=category,
        generated_at_utc=datetime.now(timezone.utc).isoformat(),
        assets=assets,
    )


def _global_style() -> str:
    return (
        "Use the shared quiz presentation style: polished high-end 3D animated "
        "family-adventure UI, deep jungle green, fresh leaf green, warm golden yellow, "
        "cream highlights, dimensional beveled edges, soft cinematic glow, crisp "
        "mobile readability, centered isolated object."
    )


def build_global_image_spec(
    *,
    model: str = DEFAULT_OPENAI_IMAGE_MODEL,
    quality: str = "medium",
) -> OpenAIImageSpecDocument:
    style = _global_style()
    common = {
        "scope": "global",
        "source": "openai",
        "provider": "openai",
        "model": model,
        "quality": quality,
        "review_status": "pending_generation",
    }
    assets: list[OpenAIImageAssetSpec] = [
        OpenAIImageAssetSpec(
            **common,
            asset_id="settings_button",
            role="settings_button",
            api_size="1024x1024",
            output_width=512,
            output_height=512,
            background="transparent",
            api_background="opaque",
            file="assets/presentation/settings_button.webp",
            prompt=(
                f"{style} Create one glossy circular green settings button with a "
                "single bold cream-white gear symbol, matching the supplied animal "
                "quiz mockup. Isolate the complete button on a flat pure white "
                "background with generous empty white space. No text, letters, extra "
                "icons, hands, scene, logo, or watermark."
            ),
        ),
        OpenAIImageAssetSpec(
            **common,
            asset_id="speaker_on_button",
            role="speaker_on",
            api_size="1024x1024",
            output_width=512,
            output_height=512,
            background="transparent",
            api_background="opaque",
            file="assets/presentation/speaker_on_button.webp",
            prompt=(
                f"{style} Create one glossy circular green sound-enabled button with "
                "a single bold cream-white speaker and three clear sound waves, "
                "matching the supplied animal quiz mockup. Isolate the complete button "
                "on a flat pure white background with generous empty white space. No "
                "text, letters, extra icons, hands, scene, logo, or watermark."
            ),
        ),
        OpenAIImageAssetSpec(
            **common,
            asset_id="speaker_muted_button",
            role="speaker_muted",
            api_size="1024x1024",
            output_width=512,
            output_height=512,
            background="transparent",
            api_background="opaque",
            file="assets/presentation/speaker_muted_button.webp",
            prompt=(
                f"{style} Create one glossy circular green muted-sound button with a "
                "single bold cream-white speaker and a clear diagonal mute slash, "
                "matching the supplied animal quiz mockup. Isolate the complete button "
                "on a flat pure white background with generous empty white space. No "
                "text, letters, extra icons, hands, scene, logo, or watermark."
            ),
        ),
    ]

    return OpenAIImageSpecDocument(
        schema_version="openai_image_spec_v1",
        name="global_presentation_images",
        category=None,
        generated_at_utc=datetime.now(timezone.utc).isoformat(),
        assets=assets,
    )


def build_progress_style() -> dict[str, object]:
    return {
        "schema_version": "quiz_progress_style_v1",
        "question_count": 10,
        "rendering": "flutter",
        "label_template": "Question {current} of 10",
        "geometry": {
            "marker_diameter_dp": 32,
            "marker_border_dp": 2,
            "connector_height_dp": 4,
            "current_glow_blur_dp": 10,
        },
        "states": {
            "unanswered": {
                "fill": "#123F24",
                "border": "#A8D76F",
                "text": "#F8F2D8",
            },
            "current": {
                "fill": "#F6B91A",
                "border": "#FFF3A6",
                "text": "#FFFFFF",
                "glow": "#FFD83D",
            },
            "correct": {
                "fill": "#36A852",
                "border": "#B9F28A",
                "text": "#FFFFFF",
            },
            "incorrect": {
                "fill": "#D94B4B",
                "border": "#FFC0B7",
                "text": "#FFFFFF",
            },
        },
        "connector": {
            "unanswered": "#78A94E",
            "answered": "#D7B52E",
        },
        "animation_ms": 220,
    }
