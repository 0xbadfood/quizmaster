from __future__ import annotations

import base64
import hashlib
import io
import json
import shutil
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Annotated, Any, Callable, Literal

from openai import APIError, OpenAI
from PIL import Image, ImageDraw, ImageOps, UnidentifiedImageError
from pydantic import Field, model_validator

from .models import Identifier, StrictModel
from .openai_bank import resolve_openai_token


OpenAIImageSize = Literal["1024x1024", "1536x1024", "1024x1536"]
OpenAIImageQuality = Literal["low", "medium", "high", "auto"]


class OpenAIImageAssetSpec(StrictModel):
    asset_id: Identifier
    scope: Literal["category", "global"]
    role: Literal[
        "runtime_background",
        "category_selector",
        "quiz_tile",
        "answer_image",
        "settings_button",
        "speaker_on",
        "speaker_muted",
        "progress_bar",
        "video_background_landscape",
        "video_progress_plaque",
        "video_question_frame",
        "video_answer_frame",
        "video_explanation_frame",
        "video_badge",
    ]
    source: Literal["openai", "user_upload"]
    provider: Literal["openai"] | None = None
    model: Annotated[str, Field(min_length=2, max_length=80)] | None = None
    quality: OpenAIImageQuality | None = None
    api_size: OpenAIImageSize | None = None
    api_background: Literal["opaque", "transparent"] | None = None
    output_width: Annotated[int, Field(ge=128, le=2048)]
    output_height: Annotated[int, Field(ge=128, le=2048)]
    background: Literal["opaque", "transparent"]
    file: Annotated[str, Field(min_length=8, max_length=240)]
    prompt: Annotated[str, Field(min_length=30, max_length=4000)] | None = None
    exact_text: list[Annotated[str, Field(min_length=1, max_length=80)]] = []
    review_status: Literal[
        "awaiting_upload",
        "pending_generation",
        "generated_pending_review",
        "approved",
        "rejected",
    ]

    @model_validator(mode="after")
    def validate_source(self) -> OpenAIImageAssetSpec:
        if self.source == "openai":
            missing = [
                name
                for name, value in (
                    ("provider", self.provider),
                    ("model", self.model),
                    ("quality", self.quality),
                    ("api_size", self.api_size),
                    ("prompt", self.prompt),
                )
                if value is None
            ]
            if missing:
                raise ValueError(
                    "OpenAI assets require " + ", ".join(missing)
                )
        elif any(
            value is not None
            for value in (self.provider, self.model, self.quality, self.api_size)
        ):
            raise ValueError("user uploads cannot declare generation settings")
        return self


class OpenAIImageSpecDocument(StrictModel):
    schema_version: Literal["openai_image_spec_v1"]
    name: Identifier
    category: Annotated[str, Field(min_length=2, max_length=60)] | None = None
    generated_at_utc: Annotated[str, Field(min_length=10, max_length=60)]
    # A category can contain 20 sets with 10 questions and 4 unique choices each.
    assets: Annotated[list[OpenAIImageAssetSpec], Field(min_length=1, max_length=800)]

    @model_validator(mode="after")
    def validate_assets(self) -> OpenAIImageSpecDocument:
        asset_ids = [asset.asset_id for asset in self.assets]
        files = [asset.file for asset in self.assets]
        if len(asset_ids) != len(set(asset_ids)):
            raise ValueError("asset IDs must be unique")
        if len(files) != len(set(files)):
            raise ValueError("asset files must be unique")
        return self


class OpenAIImageGenerationError(RuntimeError):
    """Raised when a requested OpenAI image asset cannot be generated."""


