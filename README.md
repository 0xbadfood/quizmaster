# Quizmaster

This repository owns the Quizmaster production pipeline, delivery API, Studio UI,
and Flutter client:

- `quiz_harness/`, `scripts/`, and `webui/` contain the quiz authoring and delivery stack.
- `app/` is the Quizmaster Flutter fork of StoryVault. It opens without customer
  login and treats the development catalog as fully accessible.
- `dist/category_bundles/` is generated deployment state and is not committed.

The original ten published categories were inherited by Story Generator for its V1
release. `flora-and-fauna` was produced afterward and remains Quizmaster-only unless
it is deliberately migrated later.

## Bundle variants

Published full bundles remain the canonical Quizmaster artifacts. Generate a
one-beginner-quiz compatibility variant for each current category with:

```bash
python3 scripts/create_quiz_bundle_variants.py --force
```

The command records both `access_variants.full_library` and
`access_variants.free` without changing the top-level full bundle. Compatibility
archives contain only the selected quiz and its referenced answer and narration
assets. The Quizmaster delivery API always resolves the full-library variant and
reports `access.has_full_access: true`.

The emergency Story Generator split has separate V1 hardening notes in
[`STORY_GENERATOR_V1_SPLIT_AUDIT.md`](STORY_GENERATOR_V1_SPLIT_AUDIT.md).

## Development

Run the API and Vite UI separately:

```bash
uv run uvicorn quiz_harness.webapi:app --host 0.0.0.0 --port 9061
cd webui && npm run dev
```

Open `http://localhost:9060`.

## Caddy deployment

Build the UI, then expose only the FastAPI process. It serves the API, generated
artifacts, quiz bundles, and the compiled UI from one origin.

```bash
cd webui && npm run build
uv run uvicorn quiz_harness.webapi:app \
  --host 10.8.0.2 --port 9061 \
  --proxy-headers --forwarded-allow-ips=10.8.0.1
```

Example Caddy route:

```caddyfile
quiz.example.test {
    reverse_proxy 10.8.0.2:9061
}
```

The repository also includes [`deploy/quiz.service`](deploy/quiz.service). Install
it as `/etc/systemd/system/quiz.service`, then enable it with
`systemctl enable --now quiz.service`.

Configuration is available through `QUIZ_DATABASE_PATH`, `QUIZ_ASSET_ROOT`,
`QUIZ_BUNDLE_ROOT`, `QUIZ_VLLM_BASE_URL`, `QUIZ_MAGEFLOW_BASE_URL`,
`QUIZ_IMAGESTUDIO_BASE_URL`, `QUIZ_ADMIN_USERNAME`, and `QUIZ_ADMIN_PASSWORD`.

### Studio provider administration

The Admin workspace stores ImageStudio, OpenAI Images, OpenAI-compatible LLM,
and VibeVoice connections in SQLite. API keys are encrypted with Fernet before
they are written to the database; only a masked suffix is returned to the UI.
Set `QUIZ_SECRET_KEY` to a stable Fernet key in production, or preserve
`data/.provider_secret_key`, which is generated with owner-only permissions on
first startup. Losing both values makes stored provider credentials unreadable.

Provider tests run as durable background jobs and retain their progress and result
history in SQLite. Model-capable endpoints are discovered during the test. The
VibeVoice test additionally renders a short MP3 using the configured reference
audio, language, and CFG scale.

### Studio question bank

The Questions stage reads the production bank files under
`visual_quiz_qwen/<category>/banks/` and provides pagination, search, difficulty,
allocation, and review filters. Review decisions and immutable edit history are
stored in SQLite. Allocated questions are content-locked because existing quiz sets
reference them; reserve questions can be edited or rejected safely.

