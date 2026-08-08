from __future__ import annotations

import time
from pathlib import Path

from quiz_harness.pipeline_api import (
    PipelineBusyError,
    PipelineLock,
    PipelineStartRequest,
    _authorized,
    create_app,
)


def _app(tmp_path: Path):
    return create_app(
        database_path=tmp_path / "quiz.db",
        source_root=tmp_path / "source",
        bundle_root=tmp_path / "bundles",
        secret_key_file=tmp_path / "secret.key",
        lock_path=tmp_path / "pipeline.lock",
        provider_test_root=tmp_path / "provider-tests",
        provider_audio_root=tmp_path / "provider-audio",
    )


def _pipeline_payload() -> dict[str, object]:
    return {
        "metadata": {
            "name": "Space and Astronomy",
            "slug": "space-and-astronomy",
            "display_title": "SPACE QUIZ",
            "display_tag": "Space",
            "description": "A visual quiz about astronomy and space exploration.",
            "editorial_brief": (
                "Use deterministic astronomy facts and concrete visual answer choices."
            ),
            "age_min": 5,
            "age_max": 10,
        }
    }


def test_pipeline_lock_is_process_exclusive(tmp_path: Path) -> None:
    lock = PipelineLock(tmp_path / "pipeline.lock")
    lease = lock.acquire({"job_id": "one"})
    try:
        assert lock.status() == {"busy": True, "holder": {"job_id": "one"}}
        try:
            lock.acquire({"job_id": "two"})
        except PipelineBusyError as exc:
            assert exc.holder["job_id"] == "one"
        else:
            raise AssertionError("second pipeline lease should fail")
    finally:
        lease.release()
    assert lock.status() == {"busy": False, "holder": None}


def test_api_token_accepts_bearer_or_explicit_header() -> None:
    assert _authorized({"authorization": "Bearer secret"}, "secret")
    assert _authorized({"x-quizmaster-token": "secret"}, "secret")
    assert not _authorized({"authorization": "Bearer wrong"}, "secret")
    assert not _authorized({}, "secret")


def test_provider_api_never_returns_encrypted_secret(tmp_path: Path) -> None:
    app = _app(tmp_path)
    service = app.state.service
    updated = service.database.update_provider_connection(
        "openai-images", service.secret_values("sk-example-1234")
    )
    openai = service.public_provider(updated)
    assert openai["has_secret"] is True
    assert openai["secret_hint"] == "...1234"
    assert "secret_ciphertext" not in openai
    assert "/api/v1/providers" in app.openapi()["paths"]
    service.jobs.shutdown()


def test_pipeline_start_returns_conflict_while_lock_is_held(tmp_path: Path) -> None:
    app = _app(tmp_path)
    service = app.state.service
    lease = service.lock.acquire({"job_id": "already-running"})
    try:
        try:
            service.start_pipeline(
                PipelineStartRequest.model_validate(_pipeline_payload())
            )
        except PipelineBusyError as exc:
            assert exc.holder["job_id"] == "already-running"
        else:
            raise AssertionError("pipeline start should fail while lock is held")
    finally:
        lease.release()
        app.state.service.jobs.shutdown()


def test_api_pipeline_prepares_bundle_without_activation(
    tmp_path: Path, monkeypatch
) -> None:
    captured = {}

    def run(config, *, progress):
        captured["config"] = config
        progress("[metadata] category ready")
        progress("[publish] bundle prepared")
        return {
            "status": "complete",
            "category_slug": "space-and-astronomy",
            "publish": {
                "bundle_version": 1,
                "deployment_status": "deployable",
                "is_current": False,
            },
        }

    monkeypatch.setattr("quiz_harness.pipeline_api.run_category_pipeline", run)
    app = _app(tmp_path)
    service = app.state.service
    started = service.start_pipeline(
        PipelineStartRequest.model_validate(_pipeline_payload())
    )
    job_id = started["id"]
    job = None
    for _ in range(100):
        job = service.pipeline_job(job_id)
        if job["status"] == "complete":
            break
        time.sleep(0.01)

    assert job is not None
    assert job["status"] == "complete"
    assert job["result"]["publish"]["deployment_status"] == "deployable"
    assert captured["config"].activate_bundle is False
    assert service.lock.status()["busy"] is False
    service.jobs.shutdown()


def test_failed_pipeline_can_restart_with_its_original_request(
    tmp_path: Path, monkeypatch
) -> None:
    attempts = 0

    def run(config, *, progress):
        nonlocal attempts
        attempts += 1
        if attempts == 1:
            raise RuntimeError("temporary generation failure")
        return {"status": "complete", "category_slug": config.metadata.slug}

    monkeypatch.setattr("quiz_harness.pipeline_api.run_category_pipeline", run)
    app = _app(tmp_path)
    service = app.state.service
    first = service.start_pipeline(
        PipelineStartRequest.model_validate(_pipeline_payload())
    )
    for _ in range(100):
        failed = service.pipeline_job(first["id"])
        if failed["status"] == "failed":
            break
        time.sleep(0.01)

    restarted = service.retry_pipeline(first["id"])
    assert restarted["id"] != first["id"]
    for _ in range(100):
        completed = service.pipeline_job(restarted["id"])
        if completed["status"] == "complete":
            break
        time.sleep(0.01)

    assert completed["status"] == "complete"
    assert completed["context"]["retry_of"] == first["id"]
    assert completed["context"]["request"] == failed["context"]["request"]
    assert attempts == 2
    service.jobs.shutdown()
