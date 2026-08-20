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
        }
        for index in range(1, set_count + 1)
    ]
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
