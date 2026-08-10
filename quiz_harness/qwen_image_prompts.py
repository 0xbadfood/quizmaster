from __future__ import annotations

import hashlib
import json
import math
import re
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Callable, Literal, TypeVar

from pydantic import Field, ValidationError, model_validator

from .client import VLLMClient, VLLMError
from .models import Identifier, StrictModel
from .openai_images import OpenAIImageSpecDocument, write_image_spec
from .visual_bank import normalize_text, slugify


DEFAULT_QWEN_IMAGE_PROMPT_ENDPOINT = "http://10.8.0.5:8001/v1"
DEFAULT_PROMPT_SEED = 20260805


SUBJECT_LABEL_ALIASES: dict[str, tuple[str, ...]] = {
    "argentina": ("argentine", "argentinian"),
    "australia": ("australian",),
    "austria": ("austrian",),
    "brazil": ("brazilian",),
    "canada": ("canadian",),
    "china": ("chinese",),
    "colombia": ("colombian",),
    "denmark": ("danish",),
    "france": ("french",),
    "germany": ("german",),
    "hungary": ("hungarian",),
    "india": ("indian",),
    "ireland": ("irish",),
    "italy": ("italian",),
    "japan": ("japanese",),
    "kenya": ("kenyan",),
    "mexico": ("mexican",),
    "netherlands": ("dutch",),
    "norway": ("norwegian",),
    "peru": ("peruvian",),
    "russia": ("russian",),
    "singapore": ("singaporean",),
    "south africa": ("south african",),
    "south korea": ("south korean", "korean"),
    "spain": ("spanish",),
    "sweden": ("swedish",),
    "switzerland": ("swiss",),
    "united kingdom": ("british", "uk"),
    "united states": ("american", "us", "usa"),
}


class SingleImagePromptResponse(StrictModel):
    prompt: Annotated[str, Field(min_length=180, max_length=3000)]
    visual_summary: Annotated[str, Field(min_length=20, max_length=400)]


class AnswerImagePromptResponse(StrictModel):
    asset_id: Identifier
    prompt: Annotated[str, Field(min_length=180, max_length=1800)]
    identity_cues: Annotated[
        list[Annotated[str, Field(min_length=3, max_length=100)]],
        Field(min_length=2, max_length=8),
    ]


class AnswerImagePromptBatchResponse(StrictModel):
    prompts: Annotated[list[AnswerImagePromptResponse], Field(min_length=1, max_length=25)]

    @model_validator(mode="after")
    def validate_ids(self) -> AnswerImagePromptBatchResponse:
        ids = [item.asset_id for item in self.prompts]
        if len(ids) != len(set(ids)):
            raise ValueError("answer prompt asset IDs must be unique")
        return self


class PromptSubject(StrictModel):
    subject_key: Identifier
    label: Annotated[str, Field(min_length=2, max_length=100)]


class TilePromptRequest(StrictModel):
    asset_id: Identifier
    difficulty: Literal["beginner", "intermediate"]
    set_number: Annotated[int, Field(ge=1, le=999)]


class TilePromptBrief(StrictModel):
    asset_id: Identifier
    difficulty: Literal["beginner", "intermediate"]
    set_number: Annotated[int, Field(ge=1, le=999)]
    scene_theme: Annotated[str, Field(min_length=10, max_length=180)]
    subjects: Annotated[
        list[Annotated[str, Field(min_length=2, max_length=60)]],
        Field(min_length=3, max_length=5),
    ]
    child_activity: Annotated[str, Field(min_length=10, max_length=180)]
    composition: Annotated[str, Field(min_length=10, max_length=220)]
    palette_and_light: Annotated[str, Field(min_length=10, max_length=180)]


class TilePromptBriefPlan(StrictModel):
    briefs: Annotated[list[TilePromptBrief], Field(min_length=1, max_length=40)]

    @model_validator(mode="after")
    def validate_ids(self) -> TilePromptBriefPlan:
        ids = [brief.asset_id for brief in self.briefs]
        if len(ids) != len(set(ids)):
            raise ValueError("tile brief asset IDs must be unique")
        return self


class PlannedImagePrompt(StrictModel):
    asset_id: Identifier
    role: Literal["category_selector", "quiz_tile", "answer_image"]
    target_provider: Literal["openai", "imagestudio"]
    seed: Annotated[int, Field(ge=0, le=2_147_483_647)]
    prompt: Annotated[str, Field(min_length=180, max_length=3000)]
    negative_prompt: Annotated[str, Field(max_length=1000)] = ""
    exact_text: list[Annotated[str, Field(min_length=1, max_length=80)]] = []
    source_labels: list[Annotated[str, Field(min_length=1, max_length=100)]] = []
    visual_summary: Annotated[str, Field(min_length=3, max_length=800)]
    difficulty: Literal["beginner", "intermediate"] | None = None
    set_number: Annotated[int, Field(ge=1, le=999)] | None = None
    review_status: Literal["pending_review", "approved", "rejected"] = (
        "pending_review"
    )


