from __future__ import annotations

import hashlib
import io
import json
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from PIL import Image, UnidentifiedImageError

from .imagestudio import ImageStudioClient
from .visual_bank import AnimalCatalog


PROMPT_VERSION = "animal-answer-3d-v4"
DEFAULT_NEGATIVE_PROMPT = (
    "text, letters, numbers, caption, logo, watermark, border, duplicate subject, blur"
)


def answer_image_prompt(label: str) -> str:
    return (
        f"Create an accurate, child-friendly visual representation of {label}. It "
        f"must be immediately recognizable specifically as {label}, not a related or "
        "generic subject. For a concrete object, living thing, place, or landmark, "
        "show one complete primary instance with accurate real-world form, materials, "
        "colors, proportions, and diagnostic visible features. For a prepared dish, "
        "material, group, nutrient, process, or abstract concept, show one coherent "
        "plated, contained, or educational arrangement with only the minimum supporting "
        "elements needed to communicate the answer. Center the focal representation "
        "with a strong silhouette and comfortable square margins. Use polished high-end "
        "3D animated family-film rendering, vivid natural color, bright cinematic "
        "lighting, and a simple softly blurred context appropriate to the subject. "
        "No text, letters, numbers, labels, logos, watermarks, borders, competing answer "
        "subjects, needless duplicates, or incorrect physical details."
    )


def stable_seed(animal_key: str, base_seed: int) -> int:
    digest = hashlib.sha256(
        f"{PROMPT_VERSION}:{base_seed}:{animal_key}".encode("utf-8")
    ).digest()
    return int.from_bytes(digest[:4], "big") & 0x7FFFFFFF


def _fingerprint(
    *,
    animal_key: str,
    label: str,
    model: str,
    width: int,
    height: int,
    steps: int,
    cfg: float,
    seed: int,
    prompt: str,
) -> str:
    payload = {
        "prompt_version": PROMPT_VERSION,
        "animal_key": animal_key,
        "label": label,
        "model": model,
        "width": width,
        "height": height,
        "steps": steps,
        "cfg": cfg,
        "seed": seed,
        "prompt": prompt,
        "negative_prompt": DEFAULT_NEGATIVE_PROMPT,
    }
    encoded = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(encoded).hexdigest()


def _valid_webp(path: Path, expected_size: tuple[int, int]) -> bool:
    try:
        with Image.open(path) as image:
            image.verify()
        with Image.open(path) as image:
            return image.format == "WEBP" and image.size == expected_size
    except (OSError, UnidentifiedImageError):
        return False


def _write_webp(image_data: bytes, path: Path, expected_size: tuple[int, int]) -> None:
    try:
        with Image.open(io.BytesIO(image_data)) as source:
            source.load()
            if source.size != expected_size:
                raise ValueError(
                    f"ImageStudio returned {source.size[0]}x{source.size[1]}; "
                    f"expected {expected_size[0]}x{expected_size[1]}"
                )
            image = source.convert("RGB")
    except (OSError, UnidentifiedImageError) as exc:
        raise ValueError(f"ImageStudio returned invalid image data: {exc}") from exc

    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    image.save(temporary, format="WEBP", quality=92, method=6)
    temporary.replace(path)


