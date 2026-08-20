from __future__ import annotations

import io
import json
from pathlib import Path

import pytest
from PIL import Image

from quiz_harness.background_images import (
    BACKGROUND_SIZE,
    BackgroundPromptPlan,
    LANDSCAPE_BACKGROUND_SIZE,
    _parse_prompt_plan,
    _validate_prompt_plan,
    build_background_planning_prompt,
    build_background_prompt,
    generate_quiz_background,
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
    assert "keep the middle calmer" in prompt
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


def test_background_plan_accepts_vertical_mobile_prompt_alias() -> None:
    raw = json.dumps(
        {
            "visual_summary": "A child-friendly Indian history scene.",
            "scene_concept": (
                "Historic landmarks and festive decoration frame a calm central "
                "area in one coherent, respectful educational scene."
            ),
            "focal_elements": ["Red Fort", "marigolds", "tricolor fabric"],
            "palette_and_lighting": (
                "Warm sunrise gold with saffron, white, green, and blue accents."
            ),
            "final_prompt": (
                "Create a vertical 9:16 mobile quiz background with the exact title "
                "INDIAN INDEPENDENCE QUIZ and exact subtitle ADVENTURE. Keep the "
                "central 30 to 72 percent calm, low contrast, and uncluttered for "
                "Flutter controls. Frame the outer edges and lower third with the "
                "Red Fort, marigolds, tricolor fabric, and smiling Indian children. "
                "Use a polished family-friendly 3D animated illustration aesthetic, "
                "warm sunrise light, crisp silhouettes, appealing depth, and generous "
                "safe margins. Make the scene historically respectful, celebratory, "
                "and suitable for children. Include no other text, dates, captions, "
                "labels, logos, watermarks, interface controls, borders, modern "
                "political imagery, malformed anatomy, or duplicate subjects."
            ),
        }
    )

    plan = _parse_prompt_plan(raw)
    _validate_prompt_plan(
        plan,
        display_title="INDIAN INDEPENDENCE QUIZ",
        subtitle="ADVENTURE",
    )

    assert plan.prompt.startswith("Create a vertical 9:16")


def test_background_plan_compacts_nested_focal_elements_without_rewriting_prompt() -> None:
    prompt = (
        "A vertical 941x1672 digital illustration for MOUNTAINS QUIZ with the exact "
        "subtitle ADVENTURE. Reserve the upper area for a dimensional title emblem, "
        "keep the central area calm and uncluttered for quiz controls, and frame the "
        "outer edges with generic alpine peaks, trees, and wildflowers. Use polished "
        "family-friendly three-dimensional artwork, cheerful natural colors, soft "
        "daylight, crisp silhouettes, appealing depth, and generous safe margins. "
        "Show no identifiable mountain that could reveal a quiz answer. Include no "
        "other text, dates, labels, logos, watermarks, interface controls, political "
        "symbols, malformed anatomy, borders, duplicate subjects, or collage panels."
    )
    raw = json.dumps(
        {
            "scene_concept": {
                "description": (
                    "A coherent alpine landscape uses generic peaks and vegetation "
                    "to create a welcoming educational mountain adventure."
                ),
                "focal_elements": [
                    "A dimensional title emblem in the upper sky.",
                    "A calm, lower-contrast, relatively uncluttered central alpine "
                    "meadow and clear sky specifically reserved for interface controls.",
                    "Detailed stylized mountain peaks, alpine trees, and wildflowers "
                    "framing the lower and outer edges for visual storytelling.",
                ],
                "supporting_subjects": "Generic alpine trees; soft clouds",
                "environment": "A high-altitude meadow",
                "palette": "Natural sky blue, green, white, and warm gold accents.",
                "lighting": "Soft daylight with gentle shadows and clear depth.",
            },
            "final_renderer_prompt": prompt,
        }
    )

    plan = _parse_prompt_plan(raw)
    _validate_prompt_plan(
        plan, display_title="MOUNTAINS QUIZ", subtitle="ADVENTURE"
    )

    assert len(plan.focal_elements) == 3
    assert all(len(item) <= 140 for item in plan.focal_elements)
    assert plan.prompt == prompt


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


def test_normalize_background_writes_landscape_video_dimensions(tmp_path: Path) -> None:
    source = Image.new("RGB", (800, 800), (40, 100, 180))
    payload = io.BytesIO()
    source.save(payload, format="PNG")
    output = tmp_path / "video_background_landscape.png"

    result = normalize_background(payload.getvalue(), output, layout="landscape")

    with Image.open(output) as generated:
        assert generated.size == LANDSCAPE_BACKGROUND_SIZE
    assert (result["width"], result["height"]) == LANDSCAPE_BACKGROUND_SIZE


def test_qwen_landscape_prompt_defines_video_safe_areas() -> None:
    prompt = build_background_planning_prompt(
        category="Geography",
        display_title="GEOGRAPHY QUIZ",
        subtitle="ADVENTURE",
        layout="landscape",
    )

    assert "1920x1080" in prompt
    assert "true 16:9 landscape" in prompt
    assert "HARD HEADER LIMIT" in prompt
    assert "y=4% to y=18%" in prompt
    assert "two-by-two grid" in prompt
    assert "high-key, light-toned, low-contrast" in prompt
    assert "Do not plan one row of four" in prompt
    assert "ADVENTURE" not in prompt


def test_direct_landscape_prompt_uses_shallow_light_quiz_layout() -> None:
    prompt = build_background_prompt(
        category="Geography",
        display_title="GEOGRAPHY QUIZ",
        subtitle="ADVENTURE",
        layout="landscape",
    )
    compact = " ".join(prompt.split())

    assert "y=4% to y=18%" in compact
    assert "y=20% to y=52%" in compact
    assert "two-by-two grid" in compact
    assert "high-key, light-toned, low-contrast" in compact
    assert "Avoid dominant dark colors" in compact
    assert "rich natural color" not in compact
    assert "cinematic light" not in compact
    assert "ADVENTURE" not in compact


def test_landscape_validator_rejects_legacy_oversized_banner_plan() -> None:
    legacy_prompt = (
        "Create a true 16:9 landscape background with the exact title GEOGRAPHY "
        "QUIZ and no other text. Reserve the top 30 percent for a large title emblem. "
        "Keep a central question safe area and place four answer cards in "
        "one horizontal row. Use a rich dark blue environment with decorative "
        "category scenery at both sides. Keep all controls and labels out of the "
        "image and use generous crop-safe margins. "
        + "Maintain a coherent family-friendly illustration. " * 3
    )
    plan = BackgroundPromptPlan(
        schema_version="quiz_background_prompt_plan_v1",
        visual_summary="A legacy landscape quiz background with a large title.",
        scene_concept=(
            "A dark geography scene frames a central quiz-safe region with maps "
            "and landmarks around the outer edges."
        ),
        focal_elements=["Title emblem", "World map", "Edge landmarks"],
        composition=(
            "A wide landscape reserves the upper third for its title and places "
            "four answer areas in one row below."
        ),
        palette_and_lighting=(
            "Dark blue cinematic lighting with saturated gold highlights and depth."
        ),
        prompt=legacy_prompt,
    )

    with pytest.raises(ValueError, match="y=4%-18%"):
        _validate_prompt_plan(
            plan,
            display_title="GEOGRAPHY QUIZ",
            subtitle="ADVENTURE",
            layout="landscape",
        )


def test_landscape_validator_rejects_adventure_subtitle() -> None:
    prompt = build_background_prompt(
        category="Geography",
        display_title="GEOGRAPHY QUIZ",
        layout="landscape",
    )
    plan = BackgroundPromptPlan(
        schema_version="quiz_background_prompt_plan_v1",
        visual_summary="A light geography quiz background with a compact title.",
        scene_concept=(
            "A pale educational landscape leaves broad calm regions for question "
            "and answer panels while small map details frame the edges."
        ),
        focal_elements=["Compact title", "Pale map", "Edge landmarks"],
        composition=(
            "A 16:9 landscape with a shallow top title and a two-by-two lower grid."
        ),
        palette_and_lighting=(
            "High-key pale sky colors with soft diffuse light and low contrast."
        ),
        prompt=prompt + " Add the subtitle ADVENTURE.",
    )

    with pytest.raises(ValueError, match="omit the subtitle"):
        _validate_prompt_plan(
            plan,
            display_title="GEOGRAPHY QUIZ",
            subtitle="",
            layout="landscape",
        )


def test_background_generation_reuses_matching_render(
    tmp_path: Path, monkeypatch
) -> None:
    provider = {
        "id": "openai-images",
        "provider_type": "openai_images",
        "enabled": True,
        "default_model": "gpt-image-1",
        "discovered_models": [],
        "secret_ciphertext": None,
    }

    class Database:
        def __init__(self, _path: Path) -> None:
            pass

        @staticmethod
        def migrate() -> None:
            return None

        @staticmethod
        def provider_connection(_provider_id: str) -> dict[str, object]:
            return provider

    class Secrets:
        def __init__(self, **_kwargs: object) -> None:
            pass

        @staticmethod
        def decrypt(_value: object) -> str:
            return "test-key"

    calls = 0

    def render(**_kwargs: object) -> tuple[bytes, dict[str, object]]:
        nonlocal calls
        calls += 1
        payload = io.BytesIO()
        Image.new("RGB", (1024, 1536), "navy").save(payload, format="PNG")
        return payload.getvalue(), {"request_id": "test"}

    monkeypatch.setattr("quiz_harness.background_images.QuizDatabase", Database)
    monkeypatch.setattr("quiz_harness.background_images.SecretStore", Secrets)
    monkeypatch.setattr("quiz_harness.background_images._openai_image", render)
    output = tmp_path / "runtime_background.png"
    kwargs = {
        "category": "Space",
        "display_title": "SPACE QUIZ",
        "provider_id": "openai-images",
        "database_path": tmp_path / "quiz.db",
        "secret_key_file": tmp_path / "secret.key",
        "output": output,
        "prompt_override": "P" * 500 + " portrait SPACE QUIZ ADVENTURE",
    }

    first = generate_quiz_background(**kwargs)
    second = generate_quiz_background(**kwargs)

    assert first["reused"] is False
    assert second["reused"] is True
    assert calls == 1
