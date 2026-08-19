# Quizmaster Remotion prototype

This prototype renders one published 10-question quiz bundle as a vertical video.
It derives timing from the audited narration durations, shows a fixed five-second
decision timer, reveals only the correct answer, and exposes the full category
background between questions. There is intentionally no end screen.

```bash
cd video_renderer
npm install
npm run prepare:geography
npm run studio
npm run render:preview
```

The preview renders at `540x960`. Use `npm run render` for the full `1080x1920`
version after approving the motion and layout.
