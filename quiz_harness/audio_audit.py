from __future__ import annotations

import hashlib
import json
import math
import os
import re
import subprocess
import sys
import threading
import unicodedata
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any


DEFAULT_WHISPER_MODEL = "Systran/faster-whisper-base.en"
DEFAULT_WHISPER_ENV = Path("/home/nitin/story_generator/.whisperx-env/bin/python3")


@dataclass(frozen=True)
class AudioAuditConfig:
    # Permit one ASR substitution in an eight-word clip. This matches the WER
    # tolerance below and avoids rejecting short phrases on homophones.
    score_threshold: float = 0.875
    coverage_threshold: float = 0.82
    wer_threshold: float = 0.18
    min_length_ratio: float = 0.65
    max_length_ratio: float = 1.45
    repeat_threshold: float = 0.22
    min_speech_coverage: float = 0.55
    min_words: int = 8


def normalize_text(text: str) -> str:
    value = unicodedata.normalize("NFKC", str(text or "")).lower()
    value = value.replace("’", "'").replace("‘", "'")
    value = re.sub(r"\bspeaker\s+\d+\s*:", " ", value)
    value = value.replace("n't", " not")
    value = value.replace("'re", " are").replace("'ve", " have")
    value = value.replace("'ll", " will").replace("'d", " would")
    value = value.replace("'m", " am").replace("'s", " is")
    value = re.sub(r"[^a-z0-9]+", " ", value)
    return re.sub(r"\s+", " ", value).strip()


def _edit_distance(left: list[str], right: list[str]) -> int:
    previous = list(range(len(right) + 1))
    for index, left_word in enumerate(left, start=1):
        current = [index]
        for offset, right_word in enumerate(right, start=1):
            cost = 0 if left_word == right_word else 1
            current.append(
                min(previous[offset] + 1, current[-1] + 1, previous[offset - 1] + cost)
            )
        previous = current
    return previous[-1]


def _lcs_length(left: list[str], right: list[str]) -> int:
    previous = [0] * (len(right) + 1)
    for left_word in left:
        current = [0]
        for offset, right_word in enumerate(right, start=1):
            current.append(
                previous[offset - 1] + 1
                if left_word == right_word
                else max(previous[offset], current[-1])
            )
        previous = current
    return previous[-1]


def _reconcile_tokens(
    expected: list[str], actual: list[str], max_window: int = 3
) -> tuple[list[str], list[str]]:
    reconciled_expected: list[str] = []
    reconciled_actual: list[str] = []
    left = right = 0
    while left < len(expected) and right < len(actual):
        if expected[left] == actual[right]:
            reconciled_expected.append(expected[left])
            reconciled_actual.append(actual[right])
            left += 1
            right += 1
            continue
        matched = False
        for size in range(2, max_window + 1):
            if right + size <= len(actual) and expected[left] == "".join(actual[right : right + size]):
                reconciled_expected.append(expected[left])
                reconciled_actual.append(expected[left])
                left += 1
                right += size
                matched = True
                break
        if matched:
            continue
        for size in range(2, max_window + 1):
            if left + size <= len(expected) and actual[right] == "".join(expected[left : left + size]):
                reconciled_expected.append(actual[right])
                reconciled_actual.append(actual[right])
                left += size
                right += 1
                matched = True
                break
        if matched:
            continue
        reconciled_expected.append(expected[left])
        reconciled_actual.append(actual[right])
        left += 1
        right += 1
    reconciled_expected.extend(expected[left:])
    reconciled_actual.extend(actual[right:])
    return reconciled_expected, reconciled_actual


def _repeated_ngram_ratio(words: list[str], size: int = 4) -> float:
    if len(words) < size * 2:
        return 0.0
    grams = [tuple(words[index : index + size]) for index in range(len(words) - size + 1)]
    return max(0.0, 1.0 - (len(set(grams)) / float(len(grams) or 1)))


