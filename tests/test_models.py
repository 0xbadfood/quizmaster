from __future__ import annotations

import copy
from datetime import datetime, timezone

import pytest
from pydantic import ValidationError

from quiz_harness.models import PlanDocument


def valid_document() -> dict:
    assets = [
        {
            "asset_id": "forest_background",
            "role": "background",
            "usage": "Full-screen background",
            "width_px": 768,
            "height_px": 1366,
            "transparent_background": False,
            "reuse_scope": "quiz",
            "generation_prompt": "A colorful layered forest background with a clear central area for a mobile quiz interface.",
            "negative_prompt": "text, letters, logo, watermark, clutter, photorealism",
            "text_policy": "no_text",
        },
        {
            "asset_id": "answer_frame",
            "role": "answer_button_frame",
            "usage": "Stretchable frame behind HTML answer labels",
            "width_px": 900,
            "height_px": 160,
            "transparent_background": True,
            "reuse_scope": "quiz",
            "generation_prompt": "A clean colorful rounded game button frame for children, blank center, transparent surroundings.",
            "negative_prompt": "text, letters, logo, watermark, busy details",
            "text_policy": "no_text",
        },
        {
            "asset_id": "progress_track",
            "role": "progress_track",
            "usage": "Horizontal progress track",
            "width_px": 700,
            "height_px": 64,
            "transparent_background": True,
            "reuse_scope": "quiz",
            "generation_prompt": "A simple horizontal children's quiz progress track with rounded ends and transparent surroundings.",
            "negative_prompt": "text, numbers, letters, logo, watermark, markers",
            "text_policy": "no_text",
        },
        {
            "asset_id": "progress_marker",
            "role": "progress_marker",
            "usage": "Marker placed over progress track",
            "width_px": 96,
            "height_px": 96,
            "transparent_background": True,
            "reuse_scope": "quiz",
            "generation_prompt": "A cheerful paw shaped progress marker, centered, crisp edge, transparent background, polished 2D style.",
            "negative_prompt": "text, letters, logo, watermark, shadow outside canvas",
            "text_policy": "no_text",
        },
        {
            "asset_id": "lion_portrait",
            "role": "question_illustration",
            "usage": "Illustration for question one",
            "width_px": 800,
            "height_px": 600,
            "transparent_background": False,
            "reuse_scope": "question",
            "generation_prompt": "A friendly young lion standing in a sunny savanna, centered subject, warm light, polished children's illustration.",
            "negative_prompt": "text, letters, logo, watermark, scary expression, extra limbs",
            "text_policy": "no_text",
        },
    ]
    return {
        "request": {
            "category": "animals",
            "subject": "lion",
            "language": "English",
            "age_min": 5,
            "age_max": 8,
            "question_count": 1,
            "option_count": 3,
            "seed": 42,
        },
        "generator": {
            "provider": "vllm",
            "endpoint": "http://localhost:8001/v1",
            "model": "test-model",
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "attempts": 1,
            "prompt_version": "1.0",
        },
        "plan": {
            "schema_version": "1.0",
            "brief": {
                "title": "Lion Explorer",
                "short_description": "A bright first look at the king of the savanna.",
                "category": "animals",
                "subject": "lion",
                "language": "English",
                "age_min": 5,
                "age_max": 8,
                "educational_goal": "Recognize a lion and distinguish it from other animals.",
                "question_count": 1,
            },
            "visual_design": {
                "theme_name": "Sunny Savanna",
                "art_direction": "Warm storybook wildlife scenes with clear silhouettes and colorful natural details.",
                "palette": {
                    "page_background": "#102050",
                    "surface": "#FFF5D6",
                    "primary": "#8B36D9",
                    "secondary": "#F6C443",
                    "accent": "#F15BA7",
                    "correct": "#65C84A",
                    "incorrect": "#E95252",
                    "text_primary": "#24114F",
                    "text_on_primary": "#FFFFFF",
                },
                "typography": {
                    "display_style": "Rounded, bold, highly legible",
                    "body_style": "Friendly geometric sans serif",
                    "casing": "sentence",
                },
                "shape_language": {
                    "corner_radius_px": 24,
                    "border_width_px": 3,
                    "shadow_style": "Soft downward shadow with restrained contrast",
                },
            },
            "mobile_layout": {
                "viewport_width_px": 390,
                "viewport_height_px": 844,
                "content_width_percent": 92,
                "minimum_touch_target_px": 52,
                "safe_area_enabled": True,
                "overflow_strategy": "vertical_scroll",
                "regions": {
                    "header": {"region_id": "top_header", "order": 1, "height_behavior": "fixed", "alignment": "stretch", "notes": "Back control, title and score"},
                    "progress": {"region_id": "quiz_progress", "order": 2, "height_behavior": "fixed", "alignment": "center", "notes": "Current question progress"},
                    "question": {"region_id": "question_area", "order": 3, "height_behavior": "flex", "alignment": "stretch", "notes": "Prompt and large illustration"},
                    "answers": {"region_id": "answer_area", "order": 4, "height_behavior": "content", "alignment": "stretch", "notes": "Three stacked answer choices"},
                    "feedback": {"region_id": "result_feedback", "order": 5, "height_behavior": "content", "alignment": "center", "notes": "Correctness and explanation"}
                },
            },
            "ui_components": {
                "background_asset_id": "forest_background",
                "answer_button_asset_id": "answer_frame",
                "progress_track_asset_id": "progress_track",
                "progress_marker_asset_id": "progress_marker",
                "question_card_treatment": "Warm light surface with a strong border and contained image crop.",
                "answer_button_behavior": "HTML text overlays the stretchable frame with pressed and disabled states.",
                "progress_behavior": "Track fills by question index while the marker moves between fixed stops.",
            },
            "assets": assets,
            "questions": [
                {
                    "question_id": "question_one",
                    "novelty_key": "visual_identity",
                    "learning_objective": "Identify a lion by its visible features.",
                    "prompt_text": "Which animal is this?",
                    "narration_text": "Look closely. Which animal is this?",
                    "image_asset_id": "lion_portrait",
                    "options": [
                        {"option_id": "bunny", "label": "Bunny"},
                        {"option_id": "lion", "label": "Lion"},
                        {"option_id": "monkey", "label": "Monkey"},
                    ],
                    "correct_option_id": "lion",
                    "success_message": "Yes, it is a lion!",
                    "explanation": "A lion has a strong body, rounded ears, and a tufted tail.",
                }
            ],
        },
    }


