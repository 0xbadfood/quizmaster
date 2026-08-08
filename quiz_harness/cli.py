from __future__ import annotations

import argparse
import json
import os
import random
import re
import sqlite3
import sys
from pathlib import Path

from pydantic import ValidationError

from .assets import generate_assets
from .bundle import bundle_id, write_bundle_files
from .client import VLLMClient, VLLMError
from .database import QuizDatabase
from .image_adapters import create_image_generator
from .mageflow import MageFlowError
from .models import GenerationRequest, PlanDocument
from .question_models import SetGenerationRequest
from .question_audit import audit_category_sets, write_audit_report
from .question_service import (
    QuestionSetGenerationError,
    generate_question_set,
    generate_question_set_phase2,
)
from .production_pipeline import (
    CategoryPipelineConfig,
    CategoryPipelineError,
    load_pipeline_metadata,
    run_category_pipeline,
)
from .service import PlanGenerationError, generate_plan


DEFAULT_ENDPOINT = "http://192.168.1.102:8001/v1"
DEFAULT_MAGEFLOW_ENDPOINT = "http://192.168.1.102:7864"
DEFAULT_IMAGESTUDIO_ENDPOINT = "http://127.0.0.1:8000"
DEFAULT_QUESTION_DRAFTER_ENDPOINT = "http://10.8.0.5:8001/v1"
DEFAULT_QUESTION_VALIDATOR_ENDPOINT = "http://192.168.1.102:8001/v1"
DEFAULT_DATABASE = Path(os.getenv("QUIZ_DATABASE_PATH", "data/quiz_harness.db"))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="quiz-harness",
        description="Generate and validate mobile kids quiz plans.",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan = subparsers.add_parser("plan", help="generate a plan with local vLLM")
    plan.add_argument("--category", required=True, help="broad category, e.g. animals")
    plan.add_argument("--subject", required=True, help="quiz subject, e.g. lion")
    plan.add_argument("--language", default="English")
    plan.add_argument("--age-min", type=int, default=5)
    plan.add_argument("--age-max", type=int, default=8)
    plan.add_argument("--questions", type=int, default=1, choices=range(1, 11))
    plan.add_argument("--options", type=int, default=3, choices=(3, 4))
    plan.add_argument("--seed", type=int)
    plan.add_argument(
        "--endpoint",
        default=os.getenv("QUIZ_VLLM_BASE_URL", DEFAULT_ENDPOINT),
    )
    plan.add_argument("--model", default=os.getenv("QUIZ_VLLM_MODEL"))
    plan.add_argument("--api-key", default=os.getenv("QUIZ_VLLM_API_KEY"))
    plan.add_argument("--timeout", type=float, default=180.0)
    plan.add_argument("--retries", type=int, default=2, choices=range(0, 5))
    plan.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    plan.add_argument("--output", type=Path)

    validate = subparsers.add_parser("validate", help="validate an existing plan")
    validate.add_argument("path", type=Path)

    bundle = subparsers.add_parser(
        "bundle", help="generate assets and package a mobile HTML quiz"
    )
    bundle.add_argument(
        "plan", nargs="?", type=Path, help="optional plan JSON interchange file"
    )
    bundle.add_argument("--plan-id", type=int, help="canonical database plan ID")
    bundle.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    bundle.add_argument(
        "--endpoint",
        default=os.getenv("QUIZ_MAGEFLOW_BASE_URL", DEFAULT_MAGEFLOW_ENDPOINT),
        help="MageFlow endpoint (retained for CLI compatibility)",
    )
    bundle.add_argument(
        "--image-provider", choices=("mageflow", "imagestudio"), default="mageflow"
    )
    bundle.add_argument("--image-model")
    bundle.add_argument(
        "--imagestudio-endpoint",
        default=os.getenv("QUIZ_IMAGESTUDIO_BASE_URL", DEFAULT_IMAGESTUDIO_ENDPOINT),
    )
    bundle.add_argument("--output-dir", type=Path, default=Path("dist"))
    bundle.add_argument("--steps", type=int, default=4, choices=range(1, 31))
    bundle.add_argument("--cfg", type=float, default=1.0)
    bundle.add_argument("--timeout", type=float, default=300.0)
    bundle.add_argument("--force", action="store_true")

    database = subparsers.add_parser(
        "db", help="initialize, seed, inspect, or import the quiz database"
    )
    database.add_argument(
        "action", choices=("init", "seed", "list", "import-plan")
    )
    database.add_argument("input", nargs="?", type=Path)
    database.add_argument("--database", type=Path, default=DEFAULT_DATABASE)

    questions = subparsers.add_parser(
        "questions",
        help="draft and independently validate ten-question content sets",
    )
    questions.add_argument("--category", required=True)
    questions.add_argument(
        "--difficulty",
        choices=("beginner", "intermediate", "expert", "all"),
        default="all",
    )
    questions.add_argument("--language", default="English")
    questions.add_argument("--set-number", type=int, default=1)
    questions.add_argument(
        "--sets", type=int, default=1, help="number of consecutive set numbers"
    )
    questions.add_argument(
        "--pipeline", choices=("phase1", "phase2"), default="phase2"
    )
    questions.add_argument("--seed", type=int)
    questions.add_argument(
        "--drafter-endpoint",
        default=os.getenv(
            "QUIZ_DRAFTER_BASE_URL", DEFAULT_QUESTION_DRAFTER_ENDPOINT
        ),
    )
    questions.add_argument(
        "--drafter-model", default=os.getenv("QUIZ_DRAFTER_MODEL")
    )
    questions.add_argument(
        "--validator-endpoint",
        default=os.getenv(
            "QUIZ_VALIDATOR_BASE_URL", DEFAULT_QUESTION_VALIDATOR_ENDPOINT
        ),
    )
    questions.add_argument(
        "--validator-model", default=os.getenv("QUIZ_VALIDATOR_MODEL")
    )
    questions.add_argument("--output-dir", type=Path, default=Path("question_sets"))
    questions.add_argument("--timeout", type=float, default=900.0)
    questions.add_argument("--retries", type=int, default=2, choices=range(0, 5))
    questions.add_argument("--force", action="store_true")

    audit = subparsers.add_parser(
        "questions-audit",
        help="audit finalized question sets for cross-set duplication",
    )
    audit.add_argument("--category", required=True)
    audit.add_argument("--input-dir", type=Path, default=Path("question_sets"))
    audit.add_argument("--output", type=Path)

    production = subparsers.add_parser(
        "category-pipeline",
        help="build and publish a category from metadata and a background image",
    )
    production.add_argument(
        "--metadata",
        type=Path,
        required=True,
        help="category metadata JSON file",
    )
    production.add_argument(
        "--background",
        type=Path,
        required=True,
        help="user-supplied category background image",
    )
    production.add_argument("--database", type=Path, default=DEFAULT_DATABASE)
    production.add_argument(
        "--source-root",
        type=Path,
        default=Path(os.getenv("QUIZ_STUDIO_SOURCE_ROOT", "visual_quiz_qwen")),
    )
    production.add_argument(
        "--bundle-root",
        type=Path,
        default=Path(os.getenv("QUIZ_CATEGORY_BUNDLE_ROOT", "dist/category_bundles")),
    )
    production.add_argument(
        "--secret-key-file",
        type=Path,
        default=Path(os.getenv("QUIZ_SECRET_KEY_FILE", "data/.provider_secret_key")),
    )
    production.add_argument("--question-provider", default="openai-images")
    production.add_argument("--question-model", default="gpt-5.6-luna")
    production.add_argument("--qwen-provider", default="llm-default")
    production.add_argument("--qwen-model")
    production.add_argument("--tile-provider", default="openai-images")
    production.add_argument("--tile-model")
    production.add_argument("--answer-provider", default="imagestudio-local")
    production.add_argument("--answer-model")
    production.add_argument("--audio-provider", default="vibevoice-local")
    production.add_argument("--seed", type=int, default=20260805)
    production.add_argument(
        "--strictness", choices=("strict", "balanced"), default="strict"
    )
    production.add_argument(
        "--image-quality", choices=("low", "medium", "high"), default="medium"
    )
    production.add_argument(
        "--force-media",
        action="store_true",
        help="regenerate existing narration and generated images",
    )
    production.add_argument(
        "--force-new-bundle",
        action="store_true",
        help="publish a new version even when content is unchanged",
    )
    production.add_argument(
        "--allow-active-jobs",
        action="store_true",
        help="run despite other active Studio jobs",
    )
    return parser


