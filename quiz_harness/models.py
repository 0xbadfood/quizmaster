from __future__ import annotations

import re
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator


HexColor = Annotated[str, StringConstraints(pattern=r"^#[0-9A-Fa-f]{6}$")]
Identifier = Annotated[
    str, StringConstraints(pattern=r"^[a-z][a-z0-9_]{1,63}$")
]


def _normalized(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


class StrictModel(BaseModel):
    model_config = ConfigDict(extra="forbid")


class QuizBrief(StrictModel):
    title: Annotated[str, Field(min_length=2, max_length=60)]
    short_description: Annotated[str, Field(min_length=10, max_length=180)]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    subject: Annotated[str, Field(min_length=1, max_length=80)]
    language: Annotated[str, Field(min_length=2, max_length=20)]
    age_min: Annotated[int, Field(ge=3, le=15)]
    age_max: Annotated[int, Field(ge=3, le=15)]
    educational_goal: Annotated[str, Field(min_length=10, max_length=240)]
    question_count: Annotated[int, Field(ge=1, le=10)]

    @model_validator(mode="after")
    def validate_age_range(self) -> QuizBrief:
        if self.age_min > self.age_max:
            raise ValueError("age_min must not exceed age_max")
        return self


class ColorPalette(StrictModel):
    page_background: HexColor
    surface: HexColor
    primary: HexColor
    secondary: HexColor
    accent: HexColor
    correct: HexColor
    incorrect: HexColor
    text_primary: HexColor
    text_on_primary: HexColor


class TypographyPlan(StrictModel):
    display_style: Annotated[str, Field(min_length=3, max_length=100)]
    body_style: Annotated[str, Field(min_length=3, max_length=100)]
    casing: Literal["sentence", "title", "uppercase"]


class ShapeLanguage(StrictModel):
    corner_radius_px: Annotated[int, Field(ge=0, le=40)]
    border_width_px: Annotated[int, Field(ge=0, le=8)]
    shadow_style: Annotated[str, Field(min_length=3, max_length=120)]


class VisualDesign(StrictModel):
    theme_name: Annotated[str, Field(min_length=2, max_length=60)]
    art_direction: Annotated[str, Field(min_length=20, max_length=400)]
    palette: ColorPalette
    typography: TypographyPlan
    shape_language: ShapeLanguage


class LayoutRegion(StrictModel):
    region_id: Identifier
    order: Annotated[int, Field(ge=1, le=10)]
    height_behavior: Literal["fixed", "content", "flex"]
    alignment: Literal["start", "center", "stretch"]
    notes: Annotated[str, Field(min_length=5, max_length=200)]


class RequiredLayoutRegions(StrictModel):
    header: LayoutRegion
    progress: LayoutRegion
    question: LayoutRegion
    answers: LayoutRegion
    feedback: LayoutRegion


class MobileLayout(StrictModel):
    viewport_width_px: Annotated[int, Field(ge=320, le=768)]
    viewport_height_px: Annotated[int, Field(ge=568, le=1366)]
    content_width_percent: Annotated[int, Field(ge=80, le=100)]
    minimum_touch_target_px: Annotated[int, Field(ge=44, le=72)]
    safe_area_enabled: bool
    overflow_strategy: Literal["fit_single_screen", "vertical_scroll"]
    regions: RequiredLayoutRegions

    @model_validator(mode="after")
    def validate_regions(self) -> MobileLayout:
        regions = [
            self.regions.header,
            self.regions.progress,
            self.regions.question,
            self.regions.answers,
            self.regions.feedback,
        ]
        ids = [region.region_id for region in regions]
        orders = [region.order for region in regions]
        if len(ids) != len(set(ids)):
            raise ValueError("layout region_id values must be unique")
        if len(orders) != len(set(orders)):
            raise ValueError("layout region order values must be unique")
        return self


class UIComponents(StrictModel):
    background_asset_id: Identifier
    answer_button_asset_id: Identifier
    progress_track_asset_id: Identifier
    progress_marker_asset_id: Identifier
    question_card_treatment: Annotated[str, Field(min_length=10, max_length=200)]
    answer_button_behavior: Annotated[str, Field(min_length=10, max_length=240)]
    progress_behavior: Annotated[str, Field(min_length=10, max_length=240)]


class AssetSpec(StrictModel):
    asset_id: Identifier
    role: Literal[
        "background",
        "answer_button_frame",
        "progress_track",
        "progress_marker",
        "question_illustration",
        "feedback_decoration",
    ]
    usage: Annotated[str, Field(min_length=5, max_length=180)]
    width_px: Annotated[int, Field(ge=32, le=2048)]
    height_px: Annotated[int, Field(ge=32, le=2048)]
    transparent_background: bool
    reuse_scope: Literal["quiz", "question"]
    generation_prompt: Annotated[str, Field(min_length=30, max_length=1000)]
    negative_prompt: Annotated[str, Field(min_length=10, max_length=500)]
    text_policy: Literal["no_text"]

    @model_validator(mode="after")
    def validate_role_geometry_and_prompt(self) -> AssetSpec:
        if self.role == "background" and self.height_px <= self.width_px:
            raise ValueError("background assets must use portrait dimensions")
        prompt = self.generation_prompt.casefold()
        forbidden_phrases = ("intended for css", "no color fill", "invisible")
        if any(phrase in prompt for phrase in forbidden_phrases):
            raise ValueError("asset prompts must request visible raster artwork")
        return self


class AnswerOption(StrictModel):
    option_id: Identifier
    label: Annotated[str, Field(min_length=1, max_length=32)]

    @model_validator(mode="after")
    def validate_short_label(self) -> AnswerOption:
        if any(character in self.label for character in ".!?\n"):
            raise ValueError("option labels must be phrases without sentence punctuation")
        if len(self.label.split()) > 6:
            raise ValueError("option labels must contain at most six words")
        return self


class QuizQuestion(StrictModel):
    question_id: Identifier
    novelty_key: Identifier
    learning_objective: Annotated[str, Field(min_length=8, max_length=180)]
    prompt_text: Annotated[str, Field(min_length=3, max_length=140)]
    narration_text: Annotated[str, Field(min_length=3, max_length=180)]
    image_asset_id: Identifier
    options: Annotated[list[AnswerOption], Field(min_length=3, max_length=4)]
    correct_option_id: Identifier
    success_message: Annotated[str, Field(min_length=2, max_length=100)]
    explanation: Annotated[str, Field(min_length=5, max_length=180)]

    @model_validator(mode="after")
    def validate_options(self) -> QuizQuestion:
        option_ids = [option.option_id for option in self.options]
        labels = [_normalized(option.label) for option in self.options]
        if len(option_ids) != len(set(option_ids)):
            raise ValueError("option_id values must be unique within a question")
        if len(labels) != len(set(labels)):
            raise ValueError("option labels must be unique within a question")
        if self.correct_option_id not in option_ids:
            raise ValueError("correct_option_id does not reference an option")
        return self


class QuizPlan(StrictModel):
    schema_version: Literal["1.0"]
    brief: QuizBrief
    visual_design: VisualDesign
    mobile_layout: MobileLayout
    ui_components: UIComponents
    assets: Annotated[list[AssetSpec], Field(min_length=5, max_length=30)]
    questions: Annotated[list[QuizQuestion], Field(min_length=1, max_length=10)]

    @model_validator(mode="after")
    def validate_plan_links(self) -> QuizPlan:
        if self.brief.question_count != len(self.questions):
            raise ValueError("brief.question_count must match questions length")

        question_ids = [question.question_id for question in self.questions]
        novelty_keys = [question.novelty_key for question in self.questions]
        prompts = [_normalized(question.prompt_text) for question in self.questions]
        if len(question_ids) != len(set(question_ids)):
            raise ValueError("question_id values must be unique")
        if len(novelty_keys) != len(set(novelty_keys)):
            raise ValueError("novelty_key values must be unique")
        if len(prompts) != len(set(prompts)):
            raise ValueError("question prompts must not repeat")

        assets_by_id = {asset.asset_id: asset for asset in self.assets}
        if len(assets_by_id) != len(self.assets):
            raise ValueError("asset_id values must be unique")

        component_refs = {
            self.ui_components.background_asset_id: "background",
            self.ui_components.answer_button_asset_id: "answer_button_frame",
            self.ui_components.progress_track_asset_id: "progress_track",
            self.ui_components.progress_marker_asset_id: "progress_marker",
        }
        for asset_id, expected_role in component_refs.items():
            asset = assets_by_id.get(asset_id)
            if asset is None:
                raise ValueError(f"UI component references missing asset {asset_id!r}")
            if asset.role != expected_role:
                raise ValueError(
                    f"asset {asset_id!r} must have role {expected_role!r}"
                )

        for question in self.questions:
            asset = assets_by_id.get(question.image_asset_id)
            if asset is None:
                raise ValueError(
                    f"question {question.question_id!r} references a missing image asset"
                )
            if asset.role != "question_illustration":
                raise ValueError(
                    f"question {question.question_id!r} image must be a question illustration"
                )
            if asset.reuse_scope != "question":
                raise ValueError(
                    f"question image {asset.asset_id!r} must use question reuse_scope"
                )
        return self


class GenerationRequest(StrictModel):
    category: Annotated[str, Field(min_length=2, max_length=60)]
    subject: Annotated[str, Field(min_length=1, max_length=80)]
    language: Annotated[str, Field(min_length=2, max_length=20)]
    age_min: Annotated[int, Field(ge=3, le=15)]
    age_max: Annotated[int, Field(ge=3, le=15)]
    question_count: Annotated[int, Field(ge=1, le=10)]
    option_count: Literal[3, 4]
    seed: int

    @model_validator(mode="after")
    def validate_age_range(self) -> GenerationRequest:
        if self.age_min > self.age_max:
            raise ValueError("age_min must not exceed age_max")
        return self


class GeneratorInfo(StrictModel):
    provider: Literal["vllm"]
    endpoint: str
    model: str
    generated_at_utc: datetime
    attempts: Annotated[int, Field(ge=1, le=5)]
    prompt_version: Literal["1.0"]


class PlanDocument(StrictModel):
    request: GenerationRequest
    generator: GeneratorInfo
    plan: QuizPlan

    @model_validator(mode="after")
    def validate_request_alignment(self) -> PlanDocument:
        brief = self.plan.brief
        request = self.request
        comparisons = {
            "category": (brief.category, request.category),
            "subject": (brief.subject, request.subject),
            "language": (brief.language, request.language),
            "age_min": (brief.age_min, request.age_min),
            "age_max": (brief.age_max, request.age_max),
            "question_count": (brief.question_count, request.question_count),
        }
        for field_name, (actual, expected) in comparisons.items():
            if isinstance(actual, str) and isinstance(expected, str):
                matches = _normalized(actual) == _normalized(expected)
            else:
                matches = actual == expected
            if not matches:
                raise ValueError(
                    f"plan brief {field_name}={actual!r} does not match request {expected!r}"
                )
        for question in self.plan.questions:
            if len(question.options) != request.option_count:
                raise ValueError(
                    f"question {question.question_id!r} must have "
                    f"{request.option_count} options"
                )
        return self