The Import action validates each question independently and retains valid entries
when other entries fail. The Generate action uses either the configured OpenAI API
connection or an OpenAI-compatible LLM connection from Admin. The OpenAI connection
reuses its encrypted API key while retaining separate image and question model
defaults. Generation requests candidate headroom, rejects invalid or
exact duplicate candidates locally, and appends only the requested number of valid
questions. Generation runs as a durable Studio job, including its raw candidates,
provider, model, and validation result in the retained job record.

### Studio quiz sets

The Sets stage reads set documents under `visual_quiz_qwen/<category>/sets/` and
combines them with review state stored in SQLite. It reports safe optional selection
capacity for each difficulty; ten sets per difficulty is a recommended maximum, not
a pipeline gate. Selection uses a configured OpenAI-compatible local LLM to choose
ten questions from each deterministic batch of fifteen candidates.

Set creation is append-only and checkpoints after every completed set. Existing
allocations are preserved, and each checkpoint verifies that the source bank has not
changed. An insufficient candidate batch consumes nothing and moves to the queue end;
if a later set still fails, earlier sets remain committed and the job reports partial
success with the next set number. Reviewers can approve, flag, or reject a set without
modifying the set document. Model, provider, seed, policy, and complete set payload
are retained in revision history.

Downstream visuals, narration, bundling, and publishing use the selected sets that
actually exist. Narration readiness is calculated as ten audio pairs per selected
set, and a category can be published with fewer than ten sets at either difficulty.

### Studio audio

The Audio stage inventories question narration and explanation clips for every
selected set. Operators can filter by difficulty or audit state, play either clip,
select missing or attention items in bulk, and regenerate an individual clip from
the inspector. Generation uses the selected VibeVoice connection and runs as a
durable Studio job.

Existing unaudited MP3s are transcribed in place first. VibeVoice is called only for
missing, stale, explicitly replaced, or Whisper-rejected clips. Audit scores,
coverage, WER, transcripts, failure reasons, and render attempts are retained in the
category audio manifest. Terminal failures are checkpointed and reported as partial
success so the remaining clips can be reviewed and retried independently.
After listening to an individual failed clip, a reviewer can clear its attention
state from that clip's right-hand inspector. The manifest retains the original
Whisper metrics, transcript, failure reason, and a timestamped manual-acceptance
record. The decision is reversible with **Restore audit result**. Missing, unaudited,
or stale clips cannot be manually accepted, and regenerating a clip replaces the
manual decision with its new automatic audit.

### Studio publishing

The Publish stage validates the selected sets, category and answer visuals, shared
presentation assets, and both passing narration audits for every unique question.
Pending visual review remains a pilot warning; missing artifacts, duplicate question
allocation, sets that do not contain exactly ten questions, and incomplete audio are
release blockers. Publishing is disabled while another production job is active for
the category.

A successful publish creates an immutable numbered ZIP under
`dist/category_bundles/<category>/versions/`, verifies its SHA-256 digest, and updates
the category's `current.json` pointer. Unchanged content reuses the current version
unless the operator explicitly requests a new version. The release history supports
authenticated ZIP downloads and activation of an earlier immutable version; the
delivery API observes the updated pointer without a restart.

### Automated category pipeline

The production CLI can take a new category from metadata and a user-supplied
background through question generation, set selection, media generation, and an
immutable published bundle. Start from
[`examples/category-metadata.example.json`](examples/category-metadata.example.json),
then run:

```bash
python3 scripts/run_category_pipeline.py \
  --metadata examples/category-metadata.example.json \
  --background /path/to/category-background.png
```

The default workflow requests up to 150 beginner and 150 intermediate questions
from `gpt-5.6-luna` through the configured `openai-images` connection. Each request
contains at most 50 candidates, and the bank stage stops after six persisted batch
attempts in total if local validation and deduplication cannot fill both levels. The
scheduler alternates levels, producing three calls per level in the normal case. Qwen then
selects as many ten-question sets as the usable banks permit, up to ten per
difficulty. Partial set selections remain committed.

