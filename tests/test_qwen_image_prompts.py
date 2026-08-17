from __future__ import annotations

import json
from pathlib import Path

import pytest

from quiz_harness.openai_images import (
    OpenAIImageAssetSpec,
    OpenAIImageSpecDocument,
    write_image_spec,
)
from quiz_harness.qwen_image_prompts import (
    AnswerImagePromptResponse,
    ImagePromptPlan,
    PlannedImagePrompt,
    SingleImagePromptResponse,
    TilePromptBrief,
    _request_json,
    _sanitize_answer_prompt_subject,
    _validate_answer_prompt,
    _validate_common_prompt,
    _validate_tile_prompt,
    answer_batch_planning_prompt,
    apply_category_prompt_plan,
    load_answer_prompt_overrides,
    load_prompt_subjects,
    stable_prompt_seed,
    tile_brief_planning_prompt,
    tile_requests_from_sets,
    tile_planning_prompt,
)
from quiz_harness.visual_bank import (
    VisualChoice,
    VisualQuestion,
    VisualQuizSet,
)


def _long_prompt(label: str) -> str:
    return (
        f"Create a reference-faithful production-ready square image of {label} with "
        "accurate visible features, clear silhouettes, natural lighting, comfortable "
        "safe margins, realistic anatomy and proportions, natural colors, "
        "and no unwanted text, logos, borders, watermarks, or duplicate subjects."
    )


def _plan() -> ImagePromptPlan:
    return ImagePromptPlan(
        schema_version="image_prompt_plan_v1",
        category="Animals",
        display_title="ANIMAL QUIZ",
        qwen_endpoint="http://10.8.0.5:8001/v1",
        qwen_model="qwen-test",
        base_seed=42,
        generated_at_utc="2026-08-05T00:00:00+00:00",
        assets=[
            PlannedImagePrompt(
                asset_id="animals_category_selector",
                role="category_selector",
                target_provider="openai",
                seed=1,
                prompt=_long_prompt("an animal category selector"),
                visual_summary="Lion and elephant in a centered forest clearing.",
            ),
            PlannedImagePrompt(
                asset_id="answer_african_elephant",
                role="answer_image",
                target_provider="imagestudio",
                seed=2,
                prompt=_long_prompt("one real African elephant"),
                source_labels=["African elephant"],
                visual_summary="Large ears; two tusks; long trunk.",
                review_status="approved",
            ),
        ],
    )


def test_prompt_seed_is_stable_and_asset_specific() -> None:
    assert stable_prompt_seed("tile_beginner_01", 42) == stable_prompt_seed(
        "tile_beginner_01", 42
    )
    assert stable_prompt_seed("tile_beginner_01", 42) != stable_prompt_seed(
        "tile_beginner_02", 42
    )


def test_generic_subject_catalog_accepts_objects(tmp_path: Path) -> None:
    path = tmp_path / "object_catalog.json"
    path.write_text(
        '{"objects":[{"object_key":"taj_mahal","label":"Taj Mahal"}]}',
        encoding="utf-8",
    )
    subjects = load_prompt_subjects(path)
    assert subjects[0].subject_key == "taj_mahal"
    assert subjects[0].label == "Taj Mahal"


def test_subject_catalog_uses_stable_key_for_non_ascii_planning_label(
    tmp_path: Path,
) -> None:
    path = tmp_path / "mountain_catalog.json"
    path.write_text(
        json.dumps({"objects": [{"object_key": "xueshan", "label": "雪山"}]}),
        encoding="utf-8",
    )

    subjects = load_prompt_subjects(path)

    assert subjects[0].subject_key == "xueshan"
    assert subjects[0].label == "Xueshan"


def test_tile_prompt_carries_exact_text_age_and_variation_context() -> None:
    choices = [
        VisualChoice(choice_id=f"choice{index}", animal_key=label, label=label.title())
        for index, label in enumerate(("lion", "tiger", "zebra", "camel"), start=1)
    ]
    correct_ids = [
        "choice1",
        "choice2",
        "choice3",
        "choice4",
        "choice1",
        "choice2",
        "choice3",
        "choice4",
        "choice1",
        "choice2",
    ]
    questions = []
    for index, correct_id in enumerate(correct_ids, start=1):
        answer = choices[int(correct_id[-1]) - 1].label
        questions.append(
            VisualQuestion(
                question_id=f"animals_beginner_{index:03d}",
                topic_key=f"animal_feature_{index:03d}",
                difficulty="beginner",
                question="Which animal matches this clear clue?",
                choices=choices,
                correct_choice_id=correct_id,
                explanation=f"The correct animal is {answer} for this clue.",
            )
        )
    quiz_set = VisualQuizSet(
        schema_version="visual_quiz_v1",
        set_id="animals_beginner_001",
        category="Animals",
        difficulty="beginner",
        source_model="test-source",
        selection_model="test-selector",
        questions=questions,
    )
    prompt = tile_planning_prompt(
        category="Animals",
        display_title="ANIMAL QUIZ",
        difficulty=quiz_set.difficulty,
        brief=TilePromptBrief(
            asset_id="tile_beginner_01",
            difficulty="beginner",
            set_number=1,
            scene_theme="Sunny grassland observation trail",
            subjects=["Lion", "Zebra", "Camel"],
            child_activity="A 4-year-old watches from a raised lookout.",
            composition="Wide eye-level view with animals in the middle distance.",
            palette_and_light="Warm morning gold with fresh natural greens.",
        ),
        set_number=1,
        seed=123,
        prior_summaries=["Previous river scene with a standing mascot."],
    )
    assert '"ANIMAL QUIZ 1"' in prompt
    assert '"BEGINNER"' in prompt
    assert "aged 3 to 5" in prompt
    assert "Variation seed: 123" in prompt
    assert "Previous river scene" in prompt


