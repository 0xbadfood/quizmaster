from __future__ import annotations

from typing import Any

import httpx


class VLLMError(RuntimeError):
    """Raised when the local vLLM service cannot return a usable completion."""


class VLLMClient:
    def __init__(
        self,
        base_url: str,
        *,
        timeout_seconds: float = 180.0,
        api_key: str | None = None,
    ) -> None:
        self.base_url = base_url.rstrip("/")
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        self._client = httpx.Client(timeout=timeout_seconds, headers=headers)

    def __enter__(self) -> VLLMClient:
        return self

    def __exit__(self, *args: object) -> None:
        self.close()

    def close(self) -> None:
        self._client.close()

    def discover_model(self) -> str:
        try:
            response = self._client.get(f"{self.base_url}/models")
            response.raise_for_status()
            models = response.json().get("data", [])
        except (httpx.HTTPError, ValueError) as exc:
            raise VLLMError(f"could not discover vLLM models: {exc}") from exc
        if not models:
            raise VLLMError("vLLM returned no available models")
        model_id = models[0].get("id")
        if not isinstance(model_id, str) or not model_id:
            raise VLLMError("vLLM model response has no valid model id")
        return model_id

    def generate_json(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        schema: dict[str, Any],
        seed: int,
        temperature: float = 0.7,
        max_tokens: int = 8_000,
        schema_name: str = "kids_quiz_plan",
    ) -> str:
        payload = {
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "seed": seed,
            "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": False},
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": schema_name,
                    "strict": True,
                    "schema": schema,
                },
            },
        }
        return self._generate(payload)

    def generate_text(
        self,
        *,
        model: str,
        messages: list[dict[str, str]],
        seed: int,
        temperature: float = 0.7,
        max_tokens: int = 2_000,
    ) -> str:
        payload = {
            "model": model,
            "messages": messages,
            "temperature": temperature,
            "seed": seed,
            "max_tokens": max_tokens,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        return self._generate(payload)

    def _generate(self, payload: dict[str, Any]) -> str:
        try:
            response = self._client.post(
                f"{self.base_url}/chat/completions", json=payload
            )
            response.raise_for_status()
            body = response.json()
            choice = body["choices"][0]
            content = choice["message"]["content"]
            finish_reason = choice.get("finish_reason")
        except httpx.HTTPStatusError as exc:
            detail = exc.response.text[:1000]
            raise VLLMError(
                f"vLLM request failed with HTTP {exc.response.status_code}: {detail}"
            ) from exc
        except (httpx.HTTPError, ValueError, KeyError, IndexError, TypeError) as exc:
            raise VLLMError(f"invalid vLLM response: {exc}") from exc
        if finish_reason != "stop":
            raise VLLMError(f"vLLM completion ended with {finish_reason!r}")
        if not isinstance(content, str) or not content.strip():
            raise VLLMError("vLLM completion contained no response content")
        # Parsing belongs to the caller so malformed content can be sent back to the
        # model verbatim on a correction attempt.
        return content
