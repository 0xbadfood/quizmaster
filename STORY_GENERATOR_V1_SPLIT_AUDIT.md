# Story Generator V1 Quiz Split Audit

This note records issues found while porting the emergency free-quiz bundle
splitter into Quizmaster. It applies to
`story_generator/content_delivery/create_free_quiz_variants.py` and
`story_generator/content_delivery/app.py`, verified on 2026-08-08.

## Remaining Release Blockers

### All answer images are retained

`collect_free_paths()` initially retains every file except `bundle.json`,
`source/`, `quizzes/`, and question/explanation audio. That means every
`assets/answers/*` image is already in `keep` before the function adds the answer
images referenced by the free quiz.

Exclude `assets/answers/` during the initial pass, then add back only paths found
through the selected quiz's `answer_assets` map and choices.

### Full inventory metadata remains visible

The unchanged `category.json` still contains `source_banks` and the category-wide
`answer_assets` map. The source files themselves are absent, but this exposes
locked bank sizes, paths, and the complete answer-object inventory.

Remove `source_banks` and the top-level `answer_assets` map from the free ZIP's
runtime `category.json`. Playable quiz JSON already carries its required answer
asset map.

## Confirmed Fixed

- Missing free variants fail closed with `404`; they do not fall back to the full
  record.
- Catalog metadata points to variant-stable download URLs. Legacy entitlement-
  dependent routes use private caching, while the explicit full route requires a
  full-library entitlement.

## Hardening

- Write updated `record.json` atomically instead of using `write_text()` directly.
- Treat a missing selected quiz payload as a terminal split failure.
- Assert that the free ZIP contains no `source/` files, locked quiz JSON, locked
  question/explanation audio, or unreferenced answer images.
- Verify `bundle.json.files` exactly matches the ZIP contents other than
  `bundle.json`.