def _write_document(document: PlanDocument, output: Path) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    temporary.write_text(
        document.model_dump_json(indent=2) + "\n", encoding="utf-8"
    )
    temporary.replace(output)


def _run_plan(args: argparse.Namespace) -> int:
    seed = args.seed if args.seed is not None else random.SystemRandom().randrange(2**31)
    try:
        request = GenerationRequest(
            category=args.category,
            subject=args.subject,
            language=args.language,
            age_min=args.age_min,
            age_max=args.age_max,
            question_count=args.questions,
            option_count=args.options,
            seed=seed,
        )
    except ValidationError as exc:
        print(f"Invalid generation request:\n{exc}", file=sys.stderr)
        return 2

    database = QuizDatabase(args.database)
    try:
        database.migrate()
        history = database.plan_history()
        with VLLMClient(
            args.endpoint,
            timeout_seconds=args.timeout,
            api_key=args.api_key,
        ) as client:
            model = args.model or client.discover_model()
            print(
                f"Generating {args.questions}-question plan with {model} "
                f"(seed {seed})...",
                file=sys.stderr,
            )
            document = generate_plan(
                client=client,
                endpoint=args.endpoint,
                model=model,
                request=request,
                history_dir=None,
                retries=args.retries,
                progress=lambda message: print(message, file=sys.stderr),
                history=history,
            )
        stored = database.store_plan(document)
        if args.output:
            _write_document(document, args.output)
    except (VLLMError, PlanGenerationError, OSError, sqlite3.Error) as exc:
        print(f"Plan generation failed: {exc}", file=sys.stderr)
        return 1

    print(
        f"plan_id={stored.plan_id} object_id={stored.object_id} "
        f"revision={stored.revision} database={args.database}"
    )
    if args.output:
        print(args.output)
    return 0


