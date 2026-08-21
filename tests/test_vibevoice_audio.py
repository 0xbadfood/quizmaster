from __future__ import annotations

import json
from pathlib import Path

from quiz_harness.vibevoice_audio import (
    DEFAULT_CORRECT_PHRASES,
    DEFAULT_INCORRECT_PHRASES,
    DEFAULT_REFERENCE_TRANSCRIPT,
    AudioTask,
    AudioAuditError,
    VibeVoiceChunkClient,
    VIBEVOICE_TAIL_PADDING_SECONDS,
    _encode_vibevoice_mp3,
    ensure_global_quiz_audio,
    generate_category_quiz_audio,
    resolve_narrator_voice,
    sync_global_audio_to_flutter,
)


def test_amit_reference_transcript_is_exact() -> None:
    assert DEFAULT_REFERENCE_TRANSCRIPT == (
        "Mumbai is the financial, commercial and the entertainment capital of India. "
        "It is also one of the world's top ten centres of commerce in terms of global "
        "financial flow."
    )


def test_resolve_narrator_voice_falls_back_to_legacy_flat_fields() -> None:
    settings = {
        "reference_audio_path": "/data/amit.wav",
        "reference_transcript": "Legacy transcript",
        "language": "en_indian",
    }
    assert resolve_narrator_voice(settings) == {
        "reference_audio_path": "/data/amit.wav",
        "reference_transcript": "Legacy transcript",
        "language": "en_indian",
    }


def test_resolve_narrator_voice_uses_active_voice_from_library() -> None:
    settings = {
        "reference_audio_path": "/data/amit.wav",
        "reference_transcript": "Legacy transcript",
        "language": "en_indian",
        "voices": [
            {
                "id": "legacy",
                "name": "Amit",
                "reference_audio_path": "/data/amit.wav",
                "reference_transcript": "Legacy transcript",
                "language": "en_indian",
            },
            {
                "id": "speaker1",
                "name": "Quizmaster Speaker 1",
                "reference_audio_path": "/data/speaker1.wav",
                "reference_transcript": "Welcome back to Ultimate Trivia Dash!",
                "language": "en",
            },
        ],
        "active_voice_id": "speaker1",
    }
    assert resolve_narrator_voice(settings) == {
        "reference_audio_path": "/data/speaker1.wav",
        "reference_transcript": "Welcome back to Ultimate Trivia Dash!",
        "language": "en",
    }


def test_resolve_narrator_voice_defaults_to_first_voice_when_active_id_is_stale() -> None:
    settings = {
        "voices": [
            {
                "id": "speaker1",
                "name": "Quizmaster Speaker 1",
                "reference_audio_path": "/data/speaker1.wav",
                "reference_transcript": "Hello",
                "language": "en",
            },
        ],
        "active_voice_id": "missing-id",
    }
    assert resolve_narrator_voice(settings)["reference_audio_path"] == "/data/speaker1.wav"


def test_vibevoice_encoder_adds_800ms_tail_padding(
    tmp_path: Path, monkeypatch
) -> None:
    captured: dict[str, object] = {}

    def encode(source: Path, destination: Path, **kwargs: object) -> None:
        captured.update(
            {"source": source, "destination": destination, **kwargs}
        )

    monkeypatch.setattr("quiz_harness.vibevoice_audio._encode_mp3", encode)
    source = tmp_path / "source.wav"
    destination = tmp_path / "destination.mp3"

    _encode_vibevoice_mp3(source, destination)

    assert VIBEVOICE_TAIL_PADDING_SECONDS == 0.8
    assert captured == {
        "source": source,
        "destination": destination,
        "audio_filter": "apad=pad_dur=0.8",
    }


class FakeClient:
    endpoint = "http://vibevoice.test"
    lang_key = "en_indian"
    cfg_scale = 1.3

    def __init__(self, reference_audio: Path) -> None:
        self.reference_audio = reference_audio
        self.batches: list[list[AudioTask]] = []

    def render(self, tasks: list[AudioTask]) -> list[dict[str, object]]:
        self.batches.append(tasks)
        results = []
        for task in tasks:
            task.destination.parent.mkdir(parents=True, exist_ok=True)
            task.destination.write_bytes(b"fake-mp3")
            results.append(
                {
                    "task_id": task.task_id,
                    "file": task.destination.as_posix(),
                    "text": task.text,
                    "text_sha256": task.text_hash,
                    "duration_seconds": 1.0,
                    "sample_rate": 24000,
                    "job_id": "fake-job",
                }
            )
        return results


def _write_set(category_root: Path) -> None:
    path = category_root / "sets/beginner/animals_beginner_001.json"
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "questions": [
                    {
                        "question_id": "animals_beginner_001",
                        "question": "Which animal has a long trunk?",
                        "explanation": "The elephant uses its trunk in many ways.",
                    },
                    {
                        "question_id": "animals_beginner_002",
                        "question": "Which animal has black and white stripes?",
                        "explanation": "The zebra has black and white stripes.",
                    },
                ]
            }
        ),
        encoding="utf-8",
    )


