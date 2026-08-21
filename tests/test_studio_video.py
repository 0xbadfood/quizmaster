import json
from pathlib import Path

import pytest

from quiz_harness.studio_video import StudioVideoError, StudioVideoStore


def published_category(
    tmp_path: Path, *, set_count: int = 6, bundled_backgrounds: bool = True
) -> StudioVideoStore:
    bundle_root = tmp_path / "bundles"
    category_root = bundle_root / "geography"
    content = category_root / "versions/000003/content"
    content.mkdir(parents=True)
    (category_root / "current.json").write_text(
        json.dumps({"bundle_version": 3}), encoding="utf-8"
    )
    if bundled_backgrounds:
        (content / "portrait.png").write_bytes(b"portrait")
        (content / "landscape.png").write_bytes(b"landscape")
    quizzes = [
        {
            "quiz_id": f"geography_beginner_{index:02d}",
            "number": index,
            "difficulty": "beginner",
            "title": f"Geography Quiz {index}",
            "question_count": 10,
            "questions_file": f"quizzes/geography_beginner_{index:02d}.json",
        }
        for index in range(1, set_count + 1)
    ] + [
        {
            "quiz_id": f"geography_intermediate_{index:02d}",
            "number": index,
            "difficulty": "intermediate",
            "title": f"Intermediate Geography Quiz {index}",
            "question_count": 10,
            "questions_file": f"quizzes/geography_intermediate_{index:02d}.json",
        }
        for index in range(1, set_count + 1)
    ]
    quiz_root = content / "quizzes"
    quiz_root.mkdir()
    for quiz in quizzes:
        (content / quiz["questions_file"]).write_text(
            json.dumps(
                {
                    "questions": [
                        {
                            "question_id": f"{quiz['quiz_id']}_{number:02d}",
                            "question": f"Geography question {number} from set {quiz['number']}?",
                        }
                        for number in range(1, 11)
                    ]
                }
            ),
            encoding="utf-8",
        )
    (content / "category.json").write_text(
        json.dumps(
            {
                "quizzes": quizzes,
                "presentation": (
                    {
                        "video_background_portrait": "portrait.png",
                        "video_background_landscape": "landscape.png",
                    }
                    if bundled_backgrounds
                    else {}
                ),
            }
        ),
        encoding="utf-8",
    )
    return StudioVideoStore(bundle_root, tmp_path / "videos")


def test_landscape_selection_accepts_up_to_five_sets(tmp_path: Path) -> None:
    store = published_category(tmp_path)
    result = store.resolve_selection(
        category_slug="geography",
        orientation="landscape",
        set_ids=[f"geography_beginner_{index:02d}" for index in range(1, 6)],
    )
    assert result["question_count"] == 50
    assert result["bundle_version"] == 3


def test_landscape_selection_orders_beginner_before_intermediate(
    tmp_path: Path,
) -> None:
    store = published_category(tmp_path)

    result = store.resolve_selection(
        category_slug="geography",
        orientation="landscape",
        set_ids=[
            "geography_intermediate_02",
            "geography_beginner_02",
            "geography_intermediate_01",
            "geography_beginner_01",
        ],
    )

    assert [item["set_id"] for item in result["selected"]] == [
        "geography_beginner_01",
        "geography_beginner_02",
        "geography_intermediate_01",
        "geography_intermediate_02",
    ]


def test_landscape_selection_rejects_more_than_fifty_questions(tmp_path: Path) -> None:
    store = published_category(tmp_path)
    with pytest.raises(StudioVideoError, match="at most 50 questions"):
        store.resolve_selection(
            category_slug="geography",
            orientation="landscape",
            set_ids=[f"geography_beginner_{index:02d}" for index in range(1, 7)],
        )


def test_portrait_selection_rejects_multiple_sets(tmp_path: Path) -> None:
    store = published_category(tmp_path)
    with pytest.raises(StudioVideoError, match="at most 10 questions"):
        store.resolve_selection(
            category_slug="geography",
            orientation="portrait",
            set_ids=["geography_beginner_01", "geography_beginner_02"],
        )