def test_valid_document_links_request_plan_and_assets() -> None:
    document = PlanDocument.model_validate(valid_document())
    assert document.plan.questions[0].correct_option_id == "lion"


def test_rejects_missing_correct_option() -> None:
    data = valid_document()
    data["plan"]["questions"][0]["correct_option_id"] = "tiger"
    with pytest.raises(ValidationError, match="does not reference an option"):
        PlanDocument.model_validate(data)


def test_rejects_wrong_asset_role() -> None:
    data = valid_document()
    data["plan"]["assets"][-1]["role"] = "feedback_decoration"
    with pytest.raises(ValidationError, match="question illustration"):
        PlanDocument.model_validate(data)


def test_rejects_request_question_mismatch() -> None:
    data = copy.deepcopy(valid_document())
    data["request"]["question_count"] = 2
    with pytest.raises(ValidationError, match="does not match request"):
        PlanDocument.model_validate(data)


def test_rejects_explanation_inside_option_label() -> None:
    data = valid_document()
    data["plan"]["questions"][0]["options"][0]["label"] = (
        "Bunny. This is incorrect"
    )
    with pytest.raises(ValidationError, match="without sentence punctuation"):
        PlanDocument.model_validate(data)


def test_rejects_invisible_raster_prompt() -> None:
    data = valid_document()
    data["plan"]["assets"][1]["generation_prompt"] = (
        "A polished invisible answer frame intended for CSS with no rendered pixels"
    )
    with pytest.raises(ValidationError, match="visible raster artwork"):
        PlanDocument.model_validate(data)
