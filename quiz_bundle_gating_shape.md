# Recommended Quiz Bundle Shape For Individual Quiz Gating

This document is a handoff for the quiz generator owner. The goal is to make quiz gating a first-class output of `quiz_generator`, not a post-processing patch in StoryVault/content delivery.

## Problem

StoryVault V1 needs this access model:

- Free users can see every quiz tile, but can play only approved free quizzes.
- Full-library users, including subscription users and toy-code users, can play all quizzes.
- The server must not rely only on Flutter UI locking. Free users should not receive locked quiz question payloads/audio in their downloadable ZIP.
- The app should still have a rich offline visual experience: locked tiles, category images, and difficulty filters should remain visible after download.

The current emergency implementation creates a `free_variant` ZIP after the normal bundle is built. That works, but it is the wrong long-term owner. The quiz generator should emit both full and free variants directly.

## Required Design

Each category should publish one logical bundle version with multiple access variants.

Recommended variants:

- `free`: contains all category/listing UI assets, all quiz tile assets, and only the playable free quiz payload/audio.
- `full_library`: contains all category/listing UI assets, all quiz tile assets, all quiz payloads/audio, and all required answer assets.

Both variants must keep the same visible quiz catalog in `category.json` so the Flutter app can show locked tiles. The difference is which quiz payload files and audio files are physically present.

Free selection must have one canonical production source. Recommended source: `category.json.access_policy.free_quiz_ids`. The generator should derive per-quiz `access`, legacy fallback fields, and variant contents from that one list.

## ZIP Layout

Keep the current layout. Do not introduce another top-level nesting layer.

```text
bundle.json
category.json
runtime/progress-style.json
assets/category/<category_selector>.webp
assets/category/<runtime_background>.png
assets/global/settings_button.webp
assets/global/speaker_on_button.webp
assets/global/speaker_muted_button.webp
assets/tiles/<difficulty>_<number>.webp
assets/answers/<answer_key>.webp
assets/audio/questions/<question_id>.mp3
assets/audio/explanations/<question_id>.mp3
quizzes/<difficulty>/<quiz_id>.json
source/...  # full_library variant only; forbidden in free variant
```

Variant-specific rules:

- Full ZIP includes every `quizzes/...json`, every referenced question/explanation audio file, and every answer image needed by all quizzes.
- Free ZIP includes every tile/category/global/runtime asset needed to render the category screen.
- Free ZIP includes only free/playable `quizzes/...json`.
- Free ZIP includes only audio and answer assets referenced by those free/playable quiz JSON files.
- Free ZIP must not include `source/...`. Source banks can contain locked question content and are not runtime assets.
- `bundle.json` must list every file that exists in that ZIP except `bundle.json` itself.

## category.json

`category.json` should remain the visual index for the entire category, not just playable quizzes.

For v2, `category.json` should be runtime-only. Do not include top-level source indexes such as `source_banks`, and do not include top-level full answer indexes that are not needed by runtime. Per-quiz answer maps already exist inside playable quiz documents.

Recommended shape:

```json
{
  "schema_version": "category_bundle_v2",
  "minimum_renderer_version": 1,
  "category": {
    "id": "animals",
    "name": "Animals",
    "display_title": "ANIMAL QUIZ",
    "display_tag": "Animals",
    "selector_asset": "assets/category/animals_category_selector.webp"
  },
  "access_policy": {
    "schema_version": "quiz_access_policy_v1",
    "default_entitlement": "full_library",
    "free_quiz_ids": ["animals_beginner_001"],
    "legacy_renderer_v1": {
      "free_quiz_limit": 1,
      "free_quiz_difficulty": "beginner"
    }
  },
  "presentation": {
    "runtime_background": "assets/category/animals_runtime_background.png",
    "settings_button": "assets/global/settings_button.webp",
    "speaker_on_button": "assets/global/speaker_on_button.webp",
    "speaker_muted_button": "assets/global/speaker_muted_button.webp",
    "progress_style": "runtime/progress-style.json"
  },
  "difficulties": [
    {"id": "beginner", "label": "Beginner", "quiz_count": 10},
    {"id": "intermediate", "label": "Intermediate", "quiz_count": 10}
  ],
  "quizzes": [
    {
      "quiz_id": "animals_beginner_001",
      "number": 1,
      "difficulty": "beginner",
      "title": "ANIMAL QUIZ 1",
      "question_count": 10,
      "tile_asset": "assets/tiles/beginner_01.webp",
      "questions_file": "quizzes/beginner/animals_beginner_001.json",
      "access": {
        "is_free": true,
        "entitlement_required": ""
      }
    },
    {
      "quiz_id": "animals_beginner_002",
      "number": 2,
      "difficulty": "beginner",
      "title": "ANIMAL QUIZ 2",
      "question_count": 10,
      "tile_asset": "assets/tiles/beginner_02.webp",
      "questions_file": "quizzes/beginner/animals_beginner_002.json",
      "access": {
        "is_free": false,
        "entitlement_required": "full_library"
      }
    }
  ]
}
```