After selection, two workers run concurrently. One generates and Whisper-audits
VibeVoice narration; the other asks Qwen for selector, tile, and answer prompts and
renders all missing images. OpenAI Images is the default selector/tile provider and
ImageStudio is the default answer provider. The supplied background is normalized
and registered as the category background.

Narration receives three Whisper repair attempts. A clip that still fails is
rerendered until the reported duration is greater than zero and no more than 12
seconds. Every VibeVoice narration clip receives 800 ms of trailing silence during
MP3 encoding to avoid an end click or clipped final word. Publishing starts only
after both media workers finish and all normal release gates pass.

Progress and batch attempts are written atomically to
`visual_quiz_qwen/<category>/pipeline-run.json`. Re-running the same command resumes
from existing banks, sets, prompts, images, and narration instead of discarding
completed work. Provider IDs and models can be overridden; use
`python3 scripts/run_category_pipeline.py --help` for the full list. By default the
pipeline refuses to compete with active Studio jobs.

### Generated category backgrounds

Create a production-shaped `941x1672` portrait background with either an enabled
OpenAI Images or ImageStudio connection:

```bash
python3 scripts/generate_quiz_background.py \
  --category "Indian Independence" \
  --display-title "INDIAN INDEPENDENCE QUIZ" \
  --provider openai-images \
  --quality medium \
  --visual-brief "Use the Red Fort, India Gate, a charkha, and tricolor accents."
```

Use `--provider imagestudio-local --model ernie-turbo` for the local path. The
provider value is a Studio connection ID, so other enabled OpenAI Images or
ImageStudio connections work without code changes. `--model`, `--seed`,
`--subtitle`, `--prompt`, and `--output` support controlled variants. The default
output is under `background_previews/` and includes a generation manifest beside
the PNG. The PNG can be passed directly to the category pipeline's `--background`
argument after review.

## Question-set pilot

Generate one independently validated Animals set at each difficulty:

```bash
python3 -m quiz_harness questions --category Animals --difficulty all
```

Qwen drafts 14 candidates per difficulty and Laguna selects the strongest ten,
creating replacements only when the candidate pool contains fewer than ten valid
questions. Raw responses, review output, run metadata, and final content-only JSON are
written under `question_sets/<category>/<difficulty>/`.

Phase 2 is the default. It gives the prior category+difficulty question bank to the
drafter, removes high-confidence duplicates locally, validates surviving candidates
one at a time with Laguna, promotes valid reserves, and requests replacements only
when fewer than ten questions survive. Generate five consecutive set numbers with:

```bash
python3 -m quiz_harness questions \
  --category Animals --difficulty all --set-number 3 --sets 5
```

Use `--pipeline phase1` only to reproduce the original set-level validator experiment.

Audit all finalized sets in a category for cross-set duplication:

```bash
python3 -m quiz_harness questions-audit --category Animals
```

The JSON report distinguishes likely duplicates from exact topic-key collisions and
is written to `question_sets/<category>/audit.json`.

## Visual quiz v1

The visual v1 workflow uses OpenAI to create a large four-choice source bank, then
uses Qwen to select strict ten-question sets. It finally extracts one canonical
image record for every answer choice used by those sets. This workflow is
separate from the experimental three-choice question pipeline above.

The generator reads `OPENAI_API_KEY` or `OPENAI_TOKEN`. The current profile uses the
latter, so load it before running the scripts:

```bash
source ~/.profile
python3 scripts/generate_openai_visual_bank.py
python3 scripts/create_qwen_visual_sets.py --strictness strict
python3 scripts/extract_visual_animals.py \
  --root visual_quiz_qwen --include-available
```

Generation defaults to 120 beginner and 120 intermediate questions with
`gpt-5.6-luna`. The Animals prompt explicitly excludes birds. For each set, the
selection stage deterministically draws 15 questions from the remaining stack. Qwen
selects the strongest 10 and returns the other 5 to the end of the stack. Correct
answer positions are rebalanced while question and choice text remain unchanged.

