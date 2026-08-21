from pathlib import Path

import pytest

from scripts.build_quiz_outro import build_landscape_outro, discover_outro_sources


def test_discovers_end_clips_in_numeric_order(tmp_path: Path) -> None:
    (tmp_path / "quiz_end_2.mp4").write_bytes(b"second")
    (tmp_path / "quiz_end_1.mp4").write_bytes(b"first")
    (tmp_path / "unrelated.mp4").write_bytes(b"ignore")

    assert [
        path.name
        for path in discover_outro_sources(tmp_path, tmp_path / "combined.mp4")
    ] == ["quiz_end_1.mp4", "quiz_end_2.mp4"]


def test_build_normalizes_and_concatenates_sources(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / "quiz_end.mp4").write_bytes(b"first")
    output = tmp_path / "assets/outro.mp4"
    captured: list[str] = []

    def fake_run(command: list[str], *, check: bool) -> None:
        assert check is True
        captured.extend(command)
        Path(command[-1]).write_bytes(b"combined")

    monkeypatch.setattr("scripts.build_quiz_intro.subprocess.run", fake_run)

    assert build_landscape_outro(source_root=tmp_path, output=output) == output
    assert output.read_bytes() == b"combined"
    assert captured.count("-i") == 1
    filter_graph = captured[captured.index("-filter_complex") + 1]
    assert "scale=1920:1080" in filter_graph
    assert "concat=n=1:v=1:a=1" in filter_graph


def test_build_raises_when_no_outro_clips_exist(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="no quiz_end"):
        build_landscape_outro(
            source_root=tmp_path, output=tmp_path / "assets/outro.mp4"
        )
