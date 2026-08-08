from __future__ import annotations

from typing import Any
from urllib.parse import urljoin

import httpx

from .mageflow import MageFlowError


class ImageStudioClient:
    provider_id = "imagestudio"

    def __init__(
        self,
        base_url: str,
        *,
        model: str = "ernie-turbo",
        timeout_seconds: float = 300.0,
    ) -> None:
        self.base_url = base_url.rstrip("/") + "/"
        self.model = model
        self._client = httpx.Client(timeout=timeout_seconds)

    def __enter__(self) -> ImageStudioClient:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    def status(self) -> dict[str, Any]:
        try:
            response = self._client.get(urljoin(self.base_url, "api/models"))
            response.raise_for_status()
            data = response.json()
        except (httpx.HTTPError, ValueError) as exc:
            raise MageFlowError(f"could not read ImageStudio models: {exc}") from exc
        if not isinstance(data, dict) or not isinstance(data.get("engines"), list):
            raise MageFlowError("ImageStudio returned an invalid models response")
        return data

    def require_ready(self) -> dict[str, Any]:
        status = self.status()
        engine = next(
            (item for item in status["engines"] if item.get("id") == self.model), None
        )
        if engine is None:
            raise MageFlowError(f"ImageStudio engine {self.model!r} is not available")
        return {**status, "model": self.model, "engine": engine}

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
            "engine": self.model,
            "prompt": f"{prompt} Avoid: {negative_prompt}",
            "style": "illustration",
            "customStyle": "",
            "width": width,
            "height": height,
            "steps": steps,
            "cfgScale": cfg,
            "seed": seed,
            "sampler": "euler",
            "loras": [],
        }
        try:
            response = self._client.post(
                urljoin(self.base_url, "api/generate"), json=payload
            )
            response.raise_for_status()
            metadata = response.json()
            image_url = metadata["imageUrl"]
            if not isinstance(image_url, str) or not image_url:
                raise KeyError("imageUrl")
            image_response = self._client.get(urljoin(self.base_url, image_url))
            image_response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            detail = exc.response.text[:1000]
            raise MageFlowError(
                f"ImageStudio request failed with HTTP {exc.response.status_code}: {detail}"
            ) from exc
        except (httpx.HTTPError, ValueError, KeyError, TypeError) as exc:
            raise MageFlowError(f"invalid ImageStudio response: {exc}") from exc
        if not isinstance(metadata, dict):
            raise MageFlowError("ImageStudio generation metadata is not an object")
        return image_response.content, {
            **metadata,
            "seed": metadata.get("seed", seed),
            "elapsed_sec": (
                metadata.get("elapsedMs") / 1000
                if isinstance(metadata.get("elapsedMs"), (int, float))
                else None
            ),
        }
