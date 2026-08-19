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


def _read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def _copy(source: Path, relative_target: str) -> str:
    target = RENDERER_ROOT / "public" / relative_target
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)
    return relative_target


def prepare(category: str, difficulty: str, number: int) -> Path:
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
        raise ValueError("Remotion prototype requires exactly ten questions")
    audio_manifest = _read_json(content / "source/category-audio-manifest.json")

    public_quiz = RENDERER_ROOT / "public/quiz"
    if public_quiz.exists():
        shutil.rmtree(public_quiz)
    public_quiz.mkdir(parents=True)

    background_source = content / category_document["presentation"]["runtime_background"]
    _copy(background_source, "quiz/background.png")
    _copy(ROOT / "visual_quiz_qwen/global/audio/correct_chime.mp3", "quiz/correct.mp3")

    copied_answers: dict[str, str] = {}
    questions = []
    for question in quiz["questions"]:
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

    generated = {
        "schemaVersion": "quiz_video_input_v1",
        "category": category_document["category"]["name"],
        "title": quiz_record["title"],
        "difficulty": difficulty.title(),
        "quizId": quiz_record["quiz_id"],
        "width": 1080,
        "height": 1920,
        "fps": 30,
        "background": "quiz/background.png",
        "correctSfx": "quiz/correct.mp3",
        "questions": questions,
    }
    output = RENDERER_ROOT / "src/generated-quiz.json"
    output.write_text(
        json.dumps(generated, indent=2, ensure_ascii=True) + "\n",
        encoding="utf-8",
    )
    print(
        f"Prepared {quiz_record['quiz_id']} from bundle v{version} with "
        f"{len(questions)} questions and {len(copied_answers)} answer images."
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
    args = parser.parse_args()
    prepare(args.category, args.difficulty, args.number)


if __name__ == "__main__":
    main()