def score_transcript(
    *,
    expected_text: str,
    transcript_text: str,
    audio_duration_seconds: float,
    speech_span_seconds: float,
    config: AudioAuditConfig = AudioAuditConfig(),
) -> dict[str, Any]:
    expected = normalize_text(expected_text).split()
    actual = normalize_text(transcript_text).split()
    scored_expected, scored_actual = _reconcile_tokens(expected, actual)
    wer = _edit_distance(scored_expected, scored_actual) / float(
        max(1, len(scored_expected))
    )
    coverage = _lcs_length(scored_expected, scored_actual) / float(
        max(1, len(scored_expected))
    )
    length_ratio = len(scored_actual) / float(max(1, len(scored_expected)))
    speech_coverage = min(
        1.0,
        max(0.0, speech_span_seconds / float(audio_duration_seconds or 1.0)),
    )
    repeat_ratio = _repeated_ngram_ratio(actual)
    score = min(coverage, max(0.0, 1.0 - wer))
    reasons: list[str] = []
    if len(expected) >= config.min_words and len(actual) < max(
        2, math.floor(len(expected) * config.min_length_ratio)
    ):
        reasons.append("short_transcript")
    if (
        score < config.score_threshold
        or coverage < config.coverage_threshold
        or wer > config.wer_threshold
    ):
        reasons.append("text_mismatch")
    if coverage < config.coverage_threshold:
        reasons.append("low_coverage")
    if length_ratio < config.min_length_ratio:
        reasons.append("length_too_short")
    if length_ratio > config.max_length_ratio:
        reasons.append("length_too_long")
    if repeat_ratio > config.repeat_threshold:
        reasons.append("repeated_text")
    if (
        audio_duration_seconds > 0
        and speech_span_seconds > 0
        and speech_coverage < config.min_speech_coverage
    ):
        reasons.append("low_speech_coverage")
    return {
        "status": "failed" if reasons else "passed",
        "score": round(score, 4),
        "coverage": round(coverage, 4),
        "wer": round(wer, 4),
        "length_ratio": round(length_ratio, 4),
        "speech_coverage": round(speech_coverage, 4),
        "repeated_ngram_ratio": round(repeat_ratio, 4),
        "expected_words": len(expected),
        "transcript_words": len(actual),
        "reasons": reasons,
        "expected_text": " ".join(expected),
        "transcript_text": " ".join(actual),
        "audio_duration_seconds": round(audio_duration_seconds, 4),
        "speech_span_seconds": round(speech_span_seconds, 4),
    }


class WhisperAuditClient:
    def __init__(
        self,
        *,
        cache_root: Path,
        python_path: Path | None = None,
        model: str = DEFAULT_WHISPER_MODEL,
        device: str = "cuda",
        compute_type: str = "float16",
        model_cache: Path = Path("/home/nitin/.cache/huggingface"),
        config: AudioAuditConfig = AudioAuditConfig(),
    ) -> None:
        configured_python = os.getenv("QUIZ_WHISPER_PYTHON")
        self.python_path = Path(configured_python) if configured_python else (
            python_path or (DEFAULT_WHISPER_ENV if DEFAULT_WHISPER_ENV.is_file() else Path(sys.executable))
        )
        self.cache_root = Path(cache_root)
        self.model = model
        self.device = device
        self.compute_type = compute_type
        self.model_cache = Path(model_cache)
        self.config = config
        self._process: subprocess.Popen[str] | None = None
        self._lock = threading.Lock()

    def __enter__(self) -> WhisperAuditClient:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def metadata(self) -> dict[str, Any]:
        return {
            "provider": "faster_whisper",
            "model": self.model,
            "device": self.device,
            "compute_type": self.compute_type,
            "thresholds": asdict(self.config),
        }

    def _start(self) -> subprocess.Popen[str]:
        if self._process is not None and self._process.poll() is None:
            return self._process
        worker = Path(__file__).resolve().parent.parent / "scripts/whisper_audit_worker.py"
        if not self.python_path.is_file():
            raise RuntimeError(f"Whisper Python environment is missing: {self.python_path}")
        self._process = subprocess.Popen(
            [
                str(self.python_path),
                str(worker),
                "--model",
                self.model,
                "--device",
                self.device,
                "--compute-type",
                self.compute_type,
                "--cache-dir",
                str(self.model_cache),
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        return self._process

    def close(self) -> None:
        if self._process is None:
            return
        if self._process.poll() is None and self._process.stdin is not None:
            try:
                self._process.stdin.write(json.dumps({"command": "close"}) + "\n")
                self._process.stdin.flush()
                self._process.wait(timeout=10)
            except (BrokenPipeError, subprocess.TimeoutExpired):
                self._process.terminate()
        self._process = None

    def audit(self, audio_path: Path, expected_text: str) -> dict[str, Any]:
        digest = hashlib.sha256()
        digest.update(self.model.encode())
        digest.update(audio_path.read_bytes())
        cache_path = self.cache_root / f"{digest.hexdigest()}.json"
        if cache_path.is_file():
            transcript = json.loads(cache_path.read_text(encoding="utf-8"))
        else:
            with self._lock:
                process = self._start()
                assert process.stdin is not None and process.stdout is not None
                process.stdin.write(json.dumps({"audio_path": str(audio_path.resolve())}) + "\n")
                process.stdin.flush()
                line = process.stdout.readline()
            if not line:
                code = process.poll()
                raise RuntimeError(f"Whisper audit worker stopped unexpectedly ({code})")
            transcript = json.loads(line)
            if transcript.get("error"):
                raise RuntimeError(f"Whisper audit failed: {transcript['error']}")
            cache_path.parent.mkdir(parents=True, exist_ok=True)
            cache_path.write_text(json.dumps(transcript, indent=2) + "\n", encoding="utf-8")
        return {
            **score_transcript(
                expected_text=expected_text,
                transcript_text=str(transcript.get("text") or ""),
                audio_duration_seconds=float(transcript.get("audio_duration_seconds") or 0),
                speech_span_seconds=float(transcript.get("speech_span_seconds") or 0),
                config=self.config,
            ),
            "model": self.model,
        }
