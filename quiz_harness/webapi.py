from __future__ import annotations

import asyncio
import hashlib
import html
import io
import json
import os
import random
import secrets
import shutil
import sqlite3
import uuid
import wave
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Literal

from fastapi import Cookie, FastAPI, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, HTMLResponse, JSONResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from .assets import generate_assets
from .background_images import (
    generate_quiz_background,
    plan_quiz_background_prompt,
)
from .bundle import bundle_id, write_bundle_files
from .client import VLLMClient
from .database import QuizDatabase
from .flutter_layout import write_flutter_layout
from .image_adapters import create_image_generator
from .imagestudio import ImageStudioClient
from .mageflow import MageFlowClient, MageFlowError
from .models import GenerationRequest
from .provider_service import (
    PROVIDER_TYPES,
    normalize_base_url,
    run_provider_test,
)
from .secure_store import SecretStore, SecretStoreError
from .service import generate_plan
from .studio_catalog import category_metadata_status, category_production_summary
from .studio_questions import (
    QUESTION_GENERATION_PROVIDER_TYPES,
    QuestionBankError,
    QuestionBankStore,
    generate_questions,
)
from .studio_sets import QuizSetError, QuizSetStore
from .studio_audio import StudioAudioError, StudioAudioStore
from .studio_publish import StudioPublishError, StudioPublishStore
from .studio_video import StudioVideoError, StudioVideoStore
from .studio_visuals import StudioVisualError, StudioVisualStore
from .vibevoice_audio import DEFAULT_REFERENCE_TRANSCRIPT
from .youtube_publish import (
    YouTubeClient,
    YouTubePublishError,
    authorization_url,
    deployed_video_questions,
    generate_description,
)


ROOT = Path(__file__).resolve().parent.parent
DATABASE_PATH = Path(os.getenv("QUIZ_DATABASE_PATH", ROOT / "data/quiz_harness.db"))
ASSET_ROOT = Path(os.getenv("QUIZ_ASSET_ROOT", ROOT / "data/assets"))
BUNDLE_ROOT = Path(os.getenv("QUIZ_BUNDLE_ROOT", ROOT / "dist"))
WEBUI_ROOT = Path(os.getenv("QUIZ_WEBUI_ROOT", ROOT / "webui/dist"))
VLLM_ENDPOINT = os.getenv("QUIZ_VLLM_BASE_URL", "http://192.168.1.102:8001/v1")
MAGEFLOW_ENDPOINT = os.getenv("QUIZ_MAGEFLOW_BASE_URL", "http://192.168.1.102:7864")
IMAGESTUDIO_ENDPOINT = os.getenv("QUIZ_IMAGESTUDIO_BASE_URL", "http://127.0.0.1:8000")
VIBEVOICE_ENDPOINT = os.getenv("QUIZ_VIBEVOICE_BASE_URL", "http://127.0.0.1:8092")
OPENAI_ENDPOINT = os.getenv("QUIZ_OPENAI_BASE_URL", "https://api.openai.com/v1")
ADMIN_USERNAME = os.getenv("QUIZ_ADMIN_USERNAME", "admin")
ADMIN_PASSWORD = os.getenv("QUIZ_ADMIN_PASSWORD", "F@@tba11")
STUDIO_SOURCE_ROOT = Path(
    os.getenv("QUIZ_STUDIO_SOURCE_ROOT", ROOT / "visual_quiz_qwen")
)
CATEGORY_BUNDLE_ROOT = Path(
    os.getenv("QUIZ_CATEGORY_BUNDLE_ROOT", ROOT / "dist/category_bundles")
)
VIDEO_ROOT = Path(os.getenv("QUIZ_VIDEO_ROOT", ROOT / "dist/videos"))
PROVIDER_TEST_ROOT = ASSET_ROOT / "provider-tests"
PROVIDER_AUDIO_ROOT = ASSET_ROOT / "provider-audio"
SECRET_KEY_FILE = Path(
    os.getenv("QUIZ_SECRET_KEY_FILE", ROOT / "data/.provider_secret_key")
)
STUDIO_PUBLIC_BASE_URL = os.getenv("QUIZ_STUDIO_PUBLIC_BASE_URL", "").rstrip("/")

ASSET_ROOT.mkdir(parents=True, exist_ok=True)
BUNDLE_ROOT.mkdir(parents=True, exist_ok=True)
PROVIDER_TEST_ROOT.mkdir(parents=True, exist_ok=True)
PROVIDER_AUDIO_ROOT.mkdir(parents=True, exist_ok=True)
database = QuizDatabase(DATABASE_PATH)
database.migrate()
secret_store = SecretStore(
    key=os.getenv("QUIZ_SECRET_KEY"),
    key_file=SECRET_KEY_FILE,
)
database.seed_provider_connections(
    [
        {
            "id": "llm-default",
            "provider_type": "openai_compatible_llm",
            "name": "Quiz planning LLM",
            "base_url": VLLM_ENDPOINT,
        },
        {
            "id": "imagestudio-local",
            "provider_type": "imagestudio",
            "name": "Local ImageStudio",
            "base_url": IMAGESTUDIO_ENDPOINT,
            "default_model": "ernie-turbo",
        },
        {
            "id": "openai-images",
            "provider_type": "openai_images",
            "name": "OpenAI Images",
            "base_url": OPENAI_ENDPOINT,
            "default_model": "gpt-image-2",
        },
        {
            "id": "vibevoice-local",
            "provider_type": "vibevoice",
            "name": "Quiz narrator",
            "base_url": VIBEVOICE_ENDPOINT,
            "settings": {
                "reference_audio_path": str(ROOT / "amit.wav"),
                "reference_transcript": DEFAULT_REFERENCE_TRANSCRIPT,
                "language": "en_indian",
                "cfg_scale": 1.3,
                "output_format": "mp3",
                "test_phrase": "Quiz Studio is ready to create a wonderful new quiz.",
            },
        },
    ]
)
try:
    vibevoice_provider = database.provider_connection("vibevoice-local")
    vibevoice_settings = dict(vibevoice_provider.get("settings", {}))
    if not str(vibevoice_settings.get("reference_transcript") or "").strip():
        database.update_provider_connection(
            "vibevoice-local",
            {
                "settings": {
                    **vibevoice_settings,
                    "reference_transcript": DEFAULT_REFERENCE_TRANSCRIPT,
                }
            },
        )
except KeyError:
    pass
question_banks = QuestionBankStore(STUDIO_SOURCE_ROOT, database)
quiz_sets = QuizSetStore(STUDIO_SOURCE_ROOT, database)
studio_visuals = StudioVisualStore(STUDIO_SOURCE_ROOT)
studio_audio = StudioAudioStore(STUDIO_SOURCE_ROOT)
studio_publish = StudioPublishStore(STUDIO_SOURCE_ROOT, CATEGORY_BUNDLE_ROOT)
studio_videos = StudioVideoStore(CATEGORY_BUNDLE_ROOT, VIDEO_ROOT)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


class JobManager:
    def __init__(self, store: QuizDatabase) -> None:
        self._store = store
        self._executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="quiz-job")

    def start(
        self,
        kind: str,
        target: Callable[[Callable[..., None]], dict[str, Any]],
        *,
        context: dict[str, Any] | None = None,
    ) -> dict[str, Any]:
        job_id = uuid.uuid4().hex
        job = {
            "id": job_id,
            "kind": kind,
            "status": "queued",
            "message": "Queued",
            "created_at": _now(),
            "updated_at": _now(),
            "result": None,
            "error": None,
            "progress": 0,
            "context": context or {},
        }
        self._store.create_studio_job(job)
        current_progress = 0.0

        def update(message: str, progress: float | None = None) -> None:
            nonlocal current_progress
            if progress is not None:
                current_progress = max(current_progress, min(0.98, float(progress)))
            self._store.update_studio_job(
                job_id,
                status="running",
                message=message,
                progress=current_progress,
                updated_at=_now(),
            )

        def run() -> None:
            self._store.update_studio_job(
                job_id,
                status="running",
                message="Starting",
                progress=0.02,
                updated_at=_now(),
            )
            try:
                result = target(update)
            except Exception as exc:
                self._store.update_studio_job(
                    job_id,
                    status="failed",
                    message="Failed",
                    progress=current_progress,
                    error=str(exc),
                    updated_at=_now(),
                )
            else:
                message = (
                    "Partially complete"
                    if result.get("status") == "partial"
                    else "Complete"
                )
                self._store.update_studio_job(
                    job_id,
                    status="complete",
                    message=message,
                    progress=1,
                    result=result,
                    updated_at=_now(),
                )

        self._executor.submit(run)
        return self._store.studio_job(job_id)

    def get(self, job_id: str) -> dict[str, Any]:
        return self._store.studio_job(job_id)


jobs = JobManager(database)
sessions: set[str] = set()


class LoginRequest(BaseModel):
    username: str
    password: str


