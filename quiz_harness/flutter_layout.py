from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .models import PlanDocument


def build_flutter_layout(document: PlanDocument) -> dict[str, Any]:
    plan = document.plan
    palette = plan.visual_design.palette
    return {
        "schema_version": "1.0",
        "minimum_renderer_version": 1,
        "template": "image_multiple_choice_v1",
        "quiz": {
            "title": plan.brief.title,
            "description": plan.brief.short_description,
            "category": plan.brief.category,
            "subject": plan.brief.subject,
            "language": plan.brief.language,
        },
        "theme": {
            "colors": palette.model_dump(),
            "corner_radius": plan.visual_design.shape_language.corner_radius_px,
            "border_width": plan.visual_design.shape_language.border_width_px,
            "typography": plan.visual_design.typography.model_dump(),
        },
        "header": {
            "score_enabled": True,
            "progress_style": "marker_track",
            "background_asset": plan.ui_components.background_asset_id,
            "progress_track_asset": plan.ui_components.progress_track_asset_id,
            "progress_marker_asset": plan.ui_components.progress_marker_asset_id,
        },
        "answer_style": {
            "frame_asset": plan.ui_components.answer_button_asset_id,
            "minimum_touch_target": plan.mobile_layout.minimum_touch_target_px,
        },
        "questions": [
            {
                "id": question.question_id,
                "type": "image_multiple_choice",
                "prompt": question.prompt_text,
                "narration": question.narration_text,
                "image_asset": question.image_asset_id,
                "answers": [option.model_dump() for option in question.options],
                "correct_answer": question.correct_option_id,
                "success_message": question.success_message,
                "explanation": question.explanation,
            }
            for question in plan.questions
        ],
        "assets": {
            asset.asset_id: f"assets/{asset.asset_id}.png" for asset in plan.assets
        },
    }


def write_flutter_layout(document: PlanDocument, output: Path) -> dict[str, Any]:
    layout = build_flutter_layout(document)
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        json.dumps(layout, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(output)
    return layout
