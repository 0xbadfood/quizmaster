# Video Presentation Asset Inventory

The category pipeline produces two background orientations:

| Role | Size | Scope | Bundle metadata |
| --- | ---: | --- | --- |
| `runtime_background` | 941x1672 | Category | `presentation.runtime_background` |
| `video_background_landscape` | 1920x1080 | Category | `presentation.video_background_landscape` |

The landscape background has an embedded category title and subtitle. Its center is
kept calm for a wide question panel, while the lower center is reserved for four
answer cards in one row. Category decoration belongs at the outer edges.

## Reusable Images

Generated at medium quality through the configured OpenAI Images provider and stored
under `visual_quiz_qwen/global/assets/video/`:

| Asset ID | Output size | Purpose |
| --- | ---: | --- |
| `video_progress_plaque` | 1200x320 | Blank plate for `QUESTION n OF 10` |
| `video_question_frame` | 1600x640 | Blank wide question panel |
| `video_answer_frame` | 760x820 | Blank answer image and label card |
| `video_explanation_frame` | 1600x1100 | Correct-answer and explanation reveal |
| `video_badge_purple` | 320x320 | Blank badge for `Q` or an answer letter |
| `video_badge_green` | 320x320 | Blank badge for `Q` or an answer letter |
| `video_badge_orange` | 320x320 | Blank badge for `Q` or an answer letter |
| `video_badge_blue` | 320x320 | Blank badge for `Q` or an answer letter |

All reusable assets are alpha-enabled WebP files. The source specification and
generation history live in `visual_quiz_qwen/global/global-image-spec.json` and
`visual_quiz_qwen/global/global-image-manifest.json`.

## Dynamic Content

Remotion renders progress text, `Q`, `A` through `D`, questions, answer labels, and
explanations. Badge colors are deterministically shuffled per question. No textual
permutation is baked into an image.

The machine-readable contract is generated at
`visual_quiz_qwen/global/video-presentation-inventory.json` and is included in new
category bundles as `runtime/video-presentation-inventory.json`.
