from __future__ import annotations

from pathlib import Path

import pytest

from quiz_harness.audio_audit import score_transcript
from quiz_harness.vibevoice_audio import AudioTask, VibeVoiceChunkClient


def test_transcript_score_accepts_exact_speech() -> None:
    result = score_transcript(
        expected_text="The eagle has broad wings and can soar high in the sky.",
        transcript_text="The eagle has broad wings and can soar high in the sky.",
        audio_duration_seconds=5.0,
        speech_span_seconds=4.2,
    )
    assert result["status"] == "passed"
    assert result["score"] == 1.0
    assert result["wer"] == 0.0


def test_transcript_score_rejects_truncated_speech() -> None:
    result = score_transcript(
        expected_text="The eagle has broad wings and can soar high in the sky.",
        transcript_text="The eagle has broad wings.",
        audio_duration_seconds=5.0,
        speech_span_seconds=2.0,
    )
    assert result["status"] == "failed"
    assert "text_mismatch" in result["reasons"]
    assert "length_too_short" in result["reasons"]


def test_transcript_score_accepts_one_asr_substitution_in_eight_words() -> None:
    result = score_transcript(
        expected_text="Which bird is known for its loud caw?",
        transcript_text="Which bird is known for its loud call?",
        audio_duration_seconds=4.0,
        speech_span_seconds=4.0,
    )
    assert result["status"] == "passed"
    assert result["score"] == 0.875


def test_transcript_score_rejects_two_substitutions_in_eight_words() -> None:
    result = score_transcript(
        expected_text="Which bird is known for its loud caw?",
        transcript_text="Which animal is famous for its loud call?",
        audio_duration_seconds=4.0,
        speech_span_seconds=4.0,
    )
    assert result["status"] == "failed"
    assert "text_mismatch" in result["reasons"]


def test_speech_coverage_is_capped_when_whisper_segment_runs_long() -> None:
    result = score_transcript(
        expected_text="Which animal has a long trunk used for drinking?",
        transcript_text="Which animal has a long trunk used for drinking?",
        audio_duration_seconds=4.5,
        speech_span_seconds=5.0,
    )
    assert result["speech_coverage"] == 1.0


class RepairAuditor:
    def __init__(self) -> None:
        self.calls: dict[str, int] = {}

    def audit(self, path: Path, expected: str) -> dict:
        count = self.calls.get(path.name, 0) + 1
        self.calls[path.name] = count
        if path.name == "retry.mp3" and count == 1:
            return {"status": "failed", "reasons": ["text_mismatch"]}
        return {"status": "passed", "reasons": [], "score": 1.0}

    def metadata(self) -> dict:
        return {"provider": "fake-whisper"}


def test_vibevoice_rerenders_only_failed_clips(tmp_path: Path) -> None:
    client = object.__new__(VibeVoiceChunkClient)
    client.auditor = RepairAuditor()
    client.max_audit_repairs = 2
    batches: list[list[str]] = []

    def render_once(tasks: list[AudioTask]) -> list[dict]:
        batches.append([task.task_id for task in tasks])
        results = []
        for task in tasks:
            task.destination.write_bytes(b"audio")
            results.append({"task_id": task.task_id, "file": str(task.destination)})
        return results

    client._render_once = render_once
    tasks = [
        AudioTask("pass", "This clip passes immediately.", tmp_path / "pass.mp3"),
        AudioTask("retry", "This clip passes after repair.", tmp_path / "retry.mp3"),
    ]
    result = client.render(tasks)
    assert batches == [["pass", "retry"], ["retry"]]
    assert [item["task_id"] for item in result] == ["pass", "retry"]
    assert result[0]["audit"]["render_attempt"] == 1
    assert result[1]["audit"]["render_attempt"] == 2


def test_vibevoice_fails_after_repair_budget(tmp_path: Path) -> None:
    class FailingAuditor(RepairAuditor):
        def audit(self, path: Path, expected: str) -> dict:
            return {"status": "failed", "reasons": ["low_coverage"]}

    client = object.__new__(VibeVoiceChunkClient)
    client.auditor = FailingAuditor()
    client.max_audit_repairs = 1

    def render_once(tasks: list[AudioTask]) -> list[dict]:
        for task in tasks:
            task.destination.write_bytes(b"audio")
        return [{"task_id": task.task_id, "file": str(task.destination)} for task in tasks]

    client._render_once = render_once
    with pytest.raises(RuntimeError, match="failed Whisper review"):
        client.render([AudioTask("bad", "Expected words.", tmp_path / "bad.mp3")])
