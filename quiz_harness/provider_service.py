from __future__ import annotations

from pathlib import Path
from typing import Any, Callable
from urllib.parse import urlsplit

import httpx

from .imagestudio import ImageStudioClient
from .vibevoice_audio import AudioTask, VibeVoiceChunkClient


PROVIDER_TYPES = {
    "imagestudio": "ImageStudio",
    "openai_images": "OpenAI Images",
    "openai_compatible_llm": "OpenAI-compatible LLM",
    "vibevoice": "VibeVoice Chunk API",
}


def normalize_base_url(value: str) -> str:
    normalized = value.strip().rstrip("/")
    parsed = urlsplit(normalized)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise ValueError("base URL must be an absolute HTTP or HTTPS URL")
    if parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise ValueError("base URL must not include credentials, query, or fragment")
    return normalized


def _headers(secret: str | None) -> dict[str, str]:
    return {"Authorization": f"Bearer {secret}"} if secret else {}


def _openai_models(base_url: str, secret: str | None) -> list[str]:
    with httpx.Client(timeout=20, headers=_headers(secret)) as client:
        response = client.get(f"{base_url}/models")
        response.raise_for_status()
        payload = response.json()
    models = payload.get("data", []) if isinstance(payload, dict) else []
    result = sorted(
        {
            str(item["id"])
            for item in models
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        }
    )
    if not result:
        raise RuntimeError("endpoint returned no discoverable models")
    return result


def probe_provider(provider: dict[str, Any], secret: str | None) -> dict[str, Any]:
    provider_type = provider["provider_type"]
    base_url = normalize_base_url(provider["base_url"])
    if provider_type == "imagestudio":
        with ImageStudioClient(base_url, timeout_seconds=20) as client:
            status = client.status()
        models = [
            str(item["id"])
            for item in status.get("engines", [])
            if isinstance(item, dict) and isinstance(item.get("id"), str)
        ]
        return {
            "models": models,
            "message": f"Connected; {len(models)} image engine(s) available",
            "details": {"default_model": status.get("defaultEngine")},
        }
    if provider_type == "openai_compatible_llm":
        models = _openai_models(base_url, secret)
        return {
            "models": models,
            "message": f"Connected; {len(models)} model(s) discovered",
            "details": {},
        }
    if provider_type == "openai_images":
        models = _openai_models(base_url, secret)
        image_models = [
            model
            for model in models
            if "image" in model.casefold() or "dall-e" in model.casefold()
        ]
        return {
            "models": image_models,
            "message": (
                f"Authenticated; {len(image_models)} image model(s) discovered"
                if image_models
                else "Authenticated; choose an image model manually"
            ),
            "details": {"all_model_count": len(models)},
        }
    if provider_type == "vibevoice":
        settings = provider.get("settings", {})
        reference_audio = Path(settings.get("reference_audio_path", "amit.wav"))
        client = VibeVoiceChunkClient(
            endpoint=base_url,
            reference_audio=reference_audio,
            lang_key=str(settings.get("language", "en_indian")),
            cfg_scale=float(settings.get("cfg_scale", 1.3)),
            timeout_seconds=30,
        )
        health = client.health()
        return {
            "models": [],
            "message": "Connected; VibeVoice is ready",
            "details": health,
        }
    raise ValueError(f"unsupported provider type: {provider_type}")


def run_provider_test(
    provider: dict[str, Any],
    secret: str | None,
    *,
    artifact_root: Path,
    progress: Callable[[str, float], None],
) -> dict[str, Any]:
    progress("Checking endpoint", 0.18)
    probe = probe_provider(provider, secret)
    provider_type = provider["provider_type"]
    base_url = normalize_base_url(provider["base_url"])
    if provider_type == "openai_compatible_llm":
        model = provider.get("default_model") or probe["models"][0]
        progress(f"Testing {model}", 0.52)
        with httpx.Client(timeout=90, headers=_headers(secret)) as client:
            response = client.post(
                f"{base_url}/chat/completions",
                json={
                    "model": model,
                    "messages": [
                        {
                            "role": "user",
                            "content": "Reply with exactly: Quiz Studio ready",
                        }
                    ],
                    "temperature": 0,
                    "max_tokens": 24,
                },
            )
            response.raise_for_status()
            payload = response.json()
        content = payload["choices"][0]["message"]["content"]
        progress("LLM response received", 0.9)
        return {**probe, "model": model, "sample": str(content).strip()[:240]}
    if provider_type == "vibevoice":
        settings = provider.get("settings", {})
        reference_audio = Path(settings.get("reference_audio_path", "amit.wav"))
        destination = artifact_root / provider["id"] / "connection-test.mp3"
        progress("Rendering voice sample", 0.42)
        client = VibeVoiceChunkClient(
            endpoint=base_url,
            reference_audio=reference_audio,
            lang_key=str(settings.get("language", "en_indian")),
            cfg_scale=float(settings.get("cfg_scale", 1.3)),
            timeout_seconds=900,
        )
        result = client.render(
            [
                AudioTask(
                    task_id="connection_test",
                    text=str(
                        settings.get(
                            "test_phrase",
                            "Quiz Studio is ready to create a wonderful new quiz.",
                        )
                    ),
                    destination=destination,
                )
            ]
        )[0]
        progress("Voice sample encoded", 0.92)
        return {
            **probe,
            "sample_audio": f"/provider-tests/{provider['id']}/connection-test.mp3",
            "render": result,
        }
    progress("Provider capabilities verified", 0.9)
    return probe
