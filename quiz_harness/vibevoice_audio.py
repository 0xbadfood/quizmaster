from __future__ import annotations

import hashlib
import itertools
import json
import math
import re
import shutil
import struct
import subprocess
import tempfile
import time
import uuid
import wave
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable

import httpx


AUDIO_MANIFEST_SCHEMA = "quiz_audio_v1"
VIBEVOICE_TAIL_PADDING_SECONDS = 0.8
DEFAULT_REFERENCE_TRANSCRIPT = (
    "Mumbai is the financial, commercial and the entertainment capital of India. "
    "It is also one of the world's top ten centres of commerce in terms of global "
    "financial flow."
)
DEFAULT_CORRECT_PHRASES = (
    "Correct!",
    "You are correct!",
    "That's right!",
    "Awesome, that's the correct answer!",
    "Great work, you got it right!",
    "Excellent answer!",
    "Fantastic, you are right!",
    "Well done, that's correct!",
    "Amazing job!",
    "Brilliant thinking!",
    "Yes, that's the one!",
    "Super work, you found the answer!",
)
DEFAULT_INCORRECT_PHRASES = (
    "Not quite. Let's see why.",
    "That's not the correct answer, but good try!",
    "Almost! Let's learn the right answer.",
    "Good try. Here is the correct answer.",
    "Not this time. Let's find out why.",
    "That's not the one. Keep learning!",
    "Nice try! Let's look at the answer.",
    "Oops, that's not correct. Let's learn together.",
    "Close try! Here is the answer.",
    "Keep going! This one was tricky.",
    "Not quite right, but you're learning.",
    "Good effort! Let's see the correct answer.",
)


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _write_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def _read_json(path: Path) -> dict[str, Any]:
    if not path.exists():
        return {}
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        raise ValueError(f"expected a JSON object in {path}")
    return data


def _text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _file_hash(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _safe_name(value: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]+", "_", value).strip("_") or "clip"


def _speaker_script(text: str) -> str:
    normalized = " ".join(str(text).split())
    if not normalized:
        raise ValueError("narration text is empty")
    return f"Speaker 1: {normalized}"


@dataclass(frozen=True)
class AudioTask:
    task_id: str
    text: str
    destination: Path

    @property
    def text_hash(self) -> str:
        return _text_hash(self.text)


class AudioAuditError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        results: list[dict[str, Any]],
        failures: list[dict[str, Any]],
    ) -> None:
        super().__init__(message)
        self.results = results
        self.failures = failures


