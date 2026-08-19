# Quizmaster video renderer

The renderer creates portrait or landscape MP4 videos from a published category
bundle. It derives timing from audited narration durations, shows a fixed five-second
audible decision timer, replaces the question with a correct-answer panel, and exposes
the full category background between questions. There is intentionally no end screen.

```bash
./create_video \
  --category space \
  --difficulty beginner \
  --landscape \
  --set 1 \
  --questions 1-10 \
  --output-dir ./video-output
```

Use `--portrait` for `1080x1920` or `--landscape` for `1920x1080`. The question
selector accepts ranges and lists such as `1-10`, `3-6`, or `1,3,5-7`. Partial
videos retain their original position in the ten-question set.

Landscape creation fails before rendering unless the current bundle contains a
landscape background or an approved landscape background exists in the category
workspace. Portrait rendering uses the required Flutter runtime background. Shared
question, answer, progress, and explanation assets come from the bundle when present
and otherwise from `visual_quiz_qwen/global/assets/video/`.

The default scale is full production resolution. `--scale 0.5` and `--scale 0.25`
are intended only for review renders.
