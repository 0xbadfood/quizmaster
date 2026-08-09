from __future__ import annotations

from pathlib import Path

from quiz_harness.visual_generation_queue import VisualGenerationQueue


def test_visual_queue_recovers_running_jobs_and_deduplicates_assets(
    tmp_path: Path,
) -> None:
    queue = VisualGenerationQueue(tmp_path / "queue")
    queue.start_run()
    created = queue.enqueue(
        provider_id="imagestudio",
        model="ernie",
        asset_ids={"answer_lion", "answer_tiger"},
    )
    assert created is not None
    claimed = queue.claim()
    assert claimed is not None
    assert claimed["status"] == "running"

    recovered = VisualGenerationQueue(tmp_path / "queue")
    recovered.start_run()
    assert recovered.summary()["jobs"]["queued"] == 1
    claimed_again = recovered.claim()
    assert claimed_again is not None
    assert claimed_again["attempts"] == 2
    recovered.complete(claimed_again["id"], {"generated": 2})

    assert (
        recovered.enqueue(
            provider_id="imagestudio",
            model="ernie",
            asset_ids={"answer_lion"},
        )
        is None
    )
    additional = recovered.enqueue(
        provider_id="imagestudio",
        model="ernie",
        asset_ids={"answer_lion", "answer_zebra"},
    )
    assert additional is not None
    assert additional["asset_ids"] == ["answer_zebra"]


def test_visual_queue_requeues_completed_job_when_manifest_asset_is_missing(
    tmp_path: Path,
) -> None:
    queue = VisualGenerationQueue(tmp_path / "queue")
    queue.start_run()
    queue.enqueue(
        provider_id="imagestudio",
        model="ernie",
        asset_ids={"answer_lion", "answer_tiger"},
    )
    claimed = queue.claim()
    assert claimed is not None
    queue.complete(claimed["id"], {"generated": 2})

    assert queue.requeue_missing({"answer_lion"}) == 1
    assert queue.summary()["jobs"]["queued"] == 1


def test_visual_queue_exposes_producer_and_failed_asset_state(tmp_path: Path) -> None:
    queue = VisualGenerationQueue(tmp_path / "queue")
    queue.start_run()
    job = queue.enqueue(
        provider_id="openai-images",
        model="gpt-image-2",
        asset_ids={"tile_beginner_01"},
    )
    assert job is not None
    claimed = queue.claim()
    assert claimed is not None
    queue.fail(claimed["id"], "remote renderer unavailable")
    queue.finish_planning()

    summary = queue.summary()
    assert summary["producer"]["status"] == "complete"
    assert summary["jobs"]["failed"] == 1
    assert summary["assets"]["failed"] == 1
    assert summary["errors"][0]["error"] == "remote renderer unavailable"
