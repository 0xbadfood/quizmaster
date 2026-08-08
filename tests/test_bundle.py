import json
from pathlib import Path

from quiz_harness.bundle import render_html
from quiz_harness.models import PlanDocument


def test_rendered_bundle_contains_interaction_and_escaped_text() -> None:
    plan_path = Path("plans/animals-lion-single.json")
    document = PlanDocument.model_validate_json(plan_path.read_text(encoding="utf-8"))
    manifest = {
        "assets": {
            asset.asset_id: {
                "file": f"assets/{asset.asset_id}.png",
            }
            for asset in document.plan.assets
        }
    }
    rendered = render_html(document, manifest)
    assert "quiz_answered" in rendered
    assert "quiz_complete" in rendered
    assert "window.QuizHarness" in rendered
    assert "When a lion opens its big mouth" in rendered
    runtime_line = next(line for line in rendered.splitlines() if "const quiz =" in line)
    json.loads(runtime_line.split("const quiz = ", 1)[1].rstrip(";"))
