from __future__ import annotations

import json
from collections import Counter
from pathlib import Path
from typing import Any


def category_metadata_status(category: dict[str, Any]) -> dict[str, Any]:
    checks = {
        "name": len(str(category.get("name") or "").strip()) >= 2,
        "display_title": len(str(category.get("display_title") or "").strip()) >= 2,
        "display_tag": 1
        <= len(str(category.get("display_tag") or "").strip())
        <= 12,
        "editorial_brief": len(
            str(category.get("editorial_brief") or "").strip()
        ) >= 20,
        "age_range": (
            isinstance(category.get("age_min"), int)
            and isinstance(category.get("age_max"), int)
            and 3 <= category["age_min"] <= category["age_max"] <= 15
        ),
    }
    labels = {
        "name": "category name",
        "display_title": "display title",
        "display_tag": "display tag (1-12 characters)",
        "editorial_brief": "editorial brief (at least 20 characters)",
        "age_range": "valid age range",
    }
    missing = [labels[key] for key, complete in checks.items() if not complete]
    return {
        "ready": not missing,
        "current": sum(checks.values()),
        "target": len(checks),
        "missing": missing,
    }


def _read_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def _count_questions(path: Path) -> tuple[int, int]:
    document = _read_json(path)
    questions = document.get("questions", [])
    if not isinstance(questions, list):
        return 0, 0
    usable = sum(
        isinstance(item, dict) and item.get("state") != "rejected"
        for item in questions
    )
    allocated = sum(
        isinstance(item, dict) and item.get("state") == "allocated"
        for item in questions
    )
    return usable, allocated


def _manifest_summary(path: Path) -> dict[str, Any]:
    assets = _read_json(path).get("assets", {})
    if not isinstance(assets, dict):
        assets = {}
    statuses = Counter(
        str(item.get("status", "unknown"))
        for item in assets.values()
        if isinstance(item, dict)
    )
    generated = sum(
        status in {"approved", "generated", "generated_pending_review"}
        for status in (
            str(item.get("status", "unknown"))
            for item in assets.values()
            if isinstance(item, dict)
        )
    )
    return {
        "total": len(assets),
        "generated": generated,
        "approved": statuses["approved"],
        "pending_review": statuses["generated_pending_review"],
        "statuses": dict(statuses),
    }


def category_production_summary(
    category: dict[str, Any],
    *,
    source_root: Path,
    bundle_root: Path,
) -> dict[str, Any]:
    slug = category["slug"]
    root = source_root / slug
    beginner_count, beginner_allocated = _count_questions(
        root / "banks/beginner/bank.json"
    )
    intermediate_count, intermediate_allocated = _count_questions(
        root / "banks/intermediate/bank.json"
    )
    set_counts = {
        difficulty: len(list((root / "sets" / difficulty).glob("*.json")))
        for difficulty in ("beginner", "intermediate")
    }
    set_total = set_counts["beginner"] + set_counts["intermediate"]
    selected_question_count = set_total * 10
    answer_images = _manifest_summary(root / "answer-image-manifest.json")
    category_images = _manifest_summary(root / "category-image-manifest.json")
    audio = _read_json(root / "audio/audio-manifest.json")
    audio_questions = audio.get("questions", {})
    if not isinstance(audio_questions, dict):
        audio_questions = {}
    current = _read_json(bundle_root / slug / "current.json")
    record_file = current.get("record_file")
    current_record = (
        _read_json(bundle_root / slug / record_file)
        if isinstance(record_file, str) and record_file.startswith("versions/")
        else {}
    )
    released_category = current_record.get("category", {})
    if not isinstance(released_category, dict):
        released_category = {}
    redeploy_required = bool(current) and any(
        str(released_category.get(key) or "").strip()
        != str(category.get(key) or "").strip()
        for key in ("name", "display_title", "display_tag")
    )
    selector_path = root / "assets/category/category_selector.webp"
    metadata = category_metadata_status(category)
    stages = [
        {
            "id": "metadata",
            "label": "Category metadata",
            "current": metadata["current"],
            "target": metadata["target"],
            "detail": (
                "Identity, audience, and editorial boundaries"
                if metadata["ready"]
                else "Missing " + ", ".join(metadata["missing"])
            ),
            "status": "ready" if metadata["ready"] else "attention",
        },
        {
            "id": "questions",
            "label": "Question bank",
            "current": beginner_count + intermediate_count,
            "target": 240,
            "detail": f"{beginner_count} beginner / {intermediate_count} intermediate",
            "status": "ready"
            if beginner_count >= 120 and intermediate_count >= 120
            else "attention",
        },
        {
            "id": "sets",
            "label": "Quiz sets",
            "current": set_total,
            "target": None,
            "recommended_target": 20,
            "detail": (
                f"{set_counts['beginner']} beginner / "
                f"{set_counts['intermediate']} intermediate"
            ),
            "status": "ready" if set_total else "blocked",
        },
        {
            "id": "visuals",
            "label": "Visual assets",
            "current": answer_images["generated"] + category_images["generated"],
            "target": answer_images["total"] + category_images["total"],
            "detail": f"{answer_images['pending_review'] + category_images['pending_review']} awaiting review",
            "status": "attention"
            if answer_images["pending_review"] + category_images["pending_review"]
            else ("ready" if answer_images["total"] else "blocked"),
        },
        {
            "id": "audio",
            "label": "Narration",
            "current": len(audio_questions),
            "target": selected_question_count or None,
            "detail": "Question and explanation pairs",
            "status": (
                "ready"
                if selected_question_count
                and len(audio_questions) >= selected_question_count
                else "blocked"
            ),
        },
        {
            "id": "publish",
            "label": "Published bundle",
            "current": int(current.get("bundle_version", 0)),
            "target": None,
            "detail": (
                "Category metadata changed; redeploy required"
                if redeploy_required
                else f"Version {current['bundle_version']} is live"
                if current.get("bundle_version")
                else "No published version"
            ),
            "status": (
                "attention"
                if redeploy_required
                else "published"
                if current.get("bundle_version")
                else "blocked"
            ),
        },
    ]
    next_action = next(
        (stage for stage in stages if stage["status"] in {"blocked", "attention"}),
        stages[-1],
    )
    return {
        **category,
        "thumbnail_url": (
            f"/studio-assets/{slug}/assets/category/category_selector.webp"
            if selector_path.exists()
            else None
        ),
        "workspace_available": root.exists(),
        "metadata": metadata,
        "bank": {
            "beginner": beginner_count,
            "intermediate": intermediate_count,
            "allocated": beginner_allocated + intermediate_allocated,
        },
        "sets": set_counts,
        "answer_images": answer_images,
        "category_images": category_images,
        "audio_count": len(audio_questions),
        "bundle": current or None,
        "redeploy_required": redeploy_required,
        "stages": stages,
        "next_action": next_action,
    }
