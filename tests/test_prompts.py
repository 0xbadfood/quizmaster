from pathlib import Path

from quiz_harness.models import GenerationRequest
from quiz_harness.prompts import build_user_prompt, load_history


def test_missing_history_directory_is_empty(tmp_path: Path) -> None:
    assert load_history(tmp_path / "missing") == []


def test_prompt_contains_request() -> None:
    request = GenerationRequest(
        category="vehicles",
        subject="fire truck",
        language="English",
        age_min=5,
        age_max=8,
        question_count=3,
        option_count=3,
        seed=7,
    )
    prompt = build_user_prompt(request, [])
    assert '"subject": "fire truck"' in prompt
    assert '"question_count": 3' in prompt
