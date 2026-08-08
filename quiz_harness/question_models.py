from __future__ import annotations

import re
from typing import Annotated, Literal

from pydantic import Field, model_validator

from .models import Identifier, StrictModel


Difficulty = Literal["beginner", "intermediate", "expert"]
ChoiceId = Literal["choice1", "choice2", "choice3"]


def normalize_text(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


class SetGenerationRequest(StrictModel):
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: Difficulty
    language: Annotated[str, Field(min_length=2, max_length=30)] = "English"
    set_number: Annotated[int, Field(ge=1, le=999)]
    seed: int


class QuestionChoice(StrictModel):
    choice_id: ChoiceId
    text: Annotated[str, Field(min_length=1, max_length=80)]


class ContentQuestion(StrictModel):
    question_id: Identifier
    topic_key: Identifier
    question: Annotated[str, Field(min_length=10, max_length=240)]
    choices: Annotated[list[QuestionChoice], Field(min_length=3, max_length=3)]
    correct_choice_id: ChoiceId
    explanation: Annotated[str, Field(min_length=20, max_length=600)]

    @model_validator(mode="after")
    def validate_choices(self) -> ContentQuestion:
        ids = [choice.choice_id for choice in self.choices]
        if ids != ["choice1", "choice2", "choice3"]:
            raise ValueError("choices must be ordered choice1, choice2, choice3")
        texts = [normalize_text(choice.text) for choice in self.choices]
        if len(texts) != len(set(texts)):
            raise ValueError("choice text must be unique within a question")
        forbidden = {"all of the above", "none of the above"}
        if any(text in forbidden for text in texts):
            raise ValueError("all/none of the above choices are not allowed")
        return self


class QuestionSetPayload(StrictModel):
    schema_version: Literal["1.0"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: Difficulty
    questions: Annotated[list[ContentQuestion], Field(min_length=10, max_length=10)]

    @model_validator(mode="after")
    def validate_set(self) -> QuestionSetPayload:
        question_ids = [question.question_id for question in self.questions]
        topic_keys = [question.topic_key for question in self.questions]
        prompts = [normalize_text(question.question) for question in self.questions]
        if len(question_ids) != len(set(question_ids)):
            raise ValueError("question_id values must be unique")
        if len(topic_keys) != len(set(topic_keys)):
            raise ValueError("topic_key values must be unique")
        if len(prompts) != len(set(prompts)):
            raise ValueError("question text must be unique")
        counts = {
            choice_id: sum(
                question.correct_choice_id == choice_id for question in self.questions
            )
            for choice_id in ("choice1", "choice2", "choice3")
        }
        if min(counts.values()) < 2 or max(counts.values()) > 4:
            raise ValueError(
                "correct answers must use each choice position 2 to 4 times"
            )
        return self


class ReviewedQuestionSetPayload(StrictModel):
    schema_version: Literal["1.0"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: Difficulty
    questions: Annotated[list[ContentQuestion], Field(min_length=10, max_length=10)]

    @model_validator(mode="after")
    def validate_set(self) -> ReviewedQuestionSetPayload:
        question_ids = [question.question_id for question in self.questions]
        topic_keys = [question.topic_key for question in self.questions]
        prompts = [normalize_text(question.question) for question in self.questions]
        if len(question_ids) != len(set(question_ids)):
            raise ValueError("question_id values must be unique")
        if len(topic_keys) != len(set(topic_keys)):
            raise ValueError("topic_key values must be unique")
        if len(prompts) != len(set(prompts)):
            raise ValueError("question text must be unique")
        return self


class CandidateQuestionPool(StrictModel):
    schema_version: Literal["1.0"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: Difficulty
    questions: Annotated[list[ContentQuestion], Field(min_length=14, max_length=14)]

    @model_validator(mode="after")
    def validate_pool(self) -> CandidateQuestionPool:
        question_ids = [question.question_id for question in self.questions]
        topic_keys = [question.topic_key for question in self.questions]
        prompts = [normalize_text(question.question) for question in self.questions]
        if len(question_ids) != len(set(question_ids)):
            raise ValueError("question_id values must be unique")
        if len(topic_keys) != len(set(topic_keys)):
            raise ValueError("topic_key values must be unique")
        if len(prompts) != len(set(prompts)):
            raise ValueError("question text must be unique")
        return self


class QuestionReview(StrictModel):
    question_id: Identifier
    decision: Literal["selected", "reserve", "rejected"]
    issue_codes: Annotated[
        list[Literal[
            "none",
            "factual_error",
            "ambiguous_answer",
            "weak_distractor",
            "difficulty_mismatch",
            "category_mismatch",
            "contested_claim",
            "duplicate",
            "internal_repetition",
            "explanation_mismatch",
            "age_inappropriate",
            "weak_question_wording",
        ]],
        Field(min_length=1, max_length=3),
    ]
    rationale: Annotated[str, Field(min_length=5, max_length=300)]


class ValidationResult(StrictModel):
    schema_version: Literal["1.0"]
    status: Literal["approved", "revised"]
    reviews: Annotated[list[QuestionReview], Field(min_length=14, max_length=14)]
    final_set: ReviewedQuestionSetPayload

    @model_validator(mode="after")
    def validate_review_coverage(self) -> ValidationResult:
        reviewed_ids = [review.question_id for review in self.reviews]
        if len(reviewed_ids) != len(set(reviewed_ids)):
            raise ValueError("each candidate question must be reviewed exactly once")
        for review in self.reviews:
            if review.decision in {"selected", "reserve"} and review.issue_codes != ["none"]:
                raise ValueError(
                    "selected and reserve questions must use only the none issue code"
                )
            if review.decision == "rejected" and "none" in review.issue_codes:
                raise ValueError("rejected questions cannot use the none issue code")
        return self


class FinalQuestionSet(StrictModel):
    schema_version: Literal["1.0"]
    set_id: Identifier
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: Difficulty
    language: Annotated[str, Field(min_length=2, max_length=30)]
    questions: Annotated[list[ContentQuestion], Field(min_length=10, max_length=10)]


class ChoiceAssessment(StrictModel):
    choice_id: ChoiceId
    verdict: Literal["correct", "incorrect", "ambiguous"]
    rationale: Annotated[str, Field(min_length=5, max_length=220)]


class PerQuestionValidation(StrictModel):
    schema_version: Literal["1.0"]
    candidate_question_id: Identifier
    decision: Literal["accepted", "rejected"]
    issue_codes: Annotated[
        list[Literal[
            "none",
            "factual_error",
            "ambiguous_answer",
            "weak_distractor",
            "difficulty_mismatch",
            "category_mismatch",
            "contested_claim",
            "duplicate",
            "explanation_mismatch",
            "age_inappropriate",
            "weak_question_wording",
        ]],
        Field(min_length=1, max_length=4),
    ]
    factual_confidence: Annotated[int, Field(ge=1, le=5)]
    difficulty_assessment: Literal["too_easy", "aligned", "too_hard"]
    distractor_quality: Annotated[int, Field(ge=1, le=5)]
    selection_score: Annotated[int, Field(ge=1, le=100)]
    choice_assessments: Annotated[
        list[ChoiceAssessment], Field(min_length=3, max_length=3)
    ]
    rationale: Annotated[str, Field(min_length=10, max_length=500)]

    @model_validator(mode="after")
    def validate_decision(self) -> PerQuestionValidation:
        if self.decision == "accepted" and self.issue_codes != ["none"]:
            raise ValueError("accepted questions must use only the none issue code")
        if self.decision == "rejected" and "none" in self.issue_codes:
            raise ValueError("rejected questions cannot use the none issue code")
        assessment_ids = [item.choice_id for item in self.choice_assessments]
        if assessment_ids != ["choice1", "choice2", "choice3"]:
            raise ValueError("choice assessments must be ordered choice1 to choice3")
        correct_assessments = [
            item.choice_id
            for item in self.choice_assessments
            if item.verdict == "correct"
        ]
        if self.decision == "accepted":
            if self.factual_confidence < 4 or self.distractor_quality < 4:
                raise ValueError("accepted questions require scores of at least 4")
            if self.difficulty_assessment != "aligned":
                raise ValueError("accepted questions must align with difficulty")
            if self.selection_score < 70:
                raise ValueError("accepted questions require selection_score >= 70")
            if len(correct_assessments) != 1:
                raise ValueError(
                    "accepted questions require exactly one assessed correct choice"
                )
            if any(
                item.verdict == "ambiguous" for item in self.choice_assessments
            ):
                raise ValueError("accepted questions cannot have ambiguous choices")
        return self


class ReplacementQuestion(StrictModel):
    schema_version: Literal["1.0"]
    rationale: Annotated[str, Field(min_length=10, max_length=300)]
    question: ContentQuestion