def test_tile_prompt_and_brief_instructions_are_category_neutral() -> None:
    brief = TilePromptBrief(
        asset_id="tile_beginner_04",
        difficulty="beginner",
        set_number=4,
        scene_theme="Bright breakfast table discovery",
        subjects=["Pancake", "Blueberry", "Maple syrup"],
        child_activity="A 4-year-old observes a colorful breakfast plate.",
        composition="Close view of the child and breakfast on the table.",
        palette_and_light="Warm morning light with gold and deep blue accents.",
    )
    prompt = tile_planning_prompt(
        category="Food",
        display_title="FOOD QUIZ",
        difficulty="beginner",
        brief=brief,
        set_number=4,
        seed=123,
        prior_summaries=[],
    )
    brief_prompt = tile_brief_planning_prompt(
        category="Food",
        tile_requests=[],
        subject_labels=["Pancake", "Blueberry", "Maple syrup"],
    )
    assert "Do not add other animals" not in prompt
    assert "wild animals" not in prompt
    assert "ordinary objects may be held" in prompt
    assert "tiles do not need to mirror the questions" in brief_prompt
    assert "Subject inspiration catalog" in brief_prompt


def test_tile_validator_accepts_inflections_and_a_clear_majority() -> None:
    response = SingleImagePromptResponse(
        prompt=(
            "Create a polished square scene with fluffy pancakes and fresh blueberries "
            "on a breakfast table. Render the exact title FOOD QUIZ 4 and the exact "
            "difficulty BEGINNER. Use cinematic lighting, clear crop margins, one child "
            "mascot, accurate food details, and no other writing, logos, or watermarks."
        ),
        visual_summary="Child viewing pancakes and blueberries at breakfast.",
    )
    _validate_tile_prompt(
        response,
        difficulty="beginner",
        display_title="FOOD QUIZ",
        set_number=4,
        source_labels=["Pancake", "Blueberry", "Maple syrup"],
    )


def test_tile_validator_accepts_place_names_and_demonyms() -> None:
    response = SingleImagePromptResponse(
        prompt=(
            "Create a polished square scene with one cheerful child beside an Irish "
            "flag and a Danish flag on a rainy windowsill. Render the exact title "
            "FLAGS QUIZ 7 and the exact difficulty BEGINNER. Use cinematic warm "
            "interior lighting, clear square crop margins, accurate flag designs, "
            "and no other writing, logos, borders, or watermarks."
        ),
        visual_summary="Child beside Irish and Danish flags at a rainy window.",
    )
    _validate_tile_prompt(
        response,
        difficulty="beginner",
        display_title="FLAGS QUIZ",
        set_number=7,
        source_labels=["Ireland", "Denmark", "child"],
    )


def test_answer_validator_accepts_inflection_but_keeps_subject_fidelity() -> None:
    item = AnswerImagePromptResponse(
        asset_id="answer_blueberry",
        prompt=_long_prompt("fresh blueberries"),
        identity_cues=["round blue fruit", "small crown at the base"],
    )
    _validate_answer_prompt(item, expected_label="Blueberry")


def test_common_prompt_validator_allows_studio_word_in_proper_name() -> None:
    _validate_common_prompt(
        "The Walt Disney Concert Hall with curved stainless steel surfaces, rendered "
        "in a polished high-end 3D animated family-film style."
    )


@pytest.mark.parametrize(
    "style_reference",
    (
        "Pixar-style 3D artwork",
        "Disney inspired animation",
        "an image in the style of Studio Ghibli",
        "a look like DreamWorks",
    ),
)
def test_common_prompt_validator_rejects_named_studio_style(
    style_reference: str,
) -> None:
    with pytest.raises(ValueError, match="copyrighted studio style"):
        _validate_common_prompt(
            f"Create a polished child-friendly square illustration with {style_reference}."
        )


