from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Callable

from openai import APIError, OpenAI

from .visual_bank import (
    GeneratedVisualBank,
    VisualBankDocument,
    VisualDifficulty,
    write_model,
)


DEFAULT_OPENAI_MODEL = "gpt-5.6-luna"


class OpenAIBankError(RuntimeError):
    """Raised when OpenAI does not return a usable visual question bank."""


def _load_saved_response(path: Path) -> tuple[GeneratedVisualBank, str]:
    payload = json.loads(path.read_text(encoding="utf-8"))
    for output in payload.get("output", []):
        for content in output.get("content", []):
            if content.get("type") == "output_text" and content.get("text"):
                return (
                    GeneratedVisualBank.model_validate_json(content["text"]),
                    payload["id"],
                )
    raise OpenAIBankError(f"no structured output text found in {path}")


def resolve_openai_token(explicit: str | None = None) -> str:
    token = explicit or os.getenv("OPENAI_API_KEY") or os.getenv("OPENAI_TOKEN")
    if not token:
        raise OpenAIBankError(
            "OpenAI credential is missing; source ~/.profile or set "
            "OPENAI_API_KEY/OPENAI_TOKEN"
        )
    return token


def bank_prompt(*, category: str, difficulty: VisualDifficulty, count: int) -> str:
    rubric = (
        "Beginner questions use familiar animals and one direct, observable or "
        "widely taught identifying fact for children aged about 5 to 8."
        if difficulty == "beginner"
        else
        "Intermediate questions use a distinctive adaptation, behavior, habitat, "
        "diet, anatomy, or life-cycle fact for children aged about 8 to 11."
    )
    return f"""Create exactly {count} independent visual multiple-choice questions
for the {category} category at {difficulty} difficulty. {rubric}

Every question must:
- begin with "Which animal", "Which of these animals", "Name an animal", or
  "Name the animal";
- be answered by identifying one animal from a deterministic factual clue;
- contain exactly four distinct named animals as choices;
- have exactly one defensible correct choice under a natural reading;
- use choices that can each be represented by one clear animal image;
- avoid subjective language, disputed records, vague clues, trick questions, and
  time-sensitive claims;
- use plausible distractors that do not also satisfy the clue;
- explicitly name the correct animal in a concise educational explanation.

Category boundary: Animals and Birds are separate product categories. Do not create
questions about birds and do not use any bird as an answer choice or distractor.

Use stable lowercase snake_case question_id, topic_key, and animal_key values.
Use question IDs beginning with {category.casefold()}_{difficulty}_. Test a different
fact in every question. Do not add layout, image prompts, presentation, or audio.
"""


def generate_openai_bank(
    *,
    category: str,
    difficulty: VisualDifficulty,
    count: int,
    output_dir: Path,
    model: str = DEFAULT_OPENAI_MODEL,
    api_key: str | None = None,
    timeout_seconds: float = 900.0,
    max_invalid: int = 5,
    force: bool = False,
    reingest: bool = False,
    progress: Callable[[str], None] | None = None,
) -> tuple[VisualBankDocument, Path]:
    bank_path = output_dir / "bank.json"
    if bank_path.exists() and not force and not reingest:
        document = VisualBankDocument.model_validate_json(
            bank_path.read_text(encoding="utf-8")
        )
        if progress:
            progress(f"reusing {bank_path}")
        return document, bank_path

    raw_path = output_dir / "openai-response.json"
    if raw_path.exists() and not force:
        generated, response_id = _load_saved_response(raw_path)
        if len(generated.questions) != count:
            raise OpenAIBankError(
                f"saved response has {len(generated.questions)} questions; "
                f"expected {count}"
            )
        document = VisualBankDocument.from_generated(
            generated,
            source_model=model,
            source_response_id=response_id,
            max_invalid=max_invalid,
        )
        write_model(bank_path, document)
        if progress:
            progress(
                f"recovered {len(document.questions)} questions from {raw_path} "
                f"({len(document.ingestion_rejections)} rejected during ingestion)"
            )
        return document, bank_path

    token = resolve_openai_token(api_key)
    output_dir.mkdir(parents=True, exist_ok=True)
    prompt = bank_prompt(category=category, difficulty=difficulty, count=count)
    (output_dir / "prompt.txt").write_text(prompt, encoding="utf-8")
    if progress:
        progress(f"requesting {count} {difficulty} questions from {model}")
    try:
        with OpenAI(api_key=token, timeout=timeout_seconds) as client:
            response = client.responses.parse(
                model=model,
                instructions=(
                    "You create accurate children's quiz banks. Follow the supplied "
                    "schema exactly and prefer deterministic, well-established facts."
                ),
                input=prompt,
                text_format=GeneratedVisualBank,
                reasoning={"effort": "low"},
                max_output_tokens=max(8_000, count * 260),
                store=False,
            )
    except APIError as exc:
        raise OpenAIBankError(f"OpenAI request failed: {exc}") from exc

    generated = response.output_parsed
    if generated is None:
        raise OpenAIBankError("OpenAI returned no parsed question bank")
    if len(generated.questions) != count:
        raise OpenAIBankError(
            f"OpenAI returned {len(generated.questions)} questions; expected {count}"
        )
    if generated.category.casefold() != category.casefold():
        raise OpenAIBankError("OpenAI returned the wrong category")
    if generated.difficulty != difficulty:
        raise OpenAIBankError("OpenAI returned the wrong difficulty")

    raw_path.write_text(
        json.dumps(
            response.model_dump(mode="json", warnings=False),
            indent=2,
            ensure_ascii=True,
        )
        + "\n",
        encoding="utf-8",
    )
    document = VisualBankDocument.from_generated(
        generated,
        source_model=model,
        source_response_id=response.id,
        max_invalid=max_invalid,
    )
    write_model(bank_path, document)
    if progress:
        progress(
            f"wrote {len(document.questions)} questions to {bank_path} "
            f"({len(document.ingestion_rejections)} rejected during ingestion)"
        )
    return document, bank_path