def write_image_spec(path: Path, document: OpenAIImageSpecDocument) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(document.model_dump_json(indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def load_or_create_image_spec(
    path: Path,
    proposed: OpenAIImageSpecDocument,
    *,
    refresh: bool = False,
) -> OpenAIImageSpecDocument:
    if path.exists() and not refresh:
        return OpenAIImageSpecDocument.model_validate_json(
            path.read_text(encoding="utf-8")
        )
    write_image_spec(path, proposed)
    return proposed


def _load_manifest(path: Path, *, name: str) -> dict[str, Any]:
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            data = {}
    else:
        data = {}
    if not isinstance(data, dict):
        data = {}
    if not isinstance(data.get("assets"), dict):
        data["assets"] = {}
    return {
        **data,
        "schema_version": "openai_image_manifest_v1",
        "name": name,
        "assets": data["assets"],
    }


def _write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def reconcile_manifest_assets(
    *,
    document: OpenAIImageSpecDocument,
    manifest_path: Path,
) -> dict[str, Any]:
    manifest = _load_manifest(manifest_path, name=document.name)
    active_ids = {asset.asset_id for asset in document.assets}
    changed = False
    for asset_id, record in manifest["assets"].items():
        if asset_id in active_ids or not isinstance(record, dict):
            continue
        if record.get("status") != "retired":
            record["status"] = "retired"
            record["retired_at_utc"] = datetime.now(timezone.utc).isoformat()
            changed = True
    if changed:
        _write_manifest(manifest_path, manifest)
    return manifest


def _fingerprint(asset: OpenAIImageAssetSpec) -> str:
    payload = asset.model_dump(mode="json", exclude={"review_status"})
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _valid_image(
    path: Path,
    *,
    size: tuple[int, int],
    require_alpha: bool,
) -> bool:
    try:
        with Image.open(path) as image:
            image.load()
            if image.format != "WEBP" or image.size != size:
                return False
            return not require_alpha or "A" in image.getbands()
    except (OSError, UnidentifiedImageError):
        return False


def _normalize_image(
    image_data: bytes,
    *,
    output: Path,
    target_size: tuple[int, int],
    transparent: bool,
) -> None:
    try:
        with Image.open(io.BytesIO(image_data)) as source:
            source.load()
            image = source.convert("RGBA" if transparent else "RGB")
    except (OSError, UnidentifiedImageError) as exc:
        raise OpenAIImageGenerationError(
            f"OpenAI returned invalid image data: {exc}"
        ) from exc

    if transparent:
        if image.getchannel("A").getextrema() == (255, 255):
            corners = [
                (0, 0),
                (image.width - 1, 0),
                (0, image.height - 1),
                (image.width - 1, image.height - 1),
            ]
            for corner in corners:
                red, green, blue, _ = image.getpixel(corner)
                ImageDraw.floodfill(
                    image,
                    corner,
                    value=(red, green, blue, 0),
                    thresh=42,
                )
        alpha = image.getchannel("A")
        box = alpha.getbbox()
        if box:
            image = image.crop(box)
        image.thumbnail(target_size, Image.Resampling.LANCZOS)
        canvas = Image.new("RGBA", target_size, (0, 0, 0, 0))
        position = (
            (target_size[0] - image.width) // 2,
            (target_size[1] - image.height) // 2,
        )
        canvas.alpha_composite(image, position)
        image = canvas
    else:
        image = ImageOps.fit(
            image, target_size, method=Image.Resampling.LANCZOS, centering=(0.5, 0.5)
        ).convert("RGB")

    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    image.save(temporary, format="WEBP", quality=92, method=6)
    temporary.replace(output)


def register_user_upload(
    *,
    spec: OpenAIImageAssetSpec,
    source: Path,
    root: Path,
    manifest_path: Path,
    manifest_name: str,
) -> dict[str, Any]:
    if spec.source != "user_upload":
        raise ValueError(f"{spec.asset_id} is not a user-upload asset")
    try:
        with Image.open(source) as image:
            image.load()
            width, height = image.size
            image_format = image.format or source.suffix.lstrip(".").upper()
    except (OSError, UnidentifiedImageError) as exc:
        raise ValueError(f"invalid uploaded image {source}: {exc}") from exc

    output = root / spec.file
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    shutil.copyfile(source, temporary)
    temporary.replace(output)
    digest = hashlib.sha256(output.read_bytes()).hexdigest()
    manifest = _load_manifest(manifest_path, name=manifest_name)
    manifest["assets"][spec.asset_id] = {
        "asset_id": spec.asset_id,
        "role": spec.role,
        "source": "user_upload",
        "file": spec.file,
        "status": "approved",
        "sha256": digest,
        "width": width,
        "height": height,
        "format": image_format.casefold(),
        "imported_from": str(source),
        "imported_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    _write_manifest(manifest_path, manifest)
    return manifest


def _next_version_file(
    root: Path, asset: OpenAIImageAssetSpec, generation: int
) -> tuple[Path, str]:
    relative = f"assets/versions/{asset.asset_id}/v{generation:03d}.webp"
    return root / relative, relative


def generate_openai_image_assets(
    *,
    document: OpenAIImageSpecDocument,
    root: Path,
    manifest_path: Path,
    api_key: str | None = None,
    base_url: str | None = None,
    selected_asset_ids: set[str] | None = None,
    force: bool = False,
    retries: int = 2,
    timeout_seconds: float = 900.0,
    progress: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    generated_assets = [asset for asset in document.assets if asset.source == "openai"]
    known_ids = {asset.asset_id for asset in generated_assets}
    if selected_asset_ids is not None:
        missing = sorted(selected_asset_ids - known_ids)
        if missing:
            raise ValueError(f"unknown OpenAI asset IDs: {', '.join(missing)}")
        generated_assets = [
            asset for asset in generated_assets if asset.asset_id in selected_asset_ids
        ]
    token = resolve_openai_token(api_key)
    manifest = _load_manifest(manifest_path, name=document.name)
    manifest["spec_schema_version"] = document.schema_version
    total = len(generated_assets)
    generated = 0
    reused = 0
    failed = 0

    client_options: dict[str, Any] = {
        "api_key": token,
        "timeout": timeout_seconds,
    }
    if base_url:
        client_options["base_url"] = base_url
    with OpenAI(**client_options) as client:
        for index, asset in enumerate(generated_assets, start=1):
            assert asset.model is not None
            assert asset.quality is not None
            assert asset.api_size is not None
            assert asset.prompt is not None
            output = root / asset.file
            fingerprint = _fingerprint(asset)
            cached = manifest["assets"].get(asset.asset_id)
            valid_cached = (
                isinstance(cached, dict)
                and cached.get("fingerprint") == fingerprint
                and _valid_image(
                    output,
                    size=(asset.output_width, asset.output_height),
                    require_alpha=asset.background == "transparent",
                )
            )
            if not force and valid_cached:
                reused += 1
                if progress:
                    progress(f"Asset {index}/{total}: reusing {asset.asset_id}")
                continue

            if progress:
                progress(f"Asset {index}/{total}: generating {asset.asset_id}")
            last_error: Exception | None = None
            for attempt in range(1, retries + 2):
                try:
                    response = client.images.generate(
                        model=asset.model,
                        prompt=asset.prompt,
                        n=1,
                        quality=asset.quality,
                        size=asset.api_size,
                        background=asset.api_background or asset.background,
                        output_format="webp",
                        output_compression=90,
                        moderation="auto",
                    )
                    item = response.data[0]
                    if not item.b64_json:
                        raise OpenAIImageGenerationError(
                            "OpenAI image response did not include b64_json"
                        )
                    image_data = base64.b64decode(item.b64_json, validate=True)
                    generation = (
                        int(cached.get("generation", 0)) + 1
                        if isinstance(cached, dict)
                        else 1
                    )
                    version_path, version_file = _next_version_file(
                        root, asset, generation
                    )
                    _normalize_image(
                        image_data,
                        output=version_path,
                        target_size=(asset.output_width, asset.output_height),
                        transparent=asset.background == "transparent",
                    )
                    output.parent.mkdir(parents=True, exist_ok=True)
                    temporary = output.with_suffix(output.suffix + ".tmp")
                    shutil.copyfile(version_path, temporary)
                    temporary.replace(output)
                    versions = (
                        list(cached.get("versions", []))
                        if isinstance(cached, dict)
                        else []
                    )
                    versions.append(
                        {
                            "generation": generation,
                            "file": version_file,
                            "fingerprint": fingerprint,
                            "prompt": asset.prompt,
                            "model": asset.model,
                            "quality": asset.quality,
                            "api_size": asset.api_size,
                            "created": response.created,
                            "usage": (
                                response.usage.model_dump(mode="json")
                                if response.usage is not None
                                else None
                            ),
                            "generated_at_utc": datetime.now(timezone.utc).isoformat(),
                        }
                    )
                    manifest["assets"][asset.asset_id] = {
                        "asset_id": asset.asset_id,
                        "role": asset.role,
                        "source": "openai",
                        "provider": "openai",
                        "model": asset.model,
                        "quality": asset.quality,
                        "file": asset.file,
                        "status": "generated_pending_review",
                        "exact_text": asset.exact_text,
                        "generation": generation,
                        "fingerprint": fingerprint,
                        "width": asset.output_width,
                        "height": asset.output_height,
                        "format": "webp",
                        "versions": versions,
                    }
                    _write_manifest(manifest_path, manifest)
                    cached = manifest["assets"][asset.asset_id]
                    generated += 1
                    last_error = None
                    break
                except (APIError, ValueError, OSError, OpenAIImageGenerationError) as exc:
                    last_error = exc
                    if attempt <= retries:
                        time.sleep(min(2**attempt, 10))
            if last_error is not None:
                failed += 1
                manifest["assets"][asset.asset_id] = {
                    **(cached if isinstance(cached, dict) else {}),
                    "asset_id": asset.asset_id,
                    "role": asset.role,
                    "source": "openai",
                    "file": asset.file,
                    "status": "generation_failed",
                    "error": str(last_error),
                    "failed_at_utc": datetime.now(timezone.utc).isoformat(),
                }
                _write_manifest(manifest_path, manifest)
                if progress:
                    progress(f"Asset {index}/{total}: failed: {last_error}")

    manifest["last_run"] = {
        "requested": total,
        "generated": generated,
        "reused": reused,
        "failed": failed,
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    _write_manifest(manifest_path, manifest)
    return manifest
