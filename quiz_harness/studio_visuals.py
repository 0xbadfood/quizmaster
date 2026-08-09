from __future__ import annotations

import json
import io
import hashlib
import shutil
import tempfile
import threading
import time
from collections import Counter
from contextlib import nullcontext
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from PIL import Image, ImageOps, UnidentifiedImageError

from .answer_images import answer_image_prompt
from .client import VLLMClient
from .image_inventory import build_category_image_spec
from .imagestudio import ImageStudioClient
from .openai_images import (
    OpenAIImageAssetSpec,
    OpenAIImageSpecDocument,
    generate_openai_image_assets,
    reconcile_manifest_assets,
    register_user_upload,
    write_image_spec,
)
from .qwen_image_prompts import (
    ImagePromptPlan,
    apply_category_prompt_plan,
    generate_qwen_image_prompt_plan,
    load_answer_prompt_overrides,
    load_prompt_subjects,
    tile_requests_from_sets,
)
from .visual_bank import (
    AnimalCatalog,
    extract_animal_catalog,
    load_bank,
    slugify,
    write_model,
)


VISUAL_WRITE_LOCK = threading.Lock()
VISUAL_ROLES = ("runtime_background", "category_selector", "quiz_tile", "answer_image")
VISUAL_REVIEW_STATUSES = ("generated_pending_review", "approved", "rejected")
IMAGESTUDIO_NEGATIVE_PROMPT = (
    "watermark, unwanted logo, cropped subject, duplicate subject, blur, distortion"
)


class StudioVisualError(ValueError):
    """Raised when a Studio visual operation cannot be completed safely."""


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise StudioVisualError(f"cannot read {path.name}: {exc}") from exc
    return value if isinstance(value, dict) else {}


