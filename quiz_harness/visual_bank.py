from __future__ import annotations

import json
import hashlib
import random
import re
from collections import Counter, defaultdict
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Literal

from pydantic import Field, ValidationError, model_validator

from .models import Identifier, StrictModel


VisualDifficulty = Literal["beginner", "intermediate"]
VisualChoiceId = Literal["choice1", "choice2", "choice3", "choice4"]
BankState = Literal["available", "allocated", "rejected"]

BIRD_TERMS = {
    "albatross", "bird", "chicken", "crow", "duck", "eagle", "emu", "falcon",
    "flamingo", "goose", "hawk", "hen", "heron", "hummingbird", "kiwi", "owl",
    "ostrich", "parrot", "peacock", "pelican", "penguin", "pigeon", "raven",
    "rooster", "seagull", "sparrow", "swan", "turkey", "vulture", "woodpecker",
}


def normalize_text(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", " ", value.casefold()).strip()


def slugify(value: str) -> str:
    slug = re.sub(r"[^a-z0-9]+", "_", value.casefold()).strip("_")
    if slug and not slug[0].isalpha():
        slug = f"item_{slug}"
    if len(slug) < 2:
        raise ValueError(f"cannot create a stable identifier from {value!r}")
    return slug[:64]


def canonical_topic_key(question: VisualQuestion) -> str:
    normalized = normalize_text(question.question)
    stop_words = {
        "a", "an", "animal", "animals", "has", "have", "is", "name", "of",
        "the", "these", "which", "with",
    }
    clue_words = [
        word for word in normalized.split() if word not in stop_words
    ][:5]
    fingerprint = hashlib.sha1(normalized.encode("utf-8")).hexdigest()[:8]
    return slugify(
        f"{question.correct_animal_key}_{'_'.join(clue_words)}_{fingerprint}"
    )


def is_bird_choice(choice: VisualChoice) -> bool:
    words = set(normalize_text(f"{choice.animal_key} {choice.label}").split())
    # Hummingbird bats are mammals despite their common name.
    return "bat" not in words and bool(words & BIRD_TERMS)


class VisualChoice(StrictModel):
    choice_id: VisualChoiceId
    animal_key: Identifier
    label: Annotated[str, Field(min_length=2, max_length=50)]


class VisualQuestion(StrictModel):
    question_id: Identifier
    topic_key: Identifier
    difficulty: VisualDifficulty
    question: Annotated[str, Field(min_length=12, max_length=180)]
    choices: Annotated[list[VisualChoice], Field(min_length=4, max_length=4)]
    correct_choice_id: VisualChoiceId
    explanation: Annotated[str, Field(min_length=20, max_length=320)]

    @model_validator(mode="after")
    def validate_question(self) -> VisualQuestion:
        choice_ids = [choice.choice_id for choice in self.choices]
        if choice_ids != ["choice1", "choice2", "choice3", "choice4"]:
            raise ValueError("choices must be ordered choice1 through choice4")
        animal_keys = [choice.animal_key for choice in self.choices]
        labels = [normalize_text(choice.label) for choice in self.choices]
        if len(set(animal_keys)) != 4 or len(set(labels)) != 4:
            raise ValueError("all four animal choices must be distinct")
        if not self.question.endswith("?"):
            raise ValueError("question must end with a question mark")
        answer = next(
            choice for choice in self.choices
            if choice.choice_id == self.correct_choice_id
        )
        if normalize_text(answer.label) not in normalize_text(self.explanation):
            raise ValueError("explanation must explicitly name the correct animal")
        return self

    @property
    def correct_animal_key(self) -> str:
        return next(
            choice.animal_key for choice in self.choices
            if choice.choice_id == self.correct_choice_id
        )


class GeneratedVisualQuestion(StrictModel):
    question_id: Identifier
    topic_key: Identifier
    difficulty: VisualDifficulty
    question: Annotated[str, Field(min_length=12, max_length=180)]
    choices: Annotated[list[VisualChoice], Field(min_length=4, max_length=4)]
    correct_choice_id: VisualChoiceId
    explanation: Annotated[str, Field(min_length=20, max_length=320)]


class GeneratedVisualBank(StrictModel):
    schema_version: Literal["1.0"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: VisualDifficulty
    questions: Annotated[
        list[GeneratedVisualQuestion], Field(min_length=10, max_length=150)
    ]

    @model_validator(mode="after")
    def validate_bank(self) -> GeneratedVisualBank:
        if any(question.difficulty != self.difficulty for question in self.questions):
            raise ValueError("every question must match the bank difficulty")
        return self


class BankQuestion(VisualQuestion):
    state: BankState = "available"
    set_id: Identifier | None = None

    @model_validator(mode="after")
    def validate_state(self) -> BankQuestion:
        if self.state == "allocated" and self.set_id is None:
            raise ValueError("allocated questions require set_id")
        if self.state != "allocated" and self.set_id is not None:
            raise ValueError("only allocated questions may have set_id")
        return self


class BankIngestionRejection(StrictModel):
    question_index: Annotated[int, Field(ge=1, le=150)]
    source_question_id: Identifier
    reasons: Annotated[list[str], Field(min_length=1, max_length=8)]


class VisualBankDocument(StrictModel):
    schema_version: Literal["visual_bank_v1"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: VisualDifficulty
    source_provider: Literal["openai"]
    source_model: Annotated[str, Field(min_length=2, max_length=80)]
    source_response_id: Annotated[str, Field(min_length=2, max_length=120)]
    generated_at_utc: Annotated[str, Field(min_length=10, max_length=60)]
    questions: Annotated[list[BankQuestion], Field(min_length=1, max_length=150)]
    ingestion_rejections: list[BankIngestionRejection] = []

    @model_validator(mode="after")
    def validate_document(self) -> VisualBankDocument:
        if any(question.difficulty != self.difficulty for question in self.questions):
            raise ValueError("every question must match the bank difficulty")
        return self

    @classmethod
    def from_generated(
        cls,
        generated: GeneratedVisualBank,
        *,
        source_model: str,
        source_response_id: str,
        max_invalid: int = 5,
    ) -> VisualBankDocument:
        records: list[BankQuestion] = []
        rejections: list[BankIngestionRejection] = []
        seen_prompts: set[str] = set()
        category_slug = slugify(generated.category)
        for index, generated_question in enumerate(generated.questions, start=1):
            source_question_id = generated_question.question_id
            try:
                question = VisualQuestion.model_validate(
                    generated_question.model_dump(mode="json")
                )
            except ValidationError as exc:
                rejections.append(
                    BankIngestionRejection(
                        question_index=index,
                        source_question_id=source_question_id,
                        reasons=[
                            f"{'.'.join(str(item) for item in error['loc'])}: "
                            f"{error['msg']}"
                            for error in exc.errors()[:8]
                        ],
                    )
                )
                continue
            bird_choices = [choice.label for choice in question.choices if is_bird_choice(choice)]
            if bird_choices:
                rejections.append(
                    BankIngestionRejection(
                        question_index=index,
                        source_question_id=source_question_id,
                        reasons=[
                            "bird choices are outside the Animals category: "
                            + ", ".join(bird_choices)
                        ],
                    )
                )
                continue
            data = question.model_dump(mode="json")
            data["question_id"] = slugify(
                f"{category_slug}_{generated.difficulty}_{index:03d}"
            )
            data["topic_key"] = canonical_topic_key(question)
            normalized_prompt = normalize_text(question.question)
            repeated = normalized_prompt in seen_prompts
            if repeated:
                rejections.append(
                    BankIngestionRejection(
                        question_index=index,
                        source_question_id=source_question_id,
                        reasons=["duplicate normalized question text"],
                    )
                )
            else:
                records.append(BankQuestion.model_validate(data))
            seen_prompts.add(normalized_prompt)
        if len(rejections) > max_invalid:
            raise ValueError(
                f"bank contains {len(rejections)} invalid questions; "
                f"tolerance is {max_invalid}"
            )
        return cls(
            schema_version="visual_bank_v1",
            category=generated.category,
            difficulty=generated.difficulty,
            source_provider="openai",
            source_model=source_model,
            source_response_id=source_response_id,
            generated_at_utc=datetime.now(timezone.utc).isoformat(),
            questions=records,
            ingestion_rejections=rejections,
        )


class VisualQuizSet(StrictModel):
    schema_version: Literal["visual_quiz_v1"]
    set_id: Identifier
    category: Annotated[str, Field(min_length=2, max_length=60)]
    difficulty: VisualDifficulty
    source_model: Annotated[str, Field(min_length=2, max_length=80)]
    selection_model: Annotated[str, Field(min_length=2, max_length=120)] | None = None
    questions: Annotated[list[VisualQuestion], Field(min_length=10, max_length=10)]

    @model_validator(mode="after")
    def validate_set(self) -> VisualQuizSet:
        ids = [question.question_id for question in self.questions]
        topics = [question.topic_key for question in self.questions]
        if len(ids) != len(set(ids)) or len(topics) != len(set(topics)):
            raise ValueError("set questions and topics must be unique")
        counts = Counter(question.correct_choice_id for question in self.questions)
        if sorted(counts.values()) != [2, 2, 3, 3]:
            raise ValueError("correct choices must be balanced 3/3/2/2")
        return self


class AnimalCatalogEntry(StrictModel):
    animal_key: Identifier
    label: Annotated[str, Field(min_length=2, max_length=50)]
    aliases: list[str]
    image_path: Annotated[str, Field(min_length=5, max_length=160)]
    image_status: Literal["pending", "approved", "rejected"] = "pending"
    choice_count: Annotated[int, Field(ge=1)]
    correct_answer_count: Annotated[int, Field(ge=0)]
    question_ids: list[Identifier]


class AnimalCatalog(StrictModel):
    schema_version: Literal["animal_catalog_v1"]
    category: Annotated[str, Field(min_length=2, max_length=60)]
    generated_at_utc: Annotated[str, Field(min_length=10, max_length=60)]
    animals: list[AnimalCatalogEntry]


def write_model(path: Path, model: StrictModel) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(model.model_dump_json(indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_bank(path: Path) -> VisualBankDocument:
    return VisualBankDocument.model_validate_json(path.read_text(encoding="utf-8"))


def _rebalance_question(
    question: BankQuestion, target: VisualChoiceId, rng: random.Random
) -> VisualQuestion:
    correct = next(
        choice for choice in question.choices
        if choice.choice_id == question.correct_choice_id
    )
    distractors = [
        choice for choice in question.choices
        if choice.choice_id != question.correct_choice_id
    ]
    rng.shuffle(distractors)
    target_index = ["choice1", "choice2", "choice3", "choice4"].index(target)
    ordered = list(distractors)
    ordered.insert(target_index, correct)
    choices = [
        VisualChoice(
            choice_id=f"choice{index}",
            animal_key=choice.animal_key,
            label=choice.label,
        )
        for index, choice in enumerate(ordered, start=1)
    ]
    return VisualQuestion(
        question_id=question.question_id,
        topic_key=question.topic_key,
        difficulty=question.difficulty,
        question=question.question,
        choices=choices,
        correct_choice_id=target,
        explanation=question.explanation,
    )


def build_visual_quiz_set(
    bank: VisualBankDocument,
    selected: list[BankQuestion],
    *,
    set_number: int,
    seed: int,
    selection_model: str | None = None,
) -> VisualQuizSet:
    if len(selected) != 10:
        raise ValueError("a visual quiz set requires exactly ten selected questions")
    rng = random.Random(seed)
    targets: list[VisualChoiceId] = [
        "choice1", "choice1", "choice1",
        "choice2", "choice2", "choice2",
        "choice3", "choice3", "choice4", "choice4",
    ]
    rng.shuffle(targets)
    set_id = slugify(f"{bank.category}_{bank.difficulty}_{set_number:03d}")
    questions = [
        _rebalance_question(question, target, rng)
        for question, target in zip(selected, targets, strict=True)
    ]
    return VisualQuizSet(
        schema_version="visual_quiz_v1",
        set_id=set_id,
        category=bank.category,
        difficulty=bank.difficulty,
        source_model=bank.source_model,
        selection_model=selection_model,
        questions=questions,
    )


def allocate_sets(
    bank: VisualBankDocument,
    *,
    seed: int,
    first_set_number: int = 1,
    max_sets: int | None = None,
) -> list[VisualQuizSet]:
    rng = random.Random(seed)
    available = [question for question in bank.questions if question.state == "available"]
    rng.shuffle(available)
    by_id = {question.question_id: question for question in bank.questions}
    sets: list[VisualQuizSet] = []
    next_set_number = first_set_number

    while len(available) >= 10 and (
        max_sets is None or len(sets) < max_sets
    ):
        selected: list[BankQuestion] = []
        used_answers: set[str] = set()
        used_topics: set[str] = set()
        for question in available:
            if (
                question.correct_animal_key in used_answers
                or question.topic_key in used_topics
            ):
                continue
            selected.append(question)
            used_answers.add(question.correct_animal_key)
            used_topics.add(question.topic_key)
            if len(selected) == 10:
                break
        if len(selected) < 10:
            for question in available:
                if question in selected:
                    continue
                if question.topic_key in used_topics:
                    continue
                selected.append(question)
                used_topics.add(question.topic_key)
                if len(selected) == 10:
                    break

        quiz_set = build_visual_quiz_set(
            bank,
            selected,
            set_number=next_set_number,
            seed=rng.randrange(2**31),
        )
        sets.append(quiz_set)
        set_id = quiz_set.set_id
        selected_ids = {question.question_id for question in selected}
        for question_id in selected_ids:
            record = by_id[question_id]
            record.state = "allocated"
            record.set_id = set_id
        available = [
            question for question in available
            if question.question_id not in selected_ids
        ]
        next_set_number += 1
    return sets


def extract_animal_catalog(
    banks: list[VisualBankDocument],
    *,
    category: str,
    include_states: set[BankState] | None = None,
) -> AnimalCatalog:
    allowed_states = include_states or {"allocated"}
    labels: dict[str, Counter[str]] = defaultdict(Counter)
    question_ids: dict[str, set[str]] = defaultdict(set)
    choice_counts: Counter[str] = Counter()
    correct_counts: Counter[str] = Counter()
    for bank in banks:
        for question in bank.questions:
            if question.state not in allowed_states:
                continue
            for choice in question.choices:
                labels[choice.animal_key][choice.label] += 1
                question_ids[choice.animal_key].add(question.question_id)
                choice_counts[choice.animal_key] += 1
                if choice.choice_id == question.correct_choice_id:
                    correct_counts[choice.animal_key] += 1
    animals = []
    for animal_key in sorted(labels):
        label_counts = labels[animal_key]
        label = label_counts.most_common(1)[0][0]
        aliases = sorted(item for item in label_counts if item != label)
        animals.append(
            AnimalCatalogEntry(
                animal_key=animal_key,
                label=label,
                aliases=aliases,
                image_path=f"assets/animals/{animal_key}.webp",
                choice_count=choice_counts[animal_key],
                correct_answer_count=correct_counts[animal_key],
                question_ids=sorted(question_ids[animal_key]),
            )
        )
    return AnimalCatalog(
        schema_version="animal_catalog_v1",
        category=category,
        generated_at_utc=datetime.now(timezone.utc).isoformat(),
        animals=animals,
    )