class VibeVoiceChunkClient:
    def __init__(
        self,
        *,
        endpoint: str,
        reference_audio: Path,
        lang_key: str = "en_indian",
        cfg_scale: float = 1.3,
        timeout_seconds: float = 900,
        poll_seconds: float = 2,
        auditor: Any | None = None,
        max_audit_repairs: int = 2,
        duration_fallback_seconds: float | None = None,
        max_duration_repairs: int | None = 0,
    ) -> None:
        self.endpoint = endpoint.rstrip("/")
        self.reference_audio = reference_audio.expanduser().resolve()
        self.lang_key = lang_key
        self.cfg_scale = cfg_scale
        self.timeout_seconds = timeout_seconds
        self.poll_seconds = poll_seconds
        self.auditor = auditor
        self.max_audit_repairs = max(0, int(max_audit_repairs))
        self.duration_fallback_seconds = (
            float(duration_fallback_seconds)
            if duration_fallback_seconds is not None
            else None
        )
        self.max_duration_repairs = (
            None
            if max_duration_repairs is None
            else max(0, int(max_duration_repairs))
        )
        if not self.reference_audio.is_file():
            raise ValueError(f"reference audio is missing: {self.reference_audio}")

    def health(self) -> dict[str, Any]:
        with httpx.Client(timeout=15) as client:
            response = client.get(f"{self.endpoint}/health")
            response.raise_for_status()
            data = response.json()
        if not data.get("ok"):
            raise RuntimeError(f"VibeVoice endpoint is unhealthy: {data}")
        return data

    def _render_once(self, tasks: list[AudioTask]) -> list[dict[str, Any]]:
        if not tasks or len(tasks) > 10:
            raise ValueError("VibeVoice batches must contain between one and ten clips")
        job_id = f"quiz_{int(time.time())}_{uuid.uuid4().hex[:10]}"
        output_names = {
            task.task_id: f"{index:02d}_{_safe_name(task.task_id)}.wav"
            for index, task in enumerate(tasks, start=1)
        }
        payload = {
            "job_id": job_id,
            "lang_key": self.lang_key,
            "cfg_scale": self.cfg_scale,
            "items": [
                {
                    "script": _speaker_script(task.text),
                    "voice_samples": [str(self.reference_audio)],
                    "output_name": output_names[task.task_id],
                    "chunk_index": index,
                }
                for index, task in enumerate(tasks, start=1)
            ],
        }
        with httpx.Client(timeout=30) as client:
            response = client.post(f"{self.endpoint}/render-batch", json=payload)
            response.raise_for_status()

        deadline = time.monotonic() + self.timeout_seconds
        job: dict[str, Any] = {}
        while time.monotonic() < deadline:
            with httpx.Client(timeout=30) as client:
                response = client.get(f"{self.endpoint}/jobs/{job_id}")
                response.raise_for_status()
                job = response.json()
            status = str(job.get("status") or "")
            if status == "success":
                break
            if status == "failed":
                raise RuntimeError(f"VibeVoice job {job_id} failed: {job.get('error')}")
            time.sleep(self.poll_seconds)
        else:
            raise TimeoutError(f"VibeVoice job {job_id} exceeded {self.timeout_seconds}s")

        remote_outputs = {
            str(item.get("output_name")): item
            for item in job.get("outputs", [])
            if isinstance(item, dict)
        }
        results = []
        with tempfile.TemporaryDirectory(prefix="quiz-vibevoice-") as temporary:
            temporary_root = Path(temporary)
            for task in tasks:
                output_name = output_names[task.task_id]
                wav_path = temporary_root / output_name
                with httpx.stream(
                    "GET",
                    f"{self.endpoint}/jobs/{job_id}/audio-file/{output_name}",
                    timeout=120,
                ) as response:
                    response.raise_for_status()
                    with wav_path.open("wb") as handle:
                        for chunk in response.iter_bytes():
                            handle.write(chunk)
                _encode_vibevoice_mp3(wav_path, task.destination)
                remote = remote_outputs.get(output_name, {})
                results.append(
                    {
                        "task_id": task.task_id,
                        "file": task.destination.as_posix(),
                        "text": task.text,
                        "text_sha256": task.text_hash,
                        "duration_seconds": remote.get("duration_seconds"),
                        "sample_rate": remote.get("sample_rate"),
                        "job_id": job_id,
                    }
                )
        return results

    def render(self, tasks: list[AudioTask]) -> list[dict[str, Any]]:
        if self.auditor is None:
            return self._render_once(tasks)
        pending = list(tasks)
        results_by_id: dict[str, dict[str, Any]] = {}
        failures: list[dict[str, Any]] = []
        for attempt in range(self.max_audit_repairs + 1):
            rendered = self._render_once(pending)
            failures = []
            retry_tasks: list[AudioTask] = []
            task_by_id = {task.task_id: task for task in pending}
            for result in rendered:
                task = task_by_id[str(result["task_id"])]
                audit = self.auditor.audit(task.destination, task.text)
                result = {**result, "audit": {**audit, "render_attempt": attempt + 1}}
                results_by_id[task.task_id] = result
                if audit.get("status") != "passed":
                    failures.append(result)
                    retry_tasks.append(task)
            if not failures:
                return [results_by_id[task.task_id] for task in tasks]
            pending = retry_tasks
        duration_fallback_seconds = getattr(
            self, "duration_fallback_seconds", None
        )
        configured_duration_repairs = getattr(self, "max_duration_repairs", 0)
        max_duration_repairs = (
            None
            if configured_duration_repairs is None
            else max(0, int(configured_duration_repairs))
        )
        if failures and duration_fallback_seconds is not None and (
            max_duration_repairs is None or max_duration_repairs > 0
        ):
            pending = [
                task
                for task in tasks
                if task.task_id in {str(item["task_id"]) for item in failures}
            ]
            fallback_attempts = (
                itertools.count(1)
                if max_duration_repairs is None
                else range(1, max_duration_repairs + 1)
            )
            for fallback_attempt in fallback_attempts:
                rendered = self._render_once(pending)
                retry_tasks = []
                task_by_id = {task.task_id: task for task in pending}
                for result in rendered:
                    task_id = str(result["task_id"])
                    task = task_by_id[task_id]
                    try:
                        duration = float(result.get("duration_seconds") or 0)
                    except (TypeError, ValueError):
                        duration = 0
                    previous_audit = results_by_id[task_id].get("audit", {})
                    accepted = 0 < duration <= duration_fallback_seconds
                    result = {
                        **result,
                        "audit": {
                            **previous_audit,
                            "status": "passed" if accepted else "failed",
                            "automatic_status": "failed",
                            "render_attempt": (
                                self.max_audit_repairs + 1 + fallback_attempt
                            ),
                            "duration_fallback": {
                                "accepted": accepted,
                                "duration_seconds": duration,
                                "maximum_seconds": duration_fallback_seconds,
                                "attempt": fallback_attempt,
                            },
                        },
                    }
                    results_by_id[task_id] = result
                    if not accepted:
                        retry_tasks.append(task)
                if not retry_tasks:
                    return [results_by_id[task.task_id] for task in tasks]
                pending = retry_tasks
            failures = [results_by_id[task.task_id] for task in pending]
        details = "; ".join(
            f"{item['task_id']}: {','.join(item['audit'].get('reasons', []))}"
            for item in failures
        )
        ordered = [results_by_id[task.task_id] for task in tasks]
        raise AudioAuditError(
            (
                f"{len(failures)} audio clip(s) failed Whisper review after "
                f"{self.max_audit_repairs + 1} render attempts: {details}"
            ),
            results=ordered,
            failures=failures,
        )


