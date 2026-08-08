from __future__ import annotations

import json

from .question_models import CandidateQuestionPool, ContentQuestion, SetGenerationRequest


DRAFTER_SYSTEM_PROMPT = """You draft factual multiple-choice quiz content for children.
Return only the requested JSON. Do not discuss presentation, images, visual design,
audio, layout, or assets.

Rules:
- Produce exactly 14 candidate questions and exactly 3 choices for every question.
- Every question must have one unambiguously correct answer.
- Distractors must be plausible, distinct, and factually incorrect for the question.
- Explicitly name the correct answer in the explanation and explain why it is correct.
- Use a different topic_key and knowledge concept for every question.
- Do not repeat the same fact through different wording.
- Never use "all of the above" or "none of the above".
- Use lowercase snake_case for question_id and topic_key.
- Do not include trick questions, disputed claims, or time-sensitive facts.

Difficulty rubric:
- beginner: familiar recognition, vocabulary, and directly observable facts.
- intermediate: behavior, habitat, adaptations, relationships, and simple inference.
- expert: precise taxonomy, physiology, ecology, evolution, and multi-step reasoning,
  while remaining understandable to an interested child aged roughly 11 to 14.
"""


VALIDATOR_SYSTEM_PROMPT = """You are the independent senior validator and replacer
for children's multiple-choice quiz content. Return only the requested JSON.

Review all 14 candidates for factual correctness, one unambiguous answer, distractor
quality, explanation consistency, difficulty alignment, age appropriateness, and
repetition inside the pool. Select the strongest 10 sound questions. Reject the other
defective candidates with specific issue codes and mark sound unchosen candidates as
reserve. If fewer than 10 candidates are sound, create only enough new replacement
questions to make final_set contain exactly 10 valid questions.

Apply these gates strictly:
- Reject a question whose subject falls outside the requested category. For Animals,
  exclude plants, fungi, bacteria, protists, and other non-animal organisms.
- Reject disputed, oversimplified, or compound answers when any claimed component is
  uncertain. Prefer well-established facts over popular explanations still debated.
- Reject a question that belongs at a lower or higher difficulty, even if it is true.
- Treat familiar names, simple body-part counts, colors, and basic recognition as
  beginner material unless the reasoning required clearly goes beyond recall.
- Do not approve all candidates by default. Rank them and select the strongest ten.

Do not add image, layout, presentation, audio, or asset information. Explicitly name
the correct answer in each explanation. Choice positions will be balanced by the CLI.
Use decision "selected" for candidates included in final_set, "reserve" for sound
candidates not included, and "rejected" for defective candidates. Use issue_codes
["none"] for selected and reserve questions. Rejected candidates must use one or more
specific issue codes. Reviews refer to all 14 candidate question_id values;
replacement questions may use new question_id and topic_key values. Set status to
approved when all final questions were selected from the candidate pool, or revised
when at least one new replacement was required.
"""


PER_QUESTION_VALIDATOR_SYSTEM_PROMPT = """You independently validate one children's
multiple-choice question. Return only the requested JSON. Review the question closely;
do not assume it is valid because another model drafted it.

Reject material factual errors, ambiguous answers, weak distractors, category
mismatches, disputed claims presented as certainty, and real difficulty mismatches.
An answer is acceptable when it is a reasonable, defensible interpretation even if a
more technical qualification exists. Do not reject merely to be pedantic.

Difficulty rubric:
- beginner: familiar recognition, vocabulary, and directly observable facts.
- intermediate: behavior, habitat, adaptations, relationships, and simple inference.
- expert: precise taxonomy, physiology, ecology, evolution, or multi-step reasoning
  suitable for an interested child aged roughly 11 to 14.

The prior bank is authoritative for originality. Reject a candidate that tests the
same fact as an existing question even when wording and topic_key differ. A different
fact about the same animal is allowed. Identify the candidate only by its exact
candidate_question_id; do not copy or rewrite the question in the response.

Assess all three choices individually in choice1, choice2, choice3 order. Mark a choice
correct when it truthfully answers the question under a natural reading, incorrect when
it does not, or ambiguous when it could reasonably be defended. A plausible distractor
must still be incorrect; a relevant true statement is not an effective distractor.
Accept only when exactly the declared correct choice is assessed correct, neither
distractor is ambiguous, difficulty_assessment is aligned, factual_confidence and
distractor_quality are at least 4, and selection_score is at least 70.

Calibrate selection_score: 90-100 is exceptional, 80-89 is strong, 70-79 is acceptable,
and below 70 must be rejected. Do not give every acceptable question the same score.
"""


REPLACER_SYSTEM_PROMPT = """You create one replacement multiple-choice question for
a children's quiz. Return only the requested JSON. The replacement must match the
requested category and difficulty, have exactly three choices and one unambiguous
answer, explicitly name the answer in its explanation, and avoid every fact already
present in the supplied question bank. Do not include images or presentation details.
Use a new lowercase snake_case question_id and topic_key. Avoid disputed claims,
trick questions, and time-sensitive facts.
"""


def build_drafter_prompt(
    request: SetGenerationRequest,
    prior_questions: list[dict[str, str]] | None = None,
) -> str:
    return "Draft this quiz set:\n" + json.dumps(
        {
            "category": request.category,
            "difficulty": request.difficulty,
            "language": request.language,
            "set_number": request.set_number,
            "candidate_question_count": 14,
            "final_question_count": 10,
            "choices_per_question": 3,
            "prior_questions_to_avoid": prior_questions or [],
        },
        indent=2,
        ensure_ascii=True,
    )


def build_per_question_validator_prompt(
    request: SetGenerationRequest,
    candidate: ContentQuestion,
    bank: list[dict[str, str]],
    local_duplicate_matches: list[dict[str, str]],
) -> str:
    return "Validate this candidate question:\n" + json.dumps(
        {
            "request": request.model_dump(),
            "candidate": candidate.model_dump(mode="json"),
            "local_duplicate_matches": local_duplicate_matches,
            "prior_question_bank": bank,
        },
        indent=2,
        ensure_ascii=True,
    )


def build_replacement_prompt(
    request: SetGenerationRequest,
    bank: list[dict[str, str]],
    rejected_questions: list[dict[str, str]],
    replacement_number: int,
) -> str:
    return "Create one replacement question:\n" + json.dumps(
        {
            "request": request.model_dump(),
            "replacement_number": replacement_number,
            "prior_question_bank": bank,
            "rejected_questions_to_avoid": rejected_questions,
        },
        indent=2,
        ensure_ascii=True,
    )


def build_validator_prompt(
    request: SetGenerationRequest, candidate: CandidateQuestionPool
) -> str:
    return "Validate and, where required, replace questions in this set:\n" + json.dumps(
        {
            "request": request.model_dump(),
            "candidate_set": candidate.model_dump(mode="json"),
        },
        indent=2,
        ensure_ascii=True,
    )