def _write_json(path: Path, value: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(value, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def _is_legacy_animal_fallback(prompt: str | None) -> bool:
    if not prompt:
        return False
    return (
        "friendly lion, elephant, monkey, and giant panda" in prompt
        or "together with a friendly, balanced group representing these quiz" in prompt
    )


def _progress_adapter(progress: Callable[..., None], start: float, end: float):
    def report(message: str) -> None:
        current = start
        for token in message.replace(":", " ").split():
            if "/" not in token:
                continue
            left, _, right = token.partition("/")
            if left.isdigit() and right.isdigit() and int(right):
                current = start + (int(left) / int(right)) * (end - start)
                break
        progress(message, min(end, current))

    return report


def _image_is_valid(path: Path, size: tuple[int, int]) -> bool:
    try:
        with Image.open(path) as image:
            image.load()
            return image.format == "WEBP" and image.size == size
    except (OSError, UnidentifiedImageError):
        return False


def _write_fitted_webp(data: bytes, output: Path, size: tuple[int, int]) -> None:
    try:
        with Image.open(io.BytesIO(data)) as source:
            source.load()
            image = ImageOps.fit(
                source.convert("RGB"),
                size,
                method=Image.Resampling.LANCZOS,
                centering=(0.5, 0.5),
            )
    except (OSError, UnidentifiedImageError) as exc:
        raise StudioVisualError(f"ImageStudio returned invalid image data: {exc}") from exc
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    image.save(temporary, format="WEBP", quality=92, method=6)
    temporary.replace(output)


def _imagestudio_seed(asset_id: str, model: str) -> int:
    digest = hashlib.sha256(f"studio-visual-v1:{model}:{asset_id}".encode()).digest()
    return int.from_bytes(digest[:4], "big") & 0x7FFFFFFF


def _generate_imagestudio_assets(
    *,
    document: OpenAIImageSpecDocument,
    root: Path,
    manifest_path: Path,
    client: ImageStudioClient,
    endpoint: str,
    model: str,
    selected_asset_ids: set[str],
    force: bool,
    progress: Callable[[str], None],
) -> dict[str, Any]:
    client.require_ready()
    assets = [item for item in document.assets if item.asset_id in selected_asset_ids]
    missing = selected_asset_ids - {item.asset_id for item in assets}
    if missing:
        raise StudioVisualError(f"unknown ImageStudio assets: {', '.join(sorted(missing))}")
    manifest = _read_json(manifest_path)
    manifest.setdefault("schema_version", "studio_visual_manifest_v1")
    manifest.setdefault("name", document.name)
    manifest.setdefault("assets", {})
    manifest.setdefault("failures", {})
    generated = reused = failed = 0
    total = len(assets)
    for index, asset in enumerate(assets, start=1):
        if not asset.prompt:
            raise StudioVisualError(f"{asset.asset_id} has no generation prompt")
        output = root / asset.file
        seed = _imagestudio_seed(asset.asset_id, model)
        fingerprint = hashlib.sha256(
            json.dumps(
                {
                    "provider": "imagestudio",
                    "model": model,
                    "prompt": asset.prompt,
                    "width": asset.output_width,
                    "height": asset.output_height,
                    "seed": seed,
                },
                sort_keys=True,
            ).encode()
        ).hexdigest()
        cached = manifest["assets"].get(asset.asset_id)
        if (
            not force
            and isinstance(cached, dict)
            and cached.get("fingerprint") == fingerprint
            and _image_is_valid(output, (asset.output_width, asset.output_height))
        ):
            reused += 1
            progress(f"Asset {index}/{total}: reusing {asset.asset_id}")
            continue
        progress(f"Asset {index}/{total}: generating {asset.asset_id}")
        last_error: Exception | None = None
        for attempt in range(1, 4):
            try:
                data, metadata = client.generate(
                    prompt=asset.prompt,
                    negative_prompt=IMAGESTUDIO_NEGATIVE_PROMPT,
                    width=asset.output_width,
                    height=asset.output_height,
                    steps=8,
                    cfg=1.0,
                    seed=seed,
                )
                generation = (
                    int(cached.get("generation", 0)) + 1
                    if isinstance(cached, dict)
                    else 1
                )
                version_file = f"assets/versions/{asset.asset_id}/v{generation:03d}.webp"
                version_path = root / version_file
                _write_fitted_webp(
                    data,
                    version_path,
                    (asset.output_width, asset.output_height),
                )
                output.parent.mkdir(parents=True, exist_ok=True)
                temporary = output.with_suffix(output.suffix + ".tmp")
                shutil.copyfile(version_path, temporary)
                temporary.replace(output)
                versions = list(cached.get("versions", [])) if isinstance(cached, dict) else []
                versions.append(
                    {
                        "generation": generation,
                        "file": version_file,
                        "prompt": asset.prompt,
                        "model": model,
                        "seed": metadata.get("seed", seed),
                        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
                    }
                )
                manifest["assets"][asset.asset_id] = {
                    "asset_id": asset.asset_id,
                    "role": asset.role,
                    "source": "imagestudio",
                    "provider": "imagestudio",
                    "model": model,
                    "file": asset.file,
                    "status": "generated_pending_review",
                    "generation": generation,
                    "fingerprint": fingerprint,
                    "prompt": asset.prompt,
                    "seed": metadata.get("seed", seed),
                    "width": asset.output_width,
                    "height": asset.output_height,
                    "format": "webp",
                    "versions": versions,
                }
                manifest["failures"].pop(asset.asset_id, None)
                _write_json(manifest_path, manifest)
                cached = manifest["assets"][asset.asset_id]
                generated += 1
                last_error = None
                break
            except Exception as exc:  # Preserve progress through long visual batches.
                last_error = exc
                if attempt < 3:
                    time.sleep(min(2**attempt, 8))
        if last_error is not None:
            failed += 1
            manifest["assets"][asset.asset_id] = {
                **(cached if isinstance(cached, dict) else {}),
                "asset_id": asset.asset_id,
                "role": asset.role,
                "source": "imagestudio",
                "file": asset.file,
                "status": "generation_failed",
                "error": str(last_error),
                "failed_at_utc": datetime.now(timezone.utc).isoformat(),
            }
            manifest["failures"][asset.asset_id] = {
                "error": str(last_error),
                "failed_at_utc": datetime.now(timezone.utc).isoformat(),
            }
            _write_json(manifest_path, manifest)
    manifest["last_run"] = {
        "requested": total,
        "generated": generated,
        "reused": reused,
        "failed": failed,
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    _write_json(manifest_path, manifest)
    return manifest


class StudioVisualStore:
    def __init__(self, root: Path) -> None:
        self.root = Path(root)

    def category_root(self, category_slug: str) -> Path:
        return self.root / category_slug

    @staticmethod
    def blocked_inventory(reason: str) -> dict[str, Any]:
        return {
            "ready": False,
            "blocked_reason": reason,
            "assets": [],
            "summary": {
                "total": 0,
                "generated": 0,
                "approved": 0,
                "pending_review": 0,
                "rejected": 0,
                "failed": 0,
                "unplanned": 0,
                "attention": 0,
                "roles": {},
            },
            "prompt_plan": {
                "exists": False,
                "model": None,
                "seed": None,
                "guidance": "",
            },
        }

    def _catalog(self, category: dict[str, Any], *, persist: bool) -> AnimalCatalog:
        root = self.category_root(category["slug"])
        bank_paths = sorted((root / "banks").glob("*/bank.json"))
        if not bank_paths:
            raise StudioVisualError("question banks are required before visual planning")
        catalog = extract_animal_catalog(
            [load_bank(path) for path in bank_paths],
            category=category["name"],
            include_states={"allocated"},
        )
        if not catalog.animals:
            raise StudioVisualError("select at least one quiz set before visual planning")
        if persist:
            write_model(root / "animal_catalog.json", catalog)
        return catalog

    def prepare(
        self,
        category: dict[str, Any],
        *,
        model: str = "gpt-image-2",
        quality: str = "medium",
    ) -> tuple[AnimalCatalog, OpenAIImageSpecDocument]:
        with VISUAL_WRITE_LOCK:
            return self._prepare_unlocked(category, model=model, quality=quality)

    def _prepare_unlocked(
        self,
        category: dict[str, Any],
        *,
        model: str,
        quality: str,
    ) -> tuple[AnimalCatalog, OpenAIImageSpecDocument]:
        root = self.category_root(category["slug"])
        catalog = self._catalog(category, persist=True)
        background = root / "assets/category/runtime_background.png"
        proposed = build_category_image_spec(
            category=category["name"],
            category_root=root,
            display_title=category["display_title"],
            model=model,
            quality=quality,
            background_ready=background.exists(),
        )
        spec_path = root / "category-image-spec.json"
        if spec_path.exists():
            existing = OpenAIImageSpecDocument.model_validate_json(
                spec_path.read_text(encoding="utf-8")
            )
            by_id = {item.asset_id: item for item in existing.assets}
            merged = []
            for asset in proposed.assets:
                prior = by_id.get(asset.asset_id)
                if prior is None or prior.role != asset.role or prior.source != asset.source:
                    merged.append(asset)
                    continue
                update: dict[str, Any] = {
                    "file": asset.file,
                    "output_width": asset.output_width,
                    "output_height": asset.output_height,
                    "exact_text": asset.exact_text,
                }
                if _is_legacy_animal_fallback(prior.prompt):
                    update["prompt"] = asset.prompt
                if prior.source == "user_upload" and background.exists():
                    update["review_status"] = "approved"
                merged.append(prior.model_copy(update=update))
            proposed = proposed.model_copy(update={"assets": merged})
        write_image_spec(spec_path, proposed)
        reconcile_manifest_assets(
            document=proposed,
            manifest_path=root / "category-image-manifest.json",
        )
        return catalog, proposed

    def inventory(self, category: dict[str, Any]) -> dict[str, Any]:
        root = self.category_root(category["slug"])
        try:
            catalog = self._catalog(category, persist=False)
        except StudioVisualError as exc:
            return self.blocked_inventory(str(exc))
        spec_path = root / "category-image-spec.json"
        spec = (
            OpenAIImageSpecDocument.model_validate_json(
                spec_path.read_text(encoding="utf-8")
            )
            if spec_path.exists()
            else build_category_image_spec(
                category=category["name"],
                category_root=root,
                display_title=category["display_title"],
                background_ready=(root / "assets/category/runtime_background.png").exists(),
            )
        )
        if any(_is_legacy_animal_fallback(item.prompt) for item in spec.assets):
            proposed = build_category_image_spec(
                category=category["name"],
                category_root=root,
                display_title=category["display_title"],
                background_ready=(
                    root / "assets/category/runtime_background.png"
                ).exists(),
            )
            proposed_by_id = {item.asset_id: item for item in proposed.assets}
            spec = spec.model_copy(
                update={
                    "assets": [
                        item.model_copy(
                            update={"prompt": proposed_by_id[item.asset_id].prompt}
                        )
                        if _is_legacy_animal_fallback(item.prompt)
                        and item.asset_id in proposed_by_id
                        else item
                        for item in spec.assets
                    ]
                }
            )
            write_image_spec(spec_path, spec)
        category_manifest = _read_json(root / "category-image-manifest.json")
        answer_manifest = _read_json(root / "answer-image-manifest.json")
        plan_path = root / "image-prompt-plan.json"
        plan = (
            ImagePromptPlan.model_validate_json(plan_path.read_text(encoding="utf-8"))
            if plan_path.exists()
            else None
        )
        planned = {item.asset_id: item for item in plan.assets} if plan else {}
        assets: list[dict[str, Any]] = []
        for item in spec.assets:
            record = category_manifest.get("assets", {}).get(item.asset_id, {})
            plan_item = planned.get(item.asset_id)
            output = root / item.file
            assets.append(
                {
                    **item.model_dump(mode="json"),
                    "status": record.get("status", item.review_status),
                    "image_url": (
                        f"/studio-assets/{category['slug']}/{item.file}"
                        if output.is_file()
                        else None
                    ),
                    "generation": record.get("generation", 0),
                    "error": record.get("error"),
                    "prompt_status": plan_item.review_status if plan_item else "unplanned",
                    "visual_summary": plan_item.visual_summary if plan_item else "",
                }
            )
        for subject in catalog.animals:
            asset_id = f"answer_{subject.animal_key}"
            record = answer_manifest.get("assets", {}).get(subject.animal_key, {})
            plan_item = planned.get(asset_id)
            output = root / subject.image_path
            assets.append(
                {
                    "asset_id": asset_id,
                    "role": "answer_image",
                    "source": record.get("source", "provider_choice"),
                    "file": subject.image_path,
                    "label": subject.label,
                    "prompt": (
                        plan_item.prompt if plan_item else answer_image_prompt(subject.label)
                    ),
                    "negative_prompt": plan_item.negative_prompt if plan_item else "",
                    "seed": plan_item.seed if plan_item else None,
                    "status": record.get(
                        "status",
                        "generated_pending_review" if output.is_file() else "pending_generation",
                    ),
                    "image_url": (
                        f"/studio-assets/{category['slug']}/{subject.image_path}"
                        if output.is_file()
                        else None
                    ),
                    "generation": record.get("generation", int(output.is_file())),
                    "error": record.get("error")
                    or answer_manifest.get("failures", {})
                    .get(subject.animal_key, {})
                    .get("error"),
                    "prompt_status": plan_item.review_status if plan_item else "unplanned",
                    "visual_summary": plan_item.visual_summary if plan_item else "",
                    "choice_count": subject.choice_count,
                }
            )
        status_counts = Counter(item["status"] for item in assets)
        role_counts = Counter(item["role"] for item in assets)
        unplanned = sum(
            item["role"] != "runtime_background"
            and item["prompt_status"] == "unplanned"
            for item in assets
        )
        attention = sum(
            item["status"] in {"rejected", "generation_failed"}
            or (
                item["role"] != "runtime_background"
                and item["prompt_status"] == "unplanned"
            )
            for item in assets
        )
        return {
            "ready": True,
            "blocked_reason": None,
            "assets": assets,
            "summary": {
                "total": len(assets),
                "generated": sum(bool(item["image_url"]) for item in assets),
                "approved": status_counts["approved"],
                "pending_review": status_counts["generated_pending_review"],
                "rejected": status_counts["rejected"],
                "failed": status_counts["generation_failed"],
                "unplanned": unplanned,
                "attention": attention,
                "roles": dict(role_counts),
            },
            "prompt_plan": {
                "exists": plan is not None,
                "model": plan.qwen_model if plan else None,
                "seed": plan.base_seed if plan else None,
                "guidance": plan.category_guidance if plan else "",
            },
        }

    def plan_prompts(
        self,
        *,
        category: dict[str, Any],
        client: VLLMClient,
        endpoint: str,
        model: str,
        roles: set[str],
        guidance: str,
        seed: int,
        force: bool,
        progress: Callable[..., None],
        on_batch_planned: Callable[[set[str]], None] | None = None,
    ) -> dict[str, Any]:
        root = self.category_root(category["slug"])
        catalog, _ = self.prepare(category)
        progress("Preparing visual subjects", 0.04)
        category_spec_path = root / "category-image-spec.json"

        def batch_committed(plan: ImagePromptPlan, asset_ids: set[str]) -> None:
            with VISUAL_WRITE_LOCK:
                apply_category_prompt_plan(
                    plan=plan, category_spec_path=category_spec_path
                )
            if on_batch_planned:
                on_batch_planned(asset_ids)

        plan = generate_qwen_image_prompt_plan(
            category=category["name"],
            display_title=category["display_title"],
            category_guidance=guidance,
            category_root=root,
            subjects=load_prompt_subjects(root / "animal_catalog.json"),
            client=client,
            endpoint=endpoint,
            model=model,
            roles=roles,
            base_seed=seed,
            tile_requests=tile_requests_from_sets(root),
            force=force,
            refresh_tile_briefs=force,
            progress=_progress_adapter(progress, 0.08, 0.9),
            on_batch_committed=batch_committed,
        )
        with VISUAL_WRITE_LOCK:
            apply_category_prompt_plan(
                plan=plan, category_spec_path=category_spec_path
            )
        progress("Visual prompt plan ready", 0.96)
        return {
            "category_slug": category["slug"],
            "roles": sorted(roles),
            "asset_count": len(plan.assets),
            "subject_count": len(catalog.animals),
            "model": model,
        }

    def update_prompt(
        self, category_slug: str, asset_id: str, prompt: str
    ) -> dict[str, Any]:
        root = self.category_root(category_slug)
        prompt = prompt.strip()
        if asset_id.startswith("answer_"):
            if len(prompt) < 180:
                raise StudioVisualError("answer prompts must contain at least 180 characters")
            plan_path = root / "image-prompt-plan.json"
            if not plan_path.exists():
                raise StudioVisualError("generate answer prompts before editing them")
            plan = ImagePromptPlan.model_validate_json(plan_path.read_text(encoding="utf-8"))
            found = False
            updated = []
            for item in plan.assets:
                if item.asset_id != asset_id:
                    updated.append(item)
                    continue
                updated.append(item.model_copy(update={"prompt": prompt, "review_status": "approved"}))
                found = True
            if not found:
                raise KeyError(asset_id)
            write_model(plan_path, plan.model_copy(update={"assets": updated}))
        else:
            if len(prompt) < 30:
                raise StudioVisualError("prompt must contain at least 30 characters")
            spec_path = root / "category-image-spec.json"
            if not spec_path.exists():
                raise StudioVisualError("prepare visual inventory before editing prompts")
            document = OpenAIImageSpecDocument.model_validate_json(
                spec_path.read_text(encoding="utf-8")
            )
            found = False
            updated = []
            for item in document.assets:
                if item.asset_id != asset_id:
                    updated.append(item)
                    continue
                if item.source != "openai":
                    raise StudioVisualError("uploaded backgrounds do not have generation prompts")
                updated.append(item.model_copy(update={"prompt": prompt, "review_status": "pending_generation"}))
                found = True
            if not found:
                raise KeyError(asset_id)
            write_image_spec(spec_path, document.model_copy(update={"assets": updated}))
        return {"asset_id": asset_id, "prompt": prompt}

    def review_asset(
        self, category_slug: str, asset_id: str, status: str
    ) -> dict[str, Any]:
        if status not in {"approved", "rejected", "generated_pending_review"}:
            raise StudioVisualError("invalid visual review status")
        root = self.category_root(category_slug)
        if asset_id.startswith("answer_"):
            key = asset_id.removeprefix("answer_")
            manifest_path = root / "answer-image-manifest.json"
            manifest = _read_json(manifest_path)
            record = manifest.get("assets", {}).get(key)
        else:
            key = asset_id
            manifest_path = root / "category-image-manifest.json"
            manifest = _read_json(manifest_path)
            record = manifest.get("assets", {}).get(key)
        if not isinstance(record, dict):
            raise StudioVisualError("generate or upload the asset before reviewing it")
        record["status"] = status
        record["reviewed_at_utc"] = datetime.now(timezone.utc).isoformat()
        _write_json(manifest_path, manifest)
        return {"asset_id": asset_id, "status": status}

    def upload_background(
        self, category: dict[str, Any], data: bytes, content_type: str
    ) -> dict[str, Any]:
        if not data:
            raise StudioVisualError("uploaded background is empty")
        root = self.category_root(category["slug"])
        _, document = self.prepare(category)
        spec = next(item for item in document.assets if item.role == "runtime_background")
        if not content_type.startswith("image/"):
            raise StudioVisualError("background upload must be an image")
        try:
            with Image.open(io.BytesIO(data)) as source:
                source.load()
                normalized = source.convert("RGB")
        except (OSError, UnidentifiedImageError) as exc:
            raise StudioVisualError(f"background upload is invalid: {exc}") from exc
        with tempfile.NamedTemporaryFile(suffix=".png") as handle:
            normalized.save(handle, format="PNG", optimize=True)
            handle.flush()
            register_user_upload(
                spec=spec,
                source=Path(handle.name),
                root=root,
                manifest_path=root / "category-image-manifest.json",
                manifest_name=document.name,
            )
        return {"asset_id": spec.asset_id, "status": "approved"}

    def generate_images(
        self,
        *,
        category: dict[str, Any],
        asset_ids: set[str],
        provider: dict[str, Any],
        secret: str | None,
        model: str,
        quality: str,
        force: bool,
        progress: Callable[..., None],
    ) -> dict[str, Any]:
        if not asset_ids:
            raise StudioVisualError("select at least one visual asset")
        root = self.category_root(category["slug"])
        catalog, document = self.prepare(
            category,
            model=model if provider["provider_type"] == "openai_images" else "gpt-image-2",
            quality=quality,
        )
        category_ids = {
            item.asset_id for item in document.assets if item.role != "runtime_background"
        }
        answer_ids = {f"answer_{item.animal_key}" for item in catalog.animals}
        unknown = asset_ids - category_ids - answer_ids
        if unknown:
            raise StudioVisualError(f"unknown visual assets: {', '.join(sorted(unknown))}")
        selected_category = asset_ids & category_ids
        selected_answers = asset_ids & answer_ids
        plan_path = root / "image-prompt-plan.json"
        overrides = (
            load_answer_prompt_overrides(plan_path, include_pending=True)
            if plan_path.exists()
            else {}
        )
        answer_document = OpenAIImageSpecDocument(
            schema_version="openai_image_spec_v1",
            name=f"{slugify(category['slug'])}_answer_images",
            category=category["name"],
            generated_at_utc=datetime.now(timezone.utc).isoformat(),
            assets=[
                OpenAIImageAssetSpec(
                    asset_id=subject.animal_key,
                    scope="category",
                    role="answer_image",
                    source="openai",
                    provider="openai",
                    model=model,
                    quality=quality,
                    api_size="1024x1024",
                    output_width=768,
                    output_height=768,
                    background="opaque",
                    file=subject.image_path,
                    prompt=overrides.get(
                        subject.animal_key, answer_image_prompt(subject.label)
                    ),
                    exact_text=[],
                    review_status="pending_generation",
                )
                for subject in catalog.animals
            ],
        )
        selected_answer_keys = {
            item.removeprefix("answer_") for item in selected_answers
        }
        groups: list[tuple[OpenAIImageSpecDocument, Path, set[str]]] = []
        if selected_category:
            updated = [
                item.model_copy(update={"model": model, "quality": quality})
                if item.asset_id in selected_category
                else item
                for item in document.assets
            ]
            document = document.model_copy(update={"assets": updated})
            groups.append(
                (document, root / "category-image-manifest.json", selected_category)
            )
        if selected_answer_keys:
            groups.append(
                (
                    answer_document,
                    root / "answer-image-manifest.json",
                    selected_answer_keys,
                )
            )
        runs: list[dict[str, Any]] = []
        with ImageStudioClient(
            provider["base_url"], model=model, timeout_seconds=900
        ) if provider["provider_type"] == "imagestudio" else nullcontext() as client:
            for index, (group_document, manifest_path, selected) in enumerate(groups):
                start = 0.04 + (index / len(groups)) * 0.9
                end = 0.04 + ((index + 1) / len(groups)) * 0.9
                group_progress = _progress_adapter(progress, start, end)
                if provider["provider_type"] == "openai_images":
                    manifest = generate_openai_image_assets(
                        document=group_document,
                        root=root,
                        manifest_path=manifest_path,
                        api_key=secret,
                        base_url=provider["base_url"],
                        selected_asset_ids=selected,
                        force=force,
                        progress=group_progress,
                    )
                else:
                    assert isinstance(client, ImageStudioClient)
                    manifest = _generate_imagestudio_assets(
                        document=group_document,
                        root=root,
                        manifest_path=manifest_path,
                        client=client,
                        endpoint=provider["base_url"],
                        model=model,
                        selected_asset_ids=selected,
                        force=force,
                        progress=group_progress,
                    )
                runs.append(manifest.get("last_run", {}))
        return {
            "category_slug": category["slug"],
            "requested": len(asset_ids),
            "generated": sum(run.get("generated", 0) for run in runs),
            "reused": sum(run.get("reused", 0) for run in runs),
            "failed": sum(run.get("failed", 0) for run in runs),
            "provider_id": provider["id"],
            "model": model,
        }