def _narrator_metadata(
    client: VibeVoiceChunkClient, reference_transcript: str
) -> dict[str, Any]:
    metadata = {
        "provider": "vibevoice_chunk_api",
        "endpoint": client.endpoint,
        "language": client.lang_key,
        "cfg_scale": client.cfg_scale,
        "reference_audio": client.reference_audio.name,
        "reference_audio_sha256": _file_hash(client.reference_audio),
        "reference_transcript": reference_transcript,
        "tail_padding_seconds": VIBEVOICE_TAIL_PADDING_SECONDS,
    }
    auditor = getattr(client, "auditor", None)
    if auditor is not None:
        metadata["audio_audit"] = {
            **auditor.metadata(),
            "max_repair_attempts": getattr(client, "max_audit_repairs", 0),
            "duration_fallback_seconds": getattr(
                client, "duration_fallback_seconds", None
            ),
            "max_duration_repairs": getattr(client, "max_duration_repairs", 0),
        }
    return metadata


def _narrator_matches(previous: dict[str, Any], current: dict[str, Any]) -> bool:
    if not previous:
        return False
    for key, value in current.items():
        if key == "reference_audio_sha256" and key not in previous:
            continue
        if (
            key == "reference_audio"
            and previous.get("reference_audio_sha256")
            and previous.get("reference_audio_sha256")
            == current.get("reference_audio_sha256")
        ):
            continue
        if previous.get(key) != value:
            return False
    return True


def _encode_mp3(
    source: Path,
    destination: Path,
    *,
    audio_filter: str | None = None,
    bitrate: str = "80k",
    sample_rate: int = 24000,
    channels: int = 1,
) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError("ffmpeg is required to encode quiz narration")
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".tmp")
    command = [
        ffmpeg,
        "-hide_banner",
        "-loglevel",
        "error",
        "-y",
        "-i",
        str(source),
    ]
    if audio_filter:
        command.extend(["-af", audio_filter])
    command.extend([
        "-codec:a",
        "libmp3lame",
        "-b:a",
        bitrate,
        "-ar",
        str(sample_rate),
        "-ac",
        str(channels),
        "-f",
        "mp3",
        str(temporary),
    ])
    completed = subprocess.run(command, capture_output=True, text=True)
    if completed.returncode != 0:
        raise RuntimeError(f"ffmpeg failed: {completed.stderr.strip()}")
    temporary.replace(destination)


def _encode_vibevoice_mp3(source: Path, destination: Path) -> None:
    _encode_mp3(
        source,
        destination,
        audio_filter=f"apad=pad_dur={VIBEVOICE_TAIL_PADDING_SECONDS}",
    )