def test_audio_generation_is_resumable_and_uses_mp3(tmp_path: Path) -> None:
    reference = tmp_path / "amit.wav"
    reference.write_bytes(b"reference")
    client = FakeClient(reference)
    global_root = tmp_path / "global"
    category_root = tmp_path / "animals"
    _write_set(category_root)

    global_manifest = ensure_global_quiz_audio(
        global_root=global_root,
        client=client,
    )
    category_manifest = generate_category_quiz_audio(
        category_root=category_root,
        category="Animals",
        client=client,
    )

    assert len(global_manifest["correct_feedback_clips"]) == len(
        DEFAULT_CORRECT_PHRASES
    )
    assert len(global_manifest["incorrect_feedback_clips"]) == len(
        DEFAULT_INCORRECT_PHRASES
    )
    assert global_manifest["correct_sfx"].endswith(".mp3")
    assert global_manifest["incorrect_sfx"].endswith(".mp3")
    assert len(category_manifest["questions"]) == 2
    assert all(
        item["question"].endswith(".mp3")
        and item["explanation"].endswith(".mp3")
        for item in category_manifest["questions"].values()
    )
    first_batch_count = len(client.batches)

    ensure_global_quiz_audio(global_root=global_root, client=client)
    generate_category_quiz_audio(
        category_root=category_root,
        category="Animals",
        client=client,
    )
    assert len(client.batches) == first_batch_count

    reference.write_bytes(b"changed-reference")
    generate_category_quiz_audio(
        category_root=category_root,
        category="Animals",
        client=client,
    )
    assert len(client.batches) == first_batch_count + 1

    flutter_manifest = sync_global_audio_to_flutter(
        global_root=global_root,
        flutter_root=tmp_path / "flutter",
    )
    assert len(flutter_manifest["correct_feedback_clips"]) == 12
    assert len(flutter_manifest["incorrect_feedback_clips"]) == 12
    assert (tmp_path / "flutter/assets/audio/quiz_correct_sfx.mp3").is_file()


def test_terminal_audit_failure_is_persisted_for_targeted_retry(tmp_path: Path) -> None:
    reference = tmp_path / "amit.wav"
    reference.write_bytes(b"reference")
    category_root = tmp_path / "animals"
    _write_set(category_root)

    class Auditor:
        def metadata(self) -> dict:
            return {"provider": "fake-whisper"}

    class FailingClient(FakeClient):
        auditor = Auditor()
        max_audit_repairs = 1

        def render(self, tasks: list[AudioTask]) -> list[dict[str, object]]:
            results = []
            for task in tasks:
                task.destination.parent.mkdir(parents=True, exist_ok=True)
                task.destination.write_bytes(b"failed-audio")
                results.append(
                    {
                        "task_id": task.task_id,
                        "file": task.destination.as_posix(),
                        "audit": {
                            "status": "failed",
                            "reasons": ["text_mismatch"],
                            "render_attempt": 2,
                        },
                    }
                )
            raise AudioAuditError(
                "failed Whisper review", results=results, failures=results
            )

    client = FailingClient(reference)
    manifest = generate_category_quiz_audio(
        category_root=category_root,
        category="Animals",
        client=client,
        clip_ids={("animals_beginner_001", "explanation")},
        force=True,
    )

    record = manifest["questions"]["animals_beginner_001"]
    assert record["explanation_audit"]["status"] == "failed"
    assert "question_audit" not in record
    assert manifest["last_run"]["requested"] == 1
    assert manifest["last_run"]["failed_task_ids"] == [
        "animals_beginner_001_explanation"
    ]


def test_duration_fallback_accepts_short_render_after_whisper_repairs(
    tmp_path: Path,
) -> None:
    class FailingAuditor:
        def audit(self, path: Path, expected: str) -> dict:
            return {
                "status": "failed",
                "reasons": ["text_mismatch"],
                "audio_duration_seconds": 20,
            }

    client = object.__new__(VibeVoiceChunkClient)
    client.auditor = FailingAuditor()
    client.max_audit_repairs = 3
    client.duration_fallback_seconds = 12.0
    client.max_duration_repairs = 3
    durations = iter((20.0, 20.0, 20.0, 20.0, 18.0, 8.5))

    def render_once(tasks: list[AudioTask]) -> list[dict[str, object]]:
        duration = next(durations)
        return [
            {
                "task_id": task.task_id,
                "file": task.destination.as_posix(),
                "duration_seconds": duration,
            }
            for task in tasks
        ]

    client._render_once = render_once
    task = AudioTask("example_question", "Which answer is correct?", tmp_path / "q.mp3")
    result = client.render([task])[0]

    assert result["duration_seconds"] == 8.5
    assert result["audit"]["status"] == "passed"
    assert result["audit"]["automatic_status"] == "failed"
    assert result["audit"]["duration_fallback"]["attempt"] == 2


def test_existing_unaudited_clip_is_checked_before_rerender(tmp_path: Path) -> None:
    reference = tmp_path / "amit.wav"
    reference.write_bytes(b"reference")
    category_root = tmp_path / "animals"
    _write_set(category_root)
    generate_category_quiz_audio(
        category_root=category_root,
        category="Animals",
        client=FakeClient(reference),
    )

    class PassingAuditor:
        def metadata(self) -> dict:
            return {"provider": "fake-whisper"}

        def audit(self, path: Path, expected: str) -> dict:
            assert path.is_file()
            return {"status": "passed", "score": 1.0, "reasons": []}

    class AuditOnlyClient(FakeClient):
        auditor = PassingAuditor()
        max_audit_repairs = 1

        def render(self, tasks: list[AudioTask]) -> list[dict[str, object]]:
            raise AssertionError("a passing existing clip must not be rerendered")

    manifest = generate_category_quiz_audio(
        category_root=category_root,
        category="Animals",
        client=AuditOnlyClient(reference),
        clip_ids={("animals_beginner_001", "question")},
    )

    audit = manifest["questions"]["animals_beginner_001"]["question_audit"]
    assert audit["status"] == "passed"
    assert audit["audit_source"] == "existing_clip"
    assert manifest["last_run"]["requested"] == 0
    assert manifest["last_run"]["audited_existing"] == 1
