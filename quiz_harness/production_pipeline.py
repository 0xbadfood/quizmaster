from __future__ import annotations

import json
import mimetypes
import os
import re
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from PIL import Image, UnidentifiedImageError
from pydantic import Field

from .background_images import (
    generate_quiz_background,
    plan_quiz_background_prompt,
)
from .client import VLLMClient
from .database import QuizDatabase
from .models import StrictModel
from .secure_store import SecretStore
from .studio_audio import StudioAudioStore
from .studio_catalog import category_metadata_status
from .studio_publish import StudioPublishStore
from .studio_questions import QuestionBankStore, generate_questions
from .studio_sets import QuizSetStore
from .studio_visuals import StudioVisualStore


DIFFICULTIES = ("beginner", "intermediate")


class CategoryPipelineError(RuntimeError):
    pass


class CategoryPipelineMetadata(StrictModel):
    name: str = Field(min_length=2, max_length=80)
    slug: str | None = Field(
        default=None, pattern=r"^[a-z][a-z0-9-]{1,79}$"
    )
    display_title: str = Field(min_length=2, max_length=80)
    display_tag: str = Field(min_length=1, max_length=12)
    description: str = Field(min_length=10, max_length=300)
    editorial_brief: str = Field(min_length=20, max_length=1200)
    age_min: int = Field(ge=3, le=15)
    age_max: int = Field(ge=3, le=15)


@dataclass(frozen=True)
class CategoryPipelineConfig:
    metadata: CategoryPipelineMetadata
    background: Path | None
    database_path: Path
    source_root: Path
    bundle_root: Path
    secret_key_file: Path
    question_provider_id: str = "openai-images"
    question_model: str = "gpt-5.6-luna"
    qwen_provider_id: str = "llm-default"
    qwen_model: str | None = None
    background_provider_id: str = "openai-images"
    background_model: str | None = None
    background_guidance: str | None = None
    tile_provider_id: str = "openai-images"
    tile_model: str | None = None
    answer_provider_id: str = "imagestudio-local"
    answer_model: str | None = None
    audio_provider_id: str = "vibevoice-local"
    target_questions: int = 150
    question_batch_size: int = 50
    max_question_batches: int = 6
    sets_per_difficulty: int = 10
    strictness: str = "strict"
    seed: int = 20260805
    image_quality: str = "medium"
    whisper_retries: int = 3
    audio_duration_seconds: float = 12.0
    audio_duration_retries: int | None = None
    force_media: bool = False
    force_background: bool = False
    refresh_background_plan: bool = False
    force_new_bundle: bool = False
    allow_active_jobs: bool = False


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "quiz"


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise CategoryPipelineError(f"expected a JSON object in {path}")
    return value


def load_pipeline_metadata(path: Path) -> CategoryPipelineMetadata:
    return CategoryPipelineMetadata.model_validate_json(path.read_text(encoding="utf-8"))


class PipelineCheckpoint:
    def __init__(self, path: Path, category_slug: str) -> None:
        self.path = path
        self._lock = threading.Lock()
        self.document = _read_json(path) or {
            "schema_version": "category_pipeline_run_v1",
            "category_slug": category_slug,
            "created_at_utc": _now(),
            "updated_at_utc": _now(),
            "phases": {},
        }
        if self.document.get("category_slug") != category_slug:
            raise CategoryPipelineError("pipeline checkpoint belongs to another category")

    def phase(self, name: str) -> dict[str, Any]:
        with self._lock:
            value = self.document.setdefault("phases", {}).get(name, {})
            return dict(value) if isinstance(value, dict) else {}

    def update(self, name: str, value: dict[str, Any]) -> None:
        with self._lock:
            phases = self.document.setdefault("phases", {})
            previous = phases.get(name, {})
            phases[name] = {
                **(previous if isinstance(previous, dict) else {}),
                **value,
                "updated_at_utc": _now(),
            }
            self.document["updated_at_utc"] = _now()
            self.path.parent.mkdir(parents=True, exist_ok=True)
            temporary = self.path.with_suffix(self.path.suffix + ".tmp")
            temporary.write_text(
                json.dumps(self.document, indent=2, ensure_ascii=True) + "\n",
                encoding="utf-8",
            )
            temporary.replace(self.path)