def _write_pcm_wav(path: Path, samples: Iterable[float], sample_rate: int = 24000) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(sample_rate)
        payload = bytearray()
        for sample in samples:
            clipped = max(-1.0, min(1.0, sample))
            payload.extend(struct.pack("<h", int(clipped * 32767)))
        output.writeframes(payload)


def _correct_chime(sample_rate: int = 24000) -> list[float]:
    duration = 1.15
    notes = ((0.00, 523.25), (0.18, 659.25), (0.36, 783.99), (0.54, 1046.50))
    samples = []
    for index in range(int(duration * sample_rate)):
        time_s = index / sample_rate
        value = 0.0
        for start, frequency in notes:
            elapsed = time_s - start
            if 0 <= elapsed < 0.58:
                envelope = math.sin(math.pi * min(elapsed / 0.035, 1.0) / 2)
                envelope *= math.exp(-4.8 * elapsed)
                value += envelope * (
                    math.sin(2 * math.pi * frequency * elapsed)
                    + 0.28 * math.sin(2 * math.pi * frequency * 2 * elapsed)
                )
        sparkle = math.sin(2 * math.pi * 1800 * time_s) * math.exp(-18 * max(0, time_s - 0.72))
        if time_s < 0.72:
            sparkle = 0.0
        samples.append(0.22 * value + 0.035 * sparkle)
    return samples


def _incorrect_buzzer(sample_rate: int = 24000) -> list[float]:
    duration = 0.72
    samples = []
    for index in range(int(duration * sample_rate)):
        time_s = index / sample_rate
        active = (0.00 <= time_s < 0.24) or (0.34 <= time_s < 0.62)
        if not active:
            samples.append(0.0)
            continue
        local = time_s if time_s < 0.24 else time_s - 0.34
        envelope = min(local / 0.012, 1.0) * min((0.28 - local) / 0.04, 1.0)
        tone = math.sin(2 * math.pi * 185 * local) + 0.22 * math.sin(2 * math.pi * 370 * local)
        samples.append(0.18 * max(0.0, envelope) * tone)
    return samples


