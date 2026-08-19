from pathlib import Path

import pytest

from scripts.create_video import _output_name
from scripts.prepare_remotion_quiz import (
    _resolve_background,
    parse_question_selection,
)


def test_question_selection_accepts_ranges_and_lists() -> None:
    assert parse_question_selection("1-3,5,8-9") == [1, 2, 3, 5, 8, 9]
    assert parse_question_selection("all") == list(range(1, 11))


@pytest.mark.parametrize("value", ["0", "11", "4-2", "one", "1,,3"])
def test_question_selection_rejects_invalid_input(value: str) -> None:
    with pytest.raises(ValueError):
        parse_question_selection(value)


def test_landscape_background_is_mandatory(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "scripts.prepare_remotion_quiz.STUDIO_ROOT", tmp_path / "studio"
    )
    with pytest.raises(ValueError, match="landscape background image is not available"):
        _resolve_background(
            category="missing",
            orientation="landscape",
            content=tmp_path / "bundle",
            category_document={"presentation": {}},
        )


def test_video_filename_records_orientation_and_question_range() -> None:
    assert (
        _output_name(
            category="World History",
            difficulty="intermediate",
            set_number=2,
            orientation="landscape",
            questions=[3, 4, 5],
        )
        == "world-history-intermediate-set-02-landscape-q03-05.mp4"
    )
