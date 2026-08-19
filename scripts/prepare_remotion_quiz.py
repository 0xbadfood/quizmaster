#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import shutil
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
BUNDLE_ROOT = ROOT / "dist/category_bundles"
RENDERER_ROOT = ROOT / "video_renderer"
STUDIO_ROOT = ROOT / "visual_quiz_qwen"
GLOBAL_VIDEO_ROOT = STUDIO_ROOT / "global/assets/video"
ORIENTATION_SIZE = {
    "portrait": (1080, 1920),
    "landscape": (1920, 1080),
}


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _copy(source: Path, relative_target: str) -> str:
    target = RENDERER_ROOT / "public" / relative_target
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return relative_target


def parse_question_selection(value: str, total: int = 10) -> list[int]:
    selection: set[int] = set()
    text = value.strip().lower()
    if text in {"", "all"}:
        return list(range(1, total + 1))
    for part in text.split(","):
        token = part.strip()
        if not token:
            raise ValueError("question selection contains an empty item")
        if "-" in token:
            pieces = token.split("-", 1)
            try:
                start, end = (int(piece) for piece in pieces)
            except ValueError as exc:
                raise ValueError(f"invalid question range: {token}") from exc
            if start > end:
                raise ValueError(f"question range is reversed: {token}")
            selection.update(range(start, end + 1))
        else:
            try:
                selection.add(int(token))
            except ValueError as exc:
                raise ValueError(f"invalid question number: {token}") from exc
    invalid = sorted(number for number in selection if number < 1 or number > total)
    if invalid:
        raise ValueError(
            f"question numbers must be between 1 and {total}: "
            + ", ".join(str(number) for number in invalid)
        )
    return sorted(selection)


def _studio_landscape_background(category: str) -> Path | None:
    root = STUDIO_ROOT / category
    spec_path = root / "category-image-spec.json"
    manifest_path = root / "category-image-manifest.json"
    if not spec_path.is_file() or not manifest_path.is_file():
        return None
    spec = _read_json(spec_path)
    manifest = _read_json(manifest_path)
    asset = next(
        (
            item
            for item in spec.get("assets", [])
            if item.get("role") == "video_background_landscape"
        ),
        None,
    )
    if not isinstance(asset, dict):
        return None
    record = manifest.get("assets", {}).get(asset.get("asset_id"), {})
    if not isinstance(record, dict) or record.get("status") not in {
        "approved",
        "generated_pending_review",
    }:
        return None
    candidate = root / str(asset.get("file") or "")
    return candidate if candidate.is_file() else None


def _resolve_background(
    *,
    category: str,
    orientation: str,
    content: Path,
    category_document: dict[str, Any],
) -> Path:
    presentation = category_document.get("presentation", {})
    key = (
        "runtime_background"
        if orientation == "portrait"
        else "video_background_landscape"
    )
    relative = presentation.get(key)
    if relative:
        candidate = content / str(relative)
        if candidate.is_file():
            return candidate
    if orientation == "landscape":
        candidate = _studio_landscape_background(category)
        if candidate is not None:
            return candidate
        raise ValueError(
            "landscape background image is not available; generate it in "
            f"Visuals for category '{category}' before creating a landscape video"
        )
    raise ValueError(f"portrait runtime background is missing for category '{category}'")


def _copy_presentation_assets(
    *, content: Path, category_document: dict[str, Any]
) -> dict[str, Any]:
    presentation = category_document.get("presentation", {})
    asset_names = {
        "progressPlaque": "video_progress_plaque",
        "questionFrame": "video_question_frame",
        "answerFrame": "video_answer_frame",
        "explanationFrame": "video_explanation_frame",
    }
    copied: dict[str, Any] = {}
    for output_key, asset_id in asset_names.items():
        relative = presentation.get(asset_id)
        source = content / str(relative) if relative else None
        if source is None or not source.is_file():
            source = GLOBAL_VIDEO_ROOT / f"{asset_id}.webp"
        if not source.is_file():
            raise ValueError(f"reusable video asset is missing: {asset_id}")
        copied[output_key] = _copy(source, f"quiz/ui/{asset_id}.webp")
    badges: list[str] = []
    bundle_badges = presentation.get("video_badges", {})
    for color in ("purple", "green", "orange", "blue"):
        asset_id = f"video_badge_{color}"
        relative = bundle_badges.get(color) if isinstance(bundle_badges, dict) else None
        source = content / str(relative) if relative else None
        if source is None or not source.is_file():
            source = GLOBAL_VIDEO_ROOT / f"{asset_id}.webp"
        if not source.is_file():
            raise ValueError(f"reusable video asset is missing: {asset_id}")
        badges.append(_copy(source, f"quiz/ui/{asset_id}.webp"))
    copied["badges"] = badges
    return copied


