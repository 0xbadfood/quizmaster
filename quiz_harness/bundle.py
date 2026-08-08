from __future__ import annotations

import hashlib
import html
import json
import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from .models import PlanDocument


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _slug(value: str) -> str:
    import re

    return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-") or "quiz"


def bundle_id(document: PlanDocument) -> str:
    return "-".join(
        [
            _slug(document.request.category),
            _slug(document.request.subject),
            str(document.request.seed),
        ]
    )


def render_html(document: PlanDocument, asset_manifest: dict[str, Any]) -> str:
    plan = document.plan
    question = plan.questions[0]
    palette = plan.visual_design.palette
    components = plan.ui_components
    files = {
        asset_id: item["file"]
        for asset_id, item in asset_manifest["assets"].items()
    }
    background = files[components.background_asset_id]
    answer_frame = files[components.answer_button_asset_id]
    progress_track = files[components.progress_track_asset_id]
    progress_marker = files[components.progress_marker_asset_id]
    question_image = files[question.image_asset_id]
    options = "\n".join(
        f'''<button class="answer" type="button" data-option-id="{html.escape(option.option_id)}">
          <span class="option-key">{chr(65 + index)}</span>
          <span class="option-label">{html.escape(option.label)}</span>
        </button>'''
        for index, option in enumerate(question.options)
    )
    runtime = {
        "bundleId": bundle_id(document),
        "questionId": question.question_id,
        "correctOptionId": question.correct_option_id,
        "narration": question.narration_text,
        "successMessage": question.success_message,
        "explanation": question.explanation,
    }
    runtime_json = json.dumps(runtime, ensure_ascii=True).replace("</", "<\\/")
    return f'''<!doctype html>
<html lang="{html.escape(document.request.language[:2].lower())}">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
  <meta name="theme-color" content="{palette.page_background}">
  <title>{html.escape(plan.brief.title)}</title>
  <style>
    :root {{
      --page: {palette.page_background}; --surface: {palette.surface};
      --primary: {palette.primary}; --secondary: {palette.secondary};
      --accent: {palette.accent}; --correct: {palette.correct};
      --incorrect: {palette.incorrect}; --text: {palette.text_primary};
      --on-primary: {palette.text_on_primary};
      --radius: {plan.visual_design.shape_language.corner_radius_px}px;
      --border: {plan.visual_design.shape_language.border_width_px}px;
      --answer-image: url("{html.escape(answer_frame)}");
    }}
    * {{ box-sizing: border-box; }}
    html, body {{ min-height: 100%; margin: 0; }}
    body {{
      background: var(--page); color: var(--text); font-family: ui-rounded,
        "Arial Rounded MT Bold", "Trebuchet MS", system-ui, sans-serif;
      letter-spacing: 0;
    }}
    button {{ font: inherit; letter-spacing: 0; }}
    .app {{
      isolation: isolate; position: relative; width: min(100%, 480px);
      min-height: 100svh; margin: 0 auto; overflow: hidden; background: var(--page);
    }}
    .scene {{
      position: absolute; inset: 0; z-index: -2; width: 100%; height: 100%;
      object-fit: cover;
    }}
    .veil {{ position: absolute; inset: 0; z-index: -1; background: rgba(255,255,255,.12); }}
    .content {{
      min-height: 100svh; padding: max(14px, env(safe-area-inset-top)) 16px
        max(16px, env(safe-area-inset-bottom)); display: flex; flex-direction: column;
      gap: 12px;
    }}
    .header {{ display: grid; grid-template-columns: 46px minmax(0, 1fr) 66px; align-items: center; gap: 8px; min-height: 52px; }}
    .icon-button {{
      width: 46px; height: 46px; display: grid; place-items: center; border: 2px solid rgba(255,255,255,.8);
      border-radius: 50%; background: var(--primary); color: var(--on-primary);
      box-shadow: 0 4px 0 rgba(0,0,0,.18); cursor: pointer; font-size: 25px;
    }}
    .title {{ min-width: 0; text-align: center; }}
    .title strong {{ display: block; font-size: 20px; line-height: 1.05; overflow-wrap: anywhere; }}
    .title span {{ display: block; margin-top: 3px; font: 700 11px/1.2 system-ui, sans-serif; overflow-wrap: anywhere; }}
    .score {{
      min-width: 66px; min-height: 42px; padding: 0 11px; display: flex; align-items: center;
      justify-content: center; gap: 6px; border: 2px solid rgba(255,255,255,.8);
      border-radius: 22px; background: var(--secondary); color: var(--text); font-weight: 900;
    }}
    .progress-label {{ text-align: center; font-size: 14px; font-weight: 900; }}
    .progress {{ position: relative; width: min(82%, 320px); height: 38px; margin: -3px auto 0; }}
    .progress-track {{ position: absolute; inset: 10px 0; width: 100%; height: 18px; object-fit: fill; }}
    .progress-marker {{ position: absolute; right: -2px; top: 1px; width: 36px; height: 36px; object-fit: contain; }}
    .question-card {{
      background: color-mix(in srgb, var(--surface) 94%, transparent); border: 3px solid rgba(255,255,255,.85);
      border-radius: var(--radius); padding: 14px; box-shadow: 0 7px 0 rgba(0,0,0,.16);
    }}
    .prompt-row {{ display: grid; grid-template-columns: minmax(0, 1fr) 46px; gap: 8px; align-items: center; }}
    h1 {{ min-width: 0; margin: 0; text-align: center; font-size: 22px; line-height: 1.12; overflow-wrap: anywhere; }}
    .question-image {{
      display: block; width: 100%; height: min(31svh, 270px); margin-top: 12px;
      object-fit: contain; border-radius: max(8px, calc(var(--radius) - 6px));
      background: rgba(255,255,255,.35);
    }}
    .answers {{ display: grid; gap: 9px; }}
    .answer {{
      position: relative; width: 100%; min-height: 62px; padding: 8px 54px 8px 68px;
      border: 0; border-radius: 12px; background-color: color-mix(in srgb, var(--surface) 94%, transparent);
      background-image: var(--answer-image); background-position: center; background-size: 100% 100%; background-repeat: no-repeat;
      color: var(--text); cursor: pointer; font-size: 20px; font-weight: 900;
      box-shadow: 0 4px 0 rgba(0,0,0,.18); transition: transform 120ms ease, filter 120ms ease;
    }}
    .answer:active {{ transform: translateY(2px); }}
    .answer:disabled {{ cursor: default; }}
    .answer.correct {{ box-shadow: inset 0 0 0 5px var(--correct), 0 4px 0 rgba(0,0,0,.18); }}
    .answer.incorrect {{ box-shadow: inset 0 0 0 5px var(--incorrect), 0 4px 0 rgba(0,0,0,.18); filter: saturate(.7); }}
    .option-key {{
      position: absolute; left: 9px; top: 50%; translate: 0 -50%; width: 44px; height: 44px;
      display: grid; place-items: center; border: 3px solid var(--primary); border-radius: 50%;
      background: var(--surface); color: var(--primary);
    }}
    .option-label {{ display: block; overflow-wrap: anywhere; }}
    .feedback {{
      min-height: 42px; padding: 7px 12px; text-align: center; font: 800 14px/1.25 system-ui, sans-serif;
      opacity: 0; transform: translateY(4px); transition: opacity 150ms ease, transform 150ms ease;
    }}
    .feedback.visible {{ opacity: 1; transform: none; }}
    .feedback strong {{ display: block; font-size: 16px; }}
    @media (max-height: 700px) {{
      .content {{ gap: 8px; }} .question-image {{ height: 220px; }}
      .question-card {{ padding: 10px; }} .answer {{ min-height: 56px; }}
    }}
    @media (min-width: 481px) {{ .app {{ box-shadow: 0 0 40px rgba(0,0,0,.45); }} }}
    @media (prefers-reduced-motion: reduce) {{ * {{ transition: none !important; }} }}
  </style>
</head>
<body>
  <main class="app">
    <img class="scene" src="{html.escape(background)}" alt="">
    <div class="veil"></div>
    <div class="content">
      <header class="header">
        <button class="icon-button" id="back" type="button" aria-label="Back">&#8592;</button>
        <div class="title"><strong>{html.escape(plan.brief.title)}</strong><span>{html.escape(plan.visual_design.theme_name)}</span></div>
        <div class="score" aria-label="Score"><span aria-hidden="true">&#9733;</span><span id="score">0</span></div>
      </header>
      <section aria-label="Quiz progress">
        <div class="progress-label">Question 1 of 1</div>
        <div class="progress"><img class="progress-track" src="{html.escape(progress_track)}" alt=""><img class="progress-marker" src="{html.escape(progress_marker)}" alt=""></div>
      </section>
      <section class="question-card">
        <div class="prompt-row"><h1>{html.escape(question.prompt_text)}</h1><button class="icon-button" id="speak" type="button" aria-label="Read question aloud">&#128266;</button></div>
        <img class="question-image" src="{html.escape(question_image)}" alt="{html.escape(plan.brief.subject)}">
      </section>
      <section class="answers" aria-label="Answer choices">{options}</section>
      <div class="feedback" id="feedback" role="status" aria-live="polite"></div>
    </div>
  </main>
  <script>
    const quiz = {runtime_json};
    const answers = [...document.querySelectorAll('.answer')];
    const feedback = document.getElementById('feedback');
    function emit(type, detail = {{}}) {{
      const message = {{ source: 'quiz-harness', type, bundleId: quiz.bundleId, ...detail }};
      window.parent.postMessage(message, '*');
      window.dispatchEvent(new CustomEvent(type, {{ detail: message }}));
    }}
    function speak() {{
      if (!('speechSynthesis' in window)) return;
      speechSynthesis.cancel();
      speechSynthesis.speak(new SpeechSynthesisUtterance(quiz.narration));
    }}
    document.getElementById('speak').addEventListener('click', speak);
    document.getElementById('back').addEventListener('click', () => emit('quiz_back'));
    answers.forEach((button) => button.addEventListener('click', () => {{
      if (button.disabled) return;
      const optionId = button.dataset.optionId;
      const correct = optionId === quiz.correctOptionId;
      answers.forEach((answer) => {{
        answer.disabled = true;
        if (answer.dataset.optionId === quiz.correctOptionId) answer.classList.add('correct');
      }});
      if (!correct) button.classList.add('incorrect');
      document.getElementById('score').textContent = correct ? '10' : '0';
      feedback.innerHTML = `<strong>${{correct ? quiz.successMessage : 'Good try!'}}</strong>${{quiz.explanation}}`;
      feedback.classList.add('visible');
      emit('quiz_answered', {{ questionId: quiz.questionId, optionId, correct }});
      emit('quiz_complete', {{ score: correct ? 10 : 0, maxScore: 10 }});
    }}));
    window.QuizHarness = {{ metadata: quiz, speak }};
    emit('quiz_ready', {{ questionId: quiz.questionId }});
  </script>
</body>
</html>
'''


