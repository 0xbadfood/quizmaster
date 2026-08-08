from __future__ import annotations

from datetime import datetime, timezone
from pathlib import Path
from typing import Callable
from typing import Any

from pydantic import ValidationError

from .client import VLLMClient, VLLMError
from .models import (
    GenerationRequest,
    GeneratorInfo,
    PlanDocument,
    QuizPlan,
)
from .prompts import SYSTEM_PROMPT, build_user_prompt, load_history


class PlanGenerationError(RuntimeError):
    """Raised after all attempts fail to create a valid quiz plan."""


def escape_json_string_controls(value: str) -> tuple[str, int]:
    """Escape illegal control characters occurring inside JSON string literals."""
    output: list[str] = []
    in_string = False
    escaped = False
    replacements = 0
    for character in value:
        if not in_string:
            output.append(character)
            if character == '"':
                in_string = True
            continue
        if escaped:
            output.append(character)
            escaped = False
        elif character == "\\":
            output.append(character)
            escaped = True
        elif character == '"':
            output.append(character)
            in_string = False
        elif ord(character) < 0x20:
            output.append(f"\\u{ord(character):04x}")
            replacements += 1
        else:
            output.append(character)
    return "".join(output), replacements


def generate_plan(
    *,
    client: VLLMClient,
    endpoint: str,
    model: str,
    request: GenerationRequest,
    history_dir: Path | None,
    retries: int,
    progress: Callable[[str], None] | None = None,
    history: list[dict[str, Any]] | None = None,
) -> PlanDocument:
    if history is None:
        history = load_history(history_dir) if history_dir is not None else []
    messages = [
        {"role": "system", "content": SYSTEM_PROMPT},
        {"role": "user", "content": build_user_prompt(request, history)},
    ]
    last_error = "unknown validation error"
    schema = QuizPlan.model_json_schema()

    for attempt in range(1, retries + 2):
        raw_plan: str | None = None
        if progress:
            progress(f"Attempt {attempt}/{retries + 1}: requesting structured plan")
        try:
            raw_plan = client.generate_json(
                model=model,
                messages=messages,
                schema=schema,
                seed=request.seed + attempt - 1,
            )
            raw_plan, control_count = escape_json_string_controls(raw_plan)
            if control_count and progress:
                progress(
                    f"Attempt {attempt}/{retries + 1}: escaped "
                    f"{control_count} illegal JSON control character(s)"
                )
            plan = QuizPlan.model_validate_json(raw_plan)
            document = PlanDocument(
                request=request,
                generator=GeneratorInfo(
                    provider="vllm",
                    endpoint=endpoint,
                    model=model,
                    generated_at_utc=datetime.now(timezone.utc),
                    attempts=attempt,
                    prompt_version="1.0",
                ),
                plan=plan,
            )
            if progress:
                progress(f"Attempt {attempt}/{retries + 1}: plan validated")
            return document
        except (ValidationError, VLLMError) as exc:
            last_error = str(exc)
            if progress:
                summary = " ".join(last_error.split())[:240]
                progress(
                    f"Attempt {attempt}/{retries + 1}: rejected ({summary})"
                )
            if attempt > retries:
                break
            messages.extend(
                [
                    {"role": "assistant", "content": raw_plan}
                    if raw_plan is not None
                    else {
                        "role": "assistant",
                        "content": "The previous generation did not complete.",
                    },
                    {
                        "role": "user",
                        "content": (
                            "Regenerate the complete plan. The previous attempt failed "
                            f"validation:\n{last_error[:4000]}\nCorrect every issue while "
                            "preserving the original request."
                        ),
                    },
                ]
            )

    raise PlanGenerationError(
        f"could not generate a valid plan after {retries + 1} attempts: {last_error}"
    )
