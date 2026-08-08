from __future__ import annotations

import asyncio
import fcntl
import io
import json
import os
import re
import secrets
import sqlite3
import threading
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from fastapi import FastAPI, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import Field

from .database import QuizDatabase
from .models import StrictModel
from .production_pipeline import (
    CategoryPipelineConfig,
    CategoryPipelineMetadata,
    run_category_pipeline,
)
from .provider_service import PROVIDER_TYPES, normalize_base_url, run_provider_test
from .secure_store import SecretStore
from .studio_publish import StudioPublishError, StudioPublishStore
from .vibevoice_audio import DEFAULT_REFERENCE_TRANSCRIPT


ROOT = Path(__file__).resolve().parent.parent
DATABASE_PATH = Path(os.getenv("QUIZ_DATABASE_PATH", ROOT / "data/quiz_harness.db"))
SOURCE_ROOT = Path(os.getenv("QUIZ_STUDIO_SOURCE_ROOT", ROOT / "visual_quiz_qwen"))
BUNDLE_ROOT = Path(
    os.getenv("QUIZ_CATEGORY_BUNDLE_ROOT", ROOT / "dist/category_bundles")
)
SECRET_KEY_FILE = Path(
    os.getenv("QUIZ_SECRET_KEY_FILE", ROOT / "data/.provider_secret_key")
)
LOCK_PATH = Path(os.getenv("QUIZ_PIPELINE_LOCK", "/run/quizmaster/pipeline.lock"))
PROVIDER_TEST_ROOT = Path(
    os.getenv("QUIZ_PROVIDER_TEST_ROOT", ROOT / "data/assets/provider-tests")
)
PROVIDER_AUDIO_ROOT = Path(
    os.getenv("QUIZ_PROVIDER_AUDIO_ROOT", ROOT / "data/assets/provider-audio")
)
PUBLIC_BASE_URL = os.getenv(
    "QUIZMASTER_PUBLIC_BASE_URL", "https://quizmaster.photovault.live"
).rstrip("/")

PIPELINE_JOB_KIND = "category_pipeline_api"
PROVIDER_TEST_JOB_KIND = "pipeline_provider_test"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "quiz"


def _authorized(headers: Any, expected_token: str) -> bool:
    supplied = str(headers.get("x-quizmaster-token") or "").strip()
    authorization = str(headers.get("authorization") or "").strip()
    if authorization.casefold().startswith("bearer "):
        supplied = authorization[7:].strip()
    return bool(supplied) and secrets.compare_digest(supplied, expected_token)


