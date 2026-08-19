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
    landscape_background_ready: bool | None = None,
) -> OpenAIImageSpecDocument:
    quiz_sets = _load_quiz_sets(category_root)
    category_slug = slugify(category)
    landscape_background = category_root / "assets/category/video_background_landscape.png"
    if landscape_background_ready is None:
        landscape_background_ready = landscape_background.is_file()
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
            asset_id=f"{category_slug}_video_background_landscape",
            scope="category",
            role="video_background_landscape",
            source="user_upload",
            output_width=1920,
            output_height=1080,
            background="opaque",
            file="assets/category/video_background_landscape.png",
            prompt=(
                "Pipeline-generated 16:9 category video background with an embedded "
                "category title and safe regions for a question panel and four "
                "horizontal answer cards."
            ),
            exact_text=[display_title],
            review_status=(
                "approved" if landscape_background_ready else "awaiting_upload"
            ),
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


def _video_ui_style() -> str:
    return (
        "Use one consistent premium children's adventure-quiz UI style: warm carved "
        "wood, cream parchment, restrained polished gold trim, dimensional beveled "
        "edges, soft studio highlights, clean symmetrical construction, crisp edges, "
        "and strong readability at video resolution. Isolate the complete asset on a "
        "flat pure white background with generous empty white space so the adapter can "
        "extract a clean transparent outer background. Include no words, letters, numbers, icons, "
        "characters, scenery, logos, or watermarks."
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

    video_style = _video_ui_style()
    assets.extend(
        [
            OpenAIImageAssetSpec(
                **common,
                asset_id="video_progress_plaque",
                role="video_progress_plaque",
                api_size="1536x1024",
                output_width=1200,
                output_height=320,
                background="transparent",
                api_background="opaque",
                file="assets/video/video_progress_plaque.webp",
                prompt=(
                    f"{video_style} Create one wide blank carved-wood plaque for a "
                    "question progress label. Use a simple horizontal silhouette with "
                    "a broad completely empty central writing area, subtle corner "
                    "bolts, and generous pure-white space around the complete object."
                ),
            ),
            OpenAIImageAssetSpec(
                **common,
                asset_id="video_question_frame",
                role="video_question_frame",
                api_size="1536x1024",
                output_width=1600,
                output_height=640,
                background="transparent",
                api_background="opaque",
                file="assets/video/video_question_frame.webp",
                prompt=(
                    f"{video_style} Create one wide rounded rectangular ornamental "
                    "frame for a quiz question. Show only a slim cream-and-gold border "
                    "with restrained carved-wood corner accents. The entire large "
                    "interior must be completely blank pale cream with no markings so "
                    "code-rendered question text can be placed over it."
                ),
            ),
            OpenAIImageAssetSpec(
                **common,
                asset_id="video_answer_frame",
                role="video_answer_frame",
                api_size="1024x1024",
                output_width=760,
                output_height=820,
                background="transparent",
                api_background="opaque",
                file="assets/video/video_answer_frame.webp",
                prompt=(
                    f"{video_style} Create one tall rounded rectangular ornamental "
                    "frame for a visual answer card. Show only a slim neutral cream "
                    "and gold border. Leave one large upper image opening and one "
                    "short lower label area; both areas must be completely blank pale "
                    "cream with no markings for code-rendered content."
                ),
            ),
            OpenAIImageAssetSpec(
                **common,
                asset_id="video_explanation_frame",
                role="video_explanation_frame",
                api_size="1536x1024",
                output_width=1600,
                output_height=1100,
                background="transparent",
                api_background="opaque",
                file="assets/video/video_explanation_frame.webp",
                prompt=(
                    f"{video_style} Create one large rounded rectangular ornamental "
                    "reveal frame for a correct-answer image and explanation. Show "
                    "only a slim cream parchment, gold, and carved-wood outer border. "
                    "The broad interior must be completely blank pale cream with no "
                    "markings for dynamic image and text content."
                ),
            ),
        ]
    )
    badge_colors = {
        "purple": "rich royal purple",
        "green": "fresh leaf green",
        "orange": "warm vivid orange",
        "blue": "bright ocean blue",
    }
    for color, description in badge_colors.items():
        assets.append(
            OpenAIImageAssetSpec(
                **common,
                asset_id=f"video_badge_{color}",
                role="video_badge",
                api_size="1024x1024",
                output_width=320,
                output_height=320,
                background="transparent",
                api_background="opaque",
                file=f"assets/video/video_badge_{color}.webp",
                prompt=(
                    f"{video_style} Create one blank circular {description} quiz badge "
                    "with a thick cream inner ring, restrained polished-gold outer "
                    "rim, dimensional bevel, and a completely empty center. Keep the "
                    "full badge centered with generous pure-white space around it."
                ),
            )
        )

    return OpenAIImageSpecDocument(
        schema_version="openai_image_spec_v1",
        name="global_presentation_images",
        category=None,
        generated_at_utc=datetime.now(timezone.utc).isoformat(),
        assets=assets,
    )


def build_video_presentation_inventory() -> dict[str, object]:
    return {
        "schema_version": "quiz_video_presentation_inventory_v1",
        "rendering": "remotion",
        "category_assets": {
            "portrait_background": {
                "role": "runtime_background",
                "size": [941, 1672],
            },
            "landscape_background": {
                "role": "video_background_landscape",
                "size": [1920, 1080],
            },
            "answer_images": "Reuse the category answer_assets referenced by each quiz.",
        },
        "global_assets": {
            "progress_plaque": "video_progress_plaque",
            "question_frame": "video_question_frame",
            "answer_frame": "video_answer_frame",
            "explanation_frame": "video_explanation_frame",
            "badges": [
                "video_badge_purple",
                "video_badge_green",
                "video_badge_orange",
                "video_badge_blue",
            ],
        },
        "dynamic_content": {
            "progress_text": "QUESTION {current} OF {total}",
            "question_badge_text": "Q",
            "answer_badge_text": ["A", "B", "C", "D"],
            "badge_assignment": "deterministically shuffled per question",
            "question_text": "rendered by Remotion",
            "answer_labels": "rendered by Remotion",
            "explanation_text": "rendered by Remotion",
        },
        "audio": {
            "question": "category question narration",
            "timer": "global five-second timer with chime",
            "explanation": "category explanation narration",
        },
    }


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