def write_bundle_files(
    *,
    document: PlanDocument,
    asset_manifest: dict[str, Any],
    bundle_dir: Path,
) -> Path:
    bundle_dir.mkdir(parents=True, exist_ok=True)
    (bundle_dir / "index.html").write_text(
        render_html(document, asset_manifest), encoding="utf-8"
    )
    (bundle_dir / "plan.json").write_text(
        document.model_dump_json(indent=2) + "\n", encoding="utf-8"
    )
    files: list[dict[str, Any]] = []
    for path in sorted(bundle_dir.rglob("*")):
        if path.is_file() and path.name not in {"bundle.json"}:
            files.append(
                {
                    "path": path.relative_to(bundle_dir).as_posix(),
                    "bytes": path.stat().st_size,
                    "sha256": _sha256(path),
                }
            )
    metadata = {
        "schema_version": "1.0",
        "bundle_id": bundle_id(document),
        "bundle_version": 1,
        "title": document.plan.brief.title,
        "description": document.plan.brief.short_description,
        "category": document.request.category,
        "subject": document.request.subject,
        "language": document.request.language,
        "age_min": document.request.age_min,
        "age_max": document.request.age_max,
        "question_count": len(document.plan.questions),
        "entrypoint": "index.html",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "files": files,
    }
    (bundle_dir / "bundle.json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=True) + "\n", encoding="utf-8"
    )
    zip_base = bundle_dir.parent / bundle_dir.name
    archive = shutil.make_archive(str(zip_base), "zip", root_dir=bundle_dir)
    return Path(archive)
