from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .models import GenerationRequest, PlanDocument


SYSTEM_PROMPT = """You are a senior learning-game designer for children.
Create one production-oriented plan for a mobile HTML quiz. The response is constrained
by a JSON schema, so supply every field and no additional fields.

Rules:
- Keep language concrete, friendly, age-appropriate, and factually correct.
- Create exactly the requested number of multiple-choice questions and options.
- Give every question a different learning objective, interaction idea, and novelty_key.
- Avoid repeating question wording or merely swapping answer choices.
- Distractors must be plausible but unambiguously wrong.
- Ensure the correct option position varies across questions.
- Option labels contain only the short answer, never explanations, correctness hints,
  sentences, or punctuation. Keep each label at six words or fewer.
- Design for a narrow portrait phone and touch targets of at least 44 px.
- Fill all five named layout regions: header, progress, question, answers, feedback.
- Images must carry no lettering, labels, numbers, logos, UI text, or watermarks.
- Asset prompts target a children's polished 2D illustration model. Describe subject,
  composition, lighting, palette, camera, clean edges, and empty space where relevant.
- The background, answer frame, progress track, and progress marker are reusable UI
  assets. Answer labels will be HTML text over a transparent, stretchable frame.
- Every asset prompt must describe visible, polished raster artwork. Never ask the
  image model for an empty shape, no fill, CSS styling, or a bare geometric primitive.
- Make backgrounds portrait, answer frames at least 3:1 wide, progress tracks at
  least 4:1 wide, and progress markers square. Frames and tracks need visible color,
  surface treatment, borders, and depth while keeping transparent surroundings.
- Every question needs its own question_illustration asset with reuse_scope question.
- Make question artwork reveal the intended concept without accidentally showing text.
- Use visual variety beyond a single-hue palette while maintaining strong contrast.
- Keep asset identifiers and novelty keys lowercase snake_case.
"""


def load_history(history_dir: Path, *, limit: int = 20) -> list[dict[str, Any]]:
    if not history_dir.exists():
        return []
    candidates = sorted(
        history_dir.glob("*.json"), key=lambda path: path.stat().st_mtime, reverse=True
    )
    history: list[dict[str, Any]] = []
    for path in candidates[:limit]:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            document = PlanDocument.model_validate(data)
            plan = document.plan
            history.append(
                {
                    "category": plan.brief.category,
                    "subject": plan.brief.subject,
                    "theme_name": plan.visual_design.theme_name,
                    "question_ideas": [
                        {
                            "novelty_key": question.novelty_key,
                            "learning_objective": question.learning_objective,
                            "prompt_text": question.prompt_text,
                        }
                        for question in plan.questions
                    ],
                }
            )
        except (OSError, TypeError, ValueError, json.JSONDecodeError):
            continue
    return history


def build_user_prompt(
    request: GenerationRequest, history: list[dict[str, Any]]
) -> str:
    payload: dict[str, Any] = {
        "request": request.model_dump(),
        "creative_instruction": (
            "Build a cohesive quiz around the requested subject. Use varied question "
            "concepts such as recognition, behavior, context, purpose, sequence, or a "
            "surprising fact when they suit the category."
        ),
    }
    if history:
        payload["prior_plans_to_avoid_repeating"] = history
    else:
        payload["prior_plans_to_avoid_repeating"] = []
    return "Generate the quiz plan from this JSON input:\n" + json.dumps(
        payload, ensure_ascii=True, indent=2
    )