def prepare(
    category: str,
    difficulty: str,
    number: int,
    *,
    orientation: str = "portrait",
    question_numbers: list[int] | None = None,
) -> Path:
    if orientation not in ORIENTATION_SIZE:
        raise ValueError(f"unsupported orientation: {orientation}")
    pointer = _read_json(BUNDLE_ROOT / category / "current.json")
    version = int(pointer["bundle_version"])
    content = BUNDLE_ROOT / category / f"versions/{version:06d}/content"
    category_document = _read_json(content / "category.json")
    quiz_record = next(
        (
            item
            for item in category_document["quizzes"]
            if item["difficulty"] == difficulty and int(item["number"]) == number
        ),
        None,
    )
    if quiz_record is None:
        raise ValueError(f"quiz not found: {category}/{difficulty}/{number}")

    quiz = _read_json(content / quiz_record["questions_file"])
    if len(quiz["questions"]) != 10:
        raise ValueError("video rendering requires quiz sets with exactly ten questions")
    selected_numbers = question_numbers or list(range(1, 11))
    invalid = sorted(number for number in selected_numbers if number < 1 or number > 10)
    if invalid:
        raise ValueError(f"question numbers must be between 1 and 10: {invalid}")
    audio_manifest = _read_json(content / "source/category-audio-manifest.json")

    public_quiz = RENDERER_ROOT / "public/quiz"
    if public_quiz.exists():
        shutil.rmtree(public_quiz)
    public_quiz.mkdir(parents=True)

    background_source = _resolve_background(
        category=category,
        orientation=orientation,
        content=content,
        category_document=category_document,
    )
    background_suffix = background_source.suffix.lower() or ".png"
    background = _copy(background_source, f"quiz/background{background_suffix}")
    _copy(
        RENDERER_ROOT / "assets/timer-five-seconds.mp3",
        "quiz/timer-five-seconds.mp3",
    )
    presentation_assets = _copy_presentation_assets(
        content=content, category_document=category_document
    )

    copied_answers: dict[str, str] = {}
    questions = []
    for question_number in selected_numbers:
        question = quiz["questions"][question_number - 1]
        question_id = question["question_id"]
        audio = audio_manifest["questions"].get(question_id)
        if not audio:
            raise ValueError(f"audio manifest is missing {question_id}")
        for audit_key in ("question_audit", "explanation_audit"):
            audit = audio.get(audit_key, {})
            if audit.get("status") not in {"passed", "manually_accepted"}:
                raise ValueError(f"{question_id} has unaudited {audit_key}")

        choices = []
        for choice in question["choices"]:
            answer_key = choice["animal_key"]
            if answer_key not in copied_answers:
                source_relative = quiz["answer_assets"][answer_key]
                copied_answers[answer_key] = _copy(
                    content / source_relative,
                    f"quiz/answers/{answer_key}.webp",
                )
            choices.append(
                {
                    "choiceId": choice["choice_id"],
                    "label": choice["label"],
                    "image": copied_answers[answer_key],
                }
            )

        question_audio = _copy(
            content / question["audio"]["question"],
            f"quiz/audio/{question_id}-question.mp3",
        )
        explanation_audio = _copy(
            content / question["audio"]["explanation"],
            f"quiz/audio/{question_id}-explanation.mp3",
        )
        questions.append(
            {
                "questionId": question_id,
                "questionNumber": question_number,
                "question": question["question"],
                "explanation": question["explanation"],
                "correctChoiceId": question["correct_choice_id"],
                "questionAudio": question_audio,
                "explanationAudio": explanation_audio,
                "questionAudioSeconds": audio["question_audit"][
                    "audio_duration_seconds"
                ],
                "explanationAudioSeconds": audio["explanation_audit"][
                    "audio_duration_seconds"
                ],
                "choices": choices,
            }
        )

    width, height = ORIENTATION_SIZE[orientation]
    generated = {
        "schemaVersion": "quiz_video_input_v1",
        "category": category_document["category"]["name"],
        "title": quiz_record["title"],
        "difficulty": difficulty.title(),
        "quizId": quiz_record["quiz_id"],
        "width": width,
        "height": height,
        "fps": 30,
        "background": background,
        "timerAudio": "quiz/timer-five-seconds.mp3",
        "presentation": presentation_assets,
        "totalQuestions": 10,
        "questions": questions,
    }
    output = RENDERER_ROOT / "src/generated-quiz.json"
    output.write_text(
        json.dumps(generated, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"Prepared {quiz_record['quiz_id']} from bundle v{version} with "
        f"{len(questions)} questions and {len(copied_answers)} answer images "
        f"for {orientation} rendering."
    )
    return output


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Prepare one published quiz set for the Remotion prototype."
    )
    parser.add_argument("--category", default="geography")
    parser.add_argument(
        "--difficulty", choices=("beginner", "intermediate"), default="beginner"
    )
    parser.add_argument("--number", type=int, default=1)
    parser.add_argument(
        "--orientation", choices=tuple(ORIENTATION_SIZE), default="portrait"
    )
    parser.add_argument(
        "--questions",
        default="1-10",
        help="Question range or list, for example 1-10 or 1,3-5.",
    )
    args = parser.parse_args()
    prepare(
        args.category,
        args.difficulty,
        args.number,
        orientation=args.orientation,
        question_numbers=parse_question_selection(args.questions),
    )


if __name__ == "__main__":
    main()