def _run_validate(path: Path) -> int:
    try:
        document = PlanDocument.model_validate_json(path.read_text(encoding="utf-8"))
    except (OSError, ValidationError, json.JSONDecodeError) as exc:
        print(f"Invalid plan: {exc}", file=sys.stderr)
        return 1
    question_count = len(document.plan.questions)
    question_label = "question" if question_count == 1 else "questions"
    print(
        f"Valid plan: {document.plan.brief.title} "
        f"({question_count} {question_label}, {len(document.plan.assets)} assets)"
    )
    return 0


def _read_plan(path: Path) -> PlanDocument:
    return PlanDocument.model_validate_json(path.read_text(encoding="utf-8"))


def _run_bundle(args: argparse.Namespace) -> int:
    if (args.plan is None) == (args.plan_id is None):
        print(
            "Provide exactly one of a plan JSON path or --plan-id.", file=sys.stderr
        )
        return 2
    try:
        document = (
            QuizDatabase(args.database).plan_document(args.plan_id)
            if args.plan_id is not None
            else _read_plan(args.plan)
        )
    except (
        OSError,
        ValidationError,
        json.JSONDecodeError,
        KeyError,
        sqlite3.Error,
    ) as exc:
        print(f"Invalid plan: {exc}", file=sys.stderr)
        return 2
    if len(document.plan.questions) != 1:
        print(
            "Bundle generation currently requires exactly one question per plan.",
            file=sys.stderr,
        )
        return 2
    if not 1.0 <= args.cfg <= 12.0:
        print("--cfg must be between 1 and 12", file=sys.stderr)
        return 2

    destination = args.output_dir / bundle_id(document)
    endpoint = (
        args.imagestudio_endpoint
        if args.image_provider == "imagestudio"
        else args.endpoint
    )
    try:
        with create_image_generator(
            args.image_provider,
            endpoint,
            model=args.image_model,
            timeout_seconds=args.timeout,
        ) as client:
            manifest = generate_assets(
                document=document,
                client=client,
                endpoint=endpoint,
                bundle_dir=destination,
                steps=args.steps,
                cfg=args.cfg,
                force=args.force,
                progress=lambda message: print(message, file=sys.stderr),
            )
        archive = write_bundle_files(
            document=document,
            asset_manifest=manifest,
            bundle_dir=destination,
        )
    except (MageFlowError, OSError, KeyError, ValueError) as exc:
        print(f"Bundle generation failed: {exc}", file=sys.stderr)
        return 1
    print(destination)
    print(archive)
    return 0


