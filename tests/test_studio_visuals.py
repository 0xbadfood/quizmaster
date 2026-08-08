from __future__ import annotations

import io
import json
from pathlib import Path

from PIL import Image
import pytest

import quiz_harness.studio_visuals as studio_visuals_module
from quiz_harness.studio_visuals import StudioVisualStore
from quiz_harness.visual_bank import (
    VisualBankDocument,
    build_visual_quiz_set,
    write_model,
)


def make_question(index: int) -> dict:
    return {
        "question_id": f"birds_beginner_{index:03d}",
        "topic_key": f"bird_feature_{index:03d}",
        "difficulty": "beginner",
        "question": f"Which bird demonstrates visual feature number {index}?",
        "choices": [
            {
                "choice_id": f"choice{choice}",
                "animal_key": f"bird_{index}_{choice}",
                "label": f"Bird {index} {choice}",
            }
            for choice in range(1, 5)
        ],
        "correct_choice_id": "choice1",
        "explanation": f"Bird {index} 1 demonstrates visual feature number {index}.",
        "state": "available",
    }


def visual_fixture(tmp_path: Path) -> tuple[StudioVisualStore, dict, Path]:
    root = tmp_path / "source"
    category_root = root / "birds"
    bank = VisualBankDocument.model_validate(
        {
            "schema_version": "visual_bank_v1",
            "category": "Birds",
            "difficulty": "beginner",
            "source_provider": "openai",
            "source_model": "test-source",
            "source_response_id": "response-1",
            "generated_at_utc": "2026-08-05T00:00:00Z",
            "questions": [make_question(index) for index in range(1, 21)],
        }
    )
    for number in range(1, 3):
        selected = bank.questions[(number - 1) * 10 : number * 10]
        quiz_set = build_visual_quiz_set(bank, selected, set_number=number, seed=number)
        for item in selected:
            item.state = "allocated"
            item.set_id = quiz_set.set_id
        write_model(
            category_root / "sets/beginner" / f"{quiz_set.set_id}.json",
            quiz_set,
        )
    write_model(category_root / "banks/beginner/bank.json", bank)
    category = {
        "slug": "birds",
        "name": "Birds",
        "display_title": "BIRD QUIZ",
    }
    return StudioVisualStore(root), category, category_root


def test_visual_inventory_uses_actual_sets_and_allocated_choices(tmp_path: Path) -> None:
    store, category, category_root = visual_fixture(tmp_path)
    catalog, spec = store.prepare(category)
    assert len(spec.assets) == 4
    assert [item.asset_id for item in spec.assets if item.role == "quiz_tile"] == [
        "tile_beginner_01",
        "tile_beginner_02",
    ]
    assert len(catalog.animals) == 80
    inventory = store.inventory(category)
    assert inventory["summary"]["roles"]["quiz_tile"] == 2
    assert inventory["summary"]["roles"]["answer_image"] == 80
    assert (category_root / "animal_catalog.json").exists()


def test_empty_category_visual_inventory_is_blocked_not_exceptional(
    tmp_path: Path,
) -> None:
    store = StudioVisualStore(tmp_path / "source")
    result = store.inventory(
        {
            "slug": "ancient-civilizations",
            "name": "Ancient Civilizations",
            "display_title": "ANCIENT CIVILIZATIONS QUIZ",
        }
    )

    assert result["ready"] is False
    assert result["assets"] == []
    assert result["blocked_reason"] == "question banks are required before visual planning"


def test_background_upload_is_normalized_and_approved(tmp_path: Path) -> None:
    store, category, category_root = visual_fixture(tmp_path)
    source = Image.new("RGB", (400, 700), "teal")
    data = io.BytesIO()
    source.save(data, format="JPEG")
    result = store.upload_background(category, data.getvalue(), "image/jpeg")
    assert result["status"] == "approved"
    output = category_root / "assets/category/runtime_background.png"
    with Image.open(output) as image:
        assert image.format == "PNG"
        assert image.size == (400, 700)
    manifest = json.loads(
        (category_root / "category-image-manifest.json").read_text(encoding="utf-8")
    )
    assert manifest["assets"]["birds_runtime_background"]["status"] == "approved"


def test_inventory_migrates_legacy_animal_tile_fallback(tmp_path: Path) -> None:
    store, category, category_root = visual_fixture(tmp_path)
    store.prepare(category)
    spec_path = category_root / "category-image-spec.json"
    document = json.loads(spec_path.read_text(encoding="utf-8"))
    tile = next(item for item in document["assets"] if item["role"] == "quiz_tile")
    tile["prompt"] = (
        "Create a polished square mobile quiz cover with a child together with a "
        "friendly, balanced group representing these quiz\nsubjects: lion and panda. "
        "Use a lush jungle setting and render the exact quiz title clearly."
    )
    spec_path.write_text(json.dumps(document), encoding="utf-8")
    inventory = store.inventory(category)
    migrated = next(
        item for item in inventory["assets"] if item["asset_id"] == tile["asset_id"]
    )
    assert "category as a whole" in migrated["prompt"]
    assert "lion and panda" not in migrated["prompt"]


@pytest.mark.parametrize("provider_type", ["openai_images", "imagestudio"])
def test_every_provider_can_generate_tiles_and_answers(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, provider_type: str
) -> None:
    store, category, _ = visual_fixture(tmp_path)
    calls: list[tuple[str, set[str], str]] = []

    def fake_openai(**kwargs):
        calls.append(
            (
                "openai",
                set(kwargs["selected_asset_ids"]),
                kwargs["manifest_path"].name,
            )
        )
        return {"last_run": {"generated": len(kwargs["selected_asset_ids"])}}

    def fake_imagestudio(**kwargs):
        calls.append(
            (
                "imagestudio",
                set(kwargs["selected_asset_ids"]),
                kwargs["manifest_path"].name,
            )
        )
        return {"last_run": {"generated": len(kwargs["selected_asset_ids"])}}

    monkeypatch.setattr(
        studio_visuals_module, "generate_openai_image_assets", fake_openai
    )
    monkeypatch.setattr(
        studio_visuals_module, "_generate_imagestudio_assets", fake_imagestudio
    )
    provider = {
        "id": f"test-{provider_type}",
        "provider_type": provider_type,
        "base_url": "http://images.test/v1",
    }
    result = store.generate_images(
        category=category,
        asset_ids={"tile_beginner_01", "answer_bird_1_1"},
        provider=provider,
        secret="test-secret",
        model="test-image-model",
        quality="medium",
        force=False,
        progress=lambda *_: None,
    )
    assert result["generated"] == 2
    assert calls == [
        (
            "openai" if provider_type == "openai_images" else "imagestudio",
            {"tile_beginner_01"},
            "category-image-manifest.json",
        ),
        (
            "openai" if provider_type == "openai_images" else "imagestudio",
            {"bird_1_1"},
            "answer-image-manifest.json",
        ),
    ]


def test_background_cannot_enter_generation_job(tmp_path: Path) -> None:
    store, category, _ = visual_fixture(tmp_path)
    with pytest.raises(ValueError, match="unknown visual assets"):
        store.generate_images(
            category=category,
            asset_ids={"birds_runtime_background"},
            provider={
                "id": "openai",
                "provider_type": "openai_images",
                "base_url": "https://api.openai.com/v1",
            },
            secret="test-secret",
            model="gpt-image-test",
            quality="medium",
            force=False,
            progress=lambda *_: None,
        )