class ProviderCreateRequest(StrictModel):
    provider_type: str = Field(pattern="^(imagestudio|openai_images|openai_compatible_llm|vibevoice)$")
    name: str = Field(min_length=2, max_length=80)
    base_url: str = Field(min_length=8, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    default_model: str | None = Field(default=None, max_length=200)
    settings: dict[str, Any] = Field(default_factory=dict)
    enabled: bool = True


class ProviderUpdateRequest(StrictModel):
    name: str | None = Field(default=None, min_length=2, max_length=80)
    base_url: str | None = Field(default=None, min_length=8, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    clear_api_key: bool = False
    default_model: str | None = Field(default=None, max_length=200)
    settings: dict[str, Any] | None = None
    enabled: bool | None = None


class PipelineProviders(StrictModel):
    question_provider: str = "openai-images"
    question_model: str = "gpt-5.6-luna"
    qwen_provider: str = "llm-default"
    qwen_model: str | None = None
    background_provider: str = "openai-images"
    background_model: str | None = None
    tile_provider: str = "openai-images"
    tile_model: str | None = None
    answer_provider: str = "imagestudio-local"
    answer_model: str | None = None
    audio_provider: str = "vibevoice-local"


class PipelineSettings(StrictModel):
    target_questions: int = Field(default=150, ge=1, le=150)
    question_batch_size: int = Field(default=50, ge=1, le=50)
    max_question_batches: int = Field(default=6, ge=1, le=6)
    sets_per_difficulty: int = Field(default=10, ge=1, le=10)
    strictness: str = Field(default="strict", pattern="^(strict|balanced)$")
    seed: int = Field(default=20260805, ge=0, le=2_147_483_647)
    image_quality: str = Field(default="medium", pattern="^(low|medium|high)$")
    whisper_retries: int = Field(default=3, ge=0, le=4)
    audio_duration_seconds: float = Field(default=12.0, gt=0, le=60)
    audio_duration_retries: int | None = Field(default=None, ge=0, le=20)
    background_guidance: str | None = Field(default=None, max_length=2000)
    force_media: bool = False
    force_background: bool = False
    refresh_background_plan: bool = False
    force_new_bundle: bool = False


class PipelineStartRequest(StrictModel):
    metadata: CategoryPipelineMetadata
    providers: PipelineProviders = Field(default_factory=PipelineProviders)
    settings: PipelineSettings = Field(default_factory=PipelineSettings)


class DeployRequest(StrictModel):
    version: int | None = Field(default=None, ge=1)


class PipelineBusyError(RuntimeError):
    def __init__(self, holder: dict[str, Any]) -> None:
        super().__init__("quiz generation pipeline is already in use")
        self.holder = holder


class PipelineLease:
    def __init__(self, handle: Any, path: Path) -> None:
        self._handle = handle
        self.path = path
        self._released = False

    def release(self) -> None:
        if self._released:
            return
        try:
            self._handle.seek(0)
            self._handle.truncate()
            self._handle.flush()
            os.fsync(self._handle.fileno())
            fcntl.flock(self._handle.fileno(), fcntl.LOCK_UN)
        finally:
            self._handle.close()
            self._released = True


class PipelineLock:
    def __init__(self, path: Path) -> None:
        self.path = path

    @staticmethod
    def _read_holder(handle: Any) -> dict[str, Any]:
        try:
            handle.seek(0)
            value = json.loads(handle.read() or "{}")
        except (OSError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def acquire(self, holder: dict[str, Any]) -> PipelineLease:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+", encoding="utf-8")
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            current = self._read_holder(handle)
            handle.close()
            raise PipelineBusyError(current) from exc
        handle.seek(0)
        handle.truncate()
        handle.write(json.dumps(holder, ensure_ascii=True))
        handle.flush()
        os.fsync(handle.fileno())
        return PipelineLease(handle, self.path)

    def status(self) -> dict[str, Any]:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        handle = self.path.open("a+", encoding="utf-8")
        try:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return {"busy": True, "holder": self._read_holder(handle)}
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
            return {"busy": False, "holder": None}
        finally:
            handle.close()


class PersistentJobRunner:
    def __init__(self, database: QuizDatabase) -> None:
        self.database = database
        self.executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="pipeline-api")

    def start(
        self,
        *,
        job_id: str,
        kind: str,
        target: Callable[[Callable[[str, float | None], None]], dict[str, Any]],
        context: dict[str, Any],
        lease: PipelineLease | None = None,
    ) -> dict[str, Any]:
        created = _now()
        self.database.create_studio_job(
            {
                "id": job_id,
                "kind": kind,
                "status": "queued",
                "message": "Queued",
                "progress": 0,
                "context": {**context, "api": "quizmaster-pipeline-v1"},
                "created_at": created,
                "updated_at": created,
            }
        )
        progress_value = 0.0
        progress_lock = threading.Lock()
        lease_released = False

        def release_lease() -> None:
            nonlocal lease_released
            if lease is not None and not lease_released:
                lease.release()
                lease_released = True

        def update(message: str, progress: float | None = None) -> None:
            nonlocal progress_value
            with progress_lock:
                if progress is not None:
                    progress_value = max(progress_value, min(0.98, float(progress)))
                self.database.update_studio_job(
                    job_id,
                    status="running",
                    message=message,
                    progress=progress_value,
                    updated_at=_now(),
                )

        def run() -> None:
            update("Starting", 0.01)
            try:
                result = target(update)
            except Exception as exc:
                release_lease()
                self.database.update_studio_job(
                    job_id,
                    status="failed",
                    message="Failed",
                    progress=progress_value,
                    error=str(exc),
                    updated_at=_now(),
                )
            else:
                release_lease()
                self.database.update_studio_job(
                    job_id,
                    status="complete",
                    message="Bundle ready for deployment",
                    progress=1,
                    result=result,
                    updated_at=_now(),
                )
            finally:
                release_lease()

        try:
            self.executor.submit(run)
        except Exception:
            release_lease()
            raise
        return self.database.studio_job(job_id)

    def shutdown(self) -> None:
        self.executor.shutdown(wait=False, cancel_futures=False)


class PipelineProgress:
    PHASE_FLOORS = {
        "metadata": 0.03,
        "bank": 0.08,
        "sets": 0.4,
        "background": 0.5,
        "audio": 0.52,
        "visuals": 0.52,
        "publish": 0.92,
    }

    def __init__(self, update: Callable[[str, float | None], None]) -> None:
        self.update = update
        self.value = 0.02
        self.lock = threading.Lock()

    def __call__(self, message: str) -> None:
        phase = message.removeprefix("[").split("]", 1)[0].split(":", 1)[0]
        with self.lock:
            floor = self.PHASE_FLOORS.get(phase, self.value)
            ceiling = 0.91 if phase in {"background", "audio", "visuals"} else 0.97
            self.value = min(ceiling, max(floor, self.value + 0.003))
            self.update(message, self.value)


class PipelineApiService:
    def __init__(
        self,
        *,
        database_path: Path,
        source_root: Path,
        bundle_root: Path,
        secret_key_file: Path,
        lock_path: Path,
        provider_test_root: Path,
        provider_audio_root: Path,
    ) -> None:
        self.database_path = database_path
        self.source_root = source_root
        self.bundle_root = bundle_root
        self.secret_key_file = secret_key_file
        self.provider_test_root = provider_test_root
        self.provider_audio_root = provider_audio_root
        self.database = QuizDatabase(database_path)
        self.database.migrate()
        self.secrets = SecretStore(
            key=os.getenv("QUIZ_SECRET_KEY"), key_file=secret_key_file
        )
        self.publisher = StudioPublishStore(source_root, bundle_root)
        self.lock = PipelineLock(lock_path)
        self.jobs = PersistentJobRunner(self.database)
        provider_test_root.mkdir(parents=True, exist_ok=True)
        provider_audio_root.mkdir(parents=True, exist_ok=True)
        self._seed_providers()

    def _seed_providers(self) -> None:
        self.database.seed_provider_connections(
            [
                {
                    "id": "llm-default",
                    "provider_type": "openai_compatible_llm",
                    "name": "Quiz planning LLM",
                    "base_url": os.getenv(
                        "QUIZ_VLLM_BASE_URL", "http://10.8.0.5:8001/v1"
                    ),
                },
                {
                    "id": "imagestudio-local",
                    "provider_type": "imagestudio",
                    "name": "Local ImageStudio",
                    "base_url": os.getenv(
                        "QUIZ_IMAGESTUDIO_BASE_URL", "http://127.0.0.1:8000"
                    ),
                    "default_model": "ernie-turbo",
                },
                {
                    "id": "openai-images",
                    "provider_type": "openai_images",
                    "name": "OpenAI Images",
                    "base_url": os.getenv(
                        "QUIZ_OPENAI_BASE_URL", "https://api.openai.com/v1"
                    ),
                    "default_model": "gpt-image-2",
                },
                {
                    "id": "vibevoice-local",
                    "provider_type": "vibevoice",
                    "name": "Quiz narrator",
                    "base_url": os.getenv(
                        "QUIZ_VIBEVOICE_BASE_URL", "http://127.0.0.1:8092"
                    ),
                    "settings": {
                        "reference_audio_path": str(ROOT / "amit.wav"),
                        "reference_transcript": DEFAULT_REFERENCE_TRANSCRIPT,
                        "language": "en_indian",
                        "cfg_scale": 1.3,
                        "output_format": "mp3",
                    },
                },
            ]
        )

    @staticmethod
    def public_provider(provider: dict[str, Any]) -> dict[str, Any]:
        result = {
            key: value
            for key, value in provider.items()
            if key not in {"secret_ciphertext", "secret_fingerprint", "secret_last_four"}
        }
        result["has_secret"] = bool(provider.get("secret_ciphertext"))
        result["secret_hint"] = (
            f"...{provider['secret_last_four']}"
            if provider.get("secret_last_four")
            else None
        )
        result["type_label"] = PROVIDER_TYPES[provider["provider_type"]]
        return result

    def secret_values(self, value: str | None) -> dict[str, str | None]:
        if not value or not value.strip():
            return {
                "secret_ciphertext": None,
                "secret_fingerprint": None,
                "secret_last_four": None,
            }
        return {
            "secret_ciphertext": self.secrets.encrypt(value),
            "secret_fingerprint": self.secrets.fingerprint(value),
            "secret_last_four": self.secrets.last_four(value),
        }

    def validate_pipeline_providers(self, selected: PipelineProviders) -> None:
        expected = (
            (selected.question_provider, {"openai_images"}),
            (selected.qwen_provider, {"openai_compatible_llm"}),
            (selected.background_provider, {"openai_images", "imagestudio"}),
            (selected.tile_provider, {"openai_images", "imagestudio"}),
            (selected.answer_provider, {"openai_images", "imagestudio"}),
            (selected.audio_provider, {"vibevoice"}),
        )
        for provider_id, types in expected:
            try:
                provider = self.database.provider_connection(provider_id)
            except KeyError as exc:
                raise ValueError(f"provider does not exist: {provider_id}") from exc
            if not provider["enabled"]:
                raise ValueError(f"provider is disabled: {provider_id}")
            if provider["provider_type"] not in types:
                raise ValueError(
                    f"provider {provider_id} must be one of {sorted(types)}"
                )

    def start_pipeline(self, payload: PipelineStartRequest) -> dict[str, Any]:
        self.validate_pipeline_providers(payload.providers)
        job_id = uuid.uuid4().hex
        category_slug = payload.metadata.slug or _slug(payload.metadata.name)
        holder = {
            "job_id": job_id,
            "category": payload.metadata.name,
            "category_slug": category_slug,
            "acquired_at_utc": _now(),
            "pid": os.getpid(),
        }
        lease = self.lock.acquire(holder)
        providers = payload.providers
        settings = payload.settings
        config = CategoryPipelineConfig(
            metadata=payload.metadata,
            background=None,
            database_path=self.database_path,
            source_root=self.source_root,
            bundle_root=self.bundle_root,
            secret_key_file=self.secret_key_file,
            question_provider_id=providers.question_provider,
            question_model=providers.question_model,
            qwen_provider_id=providers.qwen_provider,
            qwen_model=providers.qwen_model,
            background_provider_id=providers.background_provider,
            background_model=providers.background_model,
            background_guidance=settings.background_guidance,
            tile_provider_id=providers.tile_provider,
            tile_model=providers.tile_model,
            answer_provider_id=providers.answer_provider,
            answer_model=providers.answer_model,
            audio_provider_id=providers.audio_provider,
            target_questions=settings.target_questions,
            question_batch_size=settings.question_batch_size,
            max_question_batches=settings.max_question_batches,
            sets_per_difficulty=settings.sets_per_difficulty,
            strictness=settings.strictness,
            seed=settings.seed,
            image_quality=settings.image_quality,
            whisper_retries=settings.whisper_retries,
            audio_duration_seconds=settings.audio_duration_seconds,
            audio_duration_retries=settings.audio_duration_retries,
            force_media=settings.force_media,
            force_background=settings.force_background,
            refresh_background_plan=settings.refresh_background_plan,
            force_new_bundle=settings.force_new_bundle,
            activate_bundle=False,
            allow_active_jobs=True,
        )

        def target(update: Callable[[str, float | None], None]) -> dict[str, Any]:
            return run_category_pipeline(config, progress=PipelineProgress(update))

        try:
            return self.jobs.start(
                job_id=job_id,
                kind=PIPELINE_JOB_KIND,
                target=target,
                context={
                    "category_slug": category_slug,
                    "category_name": payload.metadata.name,
                    "providers": providers.model_dump(mode="json"),
                },
                lease=lease,
            )
        except Exception:
            lease.release()
            raise

    def pipeline_jobs(self, limit: int = 50) -> list[dict[str, Any]]:
        return [
            item
            for item in self.database.studio_jobs(limit=limit)
            if item["kind"] == PIPELINE_JOB_KIND
        ]

    def pipeline_job(self, job_id: str) -> dict[str, Any]:
        job = self.database.studio_job(job_id)
        if job["kind"] != PIPELINE_JOB_KIND:
            raise KeyError(job_id)
        context = job.get("context", {})
        slug = context.get("category_slug")
        checkpoint = None
        if isinstance(slug, str) and slug:
            path = self.source_root / slug / "pipeline-run.json"
            try:
                checkpoint = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                checkpoint = None
        return {**job, "checkpoint": checkpoint}

    def bundle_summary(
        self, category: dict[str, Any], *, detail: bool = False
    ) -> dict[str, Any]:
        inventory = self.publisher.inventory(category)
        versions = [
            {
                **item,
                "download_url": (
                    f"{PUBLIC_BASE_URL}/api/v1/bundles/{category['slug']}/"
                    f"versions/{item['bundle_version']}/download"
                ),
            }
            for item in inventory.get("versions", [])
        ]
        latest = versions[0] if versions else None
        current = next((item for item in versions if item.get("is_current")), None)
        if latest and latest.get("is_current"):
            status = "deployed"
        elif latest:
            status = "deployable"
        else:
            status = "not_built"
        result = {
            "category": {
                key: category.get(key)
                for key in ("slug", "name", "display_title", "display_tag")
            },
            "status": status,
            "deploy_url": f"{PUBLIC_BASE_URL}/api/v1/bundles/{category['slug']}/deploy",
            "ready_to_build": inventory["ready"],
            "current": current,
            "latest": latest,
            "version_count": len(versions),
            "warnings": inventory.get("warnings", []),
            "summary": inventory.get("summary", {}),
        }
        if detail:
            result["versions"] = versions
            result["gates"] = inventory.get("gates", [])
        return result


def create_app(
    *,
    database_path: Path | None = None,
    source_root: Path | None = None,
    bundle_root: Path | None = None,
    secret_key_file: Path | None = None,
    lock_path: Path | None = None,
    provider_test_root: Path | None = None,
    provider_audio_root: Path | None = None,
    api_token: str | None = None,
    require_auth: bool | None = None,
) -> FastAPI:
    resolved_token = (
        api_token
        if api_token is not None
        else os.getenv("QUIZMASTER_API_TOKEN", "")
    ).strip()
    auth_required = (
        require_auth
        if require_auth is not None
        else os.getenv("QUIZMASTER_REQUIRE_AUTH", "0") == "1"
    )
    if auth_required and not resolved_token:
        raise RuntimeError(
            "QUIZMASTER_API_TOKEN is required when QUIZMASTER_REQUIRE_AUTH=1"
        )
    service = PipelineApiService(
        database_path=Path(database_path or DATABASE_PATH),
        source_root=Path(source_root or SOURCE_ROOT),
        bundle_root=Path(bundle_root or BUNDLE_ROOT),
        secret_key_file=Path(secret_key_file or SECRET_KEY_FILE),
        lock_path=Path(lock_path or LOCK_PATH),
        provider_test_root=Path(provider_test_root or PROVIDER_TEST_ROOT),
        provider_audio_root=Path(provider_audio_root or PROVIDER_AUDIO_ROOT),
    )
    @asynccontextmanager
    async def lifespan(_: FastAPI) -> Any:
        if not service.lock.status()["busy"]:
            service.database.mark_interrupted_jobs(
                _now(), kinds={PIPELINE_JOB_KIND, PROVIDER_TEST_JOB_KIND}
            )
        yield
        service.jobs.shutdown()

    app = FastAPI(
        title="Quizmaster Creation API",
        version="1.0.0",
        docs_url="/docs",
        redoc_url=None,
        lifespan=lifespan,
    )
    app.state.service = service
    app.add_middleware(
        CORSMiddleware,
        allow_origins=["*"],
        allow_methods=["*"],
        allow_headers=["*"],
    )

    @app.middleware("http")
    async def authentication(request: Request, call_next: Callable[..., Any]) -> Any:
        public = request.method == "OPTIONS" or request.url.path in {
            "/health",
            "/api/v1/health",
            "/docs",
            "/openapi.json",
        }
        if auth_required and not public and not _authorized(
            request.headers, resolved_token
        ):
            return JSONResponse(
                status_code=401,
                content={"detail": "Valid Quizmaster API token required"},
                headers={"WWW-Authenticate": "Bearer"},
            )
        return await call_next(request)
    app.mount(
        "/provider-tests",
        StaticFiles(directory=service.provider_test_root),
        name="provider-tests",
    )

    def require_pipeline_idle() -> None:
        state = service.lock.status()
        if state["busy"]:
            raise HTTPException(
                status_code=409,
                detail={
                    "message": "Provider configuration is locked during generation",
                    "holder": state["holder"],
                },
            )

    @app.get("/health")
    @app.get("/api/v1/health")
    def health() -> dict[str, Any]:
        return {
            "status": "ok",
            "service": "quizmaster-creation-api",
            "api_version": "v1",
            "public_base_url": PUBLIC_BASE_URL,
            "authentication": "bearer" if auth_required else "none",
            "pipeline_lock": service.lock.status(),
            "time": _now(),
        }

    @app.get("/api/v1/providers")
    def providers() -> dict[str, Any]:
        return {
            "provider_types": [
                {"id": provider_id, "label": label}
                for provider_id, label in PROVIDER_TYPES.items()
            ],
            "providers": [
                service.public_provider(item)
                for item in service.database.provider_connections()
            ],
        }

    @app.post("/api/v1/providers", status_code=201)
    def create_provider(payload: ProviderCreateRequest) -> dict[str, Any]:
        require_pipeline_idle()
        try:
            base_url = normalize_base_url(payload.base_url)
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        provider_id = f"{payload.provider_type}-{uuid.uuid4().hex[:12]}"
        settings = dict(payload.settings)
        if payload.provider_type == "vibevoice":
            settings = {
                "reference_audio_path": str(ROOT / "amit.wav"),
                "reference_transcript": DEFAULT_REFERENCE_TRANSCRIPT,
                "language": "en_indian",
                "cfg_scale": 1.3,
                "output_format": "mp3",
                **settings,
            }
        try:
            provider = service.database.create_provider_connection(
                {
                    "id": provider_id,
                    "provider_type": payload.provider_type,
                    "name": payload.name.strip(),
                    "base_url": base_url,
                    "default_model": payload.default_model,
                    "settings": settings,
                    "enabled": payload.enabled,
                    **service.secret_values(payload.api_key),
                }
            )
        except sqlite3.IntegrityError as exc:
            raise HTTPException(status_code=409, detail="Provider already exists") from exc
        return service.public_provider(provider)

    @app.patch("/api/v1/providers/{provider_id}")
    def update_provider(
        provider_id: str, payload: ProviderUpdateRequest
    ) -> dict[str, Any]:
        require_pipeline_idle()
        try:
            existing = service.database.provider_connection(provider_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Provider not found") from exc
        changes = payload.model_dump(exclude_unset=True)
        api_key = changes.pop("api_key", None)
        clear_api_key = bool(changes.pop("clear_api_key", False))
        if "base_url" in changes:
            try:
                changes["base_url"] = normalize_base_url(changes["base_url"])
            except ValueError as exc:
                raise HTTPException(status_code=422, detail=str(exc)) from exc
        if "name" in changes:
            changes["name"] = changes["name"].strip()
        if api_key is not None and api_key.strip():
            changes.update(service.secret_values(api_key))
        elif clear_api_key:
            changes.update(service.secret_values(None))
        if "settings" in changes and changes["settings"] is not None:
            changes["settings"] = {
                **existing.get("settings", {}),
                **changes["settings"],
            }
        return service.public_provider(
            service.database.update_provider_connection(provider_id, changes)
        )

    @app.post("/api/v1/providers/{provider_id}/test", status_code=202)
    def test_provider(provider_id: str) -> dict[str, Any]:
        require_pipeline_idle()
        try:
            provider = service.database.provider_connection(provider_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Provider not found") from exc
        if not provider["enabled"]:
            raise HTTPException(status_code=409, detail="Provider is disabled")
        job_id = uuid.uuid4().hex
        secret = service.secrets.decrypt(provider.get("secret_ciphertext"))

        def target(update: Callable[[str, float | None], None]) -> dict[str, Any]:
            try:
                result = run_provider_test(
                    provider,
                    secret,
                    artifact_root=service.provider_test_root,
                    progress=lambda message, progress: update(message, progress),
                )
            except Exception as exc:
                service.database.update_provider_health(
                    provider_id,
                    status="unhealthy",
                    message=str(exc)[:500],
                    checked_at=_now(),
                )
                raise
            service.database.update_provider_health(
                provider_id,
                status="healthy",
                message=result["message"],
                checked_at=_now(),
                models=result.get("models", []),
                default_model=result.get("details", {}).get("default_model"),
            )
            return {"provider_id": provider_id, **result}

        return service.jobs.start(
            job_id=job_id,
            kind=PROVIDER_TEST_JOB_KIND,
            target=target,
            context={"provider_id": provider_id},
        )

    @app.post("/api/v1/providers/{provider_id}/reference-audio")
    async def upload_reference_audio(
        provider_id: str, request: Request
    ) -> dict[str, Any]:
        require_pipeline_idle()
        try:
            provider = service.database.provider_connection(provider_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Provider not found") from exc
        if provider["provider_type"] != "vibevoice":
            raise HTTPException(status_code=422, detail="Provider is not VibeVoice")
        data = await request.body()
        if not data or len(data) > 25 * 1024 * 1024:
            raise HTTPException(status_code=422, detail="WAV must be 1 byte to 25 MB")
        try:
            with wave.open(io.BytesIO(data), "rb") as source:
                channels = source.getnchannels()
                sample_rate = source.getframerate()
                sample_width = source.getsampwidth()
                frames = source.getnframes()
        except (EOFError, wave.Error) as exc:
            raise HTTPException(status_code=422, detail=f"Invalid WAV: {exc}") from exc
        duration = frames / float(sample_rate or 1)
        if channels not in {1, 2} or sample_width not in {1, 2, 3, 4}:
            raise HTTPException(status_code=422, detail="WAV must contain PCM mono/stereo audio")
        if sample_rate < 8_000 or sample_rate > 96_000 or not 2 <= duration <= 120:
            raise HTTPException(status_code=422, detail="WAV must be 2-120 seconds at 8-96 kHz")
        output = service.provider_audio_root / provider_id / "reference.wav"
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_suffix(".wav.tmp")
        temporary.write_bytes(data)
        temporary.replace(output)
        updated = service.database.update_provider_connection(
            provider_id,
            {
                "settings": {
                    **provider.get("settings", {}),
                    "reference_audio_path": str(output),
                }
            },
        )
        return {
            "provider": service.public_provider(updated),
            "reference_audio": {
                "duration_seconds": round(duration, 3),
                "sample_rate": sample_rate,
                "channels": channels,
            },
        }

    @app.get("/api/v1/pipeline/options")
    def pipeline_options() -> dict[str, Any]:
        providers = [
            service.public_provider(item)
            for item in service.database.provider_connections()
            if item["enabled"]
        ]
        return {
            "defaults": {
                "providers": PipelineProviders().model_dump(mode="json"),
                "settings": PipelineSettings().model_dump(mode="json"),
            },
            "providers": providers,
            "roles": {
                "question": ["openai_images"],
                "qwen": ["openai_compatible_llm"],
                "background": ["openai_images", "imagestudio"],
                "tile": ["openai_images", "imagestudio"],
                "answer": ["openai_images", "imagestudio"],
                "audio": ["vibevoice"],
            },
        }

    @app.get("/api/v1/pipeline/lock")
    def pipeline_lock() -> dict[str, Any]:
        return service.lock.status()

    @app.post("/api/v1/pipelines", status_code=202)
    def start_pipeline(payload: PipelineStartRequest) -> dict[str, Any]:
        try:
            return service.start_pipeline(payload)
        except PipelineBusyError as exc:
            raise HTTPException(
                status_code=409,
                detail={"message": str(exc), "holder": exc.holder},
            ) from exc
        except ValueError as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.get("/api/v1/pipelines")
    def pipeline_jobs(limit: int = 30) -> dict[str, Any]:
        return {"jobs": service.pipeline_jobs(max(1, min(limit, 100)))}

    @app.get("/api/v1/pipelines/current")
    def current_pipeline() -> dict[str, Any]:
        active = next(
            (
                item
                for item in service.pipeline_jobs(100)
                if item["status"] in {"queued", "running"}
            ),
            None,
        )
        if active is not None:
            active = service.pipeline_job(active["id"])
        return {"lock": service.lock.status(), "job": active}

    @app.get("/api/v1/pipelines/{job_id}")
    def pipeline_job(job_id: str) -> dict[str, Any]:
        try:
            return service.pipeline_job(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Pipeline job not found") from exc

    @app.get("/api/v1/pipelines/{job_id}/events")
    def pipeline_events(job_id: str, after: int = 0) -> dict[str, Any]:
        try:
            job = service.pipeline_job(job_id)
            events = service.database.studio_job_events(job_id, after=max(0, after))
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Pipeline job not found") from exc
        return {"job": job, "events": events}

    @app.get("/api/v1/pipelines/{job_id}/stream")
    def pipeline_stream(job_id: str) -> StreamingResponse:
        try:
            service.pipeline_job(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Pipeline job not found") from exc

        async def stream() -> Any:
            after = 0
            while True:
                for event in service.database.studio_job_events(job_id, after=after):
                    after = event["id"]
                    yield f"id: {after}\nevent: job\ndata: {json.dumps(event)}\n\n"
                job = service.pipeline_job(job_id)
                if job["status"] in {"complete", "failed", "cancelled", "interrupted"}:
                    yield f"event: complete\ndata: {json.dumps(job)}\n\n"
                    return
                yield ": keepalive\n\n"
                await asyncio.sleep(1)

        return StreamingResponse(
            stream(),
            media_type="text/event-stream",
            headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
        )

    @app.get("/api/v1/bundles")
    def bundles() -> dict[str, Any]:
        items = []
        for category in service.database.studio_categories():
            try:
                items.append(service.bundle_summary(category))
            except (OSError, ValueError, StudioPublishError) as exc:
                items.append(
                    {
                        "category": {
                            key: category.get(key)
                            for key in ("slug", "name", "display_title", "display_tag")
                        },
                        "status": "invalid",
                        "error": str(exc),
                        "versions": [],
                    }
                )
        return {"bundles": items}

    @app.get("/api/v1/bundles/{category_slug}")
    def bundle(category_slug: str) -> dict[str, Any]:
        try:
            category = service.database.studio_category(category_slug)
            return service.bundle_summary(category, detail=True)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Category not found") from exc
        except (OSError, ValueError, StudioPublishError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc

    @app.post("/api/v1/bundles/{category_slug}/deploy")
    def deploy(category_slug: str, payload: DeployRequest) -> dict[str, Any]:
        deploy_id = f"deploy-{uuid.uuid4().hex}"
        try:
            lease = service.lock.acquire(
                {
                    "job_id": deploy_id,
                    "operation": "deploy",
                    "category_slug": category_slug,
                    "acquired_at_utc": _now(),
                    "pid": os.getpid(),
                }
            )
        except PipelineBusyError as exc:
            raise HTTPException(
                status_code=409,
                detail={"message": "Generation is active", "holder": exc.holder},
            ) from exc
        try:
            category = service.database.studio_category(category_slug)
            summary = service.bundle_summary(category, detail=True)
            version = payload.version or int((summary.get("latest") or {}).get("bundle_version", 0))
            if version < 1:
                raise HTTPException(status_code=409, detail="No deployable bundle exists")
            result = service.publisher.activate(category=category, version=version)
            return {**result, "deployment_status": "deployed"}
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Category not found") from exc
        except HTTPException:
            raise
        except (OSError, ValueError, StudioPublishError) as exc:
            raise HTTPException(status_code=422, detail=str(exc)) from exc
        finally:
            lease.release()

    @app.get("/api/v1/bundles/{category_slug}/versions/{version}/download")
    def download_bundle(category_slug: str, version: int) -> FileResponse:
        try:
            service.database.studio_category(category_slug)
            archive, record = service.publisher.archive(category_slug, version)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Category not found") from exc
        except (OSError, ValueError, StudioPublishError) as exc:
            raise HTTPException(status_code=404, detail=str(exc)) from exc
        return FileResponse(
            archive,
            media_type="application/zip",
            filename=archive.name,
            headers={"X-Content-SHA256": str(record["archive_sha256"])},
        )

    @app.get("/api/v1/jobs/{job_id}")
    def job(job_id: str) -> dict[str, Any]:
        try:
            return service.database.studio_job(job_id)
        except KeyError as exc:
            raise HTTPException(status_code=404, detail="Job not found") from exc

    @app.get("/api/v1/dashboard")
    def dashboard() -> dict[str, Any]:
        return {
            "current_generation": current_pipeline(),
            "bundles": bundles()["bundles"],
        }

    return app


app = create_app()