def _run_database(args: argparse.Namespace) -> int:
    database = QuizDatabase(args.database)
    try:
        if args.action == "init":
            applied = database.migrate()
            print(
                f"Database ready: {args.database} "
                f"(applied migrations: {applied or 'none'})"
            )
            return 0
        if args.action == "seed":
            category_count, object_count = database.seed_catalog()
            print(
                f"Seeded {category_count} categories and {object_count} objects "
                f"in {args.database}"
            )
            return 0
        if args.action == "import-plan":
            if args.input is None:
                print("db import-plan requires a plan JSON path", file=sys.stderr)
                return 2
            document = _read_plan(args.input)
            stored = database.store_plan(document, source="import")
            result = "imported" if stored.created else "already present"
            print(
                f"Plan {result}: id={stored.plan_id} revision={stored.revision} "
                f"database={args.database}"
            )
            return 0
        catalog = database.catalog()
        for category in catalog:
            print(
                f"{category['name']} [{category['slug']}] "
                f"ages {category['age_min']}-{category['age_max']}"
            )
            for item in category["objects"]:
                revision = item["current_revision"] or "-"
                print(
                    f"  {item['name']} [{item['slug']}] "
                    f"plans={item['plan_count']} current={revision} "
                    f"assets={item['asset_key']}"
                )
        return 0
    except (
        OSError,
        ValidationError,
        json.JSONDecodeError,
        ValueError,
        sqlite3.Error,
    ) as exc:
        print(f"Database operation failed: {exc}", file=sys.stderr)
        return 1