def test_answer_sanitizer_injects_trusted_label_without_domain_rules() -> None:
    item = AnswerImagePromptResponse(
        asset_id="answer_calcium",
        prompt=_long_prompt("a glass of milk representing a familiar nutrient"),
        identity_cues=["white milk", "clear drinking glass"],
    )
    _sanitize_answer_prompt_subject(item, expected_label="Calcium")
    assert item.prompt.startswith("Exact intended answer subject: Calcium.")
    _validate_answer_prompt(item, expected_label="Calcium")


def test_answer_planner_supports_concepts_without_category_special_cases() -> None:
    prompt = answer_batch_planning_prompt(
        category="Food",
        assets=[("answer_calcium", "Calcium")],
    )
    assert "abstract concept" in prompt
    assert "minimum supporting elements" in prompt
    assert "competing answer subjects" in prompt
    assert "reference-image prompt" in prompt
    assert "correct number and placement of limbs" in prompt
    assert "Do not cartoonize, stylize, anthropomorphize" in prompt
    assert "child-friendly" not in prompt
    assert "3D animated" not in prompt


@pytest.mark.parametrize(
    "style_direction",
    (
        "cute child-friendly illustration",
        "polished 3D animated family-film rendering",
        "adorable cartoon animal with oversized eyes",
        "stylized anthropomorphic character",
    ),
)
def test_answer_validator_rejects_child_facing_style(
    style_direction: str,
) -> None:
    item = AnswerImagePromptResponse(
        asset_id="answer_snake",
        prompt=(
            "Create a square reference image of a snake with accurate visible anatomy, "
            f"natural lighting, and {style_direction}. Center the complete snake with "
            "comfortable margins in a simple habitat context, keep its markings clearly "
            "visible, and avoid all text, labels, logos, watermarks, borders, or clutter."
        ),
        identity_cues=["elongated limbless body", "natural scale texture"],
    )
    with pytest.raises(ValueError, match="child-facing"):
        _validate_answer_prompt(item, expected_label="Snake")


def test_request_json_recovers_prior_raw_response_after_validator_change(
    tmp_path: Path,
) -> None:
    call_path = tmp_path / "tile_beginner_04.json"
    raw_path = tmp_path / "tile_beginner_04.attempt-03.raw.txt"
    response = SingleImagePromptResponse(
        prompt=_long_prompt("pancakes with blueberries and maple syrup"),
        visual_summary="Breakfast tile with a child and three recognizable foods.",
    )
    raw_path.write_text(response.model_dump_json(), encoding="utf-8")
    progress = []

    recovered = _request_json(
        client=object(),
        model="unused",
        response_type=SingleImagePromptResponse,
        schema_name="unused",
        prompt="unused",
        seed=1,
        call_path=call_path,
        retries=0,
        force=False,
        progress=progress.append,
    )

    assert recovered == response
    assert call_path.exists()
    assert progress == ["tile_beginner_04: recovered a valid prior raw response"]


def test_plan_applies_category_prompt_and_loads_answer_override(
    tmp_path: Path,
) -> None:
    spec_path = tmp_path / "category-image-spec.json"
    document = OpenAIImageSpecDocument(
        schema_version="openai_image_spec_v1",
        name="animals_category_images",
        category="Animals",
        generated_at_utc="2026-08-05T00:00:00+00:00",
        assets=[
            OpenAIImageAssetSpec(
                asset_id="animals_category_selector",
                scope="category",
                role="category_selector",
                source="openai",
                provider="openai",
                model="gpt-image-2",
                quality="medium",
                api_size="1024x1024",
                output_width=512,
                output_height=512,
                background="opaque",
                file="assets/category/category_selector.webp",
                prompt=_long_prompt("the old selector"),
                review_status="approved",
            )
        ],
    )
    write_image_spec(spec_path, document)
    plan = _plan()
    plan_path = tmp_path / "image-prompt-plan.json"
    plan_path.write_text(plan.model_dump_json(indent=2), encoding="utf-8")

    updated = apply_category_prompt_plan(
        plan=plan, category_spec_path=spec_path
    )

    assert updated.assets[0].prompt == _long_prompt("an animal category selector")
    assert updated.assets[0].review_status == "pending_generation"
    assert load_answer_prompt_overrides(plan_path) == {
        "african_elephant": _long_prompt("one real African elephant")
    }


def test_tile_requests_follow_existing_sets_not_fixed_twenty(tmp_path: Path) -> None:
    root = tmp_path / "birds"
    for difficulty, numbers in (("beginner", (1, 2, 3)), ("intermediate", (1,))):
        folder = root / "sets" / difficulty
        folder.mkdir(parents=True)
        for number in numbers:
            (folder / f"birds_{difficulty}_{number:03d}.json").write_text(
                json.dumps(
                    {
                        "set_id": f"birds_{difficulty}_{number:03d}",
                        "difficulty": difficulty,
                    }
                ),
                encoding="utf-8",
            )
    requests = tile_requests_from_sets(root)
    assert [item.asset_id for item in requests] == [
        "tile_beginner_01",
        "tile_beginner_02",
        "tile_beginner_03",
        "tile_intermediate_01",
    ]