class CategoryCreateRequest(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    slug: str | None = Field(default=None, max_length=80)
    description: str = Field(default="", max_length=300)
    age_min: int = Field(default=5, ge=3, le=15)
    age_max: int = Field(default=8, ge=3, le=15)
    display_title: str = Field(default="", max_length=80)
    display_tag: str = Field(default="", max_length=12)
    editorial_brief: str = Field(default="", max_length=1200)


class CategoryMetadataRequest(BaseModel):
    name: str = Field(min_length=2, max_length=80)
    display_title: str = Field(min_length=2, max_length=80)
    display_tag: str = Field(min_length=1, max_length=12)
    description: str = Field(default="", max_length=300)
    editorial_brief: str = Field(min_length=20, max_length=1200)
    age_min: int = Field(default=5, ge=3, le=15)
    age_max: int = Field(default=8, ge=3, le=15)


class ObjectCreateRequest(BaseModel):
    name: str = Field(min_length=1, max_length=80)
    slug: str | None = Field(default=None, max_length=80)
    description: str = Field(default="", max_length=300)


class PlanRequest(BaseModel):
    language: str = "English"
    question_count: int = Field(default=1, ge=1, le=10)
    option_count: int = Field(default=3, ge=3, le=4)
    seed: int | None = None


class AssetGenerationRequest(BaseModel):
    provider: str = Field(default="mageflow", pattern="^(mageflow|imagestudio)$")
    model: str | None = Field(default=None, max_length=80)


class ProviderCreateRequest(BaseModel):
    provider_type: str = Field(
        pattern="^(imagestudio|openai_images|openai_compatible_llm|vibevoice)$"
    )
    name: str = Field(min_length=2, max_length=80)
    base_url: str = Field(min_length=8, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    default_model: str | None = Field(default=None, max_length=200)
    settings: dict[str, Any] = Field(default_factory=dict)
    enabled: bool = True


class ProviderUpdateRequest(BaseModel):
    name: str | None = Field(default=None, min_length=2, max_length=80)
    base_url: str | None = Field(default=None, min_length=8, max_length=500)
    api_key: str | None = Field(default=None, max_length=500)
    clear_api_key: bool = False
    default_model: str | None = Field(default=None, max_length=200)
    settings: dict[str, Any] | None = None
    enabled: bool | None = None


class QuestionChoiceRequest(BaseModel):
    object_key: str = Field(min_length=1, max_length=80)
    label: str = Field(min_length=2, max_length=50)


class QuestionContentRequest(BaseModel):
    question: str = Field(min_length=12, max_length=180)
    choices: list[QuestionChoiceRequest] = Field(min_length=4, max_length=4)
    correct_choice_id: str = Field(pattern="^choice[1-4]$")
    explanation: str = Field(min_length=20, max_length=320)


class QuestionReviewRequest(BaseModel):
    status: str = Field(
        pattern="^(unreviewed|approved|needs_edit|rejected)$"
    )
    notes: str = Field(default="", max_length=1000)


class QuestionBulkReviewRequest(BaseModel):
    difficulty: str = Field(pattern="^(beginner|intermediate)$")
    question_ids: list[str] = Field(min_length=1, max_length=100)
    status: str = Field(pattern="^(approved|needs_edit)$")


class QuestionImportRequest(BaseModel):
    difficulty: str = Field(pattern="^(beginner|intermediate)$")
    questions: list[dict[str, Any]] = Field(min_length=1, max_length=500)
    source_model: str | None = Field(default=None, max_length=120)


class QuestionGenerationRequest(BaseModel):
    difficulty: str = Field(pattern="^(beginner|intermediate)$")
    count: int = Field(default=10, ge=1, le=30)
    provider_id: str = Field(min_length=2, max_length=100)
    model: str | None = Field(default=None, min_length=2, max_length=200)


class QuizSetSelectionRequest(BaseModel):
    difficulty: str = Field(pattern="^(beginner|intermediate)$")
    count: int = Field(default=1, ge=1, le=10)
    provider_id: str = Field(min_length=2, max_length=100)
    model: str | None = Field(default=None, min_length=2, max_length=200)
    strictness: str = Field(default="strict", pattern="^(strict|balanced)$")
    seed: int = Field(default=20260805, ge=0, le=2_147_483_647)


class QuizSetReviewRequest(BaseModel):
    status: str = Field(
        pattern="^(unreviewed|approved|needs_edit|rejected)$"
    )
    notes: str = Field(default="", max_length=1000)


class VisualPromptPlanRequest(BaseModel):
    provider_id: str = Field(min_length=2, max_length=100)
    model: str | None = Field(default=None, min_length=2, max_length=200)
    roles: list[str] = Field(min_length=1, max_length=3)
    guidance: str = Field(default="", max_length=2000)
    seed: int = Field(default=20260805, ge=0, le=2_147_483_647)
    force: bool = False


class VisualPromptUpdateRequest(BaseModel):
    prompt: str = Field(min_length=30, max_length=4000)


class VisualReviewRequest(BaseModel):
    status: str = Field(pattern="^(generated_pending_review|approved|rejected)$")


class VisualGenerationRequest(BaseModel):
    asset_ids: list[str] = Field(min_length=1, max_length=800)
    provider_id: str = Field(min_length=2, max_length=100)
    model: str | None = Field(default=None, min_length=2, max_length=200)
    quality: str = Field(default="medium", pattern="^(low|medium|high|auto)$")
    force: bool = False


class LandscapeBackgroundGenerationRequest(BaseModel):
    planner_provider_id: str = Field(min_length=2, max_length=100)
    planner_model: str | None = Field(default=None, min_length=2, max_length=200)
    image_provider_id: str = Field(min_length=2, max_length=100)
    image_model: str | None = Field(default=None, min_length=2, max_length=200)
    quality: str = Field(default="medium", pattern="^(low|medium|high|auto)$")
    guidance: str = Field(default="", max_length=2000)
    seed: int = Field(default=20260805, ge=0, le=2_147_483_647)
    refresh_plan: bool = False
    force: bool = False


class AudioGenerationRequest(BaseModel):
    provider_id: str = Field(min_length=2, max_length=100)
    clip_ids: list[str] = Field(default_factory=list, max_length=400)
    force: bool = False
    audit_repairs: int = Field(default=2, ge=0, le=4)


class AudioReviewRequest(BaseModel):
    clip_id: str = Field(min_length=3, max_length=200)
    decision: str = Field(pattern="^(accept|reset)$")


class PublishRequest(BaseModel):
    force_new_version: bool = False


class ActivateReleaseRequest(BaseModel):
    version: int = Field(ge=1)


class VideoCreationRequest(BaseModel):
    orientation: Literal["portrait", "landscape"]
    set_ids: list[str] = Field(min_length=1, max_length=5)
    concurrency: int = Field(default=8, ge=1, le=16)
    crf: int = Field(default=18, ge=1, le=51)


class YouTubeCredentialsRequest(BaseModel):
    client_id: str = Field(min_length=20, max_length=300)
    client_secret: str | None = Field(default=None, max_length=500)


class YouTubeDescriptionRequest(BaseModel):
    provider_id: str = Field(min_length=2, max_length=100)
    model: str | None = Field(default=None, min_length=2, max_length=200)


class YouTubeUploadRequest(BaseModel):
    title: str = Field(min_length=1, max_length=100)
    description: str = Field(default="", max_length=5000)
    privacy_status: Literal["private", "unlisted", "public"] = "private"


def _workspace(context: dict[str, Any]) -> Path:
    return ASSET_ROOT / context["asset_key"] / f"plan-{context['plan_id']}"


def _read_manifest(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def _public_provider(provider: dict[str, Any]) -> dict[str, Any]:
    result = {
        key: value
        for key, value in provider.items()
        if key not in {"secret_ciphertext", "secret_fingerprint", "secret_last_four"}
    }
    result["has_secret"] = bool(provider.get("secret_ciphertext"))
    result["secret_hint"] = (
        f"...{provider['secret_last_four']}" if provider.get("secret_last_four") else None
    )
    result["type_label"] = PROVIDER_TYPES[provider["provider_type"]]
    return result


def _secret_values(secret: str | None) -> dict[str, str | None]:
    if not secret or not secret.strip():
        return {
            "secret_ciphertext": None,
            "secret_fingerprint": None,
            "secret_last_four": None,
        }
    return {
        "secret_ciphertext": secret_store.encrypt(secret),
        "secret_fingerprint": secret_store.fingerprint(secret),
        "secret_last_four": secret_store.last_four(secret),
    }


def _studio_categories() -> list[dict[str, Any]]:
    return [
        category_production_summary(
            category,
            source_root=STUDIO_SOURCE_ROOT,
            bundle_root=CATEGORY_BUNDLE_ROOT,
        )
        for category in database.studio_categories()
    ]


def _require_category_metadata(category: dict[str, Any]) -> None:
    metadata = category_metadata_status(category)
    if not metadata["ready"]:
        raise HTTPException(
            status_code=409,
            detail="Complete category metadata first: " + ", ".join(metadata["missing"]),
        )


def _pipeline_detail(plan_id: int) -> dict[str, Any]:
    context = database.plan_context(plan_id)
    document = context["document"]
    workspace = _workspace(context)
    asset_manifest = _read_manifest(workspace / "asset-manifest.json")
    layout_path = workspace / "flutter-layout.json"
    audio_path = workspace / "audio-manifest.json"
    destination = BUNDLE_ROOT / bundle_id(document)
    bundle_path = destination / "bundle.json"
    assets: list[dict[str, Any]] = []
    manifest_assets = (asset_manifest or {}).get("assets", {})
    fallback_manifest = _read_manifest(destination / "asset-manifest.json")
    fallback_assets = (fallback_manifest or {}).get("assets", {})
    for spec in document.plan.assets:
        generated = manifest_assets.get(spec.asset_id) or fallback_assets.get(spec.asset_id)
        url = None
        if generated:
            if spec.asset_id in manifest_assets:
                url = (
                    f"/artifacts/{context['asset_key']}/plan-{plan_id}/"
                    f"{generated['file']}"
                )
            elif destination.exists():
                url = f"/bundles/{destination.name}/{generated['file']}"
        assets.append(
            {
                **spec.model_dump(),
                "generated": generated,
                "url": url,
            }
        )
    layout = _read_manifest(layout_path)
    preview_url = (
        f"/bundles/{destination.name}/index.html"
        if (destination / "index.html").exists()
        else None
    )
    return {
        "plan_id": plan_id,
        "revision": context["revision"],
        "object_id": context["object_id"],
        "asset_key": context["asset_key"],
        "document": document.model_dump(mode="json"),
        "assets": assets,
        "flutter_layout": layout,
        "preview_url": preview_url,
        "pipeline": {
            "plan": "complete",
            "assets": "complete" if asset_manifest or fallback_manifest else "ready",
            "audio": "complete" if audio_path.exists() else "unavailable",
            "layout": "complete" if layout_path.exists() else "ready",
            "bundle": "complete" if bundle_path.exists() else "blocked",
        },
    }


@asynccontextmanager
async def lifespan(_: FastAPI) -> Any:
    database.mark_interrupted_jobs(_now())
    database.mark_interrupted_videos(_now())
    database.mark_interrupted_youtube_uploads(_now())
    yield


app = FastAPI(title="Quiz Studio API", version="0.2.0", lifespan=lifespan)
app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:9060", "http://127.0.0.1:9060"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


@app.middleware("http")
async def authentication(request: Request, call_next: Callable[..., Any]) -> Response:
    public = request.url.path in {
        "/api/health",
        "/api/auth/login",
        "/api/auth/status",
        "/api/admin/youtube/oauth/callback",
    }
    protected = request.url.path.startswith(
        ("/api", "/artifacts", "/bundles", "/studio-assets", "/provider-tests")
    )
    if protected and not public:
        token = request.cookies.get("quiz_session")
        if not token or token not in sessions:
            return JSONResponse(status_code=401, content={"detail": "Authentication required"})
    return await call_next(request)


@app.get("/api/health")
def health() -> dict[str, Any]:
    return {"status": "ok", "database": str(DATABASE_PATH), "time": _now()}


@app.post("/api/auth/login")
def login(
    payload: LoginRequest, request: Request, response: Response
) -> dict[str, Any]:
    if payload.username != ADMIN_USERNAME or payload.password != ADMIN_PASSWORD:
        raise HTTPException(status_code=401, detail="Invalid username or password")
    token = uuid.uuid4().hex
    sessions.add(token)
    response.set_cookie(
        "quiz_session",
        token,
        httponly=True,
        samesite="lax",
        secure=request.url.scheme == "https",
        max_age=12 * 60 * 60,
    )
    return {"username": ADMIN_USERNAME, "role": "admin"}


@app.get("/api/auth/status")
def auth_status(quiz_session: str | None = Cookie(default=None)) -> dict[str, bool]:
    return {"authenticated": bool(quiz_session and quiz_session in sessions)}


@app.post("/api/auth/logout")
def logout(response: Response, quiz_session: str | None = Cookie(default=None)) -> dict[str, bool]:
    if quiz_session:
        sessions.discard(quiz_session)
    response.delete_cookie("quiz_session")
    return {"ok": True}


@app.get("/api/auth/me")
def current_user() -> dict[str, str]:
    return {"username": ADMIN_USERNAME, "role": "admin"}


@app.get("/api/catalog")
def catalog() -> dict[str, Any]:
    return {"categories": database.catalog()}


@app.get("/api/studio/categories")
def studio_categories() -> dict[str, Any]:
    return {"categories": _studio_categories()}


@app.post("/api/studio/categories")
def create_studio_category(payload: CategoryCreateRequest) -> dict[str, Any]:
    if payload.age_min > payload.age_max:
        raise HTTPException(status_code=422, detail="age_min must not exceed age_max")
    metadata = category_metadata_status(payload.model_dump())
    if not metadata["ready"]:
        raise HTTPException(
            status_code=422,
            detail="Complete category metadata: " + ", ".join(metadata["missing"]),
        )
    try:
        category = database.create_category(**payload.model_dump())
    except (sqlite3.IntegrityError, ValueError) as exc:
        raise HTTPException(status_code=409, detail="Category slug already exists") from exc
    return category_production_summary(
        category,
        source_root=STUDIO_SOURCE_ROOT,
        bundle_root=CATEGORY_BUNDLE_ROOT,
    )


@app.get("/api/studio/categories/{category_slug}")
def studio_category(category_slug: str) -> dict[str, Any]:
    category = next(
        (item for item in _studio_categories() if item["slug"] == category_slug),
        None,
    )
    if category is None:
        raise HTTPException(status_code=404, detail="Category not found")
    return category


@app.patch("/api/studio/categories/{category_slug}")
def update_studio_category(
    category_slug: str, payload: CategoryMetadataRequest
) -> dict[str, Any]:
    if payload.age_min > payload.age_max:
        raise HTTPException(status_code=422, detail="age_min must not exceed age_max")
    try:
        current = database.studio_category(category_slug)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    if payload.name.strip() != str(current["name"]).strip():
        raise HTTPException(
            status_code=409,
            detail="Category name is immutable after creation",
        )
    metadata = category_metadata_status(payload.model_dump())
    if not metadata["ready"]:
        raise HTTPException(
            status_code=422,
            detail="Complete category metadata: " + ", ".join(metadata["missing"]),
        )
    try:
        category = database.update_category_metadata(
            category_slug, **payload.model_dump()
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (sqlite3.IntegrityError, ValueError) as exc:
        raise HTTPException(status_code=409, detail="Category metadata is invalid") from exc
    return category_production_summary(
        category,
        source_root=STUDIO_SOURCE_ROOT,
        bundle_root=CATEGORY_BUNDLE_ROOT,
    )


@app.get("/api/studio/categories/{category_slug}/questions")
def category_questions(
    category_slug: str,
    difficulty: str = "all",
    state: str = "all",
    review: str = "all",
    q: str = "",
    page: int = 1,
    page_size: int = 30,
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return question_banks.list_questions(
            category_slug,
            difficulty=difficulty,
            state=state,
            review=review,
            query=q,
            page=page,
            page_size=page_size,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except QuestionBankError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get(
    "/api/studio/categories/{category_slug}/questions/{difficulty}/{question_id}"
)
def category_question(
    category_slug: str, difficulty: str, question_id: str
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return question_banks.question(category_slug, difficulty, question_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Question not found") from exc
    except QuestionBankError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.patch(
    "/api/studio/categories/{category_slug}/questions/{difficulty}/{question_id}"
)
def update_category_question(
    category_slug: str,
    difficulty: str,
    question_id: str,
    payload: QuestionContentRequest,
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return question_banks.update_question(
            category_slug,
            difficulty,
            question_id,
            payload.model_dump(mode="json"),
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Question not found") from exc
    except QuestionBankError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post(
    "/api/studio/categories/{category_slug}/questions/{difficulty}/{question_id}/review"
)
def review_category_question(
    category_slug: str,
    difficulty: str,
    question_id: str,
    payload: QuestionReviewRequest,
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return question_banks.review_question(
            category_slug,
            difficulty,
            question_id,
            status=payload.status,
            notes=payload.notes,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Question not found") from exc
    except QuestionBankError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/questions/bulk-review")
def bulk_review_category_questions(
    category_slug: str, payload: QuestionBulkReviewRequest
) -> dict[str, int]:
    try:
        database.studio_category(category_slug)
        return question_banks.bulk_review(
            category_slug,
            payload.difficulty,
            payload.question_ids,
            status=payload.status,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc


@app.post("/api/studio/categories/{category_slug}/questions/import")
def import_category_questions(
    category_slug: str, payload: QuestionImportRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        return question_banks.import_questions(
            category,
            payload.difficulty,
            payload.questions,
            source_provider="manual_import",
            source_model=payload.source_model,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except QuestionBankError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/questions/generate")
def generate_category_questions(
    category_slug: str, payload: QuestionGenerationRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        provider = database.provider_connection(payload.provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category or provider not found") from exc
    _require_category_metadata(category)
    if provider["provider_type"] not in QUESTION_GENERATION_PROVIDER_TYPES:
        raise HTTPException(
            status_code=422,
            detail=(
                "Question generation requires an OpenAI-compatible LLM or "
                "OpenAI API provider"
            ),
        )
    if not provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the provider first")
    secret = secret_store.decrypt(provider.get("secret_ciphertext"))
    if provider["provider_type"] == "openai_images" and not secret:
        raise HTTPException(
            status_code=409,
            detail="Configure the OpenAI API key in Admin before generation",
        )
    if payload.model:
        provider = {**provider, "default_model": payload.model}
    sibling_names = [
        item["name"]
        for item in database.studio_categories()
        if item["slug"] != category_slug and category_metadata_status(item)["ready"]
    ]

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        candidates, model = generate_questions(
            category=category,
            sibling_names=sibling_names,
            difficulty=payload.difficulty,
            count=payload.count,
            provider=provider,
            secret=secret,
            progress=progress,
        )
        progress("Appending valid questions", 0.82)
        result = question_banks.import_questions(
            category,
            payload.difficulty,
            candidates,
            action="generated",
            source_provider=provider["id"],
            source_model=model,
            limit=payload.count,
        )
        progress("Question bank updated", 0.96)
        return {
            **result,
            "category_slug": category_slug,
            "difficulty": payload.difficulty,
            "provider_id": provider["id"],
            "model": model,
            "candidate_count": len(candidates),
            "raw_candidates": candidates,
        }

    return jobs.start(
        "question_generation",
        target,
        context={
            "category_slug": category_slug,
            "difficulty": payload.difficulty,
            "count": payload.count,
            "provider_id": provider["id"],
            "model": payload.model or provider.get("default_model"),
        },
    )


@app.get("/api/studio/categories/{category_slug}/sets")
def category_quiz_sets(
    category_slug: str, difficulty: str = "all"
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return quiz_sets.list_sets(category_slug, difficulty=difficulty)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except QuizSetError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get(
    "/api/studio/categories/{category_slug}/sets/{difficulty}/{set_id}"
)
def category_quiz_set(
    category_slug: str, difficulty: str, set_id: str
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return quiz_sets.set_detail(category_slug, difficulty, set_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Quiz set not found") from exc
    except QuizSetError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.post(
    "/api/studio/categories/{category_slug}/sets/{difficulty}/{set_id}/review"
)
def review_category_quiz_set(
    category_slug: str,
    difficulty: str,
    set_id: str,
    payload: QuizSetReviewRequest,
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return quiz_sets.review_set(
            category_slug,
            difficulty,
            set_id,
            status=payload.status,
            notes=payload.notes,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Quiz set not found") from exc
    except QuizSetError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/sets/select")
def select_category_quiz_sets(
    category_slug: str, payload: QuizSetSelectionRequest
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        provider = database.provider_connection(payload.provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category or provider not found") from exc
    if provider["provider_type"] != "openai_compatible_llm":
        raise HTTPException(
            status_code=422,
            detail="Set selection requires an OpenAI-compatible local LLM connection",
        )
    if not provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the provider first")
    model = payload.model or provider.get("default_model")
    if not model:
        models = provider.get("discovered_models") or []
        model = models[0] if models else None
    if not model:
        raise HTTPException(status_code=409, detail="Select or discover an LLM model")
    secret = secret_store.decrypt(provider.get("secret_ciphertext"))

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        with VLLMClient(
            provider["base_url"], timeout_seconds=900, api_key=secret
        ) as client:
            return quiz_sets.select_sets(
                category_slug=category_slug,
                difficulty=payload.difficulty,
                count=payload.count,
                client=client,
                model=model,
                seed=payload.seed,
                strictness=payload.strictness,
                provider_id=provider["id"],
                progress=progress,
            )

    return jobs.start(
        "quiz_set_selection",
        target,
        context={
            "category_slug": category_slug,
            "difficulty": payload.difficulty,
            "count": payload.count,
            "provider_id": provider["id"],
            "model": model,
            "strictness": payload.strictness,
            "seed": payload.seed,
        },
    )


@app.get("/api/studio/categories/{category_slug}/visuals")
def category_visuals(category_slug: str) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        metadata = category_metadata_status(category)
        if not metadata["ready"]:
            return studio_visuals.blocked_inventory(
                "Complete category metadata first: "
                + ", ".join(metadata["missing"])
            )
        return studio_visuals.inventory(category)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (OSError, ValueError, StudioVisualError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/visuals/plan")
def plan_category_visuals(
    category_slug: str, payload: VisualPromptPlanRequest
) -> dict[str, Any]:
    active_plans = [
        job
        for job in database.studio_jobs(limit=100)
        if job["kind"] == "visual_prompt_planning"
        and job["status"] in {"queued", "running"}
        and job.get("context", {}).get("category_slug") == category_slug
    ]
    if active_plans:
        raise HTTPException(
            status_code=409,
            detail="Visual prompt planning is already active for this category",
        )
    try:
        category = database.studio_category(category_slug)
        provider = database.provider_connection(payload.provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category or provider not found") from exc
    _require_category_metadata(category)
    if provider["provider_type"] != "openai_compatible_llm":
        raise HTTPException(status_code=422, detail="Visual prompt planning requires an OpenAI-compatible LLM")
    roles = set(payload.roles)
    allowed_roles = {"selector", "tiles", "answers"}
    if not roles <= allowed_roles:
        raise HTTPException(status_code=422, detail="Visual roles must be selector, tiles, or answers")
    model = payload.model or provider.get("default_model") or next(
        iter(provider.get("discovered_models") or []), None
    )
    if not model:
        raise HTTPException(status_code=409, detail="Select or discover an LLM model")
    secret = secret_store.decrypt(provider.get("secret_ciphertext"))

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        with VLLMClient(
            provider["base_url"], timeout_seconds=900, api_key=secret
        ) as client:
            return studio_visuals.plan_prompts(
                category=category,
                client=client,
                endpoint=provider["base_url"],
                model=model,
                roles=roles,
                guidance=payload.guidance,
                seed=payload.seed,
                force=payload.force,
                progress=progress,
            )

    return jobs.start(
        "visual_prompt_planning",
        target,
        context={
            "category_slug": category_slug,
            "provider_id": provider["id"],
            "model": model,
            "roles": sorted(roles),
            "seed": payload.seed,
        },
    )


@app.patch("/api/studio/categories/{category_slug}/visuals/{asset_id}/prompt")
def update_category_visual_prompt(
    category_slug: str, asset_id: str, payload: VisualPromptUpdateRequest
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return studio_visuals.update_prompt(category_slug, asset_id, payload.prompt)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Visual asset not found") from exc
    except (OSError, ValueError, StudioVisualError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/visuals/{asset_id}/review")
def review_category_visual(
    category_slug: str, asset_id: str, payload: VisualReviewRequest
) -> dict[str, Any]:
    try:
        database.studio_category(category_slug)
        return studio_visuals.review_asset(category_slug, asset_id, payload.status)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Visual asset not found") from exc
    except (OSError, ValueError, StudioVisualError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/visuals/background")
async def upload_category_background(
    category_slug: str, request: Request
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        _require_category_metadata(category)
        return studio_visuals.upload_background(
            category,
            await request.body(),
            request.headers.get("content-type", "application/octet-stream"),
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (OSError, ValueError, StudioVisualError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


def _start_video_background_generation(
    category_slug: str,
    payload: LandscapeBackgroundGenerationRequest,
    *,
    layout: Literal["video_portrait", "landscape"],
) -> dict[str, Any]:
    portrait = layout == "video_portrait"
    job_kind = (
        "portrait_video_background_generation"
        if portrait
        else "landscape_background_generation"
    )
    label = "Portrait video" if portrait else "Landscape"
    active_jobs = [
        job
        for job in database.studio_jobs(limit=100)
        if job["kind"] == job_kind
        and job["status"] in {"queued", "running"}
        and job.get("context", {}).get("category_slug") == category_slug
    ]
    if active_jobs:
        raise HTTPException(
            status_code=409,
            detail=f"{label} background generation is already active for this category",
        )
    try:
        category = database.studio_category(category_slug)
        planner = database.provider_connection(payload.planner_provider_id)
        image_provider = database.provider_connection(payload.image_provider_id)
    except KeyError as exc:
        raise HTTPException(
            status_code=404, detail="Category or provider not found"
        ) from exc
    _require_category_metadata(category)
    if planner["provider_type"] != "openai_compatible_llm" or not planner["enabled"]:
        raise HTTPException(
            status_code=422,
            detail="Select an enabled OpenAI-compatible LLM planner",
        )
    if image_provider["provider_type"] not in {"openai_images", "imagestudio"}:
        raise HTTPException(
            status_code=422,
            detail="Select an OpenAI Images or ImageStudio image provider",
        )
    if not image_provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the image provider first")
    planner_model = payload.planner_model or planner.get("default_model") or next(
        iter(planner.get("discovered_models") or []), None
    )
    image_model = payload.image_model or image_provider.get("default_model") or next(
        iter(image_provider.get("discovered_models") or []), None
    )
    if not planner_model:
        raise HTTPException(status_code=409, detail="Select a planner model")
    if not image_model:
        raise HTTPException(status_code=409, detail="Select an image model")
    if (
        image_provider["provider_type"] == "openai_images"
        and not secret_store.decrypt(image_provider.get("secret_ciphertext"))
    ):
        raise HTTPException(
            status_code=409, detail="Configure the OpenAI API key in Admin"
        )

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        root = studio_visuals.category_root(category_slug)
        work = root / "background-generation"
        plan_path = work / (
            "video-background-portrait-prompt-plan.json"
            if portrait
            else "video-background-landscape-prompt-plan.json"
        )
        guidance = "\n\n".join(
            value.strip()
            for value in (category.get("editorial_brief"), payload.guidance)
            if value and value.strip()
        )
        progress(
            "Planning 9:16 portrait video background"
            if portrait
            else "Planning 16:9 landscape background",
            0.08,
        )
        planned = plan_quiz_background_prompt(
            category=category["name"],
            display_title=category["display_title"],
            subtitle="",
            provider_id=planner["id"],
            database_path=DATABASE_PATH,
            secret_key_file=SECRET_KEY_FILE,
            output=plan_path,
            model_override=str(planner_model),
            category_guidance=guidance or None,
            seed=payload.seed,
            force=payload.refresh_plan,
            layout=layout,
        )
        plan_document = planned["plan"]
        planning = {
            **planned,
            "plan": plan_document.model_dump(mode="json"),
        }
        progress(
            (
                "Requesting 1080x1920 background from "
                if portrait
                else "Requesting 1920x1080 background from "
            )
            + image_provider["name"],
            0.45,
        )
        generated = generate_quiz_background(
            category=category["name"],
            display_title=category["display_title"],
            provider_id=image_provider["id"],
            database_path=DATABASE_PATH,
            secret_key_file=SECRET_KEY_FILE,
            output=work
            / (
                "video_background_portrait.png"
                if portrait
                else "video_background_landscape.png"
            ),
            model_override=str(image_model),
            quality=payload.quality,
            seed=payload.seed,
            subtitle="",
            prompt_override=plan_document.prompt,
            planning_metadata=planning,
            retries=0,
            timeout_seconds=360.0,
            force=payload.force,
            layout=layout,
        )
        progress("Registering optional video background", 0.92)
        uploader = (
            studio_visuals.upload_video_background_portrait
            if portrait
            else studio_visuals.upload_video_background_landscape
        )
        registered = uploader(
            category, Path(generated["image"]["file"]).read_bytes(), "image/png"
        )
        return {
            "status": "complete",
            "optional": True,
            "planning": planning,
            "generation": generated,
            "registration": registered,
        }

    return jobs.start(
        job_kind,
        target,
        context={
            "category_slug": category_slug,
            "planner_provider_id": planner["id"],
            "planner_model": planner_model,
            "image_provider_id": image_provider["id"],
            "image_model": image_model,
            "quality": payload.quality,
            "seed": payload.seed,
            "layout": layout,
        },
    )


@app.post(
    "/api/studio/categories/{category_slug}/visuals/portrait-video-background"
)
def generate_portrait_video_background(
    category_slug: str, payload: LandscapeBackgroundGenerationRequest
) -> dict[str, Any]:
    return _start_video_background_generation(
        category_slug, payload, layout="video_portrait"
    )


@app.post(
    "/api/studio/categories/{category_slug}/visuals/landscape-background"
)
def generate_landscape_background(
    category_slug: str, payload: LandscapeBackgroundGenerationRequest
) -> dict[str, Any]:
    return _start_video_background_generation(
        category_slug, payload, layout="landscape"
    )


@app.post("/api/studio/categories/{category_slug}/visuals/generate")
def generate_category_visuals(
    category_slug: str, payload: VisualGenerationRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        provider = database.provider_connection(payload.provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category or provider not found") from exc
    _require_category_metadata(category)
    if provider["provider_type"] not in {"openai_images", "imagestudio"}:
        raise HTTPException(status_code=422, detail="Select an OpenAI Images or ImageStudio provider")
    if not provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the provider first")
    model = payload.model or provider.get("default_model") or next(
        iter(provider.get("discovered_models") or []), None
    )
    if not model:
        raise HTTPException(status_code=409, detail="Select an image model")
    secret = secret_store.decrypt(provider.get("secret_ciphertext"))
    if provider["provider_type"] == "openai_images" and not secret:
        raise HTTPException(status_code=409, detail="Configure the OpenAI API key in Admin")

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        return studio_visuals.generate_images(
            category=category,
            asset_ids=set(payload.asset_ids),
            provider=provider,
            secret=secret,
            model=model,
            quality=payload.quality,
            force=payload.force,
            progress=progress,
        )

    return jobs.start(
        "visual_generation",
        target,
        context={
            "category_slug": category_slug,
            "asset_ids": payload.asset_ids,
            "provider_id": provider["id"],
            "model": model,
            "quality": payload.quality,
            "force": payload.force,
        },
    )


@app.get("/api/studio/categories/{category_slug}/audio")
def category_audio(category_slug: str) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        return studio_audio.inventory(category)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (OSError, ValueError, StudioAudioError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.post("/api/studio/categories/{category_slug}/audio/generate")
def generate_category_audio(
    category_slug: str, payload: AudioGenerationRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        provider = database.provider_connection(payload.provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category or provider not found") from exc
    audio_inventory = studio_audio.inventory(category)
    if not audio_inventory["ready"]:
        raise HTTPException(status_code=409, detail=audio_inventory["blocked_reason"])
    if provider["provider_type"] != "vibevoice":
        raise HTTPException(status_code=422, detail="Select a VibeVoice provider")
    if not provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the narrator provider first")
    clips: set[tuple[str, str]] | None = None
    if payload.clip_ids:
        clips = set()
        for clip_id in payload.clip_ids:
            try:
                question_id, kind = clip_id.rsplit("/", 1)
            except ValueError as exc:
                raise HTTPException(status_code=422, detail=f"Invalid audio clip ID: {clip_id}") from exc
            if not question_id or kind not in {"question", "explanation"}:
                raise HTTPException(status_code=422, detail=f"Invalid audio clip ID: {clip_id}")
            clips.add((question_id, kind))

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        return studio_audio.generate(
            category=category,
            provider=provider,
            clip_ids=clips,
            force=payload.force,
            audit_repairs=payload.audit_repairs,
            progress=progress,
        )

    return jobs.start(
        "audio_generation",
        target,
        context={
            "category_slug": category_slug,
            "provider_id": provider["id"],
            "clip_ids": payload.clip_ids,
            "force": payload.force,
            "audit_repairs": payload.audit_repairs,
        },
    )


@app.post("/api/studio/categories/{category_slug}/audio/review")
def review_category_audio(
    category_slug: str, payload: AudioReviewRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    active = _active_category_jobs(category_slug)
    if active:
        raise HTTPException(
            status_code=409,
            detail="Wait for active category jobs to finish before reviewing audio",
        )
    try:
        return studio_audio.review_clip(
            category=category,
            clip_id=payload.clip_id,
            decision=payload.decision,
        )
    except (OSError, ValueError, StudioAudioError) as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc


def _active_category_jobs(category_slug: str) -> list[dict[str, Any]]:
    return [
        job
        for job in database.studio_jobs(limit=100)
        if job["status"] in {"queued", "running"}
        and job["kind"] != "video_render"
        and job.get("context", {}).get("category_slug") == category_slug
    ]


@app.get("/api/studio/categories/{category_slug}/publish")
def category_publish_inventory(category_slug: str) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        inventory = studio_publish.inventory(category)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (OSError, ValueError, StudioPublishError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    active = _active_category_jobs(category_slug)
    return {
        **inventory,
        "active_jobs": [
            {"id": item["id"], "kind": item["kind"], "status": item["status"]}
            for item in active
        ],
        "can_publish": inventory["ready"] and not active,
    }


@app.post("/api/studio/categories/{category_slug}/publish")
def publish_category(
    category_slug: str, payload: PublishRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        readiness = studio_publish.inventory(category)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (OSError, ValueError, StudioPublishError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    active = _active_category_jobs(category_slug)
    if active:
        raise HTTPException(
            status_code=409,
            detail="Wait for active category production jobs before publishing",
        )
    if not readiness["ready"]:
        blocked = ", ".join(
            item["label"]
            for item in readiness["gates"]
            if item["status"] != "ready"
        )
        raise HTTPException(
            status_code=409,
            detail=f"Complete required production stages before publishing: {blocked}",
        )

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        return studio_publish.publish(
            category=category,
            force_new_version=payload.force_new_version,
            progress=progress,
        )

    return jobs.start(
        "category_publish",
        target,
        context={
            "category_slug": category_slug,
            "force_new_version": payload.force_new_version,
        },
    )


@app.post("/api/studio/categories/{category_slug}/publish/activate")
def activate_category_release(
    category_slug: str, payload: ActivateReleaseRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        if _active_category_jobs(category_slug):
            raise HTTPException(
                status_code=409,
                detail="Wait for active category production jobs before activating a release",
            )
        return studio_publish.activate(category=category, version=payload.version)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except HTTPException:
        raise
    except (OSError, ValueError, StudioPublishError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc


@app.get(
    "/api/studio/categories/{category_slug}/publish/versions/{version}/download"
)
def download_category_release(category_slug: str, version: int) -> FileResponse:
    try:
        category = database.studio_category(category_slug)
        archive, record = studio_publish.archive(category, version)
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


def _public_video(record: dict[str, Any]) -> dict[str, Any]:
    result = {key: value for key, value in record.items() if key != "file_path"}
    if record["status"] == "complete":
        result["stream_url"] = f"/api/studio/videos/{record['id']}/stream"
        result["download_url"] = f"/api/studio/videos/{record['id']}/download"
    else:
        result["stream_url"] = None
        result["download_url"] = None
    result["youtube_upload"] = database.latest_youtube_upload(record["id"])
    return result


def _studio_video_file(video_id: str) -> tuple[Path, dict[str, Any]]:
    try:
        record = database.studio_video(video_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Video not found") from exc
    if record["status"] != "complete" or not record.get("file_path"):
        raise HTTPException(status_code=409, detail="Video is not ready")
    path = Path(record["file_path"]).resolve()
    root = VIDEO_ROOT.resolve()
    if not path.is_relative_to(root) or not path.is_file():
        raise HTTPException(status_code=404, detail="Video file is unavailable")
    return path, record


@app.get("/api/studio/categories/{category_slug}/videos")
def category_video_inventory(category_slug: str) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    try:
        inventory = studio_videos.inventory(category_slug)
        bundle_version = inventory["bundle_version"]
        sets = inventory["sets"]
        backgrounds = inventory["backgrounds"]
        blocked_reason = (
            None
            if any(backgrounds.values())
            else "Generate a portrait or landscape video background before creating a video."
        )
    except (OSError, ValueError, StudioVideoError, KeyError) as exc:
        bundle_version = None
        sets = []
        backgrounds = {"portrait": False, "landscape": False}
        blocked_reason = f"Publish {category['name']} before creating videos: {exc}"
    youtube = database.youtube_connection()
    return {
        "category_slug": category_slug,
        "deployed": bundle_version is not None,
        "can_create": bundle_version is not None and any(backgrounds.values()),
        "bundle_version": bundle_version,
        "sets": sets,
        "backgrounds": backgrounds,
        "limits": {"portrait": 10, "landscape": 50},
        "youtube": {
            "configured": bool(youtube),
            "connected": bool(youtube and youtube.get("refresh_token_ciphertext")),
            "channel_title": youtube.get("channel_title") if youtube else None,
        },
        "blocked_reason": blocked_reason,
        "videos": [
            _public_video(item)
            for item in database.studio_videos(category_slug, limit=100)
        ],
    }


@app.post("/api/studio/categories/{category_slug}/videos")
def create_category_video(
    category_slug: str, payload: VideoCreationRequest
) -> dict[str, Any]:
    try:
        category = database.studio_category(category_slug)
        resolved = studio_videos.resolve_selection(
            category_slug=category_slug,
            orientation=payload.orientation,
            set_ids=payload.set_ids,
        )
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Category not found") from exc
    except (OSError, ValueError, StudioVideoError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    video_id = uuid.uuid4().hex
    selected = resolved["selected"]
    count = resolved["question_count"]
    now = _now()
    title = f"{category['name']} · {payload.orientation.title()} · {count} questions"
    record = database.create_studio_video(
        {
            "id": video_id,
            "category_slug": category_slug,
            "title": title,
            "orientation": payload.orientation,
            "bundle_version": resolved["bundle_version"],
            "selections": selected,
            "question_count": count,
            "status": "queued",
            "created_at": now,
            "updated_at": now,
        }
    )

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        database.update_studio_video(
            video_id, status="rendering", updated_at=_now()
        )
        try:
            rendered = studio_videos.render(
                video_id=video_id,
                category_slug=category_slug,
                orientation=payload.orientation,
                bundle_version=resolved["bundle_version"],
                selections=selected,
                concurrency=payload.concurrency,
                crf=payload.crf,
                progress=progress,
            )
        except Exception as exc:
            database.update_studio_video(
                video_id,
                status="failed",
                error=str(exc),
                updated_at=_now(),
            )
            raise
        completed = database.update_studio_video(
            video_id,
            status="complete",
            file_name=rendered["file_name"],
            file_path=rendered["file_path"],
            file_bytes=rendered["file_bytes"],
            duration_seconds=rendered["duration_seconds"],
            updated_at=_now(),
        )
        return _public_video(completed)

    job = jobs.start(
        "video_render",
        target,
        context={
            "category_slug": category_slug,
            "video_id": video_id,
            "orientation": payload.orientation,
            "question_count": count,
            "bundle_version": resolved["bundle_version"],
        },
    )
    database.attach_studio_video_job(video_id, job_id=job["id"], updated_at=_now())
    return {**job, "video": _public_video(record)}


@app.get("/api/studio/videos/{video_id}")
def studio_video(video_id: str) -> dict[str, Any]:
    try:
        return _public_video(database.studio_video(video_id))
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Video not found") from exc


@app.get("/api/studio/videos/{video_id}/stream")
def stream_studio_video(video_id: str) -> FileResponse:
    path, _ = _studio_video_file(video_id)
    return FileResponse(
        path,
        media_type="video/mp4",
        headers={"Cache-Control": "private, max-age=3600"},
    )


@app.get("/api/studio/videos/{video_id}/download")
def download_studio_video(video_id: str) -> FileResponse:
    path, record = _studio_video_file(video_id)
    return FileResponse(path, media_type="video/mp4", filename=record["file_name"])


@app.post("/api/studio/videos/{video_id}/youtube/description")
def generate_youtube_description(
    video_id: str, payload: YouTubeDescriptionRequest
) -> dict[str, Any]:
    _, video = _studio_video_file(video_id)
    try:
        provider = database.provider_connection(payload.provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="LLM provider not found") from exc
    if provider["provider_type"] not in QUESTION_GENERATION_PROVIDER_TYPES:
        raise HTTPException(
            status_code=422,
            detail="Select an OpenAI-compatible LLM or OpenAI API provider",
        )
    if not provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the LLM provider first")
    model = payload.model
    if not model and provider["provider_type"] == "openai_images":
        model = provider.get("settings", {}).get("question_model")
    model = model or provider.get("default_model") or next(
        iter(provider.get("discovered_models") or []), None
    )
    if not model:
        raise HTTPException(status_code=409, detail="Select an LLM model")
    try:
        secret = secret_store.decrypt(provider.get("secret_ciphertext"))
        questions = deployed_video_questions(
            bundle_root=CATEGORY_BUNDLE_ROOT, video=video
        )
        description = generate_description(
            video=video,
            questions=questions,
            provider=provider,
            model=str(model),
            secret=secret,
        )
    except (OSError, ValueError, SecretStoreError, YouTubePublishError) as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return {
        "description": description,
        "provider_id": provider["id"],
        "model": model,
        "question_count": len(questions),
    }


@app.post("/api/studio/videos/{video_id}/youtube/upload")
def upload_studio_video_to_youtube(
    video_id: str, payload: YouTubeUploadRequest
) -> dict[str, Any]:
    path, video = _studio_video_file(video_id)
    connection = database.youtube_connection()
    if connection is None or not connection.get("refresh_token_ciphertext"):
        raise HTTPException(
            status_code=409, detail="Connect a YouTube channel in Admin first"
        )
    latest = database.latest_youtube_upload(video_id)
    if latest and latest["status"] in {"queued", "uploading"}:
        raise HTTPException(status_code=409, detail="This video is already uploading")
    try:
        client_secret = secret_store.decrypt(connection["client_secret_ciphertext"])
        refresh_token = secret_store.decrypt(connection["refresh_token_ciphertext"])
    except SecretStoreError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    if not client_secret or not refresh_token:
        raise HTTPException(status_code=409, detail="YouTube authorization is incomplete")

    upload_id = uuid.uuid4().hex
    now = _now()
    upload_record = database.create_youtube_upload(
        {
            "id": upload_id,
            "video_id": video_id,
            "title": payload.title.strip(),
            "description": payload.description.strip(),
            "privacy_status": payload.privacy_status,
            "status": "queued",
            "created_at": now,
            "updated_at": now,
        }
    )

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        database.update_youtube_upload(
            upload_id, status="uploading", updated_at=_now()
        )
        try:
            with YouTubeClient() as client:
                progress("Refreshing YouTube authorization", 0.03)
                access_token = client.refresh_access_token(
                    client_id=connection["client_id"],
                    client_secret=client_secret,
                    refresh_token=refresh_token,
                )
                result = client.upload_video(
                    access_token=access_token,
                    video_path=path,
                    title=payload.title.strip(),
                    description=payload.description.strip(),
                    privacy_status=payload.privacy_status,
                    progress=progress,
                )
        except Exception as exc:
            database.update_youtube_upload(
                upload_id,
                status="failed",
                error=str(exc),
                updated_at=_now(),
            )
            raise
        complete = database.update_youtube_upload(
            upload_id,
            status="complete",
            youtube_video_id=result["youtube_video_id"],
            youtube_url=result["youtube_url"],
            updated_at=_now(),
        )
        return complete

    job = jobs.start(
        "youtube_upload",
        target,
        context={
            "video_id": video_id,
            "upload_id": upload_id,
            "category_slug": video["category_slug"],
            "privacy_status": payload.privacy_status,
        },
    )
    upload_record = database.attach_youtube_upload_job(
        upload_id, job_id=job["id"], updated_at=_now()
    )
    return {**job, "youtube_upload": upload_record}


@app.get("/api/studio/jobs")
def studio_jobs(limit: int = 30) -> dict[str, Any]:
    return {"jobs": database.studio_jobs(limit=max(1, min(limit, 100)))}


@app.get("/api/studio/jobs/{job_id}/events")
def studio_job_events(job_id: str) -> StreamingResponse:
    try:
        database.studio_job(job_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Job not found") from exc

    async def stream() -> Any:
        after = 0
        while True:
            events = database.studio_job_events(job_id, after=after)
            for event in events:
                after = event["id"]
                yield f"id: {after}\nevent: job\ndata: {json.dumps(event)}\n\n"
            job = database.studio_job(job_id)
            if job["status"] in {
                "complete",
                "failed",
                "cancelled",
                "interrupted",
            }:
                yield f"event: complete\ndata: {json.dumps(job)}\n\n"
                return
            yield ": keepalive\n\n"
            await asyncio.sleep(0.75)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )


@app.get("/api/admin/providers")
def provider_connections() -> dict[str, Any]:
    return {
        "provider_types": [
            {"id": provider_id, "label": label}
            for provider_id, label in PROVIDER_TYPES.items()
        ],
        "providers": [
            _public_provider(item) for item in database.provider_connections()
        ],
    }


def _youtube_redirect_uri(request: Request) -> str:
    base = STUDIO_PUBLIC_BASE_URL or str(request.base_url).rstrip("/")
    return f"{base}/api/admin/youtube/oauth/callback"


def _public_youtube_connection(request: Request) -> dict[str, Any]:
    connection = database.youtube_connection()
    return {
        "configured": bool(connection),
        "connected": bool(connection and connection.get("refresh_token_ciphertext")),
        "client_id": connection.get("client_id") if connection else None,
        "client_secret_hint": (
            f"...{connection['client_secret_last_four']}"
            if connection and connection.get("client_secret_last_four")
            else None
        ),
        "channel_id": connection.get("channel_id") if connection else None,
        "channel_title": connection.get("channel_title") if connection else None,
        "connected_at": connection.get("connected_at") if connection else None,
        "redirect_uri": _youtube_redirect_uri(request),
        "scope": "youtube.upload",
    }


@app.get("/api/admin/youtube")
def youtube_connection(request: Request) -> dict[str, Any]:
    return _public_youtube_connection(request)


@app.patch("/api/admin/youtube")
def save_youtube_connection(
    payload: YouTubeCredentialsRequest, request: Request
) -> dict[str, Any]:
    existing = database.youtube_connection()
    client_secret = (payload.client_secret or "").strip()
    if client_secret:
        ciphertext = secret_store.encrypt(client_secret)
        last_four = secret_store.last_four(client_secret)
    elif existing:
        ciphertext = str(existing["client_secret_ciphertext"])
        last_four = str(existing["client_secret_last_four"])
    else:
        raise HTTPException(status_code=422, detail="Client secret is required")
    now = _now()
    database.save_youtube_credentials(
        client_id=payload.client_id.strip(),
        client_secret_ciphertext=ciphertext,
        client_secret_last_four=last_four,
        created_at=existing.get("created_at", now) if existing else now,
        updated_at=now,
    )
    return _public_youtube_connection(request)


@app.post("/api/admin/youtube/oauth/start")
def start_youtube_oauth(request: Request) -> dict[str, str]:
    connection = database.youtube_connection()
    if connection is None:
        raise HTTPException(
            status_code=409, detail="Configure YouTube client credentials first"
        )
    state = secrets.token_urlsafe(40)
    state_hash = hashlib.sha256(state.encode("utf-8")).hexdigest()
    now = datetime.now(timezone.utc)
    redirect_uri = _youtube_redirect_uri(request)
    database.create_youtube_oauth_state(
        state_hash=state_hash,
        redirect_uri=redirect_uri,
        expires_at=(now + timedelta(minutes=10)).isoformat(),
        created_at=now.isoformat(),
    )
    return {
        "authorization_url": authorization_url(
            client_id=connection["client_id"],
            redirect_uri=redirect_uri,
            state=state,
        )
    }


def _youtube_oauth_html(*, success: bool, message: str) -> HTMLResponse:
    color = "#237957" if success else "#b44741"
    status = "connected" if success else "failed"
    script_payload = json.dumps(
        {"type": "quiz-youtube-oauth", "status": status, "message": message}
    )
    safe_message = html.escape(message)
    document = f"""<!doctype html>
<html><head><meta charset="utf-8"><title>YouTube authorization</title></head>
<body style="margin:0;display:grid;place-items:center;min-height:100vh;font-family:system-ui;background:#eef1ef;color:#202622">
<main style="width:min(420px,calc(100% - 32px));padding:32px;border:1px solid #d7ddda;border-top:5px solid {color};background:white;text-align:center">
<h1 style="font-size:22px">YouTube {status}</h1><p>{safe_message}</p><p style="font-size:12px;color:#68736d">This window can be closed.</p>
</main><script>if(window.opener){{window.opener.postMessage({script_payload}, window.location.origin);window.close();}}</script></body></html>"""
    return HTMLResponse(document)


@app.get("/api/admin/youtube/oauth/callback")
def youtube_oauth_callback(
    state: str = "", code: str = "", error: str = ""
) -> HTMLResponse:
    if not state:
        return _youtube_oauth_html(success=False, message="OAuth state is missing")
    state_hash = hashlib.sha256(state.encode("utf-8")).hexdigest()
    saved_state = database.consume_youtube_oauth_state(
        state_hash=state_hash, now=_now()
    )
    if saved_state is None:
        return _youtube_oauth_html(
            success=False, message="Authorization expired or was already used"
        )
    if error:
        return _youtube_oauth_html(
            success=False, message=f"Google authorization was declined: {error}"
        )
    if not code:
        return _youtube_oauth_html(
            success=False, message="Google returned no authorization code"
        )
    connection = database.youtube_connection()
    if connection is None:
        return _youtube_oauth_html(
            success=False, message="YouTube client credentials are missing"
        )
    try:
        client_secret = secret_store.decrypt(connection["client_secret_ciphertext"])
        if not client_secret:
            raise YouTubePublishError("YouTube client secret is unavailable")
        with YouTubeClient() as client:
            tokens = client.exchange_code(
                client_id=connection["client_id"],
                client_secret=client_secret,
                code=code,
                redirect_uri=saved_state["redirect_uri"],
            )
            channel_id, channel_title = client.channel_identity(tokens["access_token"])
        refresh_token = str(tokens["refresh_token"])
        database.authorize_youtube(
            refresh_token_ciphertext=secret_store.encrypt(refresh_token),
            refresh_token_last_four=secret_store.last_four(refresh_token),
            channel_id=channel_id,
            channel_title=channel_title,
            connected_at=_now(),
        )
    except (OSError, ValueError, SecretStoreError, YouTubePublishError) as exc:
        return _youtube_oauth_html(success=False, message=str(exc))
    label = channel_title or "YouTube channel"
    return _youtube_oauth_html(success=True, message=f"Connected to {label}")


@app.post("/api/admin/youtube/disconnect")
def disconnect_youtube(request: Request) -> dict[str, Any]:
    connection = database.youtube_connection()
    if connection and connection.get("refresh_token_ciphertext"):
        try:
            token = secret_store.decrypt(connection["refresh_token_ciphertext"])
        except SecretStoreError as exc:
            raise HTTPException(status_code=409, detail=str(exc)) from exc
        if token:
            with YouTubeClient(timeout_seconds=30) as client:
                client.revoke(token)
    database.disconnect_youtube(_now())
    return _public_youtube_connection(request)


@app.post("/api/admin/providers")
def create_provider_connection(payload: ProviderCreateRequest) -> dict[str, Any]:
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
            "test_phrase": "Quiz Studio is ready to create a wonderful new quiz.",
            **settings,
        }
    item = {
        "id": provider_id,
        "provider_type": payload.provider_type,
        "name": payload.name.strip(),
        "base_url": base_url,
        "default_model": payload.default_model,
        "settings": settings,
        "enabled": payload.enabled,
        **_secret_values(payload.api_key),
    }
    return _public_provider(database.create_provider_connection(item))


@app.patch("/api/admin/providers/{provider_id}")
def update_provider_connection(
    provider_id: str, payload: ProviderUpdateRequest
) -> dict[str, Any]:
    try:
        existing = database.provider_connection(provider_id)
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
        changes.update(_secret_values(api_key))
    elif clear_api_key:
        changes.update(_secret_values(None))
    if "settings" in changes and changes["settings"] is not None:
        changes["settings"] = {**existing.get("settings", {}), **changes["settings"]}
    return _public_provider(
        database.update_provider_connection(provider_id, changes)
    )


@app.post("/api/admin/providers/{provider_id}/reference-audio")
async def upload_provider_reference_audio(
    provider_id: str, request: Request
) -> dict[str, Any]:
    try:
        provider = database.provider_connection(provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Provider not found") from exc
    if provider["provider_type"] != "vibevoice":
        raise HTTPException(status_code=422, detail="Reference audio is only valid for VibeVoice")
    content_type = request.headers.get("content-type", "").split(";", 1)[0]
    if content_type not in {"audio/wav", "audio/x-wav", "audio/wave", "application/octet-stream"}:
        raise HTTPException(status_code=422, detail="Reference audio must be a WAV file")
    data = await request.body()
    if not data or len(data) > 25 * 1024 * 1024:
        raise HTTPException(status_code=422, detail="Reference WAV must be between 1 byte and 25 MB")
    try:
        with wave.open(io.BytesIO(data), "rb") as source:
            channels = source.getnchannels()
            sample_rate = source.getframerate()
            sample_width = source.getsampwidth()
            frames = source.getnframes()
    except (EOFError, wave.Error) as exc:
        raise HTTPException(status_code=422, detail=f"Invalid WAV file: {exc}") from exc
    duration = frames / float(sample_rate or 1)
    if channels not in {1, 2} or sample_width not in {1, 2, 3, 4}:
        raise HTTPException(status_code=422, detail="Reference WAV must use mono/stereo PCM audio")
    if sample_rate < 8_000 or sample_rate > 96_000 or duration < 2 or duration > 120:
        raise HTTPException(
            status_code=422,
            detail="Reference WAV must be 2-120 seconds at an 8-96 kHz sample rate",
        )
    safe_id = "".join(character for character in provider_id if character.isalnum() or character in "-_")
    output = PROVIDER_AUDIO_ROOT / safe_id / "reference.wav"
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".wav.tmp")
    temporary.write_bytes(data)
    temporary.replace(output)
    settings = {
        **provider.get("settings", {}),
        "reference_audio_path": str(output),
    }
    updated = database.update_provider_connection(provider_id, {"settings": settings})
    return {
        "provider": _public_provider(updated),
        "reference_audio": {
            "path": str(output),
            "duration_seconds": round(duration, 3),
            "sample_rate": sample_rate,
            "channels": channels,
        },
    }


@app.post("/api/admin/providers/{provider_id}/test")
def test_provider_connection(provider_id: str) -> dict[str, Any]:
    try:
        provider = database.provider_connection(provider_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Provider not found") from exc
    if not provider["enabled"]:
        raise HTTPException(status_code=409, detail="Enable the provider before testing it")
    secret = secret_store.decrypt(provider.get("secret_ciphertext"))
    database.update_provider_health(
        provider_id,
        status="checking",
        message="Connection test queued",
        checked_at=_now(),
    )

    def target(progress: Callable[..., None]) -> dict[str, Any]:
        try:
            result = run_provider_test(
                provider,
                secret,
                artifact_root=PROVIDER_TEST_ROOT,
                progress=progress,
            )
        except Exception as exc:
            database.update_provider_health(
                provider_id,
                status="unhealthy",
                message=str(exc)[:500],
                checked_at=_now(),
            )
            raise
        database.update_provider_health(
            provider_id,
            status="healthy",
            message=result["message"],
            checked_at=_now(),
            models=result.get("models", []),
            default_model=result.get("details", {}).get("default_model"),
        )
        return {"provider_id": provider_id, **result}

    return jobs.start(
        "provider_test",
        target,
        context={"provider_id": provider_id, "provider_type": provider["provider_type"]},
    )


@app.get("/api/image-providers")
def image_providers() -> dict[str, Any]:
    providers: list[dict[str, Any]] = []
    try:
        with MageFlowClient(MAGEFLOW_ENDPOINT, timeout_seconds=4) as client:
            status = client.status()
        providers.append(
            {
                "id": "mageflow",
                "name": "MageFlow",
                "endpoint": MAGEFLOW_ENDPOINT,
                "available": bool(status.get("loaded")),
                "models": [status.get("model", "MageFlow default")],
                "default_model": status.get("model"),
            }
        )
    except MageFlowError as exc:
        providers.append(
            {
                "id": "mageflow",
                "name": "MageFlow",
                "endpoint": MAGEFLOW_ENDPOINT,
                "available": False,
                "models": [],
                "error": str(exc),
            }
        )
    try:
        with ImageStudioClient(IMAGESTUDIO_ENDPOINT, timeout_seconds=4) as client:
            status = client.status()
        engines = status["engines"]
        models = [item["id"] for item in engines if isinstance(item.get("id"), str)]
        providers.append(
            {
                "id": "imagestudio",
                "name": "ImageStudio",
                "endpoint": IMAGESTUDIO_ENDPOINT,
                "available": bool(models),
                "models": models,
                "default_model": status.get("defaultEngine") or "ernie-turbo",
            }
        )
    except MageFlowError as exc:
        providers.append(
            {
                "id": "imagestudio",
                "name": "ImageStudio",
                "endpoint": IMAGESTUDIO_ENDPOINT,
                "available": False,
                "models": [],
                "error": str(exc),
            }
        )
    return {"providers": providers}


@app.post("/api/admin/categories")
def create_category(payload: CategoryCreateRequest) -> dict[str, Any]:
    if payload.age_min > payload.age_max:
        raise HTTPException(status_code=422, detail="age_min must not exceed age_max")
    try:
        return database.create_category(**payload.model_dump())
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Category slug already exists") from exc


@app.post("/api/admin/categories/{category_id}/objects")
def create_object(category_id: int, payload: ObjectCreateRequest) -> dict[str, Any]:
    try:
        return database.create_object(category_id=category_id, **payload.model_dump())
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except sqlite3.IntegrityError as exc:
        raise HTTPException(status_code=409, detail="Object slug already exists") from exc


@app.get("/api/objects/{object_id}")
def object_detail(object_id: int) -> dict[str, Any]:
    try:
        return database.object_detail(object_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/plans/{plan_id}")
def plan_detail(plan_id: int) -> dict[str, Any]:
    try:
        return _pipeline_detail(plan_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc


@app.get("/api/jobs/{job_id}")
def job_detail(job_id: str) -> dict[str, Any]:
    try:
        return jobs.get(job_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail="Job not found") from exc


@app.post("/api/objects/{object_id}/generate-plan")
def generate_object_plan(object_id: int, request: PlanRequest) -> dict[str, Any]:
    try:
        item = database.object_detail(object_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    def target(progress: Callable[[str], None]) -> dict[str, Any]:
        seed = request.seed if request.seed is not None else random.SystemRandom().randrange(2**31)
        generation_request = GenerationRequest(
            category=item["category_name"],
            subject=item["name"],
            language=request.language,
            age_min=item["age_min"],
            age_max=item["age_max"],
            question_count=request.question_count,
            option_count=request.option_count,
            seed=seed,
        )
        with VLLMClient(VLLM_ENDPOINT, timeout_seconds=300) as client:
            model = client.discover_model()
            document = generate_plan(
                client=client,
                endpoint=VLLM_ENDPOINT,
                model=model,
                request=generation_request,
                history_dir=None,
                history=database.plan_history(),
                retries=2,
                progress=progress,
            )
        stored = database.store_plan(document)
        return {"plan_id": stored.plan_id, "revision": stored.revision}

    return jobs.start("plan", target)


@app.post("/api/plans/{plan_id}/generate-assets")
def generate_plan_assets(
    plan_id: int, request: AssetGenerationRequest
) -> dict[str, Any]:
    try:
        context = database.plan_context(plan_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    def target(progress: Callable[[str], None]) -> dict[str, Any]:
        workspace = _workspace(context)
        endpoint = (
            IMAGESTUDIO_ENDPOINT
            if request.provider == "imagestudio"
            else MAGEFLOW_ENDPOINT
        )
        with create_image_generator(
            request.provider,
            endpoint,
            model=request.model,
            timeout_seconds=300,
        ) as client:
            manifest = generate_assets(
                document=context["document"],
                client=client,
                endpoint=endpoint,
                bundle_dir=workspace,
                steps=4,
                cfg=1.0,
                force=False,
                progress=progress,
            )
        return {
            "plan_id": plan_id,
            "asset_count": len(manifest["assets"]),
            "provider": request.provider,
            "model": manifest.get("model"),
        }

    return jobs.start("assets", target)


@app.post("/api/plans/{plan_id}/generate-layout")
def generate_plan_layout(plan_id: int) -> dict[str, Any]:
    try:
        context = database.plan_context(plan_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    def target(progress: Callable[[str], None]) -> dict[str, Any]:
        progress("Writing versioned Flutter layout")
        path = _workspace(context) / "flutter-layout.json"
        layout = write_flutter_layout(context["document"], path)
        return {"plan_id": plan_id, "template": layout["template"]}

    return jobs.start("layout", target)


@app.post("/api/plans/{plan_id}/prepare-bundle")
def prepare_plan_bundle(plan_id: int) -> dict[str, Any]:
    try:
        context = database.plan_context(plan_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    workspace = _workspace(context)
    manifest = _read_manifest(workspace / "asset-manifest.json")
    if manifest is None:
        raise HTTPException(status_code=409, detail="Generate assets first")
    if not (workspace / "flutter-layout.json").exists():
        raise HTTPException(status_code=409, detail="Generate Flutter layout first")

    def target(progress: Callable[[str], None]) -> dict[str, Any]:
        document = context["document"]
        destination = BUNDLE_ROOT / bundle_id(document)
        progress("Copying generated assets")
        destination.mkdir(parents=True, exist_ok=True)
        shutil.copytree(workspace / "assets", destination / "assets", dirs_exist_ok=True)
        shutil.copyfile(
            workspace / "asset-manifest.json", destination / "asset-manifest.json"
        )
        shutil.copyfile(
            workspace / "flutter-layout.json", destination / "flutter-layout.json"
        )
        progress("Writing runtime preview and ZIP")
        archive = write_bundle_files(
            document=document,
            asset_manifest=manifest,
            bundle_dir=destination,
        )
        return {"plan_id": plan_id, "archive": str(archive)}

    return jobs.start("bundle", target)


app.mount("/artifacts", StaticFiles(directory=ASSET_ROOT), name="artifacts")
app.mount("/bundles", StaticFiles(directory=BUNDLE_ROOT), name="bundles")
app.mount(
    "/studio-assets",
    StaticFiles(directory=STUDIO_SOURCE_ROOT),
    name="studio-assets",
)
app.mount(
    "/provider-tests",
    StaticFiles(directory=PROVIDER_TEST_ROOT),
    name="provider-tests",
)
if WEBUI_ROOT.exists():
    app.mount("/", StaticFiles(directory=WEBUI_ROOT, html=True), name="webui")
