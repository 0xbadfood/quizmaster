from __future__ import annotations

import io
from pathlib import Path

from PIL import Image

from quiz_harness.background_images import (
    BACKGROUND_SIZE,
    build_background_prompt,
    normalize_background,
)


def test_background_prompt_preserves_title_and_flutter_safe_area() -> None:
    prompt = build_background_prompt(
        category="Indian Independence",
        display_title="INDIAN INDEPENDENCE QUIZ",
        visual_brief="Use the Red Fort, a charkha, and saffron, white, and green accents.",
    )

    assert 'Main title: "INDIAN INDEPENDENCE QUIZ"' in prompt
    assert 'Small ribbon subtitle: "ADVENTURE"' in prompt
    assert "Keep the middle" in prompt
    assert "living politicians" in prompt


def test_normalize_background_writes_runtime_dimensions(tmp_path: Path) -> None:
    source = Image.new("RGB", (800, 800), (220, 130, 50))
    payload = io.BytesIO()
    source.save(payload, format="PNG")
    output = tmp_path / "runtime_background.png"

    result = normalize_background(payload.getvalue(), output)

    with Image.open(output) as generated:
        assert generated.format == "PNG"
        assert generated.size == BACKGROUND_SIZE
    assert result["width"] == 941
    assert result["height"] == 1672
    assert len(result["sha256"]) == 64
