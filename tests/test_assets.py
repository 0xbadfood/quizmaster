from pathlib import Path

from PIL import Image

from quiz_harness.assets import (
    effective_generation_prompt,
    generation_dimensions,
    make_edge_background_transparent,
)
from quiz_harness.models import AssetSpec


def asset(role: str, width: int, height: int) -> AssetSpec:
    return AssetSpec(
        asset_id="sample_asset",
        role=role,
        usage="Test asset usage",
        width_px=width,
        height_px=height,
        transparent_background=role != "background",
        reuse_scope="question" if role == "question_illustration" else "quiz",
        generation_prompt="A polished colorful children's illustration with clean shapes and visible details.",
        negative_prompt="text, logo, watermark, letters, numbers",
        text_policy="no_text",
    )


def test_maps_background_to_supported_portrait_canvas() -> None:
    assert generation_dimensions(asset("background", 375, 812)) == (720, 1280)


def test_maps_wide_ui_asset_to_supported_canvas() -> None:
    assert generation_dimensions(asset("progress_track", 240, 48)) == (2048, 512)


def test_maps_square_question_to_quality_canvas() -> None:
    assert generation_dimensions(asset("question_illustration", 300, 300)) == (
        1024,
        1024,
    )


def test_maps_square_question_for_imagestudio() -> None:
    assert generation_dimensions(
        asset("question_illustration", 300, 300), "imagestudio"
    ) == (768, 768)


def test_ui_prompt_removes_dimension_language() -> None:
    item = asset("progress_track", 240, 48)
    item.generation_prompt = (
        "A polished progress bar. The aspect ratio is 5:1 (240px width, 48px height)."
    )
    prompt = effective_generation_prompt(item)
    assert "5:1" not in prompt
    assert "240px" not in prompt
    assert "Do not render measurements" in prompt


def test_edge_background_becomes_transparent_without_removing_center(
    tmp_path: Path,
) -> None:
    path = tmp_path / "button.png"
    image = Image.new("RGB", (80, 40), "white")
    for x in range(10, 70):
        for y in range(8, 32):
            image.putpixel((x, y), (20, 40, 80))
    for x in range(14, 66):
        for y in range(12, 28):
            image.putpixel((x, y), (255, 255, 255))
    image.save(path)
    make_edge_background_transparent(path)
    with Image.open(path) as result:
        assert result.mode == "RGBA"
        assert result.getpixel((0, 0))[3] == 0
        assert result.getpixel((40, 20))[3] == 255