def ensure_global_quiz_audio(
    *,
    global_root: Path,
    client: VibeVoiceChunkClient,
    reference_transcript: str = DEFAULT_REFERENCE_TRANSCRIPT,
    correct_phrases: tuple[str, ...] = DEFAULT_CORRECT_PHRASES,
    incorrect_phrases: tuple[str, ...] = DEFAULT_INCORRECT_PHRASES,
    correct_sfx_source: Path | None = None,
    incorrect_sfx_source: Path | None = None,
) -> dict[str, Any]:
    audio_root = global_root / "audio"
    manifest_path = audio_root / "audio-manifest.json"
    previous = _read_json(manifest_path)
    narrator = _narrator_metadata(client, reference_transcript)
    narrator_matches = _narrator_matches(previous.get("narrator", {}), narrator)
    previous_correct = {
        item.get("id"): item
        for item in previous.get("correct_feedback_clips", [])
        if isinstance(item, dict)
    }
    previous_incorrect = {
        item.get("id"): item
        for item in previous.get("incorrect_feedback_clips", [])
        if isinstance(item, dict)
    }

    correct_mp3 = audio_root / "correct_chime.mp3"
    incorrect_mp3 = audio_root / "incorrect_buzzer.mp3"
    if (correct_sfx_source is None) != (incorrect_sfx_source is None):
        raise ValueError("both correct and incorrect SFX sources must be supplied")
    if correct_sfx_source is not None and incorrect_sfx_source is not None:
        correct_source = correct_sfx_source.expanduser().resolve()
        incorrect_source = incorrect_sfx_source.expanduser().resolve()
        if not correct_source.is_file() or not incorrect_source.is_file():
            raise ValueError("correct or incorrect SFX source is missing")
        effects = {
            "source": "imported",
            "processing": "silence trim, 15/30ms edge fades, loudnorm I=-11 LUFS TP=-1 dBTP LRA=7",
            "correct_source": correct_source.name,
            "correct_source_sha256": _file_hash(correct_source),
            "incorrect_source": incorrect_source.name,
            "incorrect_source_sha256": _file_hash(incorrect_source),
        }
    else:
        correct_source = None
        incorrect_source = None
        effects = {"source": "generated", "version": 1}
    effects_changed = (
        not correct_mp3.is_file()
        or not incorrect_mp3.is_file()
        or previous.get("effects") != effects
    )
    if effects_changed and correct_source is not None and incorrect_source is not None:
        for source, destination in (
            (correct_source, correct_mp3),
            (incorrect_source, incorrect_mp3),
        ):
            _encode_mp3(
                source,
                destination,
                audio_filter=(
                    "silenceremove=start_periods=1:start_duration=0.02:"
                    "start_threshold=-45dB,areverse,"
                    "silenceremove=start_periods=1:start_duration=0.02:"
                    "start_threshold=-45dB,areverse,"
                    "afade=t=in:d=0.015,areverse,afade=t=in:d=0.03,areverse,"
                    "loudnorm=I=-11:TP=-1:LRA=7"
                ),
                bitrate="128k",
                sample_rate=44100,
                channels=2,
            )
    elif effects_changed:
        with tempfile.TemporaryDirectory(prefix="quiz-sfx-") as temporary:
            temporary_root = Path(temporary)
            correct_wav = temporary_root / "correct_chime.wav"
            incorrect_wav = temporary_root / "incorrect_buzzer.wav"
            _write_pcm_wav(correct_wav, _correct_chime())
            _write_pcm_wav(incorrect_wav, _incorrect_buzzer())
            _encode_mp3(correct_wav, correct_mp3)
            _encode_mp3(incorrect_wav, incorrect_mp3)

    tasks: list[AudioTask] = []

    def prepare_feedback_pool(
        *,
        kind: str,
        phrases: tuple[str, ...],
        previous_records: dict[str, dict[str, Any]],
    ) -> list[dict[str, Any]]:
        records = []
        for index, phrase in enumerate(phrases, start=1):
            clip_id = f"{kind}_{index:02d}"
            relative = Path("audio/feedback") / kind / f"{clip_id}.mp3"
            destination = global_root / relative
            old = previous_records.get(clip_id, {})
            if (
                narrator_matches
                and destination.is_file()
                and old.get("text_sha256") == _text_hash(phrase)
            ):
                records.append(old)
            else:
                tasks.append(AudioTask(clip_id, phrase, destination))
        return records

    correct_records = prepare_feedback_pool(
        kind="correct",
        phrases=correct_phrases,
        previous_records=previous_correct,
    )
    incorrect_records = prepare_feedback_pool(
        kind="incorrect",
        phrases=incorrect_phrases,
        previous_records=previous_incorrect,
    )

    for offset in range(0, len(tasks), 10):
        rendered = client.render(tasks[offset : offset + 10])
        for item in rendered:
            record = {
                **item,
                "id": item["task_id"],
                "file": str(Path(item["file"]).relative_to(global_root)),
            }
            if str(item["task_id"]).startswith("correct_"):
                correct_records.append(record)
            else:
                incorrect_records.append(record)

    correct_records.sort(key=lambda item: item["id"])
    incorrect_records.sort(key=lambda item: item["id"])

    manifest = {
        "schema_version": AUDIO_MANIFEST_SCHEMA,
        "generated_at_utc": _now(),
        "narrator": narrator,
        "correct_sfx": "audio/correct_chime.mp3",
        "incorrect_sfx": "audio/incorrect_buzzer.mp3",
        "effects": effects,
        "correct_feedback_clips": correct_records,
        "incorrect_feedback_clips": incorrect_records,
        # Kept so apps that predate incorrect feedback can still load the bundle.
        "praise_clips": correct_records,
    }
    if not tasks and not effects_changed and previous == {**manifest, "generated_at_utc": previous.get("generated_at_utc")}:
        return previous
    _write_json(manifest_path, manifest)
    return manifest