class ImagePromptPlan(StrictModel):
    schema_version: Literal["image_prompt_plan_v1"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    display_title: Annotated[str, Field(min_length=2, max_length=80)]
    category_guidance: Annotated[str, Field(max_length=2000)] = ""
    qwen_endpoint: Annotated[str, Field(min_length=8, max_length=240)]
    qwen_model: Annotated[str, Field(min_length=2, max_length=160)]
    base_seed: Annotated[int, Field(ge=0, le=2_147_483_647)]
    generated_at_utc: Annotated[str, Field(min_length=10, max_length=60)]
    assets: Annotated[list[PlannedImagePrompt], Field(max_length=1000)]

    @model_validator(mode="after")
    def validate_assets(self) -> ImagePromptPlan:
        ids = [asset.asset_id for asset in self.assets]
        if len(ids) != len(set(ids)):
            raise ValueError("planned image prompt asset IDs must be unique")
        return self


class QwenImagePromptError(RuntimeError):
    """Raised when Qwen cannot return a valid image prompt plan."""


ResponseModel = TypeVar(
    "ResponseModel",
    SingleImagePromptResponse,
    AnswerImagePromptBatchResponse,
    TilePromptBriefPlan,
)


def stable_prompt_seed(asset_id: str, base_seed: int) -> int:
    digest = hashlib.sha256(
        f"image-prompt-plan-v1:{base_seed}:{asset_id}".encode("utf-8")
    ).digest()
    return int.from_bytes(digest[:4], "big") & 0x7FFFFFFF


def _write_model(path: Path, model: StrictModel) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(model.model_dump_json(indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def default_tile_requests() -> list[TilePromptRequest]:
    return [
        TilePromptRequest(
            asset_id=f"tile_{difficulty}_{number:02d}",
            difficulty=difficulty,
            set_number=number,
        )
        for difficulty in ("beginner", "intermediate")
        for number in range(1, 11)
    ]


def tile_requests_from_sets(category_root: Path) -> list[TilePromptRequest]:
    requests: list[TilePromptRequest] = []
    for path in sorted((category_root / "sets").glob("*/*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        difficulty = data.get("difficulty")
        set_id = data.get("set_id")
        if difficulty not in {"beginner", "intermediate"} or not isinstance(
            set_id, str
        ):
            raise ValueError(f"invalid quiz set metadata in {path}")
        try:
            set_number = int(set_id.rsplit("_", 1)[-1])
        except ValueError as exc:
            raise ValueError(f"quiz set number is invalid in {path}") from exc
        requests.append(
            TilePromptRequest(
                asset_id=f"tile_{difficulty}_{set_number:02d}",
                difficulty=difficulty,
                set_number=set_number,
            )
        )
    if not requests:
        raise ValueError(f"no quiz sets found under {category_root / 'sets'}")
    return requests


def load_prompt_subjects(path: Path) -> list[PromptSubject]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError("subject catalog must be a JSON object")
    records = next(
        (
            data[name]
            for name in ("subjects", "objects", "items", "animals")
            if isinstance(data.get(name), list)
        ),
        None,
    )
    if records is None:
        raise ValueError(
            "subject catalog requires a subjects, objects, items, or animals list"
        )
    subjects: list[PromptSubject] = []
    for record in records:
        if not isinstance(record, dict):
            raise ValueError("every subject catalog entry must be an object")
        label = record.get("label") or record.get("name")
        if not isinstance(label, str) or not label.strip():
            raise ValueError("every subject catalog entry requires label or name")
        key = next(
            (
                record.get(name)
                for name in ("subject_key", "object_key", "animal_key", "key", "id")
                if isinstance(record.get(name), str) and record.get(name)
            ),
            None,
        )
        if key is None:
            key = slugify(label)
        planning_label = label.strip()
        if not re.search(r"[a-z0-9]", planning_label, flags=re.IGNORECASE):
            planning_label = key.replace("_", " ").title()
        subjects.append(PromptSubject(subject_key=key, label=planning_label))
    keys = [item.subject_key for item in subjects]
    if len(keys) != len(set(keys)):
        raise ValueError("subject catalog keys must be unique")
    return subjects


def selector_planning_prompt(*, category: str, category_guidance: str = "") -> str:
    guidance = category_guidance or (
        f"Use only unmistakable subjects that broadly represent {category}."
    )
    return f"""Write one production-ready text-to-image prompt for the category selector
thumbnail of a children's {category} quiz.

The generated image will be square and displayed at small size, sometimes through a
circular crop. Select three to five unmistakable, visually varied subjects that
represent only the {category} category. Compose them as one coherent scene with a
category-specific setting, clean silhouettes, a strong central focal point, generous
edge safety, vivid natural color, and polished high-end 3D animated family-film
artwork. It must appeal to children without appearing babyish.

Category guidance supplied by the editor:
{guidance}

The image must contain no child mascot, text, letters, numbers, title, logo, border,
collage panels, duplicate subjects, or watermark. Do not name copyrighted characters,
studios, films, or living artists. The final prompt must explicitly state all of these
constraints. The visual_summary should briefly identify the chosen subjects, setting,
and composition so later tile calls can avoid copying it."""


def tile_planning_prompt(
    *,
    category: str,
    display_title: str,
    difficulty: Literal["beginner", "intermediate"],
    brief: TilePromptBrief,
    category_guidance: str = "",
    set_number: int,
    seed: int,
    prior_summaries: list[str],
) -> str:
    if difficulty == "beginner":
        mascot = "one cheerful child explorer aged 3 to 5"
    else:
        mascot = "one confident child explorer aged 8 to 10"
    exact_title = f"{display_title} {set_number}"
    prior = prior_summaries[-8:]
    guidance = category_guidance or f"Use only subjects appropriate to {category}."
    return f"""Write one production-ready text-to-image prompt for a square mobile quiz
cover tile.

Category: {category}
Difficulty: {difficulty}
Set number: {set_number}
Variation seed: {seed}
Approved scene theme: {brief.scene_theme}
Required subjects: {json.dumps(brief.subjects, ensure_ascii=True)}
Child activity: {brief.child_activity}
Composition: {brief.composition}
Palette and lighting: {brief.palette_and_light}
Category guidance: {guidance}

Create a distinct scene featuring {mascot} and the approved recognizable subjects.
Name each depicted approved subject with its exact Required subjects wording at least
once in the prompt, even if you also use an adjectival form elsewhere.
Keep at least a clear majority of them prominent, and do not add unrelated category
subjects. The approved subjects must share one credible setting;
do not use bubbles, portals, floating frames, or other devices to force incompatible
subjects together. Give the child an age-appropriate pose and proportions.
Use an age-appropriate, plausible, safe interaction for the depicted category. Safe
ordinary objects may be held or used naturally. If a subject, tool, vehicle, location,
animal, heat source, or activity could be hazardous, show clear supervision, distance,
protective equipment, or a physical barrier as appropriate. Do not depict imminent
danger, harmful handling, or unsafe behavior.
Use a setting, camera angle, grouping, activity, lighting, and color balance specific
to this category and different from the prior summaries below. The scene must read as
one coherent high-end 3D animated family-adventure image, not a collage. Preserve
clear silhouettes and generous square-crop safe margins.

The image generator must render exactly two text elements:
- "{exact_title}"
- "{difficulty.upper()}"

Require large, correctly spelled, fully visible title lettering and one distinct
difficulty ribbon. Explicitly forbid all other text, letters, numbers, logos,
watermarks, duplicate subjects, extra limbs, and copyrighted characters. Do not name
studios, films, living artists, or trademarked characters.

Prior tile summaries to avoid repeating:
{json.dumps(prior, indent=2, ensure_ascii=True)}

The visual_summary should concisely capture the selected subjects, child pose,
setting, camera composition, and dominant lighting."""


def tile_brief_planning_prompt(
    *,
    category: str,
    tile_requests: list[TilePromptRequest],
    subject_labels: list[str],
    category_guidance: str = "",
) -> str:
    requested = []
    requested = [item.model_dump(mode="json") for item in tile_requests]
    guidance = category_guidance or (
        f"Prefer labels from the supplied inspiration list and use only subjects that "
        f"clearly belong to {category}. Group them into one coherent scene."
    )
    return f"""Create a coordinated set of distinct visual briefs for all requested
children's {category} quiz cover tiles.

Requested tiles:
{json.dumps(requested, indent=2, ensure_ascii=True)}

Subject inspiration catalog:
{json.dumps(subject_labels, ensure_ascii=True)}

Category guidance supplied by the editor:
{guidance}

Return every requested asset_id exactly once with unchanged difficulty and set_number.
Use three to five subjects or contextual scene elements per tile, with at least two
unmistakable subjects from the category. Contextual props may be introduced when they
make the scene coherent; tiles do not need to mirror the questions in their quiz set.
Across the complete collection, deliberately vary
habitat, subject group, child activity, camera composition, palette, weather, and time
of day. Do not repeat a scene_theme. Beginner briefs use a child aged 3 to 5;
intermediate briefs use a child aged 8 to 10.

Every child_activity must be plausible, age-appropriate, and safe for its specific
context. Safe everyday objects may be handled naturally. For hazardous subjects or
settings, specify suitable supervision, distance, protective equipment, or a barrier.
Do not depict imminent danger, harmful handling, or unsafe behavior."""


def answer_batch_planning_prompt(
    *,
    category: str,
    assets: list[tuple[str, str]],
    category_guidance: str = "",
) -> str:
    payload = [
        {"asset_id": asset_id, "exact_subject": label}
        for asset_id, label in assets
    ]
    return f"""Write one production-ready text-to-image prompt for every supplied answer
object in a children's {category} picture quiz.

Input objects:
{json.dumps(payload, indent=2, ensure_ascii=True)}

Category guidance supplied by the editor:
{category_guidance or f'Use only subjects appropriate to {category}.'}

For each asset_id, create one clear visual representation of exact_subject and name
that exact subject in the prompt. For a concrete object, living thing, place, or
landmark, use one primary instance. For a prepared dish, material, group, nutrient,
process, or other abstract concept, use one coherent plated, contained, or educational
arrangement with only the minimum supporting elements needed to communicate it. Make
the intended answer immediately recognizable using the most diagnostic visible cues
appropriate to the domain: anatomy and markings, form and materials, ingredients and
presentation, geographic features, verified architecture, or a familiar real-world
representation. List those features separately as identity_cues. Never substitute a
related or generic subject when the label is specific. Include only details you know
confidently; fewer accurate cues are better than invented or exaggerated details.

Each prompt must request one centered focal representation with a strong silhouette,
comfortable square margins, bright cinematic lighting, a friendly natural expression
when applicable, polished high-end 3D animated family-film rendering, and a simple
softly blurred category-appropriate context. It must forbid text, letters, numbers,
labels, logos, watermarks, borders, competing answer subjects, needless duplicates,
and incorrect physical details. Do not name studios, films, living artists, or
trademarked characters. Return every input asset_id exactly once and unchanged."""


def answer_batch_review_prompt(
    *,
    category: str,
    assets: list[tuple[str, str]],
    draft: AnswerImagePromptBatchResponse,
) -> str:
    labels = {asset_id: label for asset_id, label in assets}
    return f"""Act as a conservative factual editor for children's {category} answer-image
prompts. Review every draft below against the exact subject label.

Exact labels by immutable asset_id:
{json.dumps(labels, indent=2, ensure_ascii=True)}

Draft prompts:
{draft.model_dump_json(indent=2)}

Return the same asset IDs exactly once. Correct or delete any doubtful claim about
identity, appearance, anatomy, material, geography, period, architecture, setting, or
context. Check diagnostic distinctions from closely related subjects. A short prompt
that repeatedly names the exact subject and requests reference accuracy is preferable
to a detailed prompt containing one uncertain feature. Do not invent replacement
details. Keep the square, centered, single-focal-representation, child-friendly 3D art
direction and all no-text/no-competing-answer constraints. Concrete answers should
remain a single primary instance; abstract or group concepts may use a minimal coherent
arrangement. identity_cues must contain only visible traits you are highly confident
are correct."""


def _request_json(
    *,
    client: VLLMClient,
    model: str,
    response_type: type[ResponseModel],
    schema_name: str,
    prompt: str,
    seed: int,
    call_path: Path,
    retries: int,
    force: bool,
    validate: Callable[[ResponseModel], None] | None = None,
    progress: Callable[[str], None] | None = None,
) -> ResponseModel:
    if call_path.exists() and not force:
        try:
            response = response_type.model_validate_json(
                call_path.read_text(encoding="utf-8")
            )
            if validate:
                validate(response)
            return response
        except (OSError, ValidationError, ValueError):
            if progress:
                progress(f"{call_path.stem}: cached response failed current checks")

    if not force:
        raw_pattern = f"{call_path.stem}.attempt-*.raw.txt"
        for raw_path in sorted(call_path.parent.glob(raw_pattern), reverse=True):
            try:
                response = response_type.model_validate_json(
                    raw_path.read_text(encoding="utf-8")
                )
                if validate:
                    validate(response)
                _write_model(call_path, response)
                if progress:
                    progress(
                        f"{call_path.stem}: recovered a valid prior raw response"
                    )
                return response
            except (OSError, ValidationError, ValueError):
                continue

    call_path.parent.mkdir(parents=True, exist_ok=True)
    prompt_path = call_path.with_suffix(".prompt.txt")
    prompt_path.write_text(prompt, encoding="utf-8")
    messages = [
        {
            "role": "system",
            "content": (
                "You are an expert children's text-to-image prompt writer. Return "
                "only JSON matching the schema. Be visually specific and concise."
            ),
        },
        {"role": "user", "content": prompt},
    ]
    last_error = "unknown response error"
    for attempt in range(1, retries + 2):
        if progress:
            progress(f"{call_path.stem}: Qwen attempt {attempt}/{retries + 1}")
        raw: str | None = None
        try:
            raw = client.generate_json(
                model=model,
                messages=messages,
                schema=response_type.model_json_schema(),
                schema_name=schema_name,
                seed=seed + attempt - 1,
                temperature=0.65,
                max_tokens=12_000,
            )
            call_path.with_suffix(f".attempt-{attempt:02d}.raw.txt").write_text(
                raw, encoding="utf-8"
            )
            response = response_type.model_validate_json(raw)
            if validate:
                validate(response)
            _write_model(call_path, response)
            return response
        except (OSError, ValidationError, VLLMError, ValueError) as exc:
            last_error = str(exc)
            if attempt > retries:
                break
            messages.extend(
                [
                    {"role": "assistant", "content": raw or "No complete response."},
                    {
                        "role": "user",
                        "content": (
                            "Regenerate the complete JSON. The previous response "
                            f"failed validation: {last_error[:1800]}"
                        ),
                    },
                ]
            )
    raise QwenImagePromptError(f"{call_path.stem} failed: {last_error}")


def _load_or_create_plan(
    *,
    path: Path,
    category: str,
    display_title: str,
    category_guidance: str,
    endpoint: str,
    model: str,
    base_seed: int,
) -> ImagePromptPlan:
    if path.exists():
        plan = ImagePromptPlan.model_validate_json(path.read_text(encoding="utf-8"))
        if plan.category.casefold() != category.casefold():
            raise ValueError("existing image prompt plan belongs to another category")
        return plan
    return ImagePromptPlan(
        schema_version="image_prompt_plan_v1",
        category=category,
        display_title=display_title,
        category_guidance=category_guidance,
        qwen_endpoint=endpoint,
        qwen_model=model,
        base_seed=base_seed,
        generated_at_utc=datetime.now(timezone.utc).isoformat(),
        assets=[],
    )


def _upsert(plan: ImagePromptPlan, asset: PlannedImagePrompt) -> None:
    plan.assets = [item for item in plan.assets if item.asset_id != asset.asset_id]
    plan.assets.append(asset)
    plan.assets.sort(key=lambda item: (item.role, item.asset_id))
    plan.generated_at_utc = datetime.now(timezone.utc).isoformat()


def _validate_common_prompt(prompt: str) -> None:
    normalized = normalize_text(prompt)
    studio = r"(?:pixar|disney|dreamworks|ghibli)"
    style_reference_patterns = (
        rf"\b{studio}\s+(?:animation\s+|animated\s+|visual\s+)?"
        r"(?:style|styled|inspired|aesthetic|look)\b",
        r"\b(?:style|aesthetic|look)\s+(?:of|like)\s+(?:the\s+)?"
        r"(?:studio\s+)?"
        + studio
        + r"\b",
        r"\b(?:inspired\s+by|imitating|imitate|resembling)\s+(?:the\s+)?"
        r"(?:studio\s+)?"
        + studio
        + r"\b",
    )
    if any(re.search(pattern, normalized) for pattern in style_reference_patterns):
        raise ValueError("prompt names a copyrighted studio style")


def _finalize_prompt(prompt: str, *, role: str) -> str:
    common = (
        "Do not depict copyrighted characters and do not imitate a named studio, "
        "film, living artist, or trademarked character. No logo, watermark, border, "
        "collage panels, duplicate subjects, or unintended extra objects."
    )
    if role == "category_selector":
        policy = (
            "No child mascot, human figure, text, letters, numbers, title, or caption."
        )
    elif role == "quiz_tile":
        policy = (
            "Render only the two explicitly requested text elements. No other text, "
            "letters, numbers, labels, or captions. No extra limbs or malformed anatomy."
        )
    else:
        policy = (
            "No text, letters, numbers, labels, captions, competing answer subjects, "
            "or incorrect physical details. Show one clear focal representation."
        )
    return f"{prompt.strip()}\n\nMandatory exclusions: {common} {policy}"


def _validate_selector_prompt(
    response: SingleImagePromptResponse, *, category: str
) -> None:
    _validate_common_prompt(response.prompt)


def _canonical_subject_token(token: str) -> str:
    if len(token) > 4 and token.endswith("ies"):
        return f"{token[:-3]}y"
    if len(token) > 4 and token.endswith("oes"):
        return token[:-2]
    if len(token) > 3 and token.endswith("s") and not token.endswith("ss"):
        return token[:-1]
    return token


def _prompt_names_subject(prompt: str, label: str) -> bool:
    normalized_prompt = normalize_text(prompt)
    normalized_label = normalize_text(label)
    candidates = (normalized_label, *SUBJECT_LABEL_ALIASES.get(normalized_label, ()))
    prompt_tokens = {
        _canonical_subject_token(token) for token in normalized_prompt.split()
    }
    for candidate in candidates:
        if re.search(rf"\b{re.escape(candidate)}\b", normalized_prompt):
            return True
        candidate_tokens = {
            _canonical_subject_token(token) for token in candidate.split()
        }
        if candidate_tokens and candidate_tokens.issubset(prompt_tokens):
            return True
    return False


def _validate_tile_prompt(
    response: SingleImagePromptResponse,
    *,
    difficulty: Literal["beginner", "intermediate"],
    display_title: str,
    set_number: int,
    source_labels: list[str],
) -> None:
    _validate_common_prompt(response.prompt)
    normalized = normalize_text(response.prompt)
    exact_title = f"{display_title} {set_number}"
    if exact_title not in response.prompt or difficulty.upper() not in response.prompt:
        raise ValueError("tile prompt omits required exact title or difficulty text")
    included = sum(_prompt_names_subject(normalized, label) for label in source_labels)
    required = max(1, math.ceil(len(source_labels) * 0.6))
    if included < required:
        raise ValueError(
            f"tile prompt names only {included}/{len(source_labels)} approved brief "
            f"subjects; at least {required} are required"
        )


def _validate_tile_briefs(
    response: TilePromptBriefPlan,
    *,
    tile_requests: list[TilePromptRequest],
) -> None:
    expected = {
        item.asset_id: (item.difficulty, item.set_number)
        for item in tile_requests
    }
    actual = {brief.asset_id for brief in response.briefs}
    if actual != set(expected):
        raise ValueError("tile briefs do not cover the exact requested asset IDs")
    themes: set[str] = set()
    for brief in response.briefs:
        if (brief.difficulty, brief.set_number) != expected[brief.asset_id]:
            raise ValueError(f"tile brief metadata mismatch for {brief.asset_id}")
        theme = normalize_text(brief.scene_theme)
        if theme in themes:
            raise ValueError("tile brief scene themes must be distinct")
        themes.add(theme)
        activity = normalize_text(brief.child_activity)
        if brief.difficulty == "beginner" and not any(
            age in activity for age in ("3", "4", "5", "young", "preschool")
        ):
            raise ValueError(f"beginner child age is unclear in {brief.asset_id}")
        if brief.difficulty == "intermediate" and not any(
            age in activity for age in ("8", "9", "10", "older", "preteen")
        ):
            raise ValueError(f"intermediate child age is unclear in {brief.asset_id}")


def _validate_answer_prompt(
    item: AnswerImagePromptResponse, *, expected_label: str
) -> None:
    _validate_common_prompt(item.prompt)
    if not _prompt_names_subject(item.prompt, expected_label):
        raise ValueError(f"answer prompt does not name exact subject {expected_label}")


def _sanitize_answer_prompt_subject(
    item: AnswerImagePromptResponse, *, expected_label: str
) -> None:
    if not _prompt_names_subject(item.prompt, expected_label):
        item.prompt = (
            f"Exact intended answer subject: {expected_label}. {item.prompt}"
        )
    _validate_answer_prompt(item, expected_label=expected_label)


def apply_category_prompt_plan(
    *, plan: ImagePromptPlan, category_spec_path: Path
) -> OpenAIImageSpecDocument:
    document = OpenAIImageSpecDocument.model_validate_json(
        category_spec_path.read_text(encoding="utf-8")
    )
    prompts = {
        asset.asset_id: asset.prompt
        for asset in plan.assets
        if asset.role in {"category_selector", "quiz_tile"}
    }
    updated = []
    for asset in document.assets:
        prompt = prompts.get(asset.asset_id)
        updated.append(
            asset
            if prompt is None
            else asset.model_copy(
                update={"prompt": prompt, "review_status": "pending_generation"}
            )
        )
    result = document.model_copy(
        update={
            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
            "assets": updated,
        }
    )
    write_image_spec(category_spec_path, result)
    return result


def load_answer_prompt_overrides(
    path: Path, *, include_pending: bool = False
) -> dict[str, str]:
    plan = ImagePromptPlan.model_validate_json(path.read_text(encoding="utf-8"))
    return {
        asset.asset_id.removeprefix("answer_"): asset.prompt
        for asset in plan.assets
        if asset.role == "answer_image"
        and asset.asset_id.startswith("answer_")
        and (include_pending or asset.review_status == "approved")
    }


def generate_qwen_image_prompt_plan(
    *,
    category: str,
    display_title: str,
    category_guidance: str,
    category_root: Path,
    subjects: list[PromptSubject],
    client: VLLMClient,
    endpoint: str,
    model: str,
    roles: set[str],
    base_seed: int = DEFAULT_PROMPT_SEED,
    answer_batch_size: int = 20,
    answer_limit: int | None = None,
    answer_keys: set[str] | None = None,
    tile_asset_ids: set[str] | None = None,
    tile_requests: list[TilePromptRequest] | None = None,
    review_answers: bool = True,
    refresh_tile_briefs: bool = False,
    retries: int = 2,
    force: bool = False,
    progress: Callable[[str], None] | None = None,
    on_batch_committed: Callable[[ImagePromptPlan, set[str]], None] | None = None,
) -> ImagePromptPlan:
    plan_path = category_root / "image-prompt-plan.json"
    plan = _load_or_create_plan(
        path=plan_path,
        category=category,
        display_title=display_title,
        category_guidance=category_guidance,
        endpoint=endpoint,
        model=model,
        base_seed=base_seed,
    )
    plan.qwen_endpoint = endpoint
    plan.qwen_model = model
    plan.base_seed = base_seed
    plan.category_guidance = category_guidance
    call_root = category_root / "prompt-planning"

    if "selector" in roles:
        asset_id = f"{slugify(category)}_category_selector"
        seed = stable_prompt_seed(asset_id, base_seed)
        response = _request_json(
            client=client,
            model=model,
            response_type=SingleImagePromptResponse,
            schema_name="category_selector_image_prompt",
            prompt=selector_planning_prompt(
                category=category, category_guidance=category_guidance
            ),
            seed=seed,
            call_path=call_root / "selector" / f"{asset_id}.json",
            retries=retries,
            force=force,
            validate=lambda item: _validate_selector_prompt(
                item, category=category
            ),
            progress=progress,
        )
        _upsert(
            plan,
            PlannedImagePrompt(
                asset_id=asset_id,
                role="category_selector",
                target_provider="openai",
                seed=seed,
                prompt=_finalize_prompt(response.prompt, role="category_selector"),
                exact_text=[],
                visual_summary=response.visual_summary,
            ),
        )
        _write_model(plan_path, plan)
        if on_batch_committed:
            on_batch_committed(plan, {asset_id})

    if "tiles" in roles:
        tile_requests = tile_requests or default_tile_requests()
        tile_subject_labels = sorted(
            {item.label for item in subjects}, key=str.casefold
        )
        brief_seed = stable_prompt_seed("all_quiz_tile_briefs", base_seed)
        brief_plan = _request_json(
            client=client,
            model=model,
            response_type=TilePromptBriefPlan,
            schema_name="quiz_tile_visual_briefs",
            prompt=tile_brief_planning_prompt(
                category=category,
                tile_requests=tile_requests,
                subject_labels=tile_subject_labels,
                category_guidance=category_guidance,
            ),
            seed=brief_seed,
            call_path=call_root / "tiles" / "briefs.json",
            retries=retries,
            force=refresh_tile_briefs,
            validate=lambda item: _validate_tile_briefs(
                item, tile_requests=tile_requests
            ),
            progress=progress,
        )
        briefs = {brief.asset_id: brief for brief in brief_plan.briefs}
        prior_summaries = [
            item.visual_summary for item in plan.assets if item.role == "quiz_tile"
        ]
        for tile_request in tile_requests:
            number = tile_request.set_number
            asset_id = tile_request.asset_id
            if tile_asset_ids is not None and asset_id not in tile_asset_ids:
                continue
            brief = briefs[asset_id]
            seed = stable_prompt_seed(asset_id, base_seed)
            response = _request_json(
                client=client,
                model=model,
                response_type=SingleImagePromptResponse,
                schema_name="quiz_tile_image_prompt",
                prompt=tile_planning_prompt(
                    category=category,
                    display_title=display_title,
                    difficulty=tile_request.difficulty,
                    brief=brief,
                    category_guidance=category_guidance,
                    set_number=number,
                    seed=seed,
                    prior_summaries=prior_summaries,
                ),
                seed=seed,
                call_path=call_root / "tiles" / f"{asset_id}.json",
                retries=retries,
                force=force,
                validate=lambda item: _validate_tile_prompt(
                    item,
                    difficulty=tile_request.difficulty,
                    display_title=display_title,
                    set_number=number,
                    source_labels=brief.subjects,
                ),
                progress=progress,
            )
            _upsert(
                plan,
                PlannedImagePrompt(
                    asset_id=asset_id,
                    role="quiz_tile",
                    target_provider="openai",
                    seed=seed,
                    prompt=_finalize_prompt(response.prompt, role="quiz_tile"),
                    exact_text=[
                        f"{display_title} {number}",
                        tile_request.difficulty.upper(),
                    ],
                    source_labels=brief.subjects,
                    visual_summary=response.visual_summary,
                    difficulty=tile_request.difficulty,
                    set_number=number,
                ),
            )
            prior_summaries.append(response.visual_summary)
            _write_model(plan_path, plan)
            if on_batch_committed:
                on_batch_committed(plan, {asset_id})

    if "answers" in roles:
        existing = {
            item.asset_id for item in plan.assets if item.role == "answer_image"
        }
        selected = [
            subject
            for subject in subjects
            if (answer_keys is None or subject.subject_key in answer_keys)
            and (force or f"answer_{subject.subject_key}" not in existing)
        ]
        if answer_keys is not None:
            found = {subject.subject_key for subject in selected} | {
                asset_id.removeprefix("answer_") for asset_id in existing
            }
            missing = sorted(answer_keys - found)
            if missing:
                raise ValueError(f"answer keys not found: {', '.join(missing)}")
        if answer_limit is not None:
            selected = selected[:answer_limit]
        for offset in range(0, len(selected), answer_batch_size):
            batch = selected[offset : offset + answer_batch_size]
            source = [(f"answer_{item.subject_key}", item.label) for item in batch]
            batch_key = "_".join(asset_id for asset_id, _ in source)
            batch_hash = hashlib.sha256(batch_key.encode()).hexdigest()[:12]
            seed = stable_prompt_seed(f"answer_batch_{batch_hash}", base_seed)

            def validate_answer_batch(
                response: AnswerImagePromptBatchResponse,
            ) -> None:
                expected = {asset_id for asset_id, _ in source}
                actual = {item.asset_id for item in response.prompts}
                if actual != expected:
                    raise ValueError("answer response does not cover the exact input IDs")
                source_labels = dict(source)
                for item in response.prompts:
                    _sanitize_answer_prompt_subject(
                        item, expected_label=source_labels[item.asset_id]
                    )

            response = _request_json(
                client=client,
                model=model,
                response_type=AnswerImagePromptBatchResponse,
                schema_name="answer_image_prompts",
                prompt=answer_batch_planning_prompt(
                    category=category,
                    assets=source,
                    category_guidance=category_guidance,
                ),
                seed=seed,
                call_path=call_root / "answers" / f"batch_{batch_hash}.json",
                retries=retries,
                force=force,
                validate=validate_answer_batch,
                progress=progress,
            )
            if review_answers:
                review_seed = stable_prompt_seed(
                    f"answer_review_{batch_hash}", base_seed
                )
                response = _request_json(
                    client=client,
                    model=model,
                    response_type=AnswerImagePromptBatchResponse,
                    schema_name="reviewed_answer_image_prompts",
                    prompt=answer_batch_review_prompt(
                        category=category, assets=source, draft=response
                    ),
                    seed=review_seed,
                    call_path=(
                        call_root / "answers" / f"review_{batch_hash}.json"
                    ),
                    retries=retries,
                    force=force,
                    validate=validate_answer_batch,
                    progress=progress,
                )
            labels = dict(source)
            committed_ids: set[str] = set()
            for item in response.prompts:
                committed_ids.add(item.asset_id)
                _upsert(
                    plan,
                    PlannedImagePrompt(
                        asset_id=item.asset_id,
                        role="answer_image",
                        target_provider="imagestudio",
                        seed=stable_prompt_seed(item.asset_id, base_seed),
                        prompt=_finalize_prompt(item.prompt, role="answer_image"),
                        negative_prompt=(
                            "text, letters, numbers, caption, logo, watermark, border, "
                            "duplicate subject, unrelated objects, blur, incorrect details"
                        ),
                        source_labels=[labels[item.asset_id]],
                        visual_summary="; ".join(item.identity_cues),
                    ),
                )
            _write_model(plan_path, plan)
            if on_batch_committed:
                on_batch_committed(plan, committed_ids)

    return plan
