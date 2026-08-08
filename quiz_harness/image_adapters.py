from __future__ import annotations

from typing import Any, Protocol

from .imagestudio import ImageStudioClient
from .mageflow import MageFlowClient


class ImageGeneratorAdapter(Protocol):
    provider_id: str

    def __enter__(self) -> ImageGeneratorAdapter: ...
    def __exit__(self, *args: object) -> None: ...
    def require_ready(self) -> dict[str, Any]: ...
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
    ) -> tuple[bytes, dict[str, Any]]: ...


def create_image_generator(
    provider: str,
    endpoint: str,
    *,
    model: str | None = None,
    timeout_seconds: float = 300.0,
) -> ImageGeneratorAdapter:
    if provider == "mageflow":
        return MageFlowClient(endpoint, timeout_seconds=timeout_seconds)
    if provider == "imagestudio":
        return ImageStudioClient(
            endpoint,
            model=model or "ernie-turbo",
            timeout_seconds=timeout_seconds,
        )
    raise ValueError(f"unknown image provider: {provider}")