def _run_questions(args: argparse.Namespace) -> int:
    if not 1 <= args.set_number <= 999:
        print("--set-number must be between 1 and 999", file=sys.stderr)
        return 2
    if not 1 <= args.sets <= 20:
        print("--sets must be between 1 and 20", file=sys.stderr)
        return 2
    difficulties = (
        ("beginner", "intermediate", "expert")
        if args.difficulty == "all"
        else (args.difficulty,)
    )
    base_seed = (
        args.seed
        if args.seed is not None
        else random.SystemRandom().randrange(2**31)
    )
    try:
        with VLLMClient(
            args.drafter_endpoint, timeout_seconds=args.timeout
        ) as drafter_client, VLLMClient(
            args.validator_endpoint, timeout_seconds=args.timeout
        ) as validator_client:
            drafter_model = args.drafter_model or drafter_client.discover_model()
            validator_model = args.validator_model or validator_client.discover_model()
            print(
                f"Drafter: {drafter_model} at {args.drafter_endpoint}",
                file=sys.stderr,
            )
            print(
                f"Validator: {validator_model} at {args.validator_endpoint}",
                file=sys.stderr,
            )
            generator = (
                generate_question_set_phase2
                if args.pipeline == "phase2"
                else generate_question_set
            )
            for set_offset in range(args.sets):
                set_number = args.set_number + set_offset
                for difficulty_index, difficulty in enumerate(difficulties):
                    request = SetGenerationRequest(
                        category=args.category,
                        difficulty=difficulty,
                        language=args.language,
                        set_number=set_number,
                        seed=(
                            base_seed
                            + set_offset * 10_000_019
                            + difficulty_index * 1_000_003
                        ),
                    )
                    label = f"{difficulty}/set-{set_number:03d}"
                    print(
                        f"[{label}] drafting 14 candidates for a 10-question set "
                        f"with {args.pipeline}",
                        file=sys.stderr,
                    )
                    final_set, path = generator(
                        request=request,
                        drafter_client=drafter_client,
                        drafter_endpoint=args.drafter_endpoint,
                        drafter_model=drafter_model,
                        validator_client=validator_client,
                        validator_endpoint=args.validator_endpoint,
                        validator_model=validator_model,
                        output_root=args.output_dir,
                        retries=args.retries,
                        force=args.force,
                        progress=lambda message, item=label: print(
                            f"[{item}] {message}", file=sys.stderr
                        ),
                    )
                    print(
                        f"{final_set.set_id}: {len(final_set.questions)} "
                        f"questions -> {path}"
                    )
    except (
        VLLMError,
        QuestionSetGenerationError,
        ValidationError,
        OSError,
        ValueError,
    ) as exc:
        print(f"Question-set generation failed: {exc}", file=sys.stderr)
        return 1
    return 0


def _run_question_audit(args: argparse.Namespace) -> int:
    try:
        report = audit_category_sets(args.input_dir, args.category)
        category_slug = re.sub(
            r"[^a-z0-9]+", "_", args.category.casefold()
        ).strip("_")
        output = args.output or args.input_dir / category_slug / "audit.json"
        write_audit_report(report, output)
    except (OSError, ValidationError, ValueError, json.JSONDecodeError) as exc:
        print(f"Question audit failed: {exc}", file=sys.stderr)
        return 1
    summary = report["summary"]
    print(
        f"sets={report['set_count']} questions={report['question_count']} "
        f"likely_duplicates={summary['likely_duplicate_pairs']} "
        f"topic_collisions={summary['topic_collision_pairs']}"
    )
    print(output)
    return 0


def _run_category_pipeline(args: argparse.Namespace) -> int:
    try:
        metadata = load_pipeline_metadata(args.metadata)
        result = run_category_pipeline(
            CategoryPipelineConfig(
                metadata=metadata,
                background=args.background,
                database_path=args.database,
                source_root=args.source_root,
                bundle_root=args.bundle_root,
                secret_key_file=args.secret_key_file,
                question_provider_id=args.question_provider,
                question_model=args.question_model,
                qwen_provider_id=args.qwen_provider,
                qwen_model=args.qwen_model,
                tile_provider_id=args.tile_provider,
                tile_model=args.tile_model,
                answer_provider_id=args.answer_provider,
                answer_model=args.answer_model,
                audio_provider_id=args.audio_provider,
                strictness=args.strictness,
                seed=args.seed,
                image_quality=args.image_quality,
                force_media=args.force_media,
                force_new_bundle=args.force_new_bundle,
                allow_active_jobs=args.allow_active_jobs,
            ),
            progress=lambda message: print(message, file=sys.stderr, flush=True),
        )
    except (
        CategoryPipelineError,
        ValidationError,
        OSError,
        ValueError,
        json.JSONDecodeError,
        sqlite3.Error,
    ) as exc:
        print(f"Category pipeline failed: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2, ensure_ascii=True))
    return 0


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "plan":
        return _run_plan(args)
    if args.command == "validate":
        return _run_validate(args.path)
    if args.command == "bundle":
        return _run_bundle(args)
    if args.command == "questions":
        return _run_questions(args)
    if args.command == "questions-audit":
        return _run_question_audit(args)
    if args.command == "category-pipeline":
        return _run_category_pipeline(args)
    return _run_database(args)