def test_portrait_selection_accepts_individual_questions(tmp_path: Path) -> None:
    store = published_category(tmp_path)

    inventory = store.inventory("geography")
    result = store.resolve_selection(
        category_slug="geography",
        orientation="portrait",
        set_ids=["geography_beginner_01"],
        question_numbers=[8, 2, 5],
    )

    assert inventory["sets"][0]["questions"][1] == {
        "number": 2,
        "question_id": "geography_beginner_01_02",
        "question": "Geography question 2 from set 1?",
    }
    assert result["question_count"] == 3
    assert result["selected"] == [
        {
            "set_id": "geography_beginner_01",
            "number": 1,
            "difficulty": "beginner",
            "title": "Geography Quiz 1",
            "question_count": 3,
            "question_numbers": [2, 5, 8],
        }
    ]


def test_landscape_rejects_individual_question_selection(tmp_path: Path) -> None:
    store = published_category(tmp_path)
    with pytest.raises(StudioVideoError, match="only for portrait"):
        store.resolve_selection(
            category_slug="geography",
            orientation="landscape",
            set_ids=["geography_beginner_01"],
            question_numbers=[1, 2],
        )


def test_portrait_rejects_duplicate_question_numbers(tmp_path: Path) -> None:
    store = published_category(tmp_path)
    with pytest.raises(StudioVideoError, match="contains duplicates"):
        store.resolve_selection(
            category_slug="geography",
            orientation="portrait",
            set_ids=["geography_beginner_01"],
            question_numbers=[2, 2],
        )


def test_render_passes_partial_question_numbers_to_preparer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bundle_root = tmp_path / "bundles"
    renderer = tmp_path / "renderer"
    remotion = renderer / "node_modules/.bin/remotion"
    remotion.parent.mkdir(parents=True)
    remotion.write_text("", encoding="utf-8")
    store = StudioVideoStore(bundle_root, tmp_path / "videos")
    prepared: list[tuple[str, int, list[int] | None]] = []

    def fake_prepare(
        category: str,
        selections: list[tuple[str, int, list[int] | None]],
        **kwargs,
    ) -> None:
        assert category == "geography"
        prepared.extend(selections)

    class Process:
        def __init__(self, command, **kwargs) -> None:
            self.stdout: list[str] = []
            Path(command[4]).write_bytes(b"video")

        def wait(self) -> int:
            return 0

    monkeypatch.setattr("quiz_harness.studio_video.RENDERER_ROOT", renderer)
    monkeypatch.setattr("quiz_harness.studio_video.prepare_sets", fake_prepare)
    monkeypatch.setattr("quiz_harness.studio_video.subprocess.Popen", Process)
    monkeypatch.setattr(store, "_duration", lambda path: 42.5)

    result = store.render(
        video_id="portrait-video",
        category_slug="geography",
        orientation="portrait",
        bundle_version=3,
        selections=[
            {
                "set_id": "geography_beginner_01",
                "difficulty": "beginner",
                "number": 1,
                "question_count": 3,
                "question_numbers": [2, 5, 8],
            }
        ],
        concurrency=4,
        crf=18,
        progress=lambda message, value: None,
    )

    assert prepared == [("beginner", 1, [2, 5, 8])]
    assert result["duration_seconds"] == 42.5


def test_background_can_come_from_production_workspace(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    store = published_category(tmp_path, bundled_backgrounds=False)
    studio = tmp_path / "studio"
    category = studio / "geography"
    asset = category / "assets/category/video_background_landscape.png"
    asset.parent.mkdir(parents=True)
    asset.write_bytes(b"landscape")
    asset_id = "geography_video_background_landscape"
    (category / "category-image-spec.json").write_text(
        json.dumps(
            {
                "assets": [
                    {
                        "asset_id": asset_id,
                        "role": "video_background_landscape",
                        "file": "assets/category/video_background_landscape.png",
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    (category / "category-image-manifest.json").write_text(
        json.dumps(
            {"assets": {asset_id: {"status": "generated_pending_review"}}}
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr("scripts.prepare_remotion_quiz.STUDIO_ROOT", studio)

    inventory = store.inventory("geography")

    assert inventory["backgrounds"] == {"portrait": False, "landscape": True}