The default Qwen endpoint is `http://10.8.0.5:8001/v1`. Strict mode permits Qwen to
stop with an `insufficient_quality` decision instead of accepting weak material. Use
`--strictness balanced` only when reviewing the saved failure shows that minor
wording, distractor, or difficulty issues are blocking otherwise sound questions.
Selection prompts, raw responses, decisions, and resumable run state are stored under
`visual_quiz_qwen/animals/selections/`.

The asset catalog intentionally includes choices from both selected and reserve
questions. This allows a human reviewer to reject a question and substitute a bank
reserve without starting another image-generation run. Repeated animals share the
same canonical asset.

Generate the first-pass animal answer images with the local ImageStudio Ernie engine:

```bash
python3 scripts/generate_answer_images.py
```

The runner creates 768x768 WebP files under
`visual_quiz_qwen/animals/assets/animals/`, checkpoints every image in
`answer-image-manifest.json`, and reuses valid cached files on subsequent runs. All
generated assets remain pending human review. Regenerate a rejected animal without
disturbing the rest of the batch with:

```bash
python3 scripts/generate_answer_images.py --animal-key aardvark --force
```

### Category and global images

Category images use an editable, webapp-ready spec and a versioned OpenAI manifest.
Generate the three category-specific prompt classes with Qwen before image generation:

```bash
python3 scripts/generate_qwen_image_prompts.py
```

Qwen defaults to `http://10.8.0.5:8001/v1`. The planner creates one coordinated
category-selector prompt, one independently seeded prompt for every quiz set that
actually exists, and resumable answer-prompt batches. The result is stored in
`image-prompt-plan.json`; every raw request and response is retained under
`prompt-planning/`. Tile subjects come from the category as a whole and are not tied
to the correct answers in one quiz set.

The Studio Visuals stage is the primary operator workflow. It derives its inventory
from the selected sets, so every set produces exactly one tile while the number of
sets remains flexible. Upload the supplied runtime background, run **Plan prompts**,
then select assets for generation. Both the configured OpenAI Images and ImageStudio
connections can generate the category selector, quiz tiles, and answer-choice
objects; the operator chooses the provider for each job. **Select all tiles** and
**Select all answer images** create one asset-class batch for the shared Generate
action. Each prompt remains editable, generated assets can be approved, rejected, or
regenerated, and all generation work runs as durable jobs. The background is
approved as a user upload and is deliberately excluded from prompt planning and
generation.

Before planning, the inventory displays deterministic fallback prompts. Tile
fallbacks are derived from category/set metadata, while answer fallbacks are strict
single-subject templates. The Qwen planning pass replaces them with coordinated,
category-aware prompts for the category selector, tiles, and answer images.

Answer descriptions remain `pending_review`. The ImageStudio runner uses its
conservative exact-label fallback until a prompt is approved. Use
`--use-pending-prompts` only for an explicit experiment.

Render an isolated five-image selector/tile/answer sample with Ernie without touching
production assets:

```bash
python3 scripts/render_image_prompt_previews.py
```

Use `--asset-id answer_alligator --seed-offset 1 --force` to test the same webapp-style
regeneration path for one failed image.

For Animals, import the user-approved runtime background and generate the category
selector plus one tile per existing quiz set with GPT Image 2 at medium quality:

```bash
python3 scripts/generate_openai_category_images.py \
  --background "/path/to/animal-runtime-background.png"
```

The resulting `category-image-spec.json` is the editable prompt/provider contract.
Use `--asset-id tile_beginner_01 --force` to regenerate one rejected tile while
retaining its earlier versions. OpenAI-generated images remain
`generated_pending_review`; imported backgrounds are recorded as approved uploads.

Generate the shared settings and speaker controls with:

```bash
python3 scripts/generate_openai_global_images.py
```