def _load_manifest(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {"schema_version": "answer_images_v1", "assets": {}, "failures": {}}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {"schema_version": "answer_images_v1", "assets": {}, "failures": {}}
    if not isinstance(data, dict):
        return {"schema_version": "answer_images_v1", "assets": {}, "failures": {}}
    if not isinstance(data.get("assets"), dict):
        data["assets"] = {}
    if not isinstance(data.get("failures"), dict):
        data["failures"] = {}
    return data


def _write_manifest(path: Path, manifest: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def generate_answer_images(
    *,
    catalog: AnimalCatalog,
    catalog_root: Path,
    client: ImageStudioClient,
    endpoint: str,
    model: str,
    width: int = 768,
    height: int = 768,
    steps: int = 8,
    cfg: float = 1.0,
    base_seed: int = 20260805,
    force: bool = False,
    limit: int | None = None,
    animal_keys: set[str] | None = None,
    prompt_overrides: dict[str, str] | None = None,
    retries: int = 2,
    progress: Callable[[str], None] | None = None,
) -> dict[str, Any]:
    status = client.require_ready()
    manifest_path = catalog_root / "answer-image-manifest.json"
    manifest = _load_manifest(manifest_path)
    manifest.update(
        {
            "schema_version": "answer_images_v1",
            "category": catalog.category,
            "provider": client.provider_id,
            "model": status.get("model", model),
            "endpoint": endpoint,
            "prompt_version": PROMPT_VERSION,
            "width": width,
            "height": height,
            "steps": steps,
            "cfg": cfg,
            "base_seed": base_seed,
        }
    )
    _write_manifest(manifest_path, manifest)

    selected = [
        animal
        for animal in catalog.animals
        if animal_keys is None or animal.animal_key in animal_keys
    ]
    if animal_keys is not None:
        found = {animal.animal_key for animal in selected}
        missing = sorted(animal_keys - found)
        if missing:
            raise ValueError(f"animal keys not found in catalog: {', '.join(missing)}")
    if limit is not None:
        selected = selected[:limit]
    total = len(selected)
    generated = 0
    reused = 0
    failed = 0
    for index, animal in enumerate(selected, start=1):
        output = catalog_root / animal.image_path
        seed = stable_seed(animal.animal_key, base_seed)
        prompt = (prompt_overrides or {}).get(
            animal.animal_key, answer_image_prompt(animal.label)
        )
        fingerprint = _fingerprint(
            animal_key=animal.animal_key,
            label=animal.label,
            model=model,
            width=width,
            height=height,
            steps=steps,
            cfg=cfg,
            seed=seed,
            prompt=prompt,
        )
        cached = manifest["assets"].get(animal.animal_key)
        if (
            not force
            and isinstance(cached, dict)
            and cached.get("fingerprint") == fingerprint
            and _valid_webp(output, (width, height))
        ):
            reused += 1
            if progress:
                progress(f"Animal {index}/{total}: reusing {animal.label}")
            continue

        if progress:
            progress(f"Animal {index}/{total}: generating {animal.label}")
        last_error: Exception | None = None
        for attempt in range(1, retries + 2):
            try:
                image_data, metadata = client.generate(
                    prompt=prompt,
                    negative_prompt=DEFAULT_NEGATIVE_PROMPT,
                    width=width,
                    height=height,
                    steps=steps,
                    cfg=cfg,
                    seed=seed,
                )
                _write_webp(image_data, output, (width, height))
                manifest["assets"][animal.animal_key] = {
                    "animal_key": animal.animal_key,
                    "label": animal.label,
                    "file": animal.image_path,
                    "status": "generated_pending_review",
                    "fingerprint": fingerprint,
                    "prompt": prompt,
                    "seed": metadata.get("seed", seed),
                    "width": width,
                    "height": height,
                    "format": "webp",
                    "elapsed_sec": metadata.get("elapsed_sec"),
                    "generated_at_utc": datetime.now(timezone.utc).isoformat(),
                }
                manifest["failures"].pop(animal.animal_key, None)
                _write_manifest(manifest_path, manifest)
                generated += 1
                last_error = None
                break
            except Exception as exc:  # Keep a long batch resumable after one bad item.
                last_error = exc
                if attempt <= retries:
                    time.sleep(min(2**attempt, 8))
        if last_error is not None:
            failed += 1
            manifest["failures"][animal.animal_key] = {
                "animal_key": animal.animal_key,
                "label": animal.label,
                "error": str(last_error),
                "failed_at_utc": datetime.now(timezone.utc).isoformat(),
            }
            _write_manifest(manifest_path, manifest)
            if progress:
                progress(f"Animal {index}/{total}: failed {animal.label}: {last_error}")

    manifest["last_run"] = {
        "requested": total,
        "generated": generated,
        "reused": reused,
        "failed": failed,
        "completed_at_utc": datetime.now(timezone.utc).isoformat(),
    }
    _write_manifest(manifest_path, manifest)
    return manifest