class CategoryProductionPipeline:
    def __init__(
        self,
        config: CategoryPipelineConfig,
        *,
        progress: Callable[[str], None] | None = None,
    ) -> None:
        self.config = config
        self.progress = progress or (lambda _: None)
        self.database = QuizDatabase(config.database_path)
        self.database.migrate()
        self.questions = QuestionBankStore(config.source_root, self.database)
        self.sets = QuizSetStore(config.source_root, self.database)
        self.visuals = StudioVisualStore(config.source_root)
        self.audio = StudioAudioStore(config.source_root)
        self.publisher = StudioPublishStore(config.source_root, config.bundle_root)
        self.secrets = SecretStore(
            key=os.getenv("QUIZ_SECRET_KEY"), key_file=config.secret_key_file
        )
        slug = config.metadata.slug or _slug(config.metadata.name)
        self.checkpoint = PipelineCheckpoint(
            config.source_root / slug / "pipeline-run.json", slug
        )

    def _log(self, phase: str, message: str) -> None:
        self.progress(f"[{phase}] {message}")

    def _validate_inputs(self) -> None:
        if self.config.background is not None:
            background = self.config.background.expanduser().resolve()
            if not background.is_file():
                raise CategoryPipelineError(
                    f"background image does not exist: {background}"
                )
            content_type = mimetypes.guess_type(background.name)[0] or ""
            if not content_type.startswith("image/"):
                raise CategoryPipelineError("background file must use an image extension")
            try:
                with Image.open(background) as source:
                    source.verify()
            except (OSError, UnidentifiedImageError) as exc:
                raise CategoryPipelineError(f"background image is invalid: {exc}") from exc
        if not 1 <= self.config.question_batch_size <= 50:
            raise CategoryPipelineError("question batch size must be between 1 and 50")
        if not 1 <= self.config.max_question_batches <= 6:
            raise CategoryPipelineError("maximum question batches must be between 1 and 6")
        if not 1 <= self.config.target_questions <= 150:
            raise CategoryPipelineError("question target must be between 1 and 150")
        if not 1 <= self.config.sets_per_difficulty <= 10:
            raise CategoryPipelineError("set target must be between 1 and 10")

    def _provider(self, provider_id: str, expected: set[str]) -> dict[str, Any]:
        try:
            provider = self.database.provider_connection(provider_id)
        except KeyError as exc:
            raise CategoryPipelineError(f"provider does not exist: {provider_id}") from exc
        if provider["provider_type"] not in expected:
            raise CategoryPipelineError(
                f"provider {provider_id} must be one of {sorted(expected)}"
            )
        if not provider["enabled"]:
            raise CategoryPipelineError(f"provider is disabled: {provider_id}")
        return provider

    @staticmethod
    def _model(provider: dict[str, Any], override: str | None) -> str:
        model = override or provider.get("default_model") or next(
            iter(provider.get("discovered_models") or []), None
        )
        if not model:
            raise CategoryPipelineError(
                f"provider has no configured or discovered model: {provider['id']}"
            )
        return str(model)

    def _secret(self, provider: dict[str, Any]) -> str | None:
        return self.secrets.decrypt(provider.get("secret_ciphertext"))

    def _ensure_idle(self) -> None:
        if self.config.allow_active_jobs:
            return
        active = [
            job
            for job in self.database.studio_jobs(limit=100)
            if job["status"] in {"queued", "running"}
        ]
        if active:
            kinds = ", ".join(sorted({str(item["kind"]) for item in active}))
            raise CategoryPipelineError(
                f"Studio jobs are active ({kinds}); retry when they finish or use "
                "--allow-active-jobs"
            )

    def _ensure_category(self) -> dict[str, Any]:
        metadata = self.config.metadata
        if metadata.age_min > metadata.age_max:
            raise CategoryPipelineError("age_min must not exceed age_max")
        status = category_metadata_status(metadata.model_dump())
        if not status["ready"]:
            raise CategoryPipelineError(
                "category metadata is incomplete: " + ", ".join(status["missing"])
            )
        slug = metadata.slug or _slug(metadata.name)
        try:
            existing = self.database.studio_category(slug)
        except KeyError:
            category = self.database.create_category(**metadata.model_dump())
            action = "created"
        else:
            if existing["name"].strip() != metadata.name.strip():
                raise CategoryPipelineError(
                    f"category name is immutable: {existing['name']!r}"
                )
            category = self.database.update_category_metadata(
                slug, **metadata.model_dump(exclude={"slug"})
            )
            action = "updated"
        self.checkpoint.update(
            "metadata", {"status": "complete", "action": action, "metadata": category}
        )
        self._log("metadata", f"{action} {category['name']} [{category['slug']}]")
        return category

    def _bank_total(self, category_slug: str, difficulty: str) -> int:
        path = self.questions.bank_path(category_slug, difficulty)
        document = _read_json(path)
        questions = document.get("questions", [])
        return len(questions) if isinstance(questions, list) else 0

    def _generate_banks(self, category: dict[str, Any]) -> dict[str, Any]:
        provider = self._provider(
            self.config.question_provider_id, {"openai_images"}
        )
        secret = self._secret(provider)
        if not secret:
            raise CategoryPipelineError("OpenAI question provider has no API key")
        provider = {**provider, "default_model": self.config.question_model}
        sibling_names = [
            item["name"]
            for item in self.database.studio_categories()
            if item["slug"] != category["slug"]
            and category_metadata_status(item)["ready"]
        ]
        previous = self.checkpoint.phase("question_banks").get("difficulties", {})
        results: dict[str, Any] = {}
        for difficulty in DIFFICULTIES:
            saved = previous.get(difficulty, {}) if isinstance(previous, dict) else {}
            attempts = list(saved.get("attempts", [])) if isinstance(saved, dict) else []
            total = self._bank_total(category["slug"], difficulty)
            results[difficulty] = {
                "total": total,
                "target": self.config.target_questions,
                "settled": total < self.config.target_questions,
                "attempts": attempts,
            }
        batches_used = sum(
            len(result["attempts"]) for result in results.values()
        )
        while batches_used < self.config.max_question_batches:
            pending = [
                difficulty
                for difficulty in DIFFICULTIES
                if results[difficulty]["total"] < self.config.target_questions
            ]
            if not pending:
                break
            difficulty = min(
                pending,
                key=lambda value: (
                    len(results[value]["attempts"]),
                    DIFFICULTIES.index(value),
                ),
            )
            total = int(results[difficulty]["total"])
            difficulty_batch = len(results[difficulty]["attempts"]) + 1
            number = batches_used + 1
            self._log(
                f"bank:{difficulty}",
                f"batch {number}/{self.config.max_question_batches} overall "
                f"({difficulty} batch {difficulty_batch}); {total}/"
                f"{self.config.target_questions} retained",
            )
            outcome: dict[str, Any] = {
                "batch": number,
                "difficulty_batch": difficulty_batch,
                "started_at_utc": _now(),
            }
            try:
                candidates, model = generate_questions(
                    category=category,
                    sibling_names=sibling_names,
                    difficulty=difficulty,
                    count=min(
                        self.config.question_batch_size,
                        self.config.target_questions - total,
                    ),
                    candidate_count=self.config.question_batch_size,
                    provider=provider,
                    secret=secret,
                    progress=lambda message, *_: self._log(
                        f"bank:{difficulty}", message
                    ),
                )
                imported = self.questions.import_questions(
                    category,
                    difficulty,
                    candidates,
                    action="generated",
                    source_provider=provider["id"],
                    source_model=model,
                    limit=self.config.target_questions - total,
                )
                outcome.update(
                    {
                        "status": "complete",
                        "candidate_count": len(candidates),
                        "accepted": imported["accepted"],
                        "rejected": imported["rejected"],
                        "model": model,
                    }
                )
            except Exception as exc:
                outcome.update({"status": "failed", "error": str(exc)})
                self._log(f"bank:{difficulty}", f"batch {number} failed: {exc}")
            results[difficulty]["attempts"].append(
                {**outcome, "completed_at_utc": _now()}
            )
            results[difficulty]["total"] = self._bank_total(
                category["slug"], difficulty
            )
            results[difficulty]["settled"] = (
                results[difficulty]["total"] < self.config.target_questions
            )
            batches_used += 1
            self.checkpoint.update(
                "question_banks",
                {
                    "status": "running",
                    "batches_used": batches_used,
                    "batch_limit": self.config.max_question_batches,
                    "difficulties": results,
                },
            )
        self.checkpoint.update(
            "question_banks",
            {
                "status": "complete",
                "batches_used": batches_used,
                "batch_limit": self.config.max_question_batches,
                "difficulties": results,
            },
        )
        return results

    def _select_sets(self, category: dict[str, Any]) -> dict[str, Any]:
        provider = self._provider(
            self.config.qwen_provider_id, {"openai_compatible_llm"}
        )
        model = self._model(provider, self.config.qwen_model)
        secret = self._secret(provider)
        results: dict[str, Any] = {}
        with VLLMClient(provider["base_url"], timeout_seconds=900, api_key=secret) as client:
            for index, difficulty in enumerate(DIFFICULTIES):
                inventory = self.sets.list_sets(category["slug"])["summary"]
                existing = int(inventory[difficulty])
                capacity = int(inventory["banks"][difficulty]["selection_capacity"])
                count = min(
                    self.config.sets_per_difficulty - existing,
                    capacity,
                )
                if count <= 0:
                    results[difficulty] = {
                        "status": "settled",
                        "created_count": 0,
                        "existing_count": existing,
                    }
                    continue
                self._log("sets", f"selecting {count} {difficulty} set(s)")
                try:
                    result = self.sets.select_sets(
                        category_slug=category["slug"],
                        difficulty=difficulty,
                        count=count,
                        client=client,
                        model=model,
                        seed=self.config.seed + index * 1_000_003,
                        strictness=self.config.strictness,
                        provider_id=provider["id"],
                        progress=lambda message, *_: self._log("sets", message),
                    )
                except Exception as exc:
                    result = {
                        "status": "failed",
                        "created_count": 0,
                        "existing_count": existing,
                        "error": str(exc),
                    }
                    self._log("sets", f"{difficulty} selection stopped: {exc}")
                results[difficulty] = result
                self.checkpoint.update(
                    "sets", {"status": "running", "difficulties": results}
                )
        summary = self.sets.list_sets(category["slug"])["summary"]
        if int(summary["total"]) < 1:
            raise CategoryPipelineError("Qwen did not commit any quiz sets")
        self.checkpoint.update(
            "sets",
            {"status": "complete", "difficulties": results, "summary": summary},
        )
        return results

    def _upload_background(self, category: dict[str, Any]) -> dict[str, Any]:
        if self.config.background is None:
            raise CategoryPipelineError("no uploaded background was configured")
        path = self.config.background.expanduser().resolve()
        if not path.is_file():
            raise CategoryPipelineError(f"background image does not exist: {path}")
        content_type = mimetypes.guess_type(path.name)[0] or "image/png"
        result = self.visuals.upload_background(category, path.read_bytes(), content_type)
        self.checkpoint.update(
            "background",
            {
                "status": "complete",
                "source": "user_upload",
                "source_file": str(path),
                "result": result,
            },
        )
        self._log("background", f"registered {path.name}")
        return result

    def _ensure_background(self, category: dict[str, Any]) -> dict[str, Any]:
        if self.config.background is not None:
            return self._upload_background(category)

        root = self.visuals.category_root(category["slug"])
        runtime_background = root / "assets/category/runtime_background.png"
        if (
            runtime_background.is_file()
            and not self.config.force_background
            and not self.config.refresh_background_plan
        ):
            try:
                with Image.open(runtime_background) as source:
                    source.verify()
            except (OSError, UnidentifiedImageError):
                self._log("background", "existing background is invalid; regenerating")
            else:
                result = {
                    "asset_id": "runtime_background",
                    "status": "approved",
                    "file": str(runtime_background),
                    "reused": True,
                }
                self.checkpoint.update(
                    "background",
                    {"status": "complete", "source": "existing", "result": result},
                )
                self._log("background", "reusing registered runtime background")
                return result

        work = root / "background-generation"
        plan_path = work / "background-prompt-plan.json"
        guidance = "\n\n".join(
            value.strip()
            for value in (
                category.get("editorial_brief"),
                self.config.background_guidance,
            )
            if value and value.strip()
        )
        self.checkpoint.update(
            "background",
            {
                "status": "planning",
                "planner_provider_id": self.config.qwen_provider_id,
                "image_provider_id": self.config.background_provider_id,
            },
        )
        self._log("background", "planning category background with Qwen")
        planned = plan_quiz_background_prompt(
            category=category["name"],
            display_title=category["display_title"],
            subtitle="ADVENTURE",
            provider_id=self.config.qwen_provider_id,
            database_path=self.config.database_path,
            secret_key_file=self.config.secret_key_file,
            output=plan_path,
            model_override=self.config.qwen_model,
            category_guidance=guidance or None,
            seed=self.config.seed,
            force=self.config.refresh_background_plan,
        )
        plan_document = planned["plan"]
        planning = {
            **planned,
            "plan": plan_document.model_dump(mode="json"),
        }
        self.checkpoint.update(
            "background", {"status": "generating", "planning": planning}
        )
        self._log(
            "background",
            f"rendering category background with {self.config.background_provider_id}",
        )
        generated = generate_quiz_background(
            category=category["name"],
            display_title=category["display_title"],
            provider_id=self.config.background_provider_id,
            database_path=self.config.database_path,
            secret_key_file=self.config.secret_key_file,
            output=work / "runtime_background.png",
            model_override=self.config.background_model,
            quality=self.config.image_quality,
            seed=self.config.seed,
            subtitle="ADVENTURE",
            prompt_override=plan_document.prompt,
            planning_metadata=planning,
            force=self.config.force_background,
        )
        uploaded = self.visuals.upload_background(
            category, Path(generated["image"]["file"]).read_bytes(), "image/png"
        )
        result = {
            "source": "generated",
            "planning": planning,
            "generation": generated,
            "registration": uploaded,
        }
        self.checkpoint.update(
            "background", {"status": "complete", "source": "generated", "result": result}
        )
        return result

    def _audio_branch(self, category: dict[str, Any]) -> dict[str, Any]:
        provider = self._provider(self.config.audio_provider_id, {"vibevoice"})
        self.checkpoint.update("audio", {"status": "running"})
        result = self.audio.generate(
            category=category,
            provider=provider,
            clip_ids=None,
            force=self.config.force_media,
            audit_repairs=self.config.whisper_retries,
            duration_fallback_seconds=self.config.audio_duration_seconds,
            max_duration_repairs=self.config.audio_duration_retries,
            progress=lambda message, *_: self._log("audio", message),
        )
        inventory = self.audio.inventory(category)
        if inventory["summary"]["passed"] != inventory["summary"]["clips_total"]:
            raise CategoryPipelineError(
                "audio branch ended with clips that did not pass audit or duration recovery"
            )
        self.checkpoint.update(
            "audio", {"status": "complete", "result": result, "summary": inventory["summary"]}
        )
        return result

    def _generate_visual_group(
        self,
        *,
        category: dict[str, Any],
        provider_id: str,
        model_override: str | None,
        asset_ids: set[str],
    ) -> dict[str, Any]:
        if not asset_ids:
            return {"requested": 0, "generated": 0, "reused": 0, "failed": 0}
        provider = self._provider(provider_id, {"openai_images", "imagestudio"})
        secret = self._secret(provider)
        if provider["provider_type"] == "openai_images" and not secret:
            raise CategoryPipelineError(f"OpenAI image provider has no API key: {provider_id}")
        model = self._model(provider, model_override)
        result = self.visuals.generate_images(
            category=category,
            asset_ids=asset_ids,
            provider=provider,
            secret=secret,
            model=model,
            quality=self.config.image_quality,
            force=self.config.force_media,
            progress=lambda message, *_: self._log("visuals", message),
        )
        if result["failed"]:
            raise CategoryPipelineError(
                f"{provider_id} failed to generate {result['failed']} visual asset(s)"
            )
        return result

    def _visual_branch(self, category: dict[str, Any]) -> dict[str, Any]:
        background = self._ensure_background(category)
        qwen = self._provider(
            self.config.qwen_provider_id, {"openai_compatible_llm"}
        )
        qwen_model = self._model(qwen, self.config.qwen_model)
        qwen_secret = self._secret(qwen)
        self.checkpoint.update("visuals", {"status": "planning"})
        with VLLMClient(
            qwen["base_url"], timeout_seconds=900, api_key=qwen_secret
        ) as client:
            plan = self.visuals.plan_prompts(
                category=category,
                client=client,
                endpoint=qwen["base_url"],
                model=qwen_model,
                roles={"selector", "tiles", "answers"},
                guidance=category["editorial_brief"],
                seed=self.config.seed,
                force=False,
                progress=lambda message, *_: self._log("visuals", message),
            )
        inventory = self.visuals.inventory(category)
        category_ids = {
            item["asset_id"]
            for item in inventory["assets"]
            if item["role"] in {"category_selector", "quiz_tile"}
        }
        answer_ids = {
            item["asset_id"]
            for item in inventory["assets"]
            if item["role"] == "answer_image"
        }
        self.checkpoint.update(
            "visuals",
            {
                "status": "generating",
                "plan": plan,
                "category_asset_count": len(category_ids),
                "answer_asset_count": len(answer_ids),
            },
        )
        if self.config.tile_provider_id == self.config.answer_provider_id:
            runs = {
                "all": self._generate_visual_group(
                    category=category,
                    provider_id=self.config.tile_provider_id,
                    model_override=self.config.tile_model or self.config.answer_model,
                    asset_ids=category_ids | answer_ids,
                )
            }
        else:
            runs = {
                "category": self._generate_visual_group(
                    category=category,
                    provider_id=self.config.tile_provider_id,
                    model_override=self.config.tile_model,
                    asset_ids=category_ids,
                ),
                "answers": self._generate_visual_group(
                    category=category,
                    provider_id=self.config.answer_provider_id,
                    model_override=self.config.answer_model,
                    asset_ids=answer_ids,
                ),
            }
        final_inventory = self.visuals.inventory(category)
        if final_inventory["summary"]["generated"] != final_inventory["summary"]["total"]:
            raise CategoryPipelineError("visual branch ended with missing assets")
        result = {
            "background": background,
            "plan": plan,
            "runs": runs,
            "summary": final_inventory["summary"],
        }
        self.checkpoint.update("visuals", {"status": "complete", "result": result})
        return result

    def _run_media(self, category: dict[str, Any]) -> dict[str, Any]:
        results: dict[str, Any] = {}
        failures: dict[str, str] = {}
        with ThreadPoolExecutor(max_workers=2, thread_name_prefix="quiz-pipeline") as pool:
            futures = {
                pool.submit(self._audio_branch, category): "audio",
                pool.submit(self._visual_branch, category): "visuals",
            }
            for future in as_completed(futures):
                name = futures[future]
                try:
                    results[name] = future.result()
                except Exception as exc:
                    failures[name] = str(exc)
                    self.checkpoint.update(name, {"status": "failed", "error": str(exc)})
        if failures:
            raise CategoryPipelineError(
                "media branch failure: "
                + "; ".join(f"{name}: {error}" for name, error in failures.items())
            )
        return results

    def _publish(self, category: dict[str, Any]) -> dict[str, Any]:
        readiness = self.publisher.inventory(category)
        if not readiness["ready"]:
            blocked = ", ".join(
                gate["label"]
                for gate in readiness["gates"]
                if gate["status"] != "ready"
            )
            raise CategoryPipelineError(f"publish gates are blocked: {blocked}")
        result = self.publisher.publish(
            category=category,
            force_new_version=self.config.force_new_bundle,
            progress=lambda message, *_: self._log("publish", message),
        )
        self.checkpoint.update("publish", {"status": "complete", "result": result})
        return result

    def run(self) -> dict[str, Any]:
        self._validate_inputs()
        self._ensure_idle()
        category = self._ensure_category()
        banks = self._generate_banks(category)
        sets = self._select_sets(category)
        media = self._run_media(category)
        published = self._publish(category)
        result = {
            "status": "complete",
            "category_slug": category["slug"],
            "banks": banks,
            "sets": sets,
            "media": media,
            "publish": published,
            "checkpoint": str(self.checkpoint.path),
        }
        self.checkpoint.update("pipeline", {"status": "complete", "result": result})
        return result


def run_category_pipeline(
    config: CategoryPipelineConfig,
    *,
    progress: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    return CategoryProductionPipeline(config, progress=progress).run()
