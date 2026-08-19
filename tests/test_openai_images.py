from __future__ import annotations

import io
import json
from pathlib import Path

from PIL import Image

from quiz_harness.image_inventory import (
    build_category_image_spec,
    build_global_image_spec,
    build_progress_style,
    build_video_presentation_inventory,
)
from quiz_harness.openai_images import (
    OpenAIImageAssetSpec,
    OpenAIImageSpecDocument,
    _normalize_image,
    register_user_upload,
)
from quiz_harness.visual_bank import VisualQuestion, VisualQuizSet


def _quiz_set(difficulty: str, number: int) -> VisualQuizSet:
    questions = []
    targets = ["choice1"] * 3 + ["choice2"] * 3 + ["choice3"] * 2 + ["choice4"] * 2
    for index, target in enumerate(targets, start=1):
        choices = [
            {
                "choice_id": f"choice{choice}",
                "animal_key": f"animal_{number}_{index}_{choice}",
                "label": f"Animal {number}-{index}-{choice}",
            }
            for choice in range(1, 5)
        ]
        questions.append(
            VisualQuestion(
                question_id=f"animals_{difficulty}_{number}_{index}",
                topic_key=f"topic_{difficulty}_{number}_{index}",
                difficulty=difficulty,
                question=f"Which animal demonstrates distinctive feature {number}-{index}?",
                choices=choices,
                correct_choice_id=target,
                explanation=(
                    f"Animal {number}-{index}-{target[-1]} demonstrates the distinctive "
                    f"feature numbered {number}-{index}."
                ),
            )
        )
    return VisualQuizSet(
        schema_version="visual_quiz_v1",
        set_id=f"animals_{difficulty}_{number:03d}",
        category="Animals",
        difficulty=difficulty,
        source_model="gpt-5.6-luna",
        selection_model="test-selector",
        questions=questions,
    )


def test_category_spec_has_background_selector_and_twenty_tiles(tmp_path: Path) -> None:
    category_root = tmp_path / "animals"
    for difficulty in ("beginner", "intermediate"):
        output = category_root / "sets" / difficulty
        output.mkdir(parents=True)
        for number in range(1, 11):
            quiz_set = _quiz_set(difficulty, number)
            (output / f"set_{number:02d}.json").write_text(
                quiz_set.model_dump_json(indent=2), encoding="utf-8"
            )

    document = build_category_image_spec(
        category="Animals",
        category_root=category_root,
        display_title="ANIMAL QUIZ",
        background_ready=True,
    )
    assert len(document.assets) == 23
    assert sum(asset.role == "quiz_tile" for asset in document.assets) == 20
    landscape = next(
        asset for asset in document.assets if asset.role == "video_background_landscape"
    )
    assert (landscape.output_width, landscape.output_height) == (1920, 1080)
    first = next(asset for asset in document.assets if asset.asset_id == "tile_beginner_01")
    assert first.exact_text == ["ANIMAL QUIZ 1", "BEGINNER"]
    assert "aged 3 to 5" in first.prompt
    assert "category as a whole" in first.prompt
    assert "Animal 1-1-1" not in first.prompt
    intermediate = next(
        asset for asset in document.assets if asset.asset_id == "tile_intermediate_01"
    )
    assert "aged 8 to 10" in intermediate.prompt


def test_global_spec_has_shared_controls_and_video_frames() -> None:
    document = build_global_image_spec()
    assert len(document.assets) == 11
    assert [asset.asset_id for asset in document.assets[:3]] == [
        "settings_button",
        "speaker_on_button",
        "speaker_muted_button",
    ]
    assert {asset.asset_id for asset in document.assets[3:]} == {
        "video_progress_plaque",
        "video_question_frame",
        "video_answer_frame",
        "video_explanation_frame",
        "video_badge_purple",
        "video_badge_green",
        "video_badge_orange",
        "video_badge_blue",
    }


def test_video_inventory_keeps_letters_and_progress_dynamic() -> None:
    inventory = build_video_presentation_inventory()

    assert inventory["category_assets"]["landscape_background"]["size"] == [
        1920,
        1080,
    ]
    assert inventory["dynamic_content"]["progress_text"] == (
        "QUESTION {current} OF {total}"
    )
    assert inventory["dynamic_content"]["answer_badge_text"] == ["A", "B", "C", "D"]


def test_image_spec_supports_full_category_answer_inventory() -> None:
    assets = [
        OpenAIImageAssetSpec(
            asset_id=f"answer_{index:03d}",
            scope="category",
            role="answer_image",
            source="openai",
            provider="openai",
            model="gpt-image-test",
            quality="medium",
            api_size="1024x1024",
            output_width=768,
            output_height=768,
            background="opaque",
            file=f"assets/answers/answer_{index:03d}.webp",
            prompt="Create one clear isolated educational answer subject image.",
            review_status="pending_generation",
        )
        for index in range(800)
    ]

    document = OpenAIImageSpecDocument(
        schema_version="openai_image_spec_v1",
        name="world_history_answer_images",
        category="World History",
        generated_at_utc="2026-08-06T00:00:00Z",
        assets=assets,
    )

    assert len(document.assets) == 800


def test_progress_is_a_flutter_state_contract() -> None:
    style = build_progress_style()
    assert style["question_count"] == 10
    assert style["rendering"] == "flutter"
    assert style["states"]["unanswered"]["fill"] == "#123F24"
    assert style["states"]["correct"]["fill"] == "#36A852"
    assert style["states"]["incorrect"]["fill"] == "#D94B4B"


def test_registers_uploaded_background_as_approved(tmp_path: Path) -> None:
    document = build_global_image_spec()
    source = tmp_path / "source.png"
    Image.new("RGB", (941, 1672), "navy").save(source)
    spec = build_category_image_spec
    # Use a compatible upload spec without requiring category set fixtures.
    from quiz_harness.openai_images import OpenAIImageAssetSpec

    upload = OpenAIImageAssetSpec(
        asset_id="animals_runtime_background",
        scope="category",
        role="runtime_background",
        source="user_upload",
        output_width=941,
        output_height=1672,
        background="opaque",
        file="assets/category/runtime_background.png",
        prompt="User supplied approved portrait category background image asset.",
        exact_text=["ANIMAL QUIZ"],
        review_status="approved",
    )
    manifest_path = tmp_path / "manifest.json"
    manifest = register_user_upload(
        spec=upload,
        source=source,
        root=tmp_path / "category",
        manifest_path=manifest_path,
        manifest_name=document.name,
    )
    record = manifest["assets"][upload.asset_id]
    assert record["status"] == "approved"
    assert record["width"] == 941
    assert (tmp_path / "category" / upload.file).exists()


def test_normalizes_transparent_openai_output_to_target_canvas(tmp_path: Path) -> None:
    source = Image.new("RGBA", (300, 200), (255, 255, 255, 255))
    for x in range(100, 200):
        for y in range(50, 150):
            source.putpixel((x, y), (20, 120, 60, 255))
    buffer = io.BytesIO()
    source.save(buffer, format="PNG")
    output = tmp_path / "progress.webp"
    _normalize_image(
        buffer.getvalue(),
        output=output,
        target_size=(1280, 320),
        transparent=True,
    )
    with Image.open(output) as image:
        assert image.size == (1280, 320)
        assert "A" in image.getbands()
        assert image.getpixel((0, 0))[3] == 0