def sync_global_audio_to_flutter(
    *, global_root: Path, flutter_root: Path
) -> dict[str, Any]:
    source_manifest = _read_json(global_root / "audio/audio-manifest.json")
    correct_clips = source_manifest.get("correct_feedback_clips", [])
    incorrect_clips = source_manifest.get("incorrect_feedback_clips", [])
    if len(correct_clips) < 10 or len(incorrect_clips) < 10:
        raise ValueError("Flutter quizmaster pools require at least ten clips each")

    destination_root = flutter_root / "assets/audio"
    destination_root.mkdir(parents=True, exist_ok=True)

    def copy_asset(source_relative: str, destination_name: str) -> str:
        source = global_root / source_relative
        if not source.is_file():
            raise ValueError(f"global audio asset is missing: {source}")
        destination = destination_root / destination_name
        shutil.copy2(source, destination)
        return f"audio/{destination_name}"

    correct_sfx = copy_asset(
        str(source_manifest["correct_sfx"]), "quiz_correct_sfx.mp3"
    )
    incorrect_sfx = copy_asset(
        str(source_manifest["incorrect_sfx"]), "quiz_incorrect_sfx.mp3"
    )

    def copy_pool(items: list[dict[str, Any]], kind: str) -> list[dict[str, str]]:
        copied = []
        for index, item in enumerate(items, start=1):
            destination_name = f"quiz_{kind}_{index:02d}.mp3"
            copied.append(
                {
                    "id": str(item["id"]),
                    "text": str(item["text"]),
                    "asset": copy_asset(str(item["file"]), destination_name),
                }
            )
        return copied

    flutter_manifest = {
        "schema_version": "flutter_quiz_audio_v1",
        "source_manifest_sha256": _file_hash(
            global_root / "audio/audio-manifest.json"
        ),
        "correct_sfx": correct_sfx,
        "incorrect_sfx": incorrect_sfx,
        "correct_feedback_clips": copy_pool(correct_clips, "correct"),
        "incorrect_feedback_clips": copy_pool(incorrect_clips, "incorrect"),
    }
    _write_json(destination_root / "quiz_audio_manifest.json", flutter_manifest)
    return flutter_manifest


def _load_questions(category_root: Path) -> list[dict[str, Any]]:
    questions: dict[str, dict[str, Any]] = {}
    for path in sorted((category_root / "sets").glob("*/*.json")):
        document = _read_json(path)
        for question in document.get("questions", []):
            if not isinstance(question, dict):
                continue
            question_id = str(question.get("question_id") or "")
            if not question_id:
                raise ValueError(f"question without an ID in {path}")
            if question_id in questions and questions[question_id] != question:
                raise ValueError(f"question ID has conflicting content: {question_id}")
            questions[question_id] = question
    if not questions:
        raise ValueError(f"no quiz questions found under {category_root / 'sets'}")
    return [questions[key] for key in sorted(questions)]