Compatibility notes:

- Existing Flutter builds can ignore unknown `access` and `access_policy` fields.
- Current Flutter renderer v1 has fallback logic for `free_quiz_limit=1` and `free_quiz_difficulty=beginner`.
- While supporting renderer v1, `free_quiz_ids` must resolve to exactly the first configured beginner quiz. Otherwise renderer v1 could unlock a quiz whose JSON is absent from the free ZIP.
- Future Flutter should prefer explicit `quiz.access.is_free` over count-based rules.
- Arbitrary free quiz selection requires `minimum_renderer_version: 2`.
- Do not remove locked quiz summaries from `category.json`; otherwise locked tiles disappear.

## bundle.json

Each ZIP variant needs its own `bundle.json`, because file inventory and `content_hash` differ.

Recommended additions:

```json
{
  "schema_version": "category_bundle_v2",
  "bundle_id": "animals",
  "bundle_version": 4,
  "access_variant": "free",
  "source_content_hash": "<full-library-content-hash>",
  "content_hash": "<hash-of-this-variant>",
  "minimum_renderer_version": 1,
  "quiz_count": 20,
  "question_count": 200,
  "available_quiz_count": 1,
  "available_question_count": 10,
  "free_quiz_ids": ["animals_beginner_001"],
  "entrypoint": "category.json",
  "files": [
    {
      "path": "category.json",
      "bytes": 12345,
      "sha256": "..."
    }
  ]
}
```

Field meaning:

- `quiz_count` and `question_count`: total visible category inventory.
- `available_quiz_count` and `available_question_count`: playable inventory physically present in this ZIP.
- `access_variant`: `free` or `full_library`.
- `source_content_hash`: full-library logical content hash for traceability.
- `content_hash`: variant-specific hash used by the app cache and download verification.
- `free_quiz_ids`: derived from `category.json.access_policy.free_quiz_ids`; do not maintain it independently.

## record.json

The delivery server should choose the archive variant based on the authenticated user's entitlement. Put all variant metadata in the category `record.json`.

Recommended shape:

```json
{
  "schema_version": "category_bundle_record_v2",
  "bundle_id": "animals",
  "bundle_version": 4,
  "content_hash": "<full-library-content-hash>",
  "archive_file": "versions/000004/animals-v000004.zip",
  "archive_bytes": 57181349,
  "archive_sha256": "...",
  "access_variants": {
    "free": {
      "access_variant": "free",
      "content_hash": "<free-content-hash>",
      "archive_file": "versions/000004/animals-v000004-free.zip",
      "download_url": "/api/v1/categories/animals/bundles/4/free/download",
      "archive_bytes": 34622483,
      "archive_sha256": "...",
      "available_quiz_count": 1,
      "available_question_count": 10,
      "free_quiz_ids": ["animals_beginner_001"]
    },
    "full_library": {
      "access_variant": "full_library",
      "content_hash": "<full-library-content-hash>",
      "archive_file": "versions/000004/animals-v000004.zip",
      "download_url": "/api/v1/categories/animals/bundles/4/full_library/download",
      "archive_bytes": 57181349,
      "archive_sha256": "...",
      "available_quiz_count": 20,
      "available_question_count": 200
    }
  }
}
```

Compatibility note:

- StoryVault currently supports the emergency `free_variant` field.
- Move to `access_variants.free` and `access_variants.full_library` next.
- The content API can keep a fallback from `free_variant` during migration.
- Publishing v2 records must be atomic with an entitlement-aware delivery API. A legacy API that reads top-level `archive_file` can accidentally serve full archives publicly.
- If legacy top-level archive fields remain during migration, point them to the free archive and require explicit variant selection for full access.

## current.json

No structural change is needed.

```json
{
  "schema_version": "category_bundle_pointer_v1",
  "category_id": "animals",
  "bundle_version": 4,
  "content_hash": "<full-library-content-hash>",
  "record_file": "versions/000004/record.json",
  "updated_at_utc": "..."
}
```

The pointer should refer to the logical category version. The server decides which archive variant to serve.

## Server Contract

The content API should expose the same category list endpoint for both user types.

For free users:

```json
{
  "archive_bytes": 34622483,
  "archive_sha256": "<free-archive-sha>",
  "content_hash": "<free-content-hash>",
  "bundle_download_url": "/api/v1/categories/animals/bundles/4/free/download",
  "access": {
    "has_full_access": false,
    "free_quiz_ids": ["animals_beginner_001"],
    "legacy_renderer_v1": {
      "free_quiz_limit": 1,
      "free_quiz_difficulty": "beginner"
    }
  }
}
```

For full-library users:

```json
{
  "archive_bytes": 57181349,
  "archive_sha256": "<full-archive-sha>",
  "content_hash": "<full-content-hash>",
  "bundle_download_url": "/api/v1/categories/animals/bundles/4/full_library/download",
  "access": {
    "has_full_access": true,
    "free_quiz_ids": ["animals_beginner_001"],
    "legacy_renderer_v1": {
      "free_quiz_limit": 1,
      "free_quiz_difficulty": "beginner"
    }
  }
}
```

HTTP requirements:

- Metadata responses must include `Vary: Authorization`.
- Metadata responses should use `Cache-Control: private, max-age=60, must-revalidate`.
- Archive responses must be cache-safe and immutable. Prefer explicit variant URLs:
- `/api/v1/categories/{slug}/bundles/{version}/free/download`
- `/api/v1/categories/{slug}/bundles/{version}/full_library/download`
- Both URLs should still enforce authorization: `free` can be public/auth-optional, `full_library` must require full-library entitlement.
- Do not serve different ZIP bytes from the same immutable URL based on Authorization. If that temporary compatibility path is unavoidable, archive responses must include `Vary: Authorization` and `Cache-Control: private`.

## App Behavior Expected

The Flutter app should:

- Download the category bundle returned by the server.
- Show all quiz summaries from `category.json`.
- Renderer v1: unlock the first configured beginner quiz using `legacy_renderer_v1` fallback.
- Renderer v2 and later: treat quizzes with `access.is_free=true` as playable for free users.
- Treat quizzes requiring `full_library` as locked unless the user has full access.
- Show a lock icon on locked quiz tiles.
- Open the paywall when a locked quiz is tapped.
- Never try to load `questions_file` for a locked quiz.

If a free user later becomes entitled:

- Refresh the quiz category metadata with Authorization.
- Download the full-library variant because `content_hash` and `archive_sha256` will differ.
- Replace the cached free variant with the full variant.

## Generator Implementation Checklist

1. Choose free quizzes once and write them to `category.json.access_policy.free_quiz_ids`.
2. While supporting renderer v1, validate that the free list is exactly the first configured beginner quiz.
3. Derive `quiz.access.is_free`, `quiz.access.entitlement_required`, legacy fallback fields, and variant contents from `free_quiz_ids`.
4. Build each variant from an explicit dependency graph, not by building full and deleting files.
5. Dependency graph inputs: selected quiz IDs, quiz JSON files, question IDs, referenced question/explanation audio, referenced answer keys, category UI assets, global UI assets, runtime assets, and tile assets.
6. Build the full-library staging tree from all quiz IDs.
7. Build the free staging tree from `free_quiz_ids`.
8. Keep all category/global/runtime/tile assets in the free tree.
9. Copy only free quiz JSON files to the free tree.
10. Copy only free quiz question/explanation audio to the free tree.
11. Copy only answer images referenced by free quiz JSON files to the free tree.
12. Forbid `source/...` in the free tree.
13. Write variant-specific `bundle.json` into each tree.
14. Zip each tree separately with deterministic file ordering.
15. Write one `record.json` containing both archive variants and cache-safe variant download URLs.
16. Keep `current.json` pointing to the logical version record.
17. Add tests that verify free ZIPs contain all tile images but only free question JSON/audio.

## Suggested Tests

Minimum tests:

- Free variant contains `category.json`, `bundle.json`, runtime assets, global assets, selector image, background image, and all quiz tile images.
- Free variant contains exactly the configured free quiz JSON files.
- Free variant does not contain locked quiz JSON files.
- Free variant does not contain any `source/...` path.
- Free variant does not contain top-level full answer/source indexes in `category.json`.
- Free variant contains only audio files referenced by free quiz JSON files.
- Free variant `bundle.json.files` matches files actually present in the ZIP.
- Full variant remains semantically compatible with the current runtime contract. Do not require byte/hash compatibility after schema changes.
- ZIP construction is deterministic if reproducible hashes matter: sorted paths, stable JSON formatting, stable timestamps if required.
- `record.json.access_variants.free.archive_sha256` matches the generated free ZIP.
- `record.json.access_variants.full_library.archive_sha256` matches the generated full ZIP.
- Free-user catalog metadata points to `/free/download`; full-library catalog metadata points to `/full_library/download`.
- Legacy top-level archive fields do not expose the full archive to unauthenticated users.

## Migration Recommendation

Short-term:

- Keep emitting the current full bundle.
- Add native free variant generation to `quiz_generator`.
- Emit both `free_variant` and `access_variants.free` for one release cycle if needed by StoryVault.
- Update content delivery to prefer explicit cache-safe variant URLs.
- Until that content delivery API is deployed, do not publish v2 records whose legacy top-level archive fields point to full archives.

After Flutter/content API migration:

- Drop `free_variant`.
- Keep only `access_variants`.
- Move Flutter to explicit `quiz.access.is_free` handling and bump to renderer v2 before arbitrary free quiz selection.
- Stop post-processing quiz bundles in StoryVault/content delivery.
