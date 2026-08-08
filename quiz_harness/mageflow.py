from __future__ import annotations

from io import BytesIO
from pathlib import Path
from typing import Any
from urllib.parse import urljoin

import httpx
from PIL import Image, UnidentifiedImageError


class MageFlowError(RuntimeError):
    """Raised when MageFlow cannot produce or return a usable image."""


class MageFlowClient:
    provider_id = "mageflow"

    def __init__(self, base_url: str, *, timeout_seconds: float = 300.0) -> None:
        self.base_url = base_url.rstrip("/") + "/"
        self._client = httpx.Client(timeout=timeout_seconds)

    def __enter__(self) -> MageFlowClient:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    def status(self) -> dict[str, Any]:
        try:
            response = self._client.get(urljoin(self.base_url, "api/status"))
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise MageFlowError(f"could not read MageFlow status: {exc}") from exc
        if not isinstance(data, dict):
            raise MageFlowError("MageFlow returned an invalid status response")
        return data

    def require_ready(self) -> dict[str, Any]:
        status = self.status()
        if status.get("load_error"):
            raise MageFlowError(f"MageFlow model load failed: {status['load_error']}")
        if not status.get("loaded"):
            state = "loading" if status.get("loading") else "not loaded"
            raise MageFlowError(f"MageFlow model is {state}; load it before bundling")
        return status

    def generate(
        self,
        *,
        prompt: str,
        negative_prompt: str,
        width: int,
        height: int,
        steps: int,
        cfg: float,
        seed: int,
    ) -> tuple[bytes, dict[str, Any]]:
        payload = {
            "prompt": prompt,
            "negative_prompt": negative_prompt,
            "width": width,
            "height": height,
            "steps": steps,
            "cfg": cfg,
            "seed": seed,
        }
        try:
            response = self._client.post(
                urljoin(self.base_url, "api/generate"), json=payload
            )
            response.raise_for_status()
            metadata = response.json()
            image_url = metadata["image_url"]
            if not isinstance(image_url, str) or not image_url:
                raise KeyError("image_url")
            image_response = self._client.get(urljoin(self.base_url, image_url))
            image_response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            detail = exc.response.text[:1000]
            raise MageFlowError(
                f"MageFlow request failed with HTTP {exc.response.status_code}: {detail}"
            ) from exc
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
            raise MageFlowError(f"invalid MageFlow response: {exc}") from exc
        if not isinstance(metadata, dict):
            raise MageFlowError("MageFlow generation metadata is not an object")
        return image_response.content, metadata


def write_validated_png(data: bytes, output: Path) -> tuple[int, int, str]:
    try:
        with Image.open(BytesIO(data)) as image:
            image.load()
            width, height = image.size
            mode = image.mode
            output.parent.mkdir(parents=True, exist_ok=True)
            temporary = output.with_suffix(output.suffix + ".tmp")
            image.save(temporary, format="PNG", optimize=True)
            temporary.replace(output)
    except (OSError, UnidentifiedImageError) as exc:
        raise MageFlowError(f"downloaded asset is not a valid image: {exc}") from exc
    return width, height, mode