def generate_category_quiz_audio(
    *,
    category_root: Path,
    category: str,
    client: VibeVoiceChunkClient,
    reference_transcript: str = DEFAULT_REFERENCE_TRANSCRIPT,
    limit_questions: int | None = None,
    clip_ids: set[tuple[str, str]] | None = None,
    force: bool = False,
    progress: Callable[[int, int], None] | None = None,
) -> dict[str, Any]:
    questions = _load_questions(category_root)
    if limit_questions is not None:
        questions = questions[:limit_questions]
    if clip_ids is not None:
        requested_question_ids = {question_id for question_id, _ in clip_ids}
        questions = [
            question
            for question in questions
            if str(question["question_id"]) in requested_question_ids
        ]
        if not questions:
            raise ValueError("none of the requested audio clips belong to a quiz set")
    audio_root = category_root / "audio"
    manifest_path = audio_root / "audio-manifest.json"
    previous = _read_json(manifest_path)
    narrator = _narrator_metadata(client, reference_transcript)
    source_narrator_matches = _narrator_matches(
        previous.get("narrator", {}),
        {key: value for key, value in narrator.items() if key != "audio_audit"},
    )
    records = {
        key: value
        for key, value in previous.get("questions", {}).items()
        if isinstance(value, dict)
    }

    pending: list[AudioTask] = []
    audit_existing: list[AudioTask] = []
    for question in questions:
        question_id = str(question["question_id"])
        narration = str(question.get("question") or "").strip()
        explanation = str(question.get("explanation") or "").strip()
        if not narration or not explanation:
            raise ValueError(f"question narration is incomplete: {question_id}")
        question_file = Path("audio/questions") / f"{_safe_name(question_id)}.mp3"
        explanation_file = Path("audio/explanations") / f"{_safe_name(question_id)}.mp3"
        old = records.get(question_id, {})
        question_requested = clip_ids is None or (question_id, "question") in clip_ids
        explanation_requested = clip_ids is None or (question_id, "explanation") in clip_ids
        question_audit = old.get("question_audit", {})
        explanation_audit = old.get("explanation_audit", {})
        question_source_ready = (
            source_narrator_matches
            and (category_root / question_file).is_file()
            and old.get("question_sha256") == _text_hash(narration)
        )
        explanation_source_ready = (
            source_narrator_matches
            and (category_root / explanation_file).is_file()
            and old.get("explanation_sha256") == _text_hash(explanation)
        )
        question_task = AudioTask(
            f"{question_id}_question", narration, category_root / question_file
        )
        explanation_task = AudioTask(
            f"{question_id}_explanation", explanation, category_root / explanation_file
        )
        if question_requested:
            if force or not question_source_ready or question_audit.get("status") == "failed":
                pending.append(question_task)
            elif getattr(client, "auditor", None) is not None and question_audit.get("status") != "passed":
                audit_existing.append(question_task)
        if explanation_requested:
            if force or not explanation_source_ready or explanation_audit.get("status") == "failed":
                pending.append(explanation_task)
            elif getattr(client, "auditor", None) is not None and explanation_audit.get("status") != "passed":
                audit_existing.append(explanation_task)
        records[question_id] = {
            **old,
            "question": question_file.as_posix(),
            "explanation": explanation_file.as_posix(),
            "question_sha256": _text_hash(narration),
            "explanation_sha256": _text_hash(explanation),
        }

    def store_audit(item: dict[str, Any]) -> None:
        task_id = str(item["task_id"])
        if task_id.endswith("_question"):
            question_id = task_id.removesuffix("_question")
            field = "question_audit"
        elif task_id.endswith("_explanation"):
            question_id = task_id.removesuffix("_explanation")
            field = "explanation_audit"
        else:
            return
        if item.get("audit") is not None and question_id in records:
            records[question_id][field] = item["audit"]

    audited_existing = 0
    auditor = getattr(client, "auditor", None)
    for offset in range(0, len(audit_existing), 10):
        batch = audit_existing[offset : offset + 10]
        for task in batch:
            audit = auditor.audit(task.destination, task.text)
            result = {
                "task_id": task.task_id,
                "audit": {
                    **audit,
                    "render_attempt": 0,
                    "audit_source": "existing_clip",
                },
            }
            store_audit(result)
            if audit.get("status") != "passed":
                pending.append(task)
        audited_existing += len(batch)
        if progress is not None:
            progress(audited_existing, len(audit_existing) + len(pending))

    total_pending = len(pending)
    failed_task_ids: list[str] = []
    for offset in range(0, total_pending, 10):
        batch = pending[offset : offset + 10]
        try:
            rendered = client.render(batch)
        except AudioAuditError as exc:
            rendered = exc.results
            failed_task_ids.extend(str(item["task_id"]) for item in exc.failures)
        for item in rendered:
            store_audit(item)
        manifest = {
            "schema_version": AUDIO_MANIFEST_SCHEMA,
            "category": category,
            "generated_at_utc": _now(),
            "narrator": narrator,
            "questions": records,
            "last_run": {
                "requested": total_pending,
                "completed": min(offset + len(batch), total_pending),
                "audited_existing": audited_existing,
                "failed": len(failed_task_ids),
                "failed_task_ids": failed_task_ids,
            },
        }
        _write_json(manifest_path, manifest)
        if progress is not None:
            progress(min(offset + len(batch), total_pending), total_pending)

    manifest = {
        "schema_version": AUDIO_MANIFEST_SCHEMA,
        "category": category,
        "generated_at_utc": _now(),
        "narrator": narrator,
        "questions": records,
        "last_run": {
            "requested": total_pending,
            "completed": total_pending,
            "audited_existing": audited_existing,
            "failed": len(failed_task_ids),
            "failed_task_ids": failed_task_ids,
        },
    }
    comparable = {**manifest, "generated_at_utc": previous.get("generated_at_utc")}
    if not pending and previous == comparable:
        return previous
    _write_json(manifest_path, manifest)
    return manifest
