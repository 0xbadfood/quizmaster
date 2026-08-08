from __future__ import annotations

import io
import json
from pathlib import Path

from PIL import Image

from quiz_harness.background_images import (
    BACKGROUND_SIZE,
    _parse_prompt_plan,
    build_background_planning_prompt,
    build_background_prompt,
    normalize_background,
)


def test_background_prompt_preserves_title_and_flutter_safe_area() -> None:
    prompt = build_background_prompt(
        category="Indian Independence",
        display_title="INDIAN INDEPENDENCE QUIZ",
        visual_brief="Use the Red Fort, a charkha, and saffron, white, and green accents.",
    )

    assert 'Main title: "INDIAN INDEPENDENCE QUIZ"' in prompt
    assert 'Small ribbon subtitle: "ADVENTURE"' in prompt
    assert "Keep the middle" in prompt
    assert "living politicians" in prompt


def test_qwen_planning_prompt_defines_fixed_runtime_contract() -> None:
    prompt = build_background_planning_prompt(
        category="Indian Independence",
        display_title="INDIAN INDEPENDENCE QUIZ",
        subtitle="ADVENTURE",
        category_guidance="Celebrate the freedom movement respectfully.",
    )

    assert "941x1672" in prompt
    assert "INDIAN INDEPENDENCE QUIZ" in prompt
    assert "central 30 to 72 percent" in prompt
    assert "complete final renderer prompt" in prompt


def test_qwen_response_shape_is_normalized_to_canonical_plan() -> None:
    raw = json.dumps(
        {
            "schema_version": "1.0",
            "category": "Indian Independence",
            "visual_summary": "A hopeful sunrise scene framed by Indian history symbols.",
            "scene_concept": (
                "Children explore a respectful independence-themed landscape with "
                "historic landmarks and celebratory natural decoration."
            ),
            "focal_elements": "Red Fort; India Gate; marigolds; tricolor fabric",
            "composition": (
                "A tall portrait with a title at the top, open space through the "
                "center, and storytelling details around the lower outer edges."
            ),
            "palette_and_lighting": (
                "Warm sunrise gold with saffron, white, green, and deep blue accents."
            ),
            "prompt": (
                "Portrait composition for a polished family-friendly 3D animated "
                "Indian independence quiz scene. Place the exact title INDIAN "
                "INDEPENDENCE QUIZ in a dimensional emblem at the top and the exact "
                "subtitle ADVENTURE on one small ribbon. Show the Red Fort, India "
                "Gate, marigolds, tricolor fabric, and smiling Indian children around "
                "the outer edges and lower third. Preserve calm, low-contrast negative "
                "space through the center. Use warm sunrise light, respectful historic "
                "symbolism, crisp silhouettes, rich depth, and generous safe margins. "
                "No other text, dates, labels, logos, watermarks, interface controls, "
                "borders, modern political imagery, or malformed anatomy."
            ),
        }
    )

    plan = _parse_prompt_plan(raw)

    assert plan.schema_version == "quiz_background_prompt_plan_v1"
    assert plan.focal_elements == ["Red Fort", "India Gate", "marigolds", "tricolor fabric"]


def test_normalize_background_writes_runtime_dimensions(tmp_path: Path) -> None:
    source = Image.new("RGB", (800, 800), (220, 130, 50))
    payload = io.BytesIO()
    source.save(payload, format="PNG")
    output = tmp_path / "runtime_background.png"

    result = normalize_background(payload.getvalue(), output)

    with Image.open(output) as generated:
        assert generated.format == "PNG"
        assert generated.size == BACKGROUND_SIZE
    assert result["width"] == 941
    assert result["height"] == 1672
    assert len(result["sha256"]) == 64