Quiz progress is rendered dynamically in Flutter rather than pre-rendered into ten
images. `visual_quiz_qwen/global/progress-style.json` defines unanswered, current,
correct, and incorrect marker colors, connector colors, geometry, label format, and
animation timing. This lets every answered question independently become green or
red without requiring image permutations.

Generate the shared feedback effects, praise pool, question narration, and answer
explanations through the local VibeVoice chunk API with:

```bash
python3 scripts/generate_quiz_audio.py \
  --endpoint http://127.0.0.1:8092 \
  --reference-audio amit.wav
```

The command checkpoints every batch and resumes by question/text hash. Category
narration is mono 24 kHz MP3 at 80 kbps; the source reference WAV is generator
input only. Use `--limit-questions 1` for a voice-quality probe. The command also
syncs the shared effects and the 12 correct/12 incorrect quizmaster response pools
into `Storyvault_app/assets/audio/`. Flutter owns these common assets so category
bundles do not duplicate them. Both outcomes play the relevant SFX, a random
quizmaster response, then the category-specific explanation.

Audio generation performs an automatic Faster Whisper review by default. Each MP3
is transcribed and compared with its intended text using coverage, word-error-rate,
length, repetition, and speech-coverage checks adapted from Story Generator's chunk
auditor. A failed clip is rerendered individually up to two times; clips that already
passed are not repeated. Final failures are checkpointed for targeted retry, while
every audit and render attempt is retained in the audio manifest. The persistent Whisper process uses
the cached `Systran/faster-whisper-base.en` model from Story Generator's Whisper
environment. Use `--skip-audio-audit` only for diagnosis, or adjust the
`--audit-*-threshold` options for a reviewed exception.

The VibeVoice Admin profile stores the reference WAV and its exact transcript as
separate fields. **Upload WAV** validates a 2-120 second PCM WAV and copies it into
Quiz Studio's managed provider storage. The default Amit transcript is: "Mumbai is
the financial, commercial and the entertainment capital of India. It is also one of
the world's top ten centres of commerce in terms of global financial flow."

### Category bundle and delivery API

Build an immutable, versioned Animals category bundle after the quiz and image
assets are ready:

```bash
python3 scripts/build_category_bundle.py
```

The builder writes `dist/category_bundles/animals/current.json` and a version under
`dist/category_bundles/animals/versions/`. Unchanged content reuses the active
version. Use `--force-new-version` for an explicit release or
`--activate-version 1` to roll the current pointer back without modifying an old
bundle. Each ZIP contains the 20 quiz sets, 223 reusable answer images, category and
global presentation assets, the Flutter progress style, source banks, and checksums.

Run the read-only mobile delivery API locally with:

```bash
uvicorn quiz_harness.delivery_api:app \
  --host 0.0.0.0 --port 9070 \
  --proxy-headers --forwarded-allow-ips=10.8.0.1
```

The catalog starts at `GET /api/v1/categories`. Current and immutable bundle
metadata and downloads are exposed below `/api/v1/categories/{category}` with ETag
and cache headers. URLs in API responses are relative, so they remain valid when
Caddy on `10.8.0.1` forwards `https://quizapi.photovault.live` to
`10.8.0.2:9070`.

Install [`deploy/quizapi.service`](deploy/quizapi.service) as
`/etc/systemd/system/quizapi.service`, then enable it with:

```bash
sudo systemctl enable --now quizapi.service
```

For a quick provisional allocation that does not call Qwen, run:

```bash
python3 scripts/create_visual_quiz_sets.py
python3 scripts/extract_visual_animals.py
```

Use a separate output root when comparing a stronger OpenAI model without replacing
the Luna artifacts:

```bash
python3 scripts/generate_openai_visual_bank.py \
  --model gpt-5.6-terra --output-root visual_quiz_terra
```

OpenAI source artifacts are written beneath `visual_quiz/animals/`. Selected V1 sets,
remaining banks, selection records, and the deduplicated image inventory are written
beneath `visual_quiz_qwen/animals/`.
