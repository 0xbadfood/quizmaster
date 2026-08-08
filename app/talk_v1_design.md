# Talk V1 Design: Guided Story Creation

## Product Direction

The Talk engine should not ship as an open-ended chatbot for V1. It should become the voice and interaction layer underneath a guided StoryVault feature: **Story Wizards**.

The core experience is simple:

1. The child chooses a Story Wizard.
2. The wizard speaks a question.
3. The app shows large playful choices, such as floating buttons, balloons, balls, stars, leaves, bubbles, or cards.
4. The child taps one answer.
5. The app records that choice as a story slot.
6. After a short sequence of choices, the server generates a personalized story.
7. The app streams and plays the story using the existing Talk/TTS playback path.

This keeps the experience conversational in output, but deterministic in input. The child feels they are talking to a character, but V1 does not depend on noisy child ASR, speech inference, ambiguity handling, or retry loops.

## Why Not Open Chat For V1

Open chat is flexible, but it creates problems that are unnecessary for the first release:

- Child ASR is unreliable, especially with accents, background noise, incomplete words, and playful speech.
- Free-form responses require inference, confirmation, retries, and error handling.
- Open-ended conversation can drift away from StoryVault's core promise: stories and rhymes.
- Safety and cost are harder to bound.
- Generated output is less cacheable and harder to review.

Guided Story Creation gives us a product-coherent use of Talk: the child helps create a story, then listens to it.

## Server-Owned Automata

Each wizard should be a server-owned decision tree. Flutter should render a generic wizard state and should not hardcode the story logic.

The server owns:

- Wizard IDs, names, descriptions, and availability.
- Step order and branching rules.
- Spoken prompt text.
- Choice pools.
- Slot names and slot values.
- Age-band eligibility.
- Presentation hints, such as jungle, space, bedtime, ocean, fairy, or vehicle themes.
- Randomization rules.
- Final story-generation prompt template.

Flutter owns:

- Rendering the wizard state.
- Playing wizard prompts through the Talk/TTS path.
- Showing playful choices.
- Sending selected choice IDs back to the server.
- Playing the final generated story.

This keeps the client stable while allowing wizard content to evolve server-side.

## V1 Interaction Shape

For V1, each wizard should have a fixed decision tree with enough choice variety to avoid repetition.

Recommended starting point:

- 5 wizards.
- 5 to 6 steps per wizard.
- 10 to 20 possible choices per step.
- 3 to 5 choices displayed per step.
- No free-form voice answers required.
- Optional child name can be entered by parent or skipped.

Example wizard categories:

- Magic Bedtime.
- Jungle Adventure.
- Space Explorer.
- Ocean Rescue.
- Science Helper.

The wizard can ask questions such as:

- Who should lead the story?
- Where should the story begin?
- Who should help the hero?
- What problem should they solve?
- What magical or special object should appear?
- How should the story feel?

The app should show options in a game-like way rather than as a plain form. For example, a jungle wizard can use floating leaves or animals, while a space wizard can use orbiting planets.

## API Shape

Only a small API surface is needed.

```text
GET  /story-wizards
POST /story-wizard-sessions
POST /story-wizard-sessions/{session_id}/advance
POST /story-wizard-sessions/{session_id}/generate
```

`GET /story-wizards` returns the available server-owned wizards.

`POST /story-wizard-sessions` starts a wizard session and returns the first state.

`POST /story-wizard-sessions/{session_id}/advance` accepts a selected choice and returns the next state.

`POST /story-wizard-sessions/{session_id}/generate` creates the final story when the session is complete.

Example in-progress response:

```json
{
  "session_id": "abc123",
  "wizard_id": "jungle_rescue",
  "status": "in_progress",
  "step_id": "companion",
  "prompt": "Who should help in the jungle?",
  "presentation": {
    "layout": "floating_choices",
    "theme": "jungle",
    "choice_style": "leaves"
  },
  "choices": [
    {
      "choice_id": "parrot",
      "label": "Talking parrot",
      "image_hint": "bright green parrot"
    },
    {
      "choice_id": "tiger_cub",
      "label": "Tiger cub",
      "image_hint": "friendly tiger cub"
    }
  ]
}
```

Example completion response:

```json
{
  "session_id": "abc123",
  "wizard_id": "jungle_rescue",
  "status": "complete",
  "requirements": {
    "age_band": "5-8",
    "story_length": "short",
    "tone": "warm_adventurous",
    "slots": {
      "hero_type": "little elephant",
      "setting": "moonlit jungle",
      "companion": "talking parrot",
      "problem": "lost river path",
      "special_object": "glowing seed",
      "ending_style": "happy"
    }
  }
}
```

## Final Story Generation

The existing Talk persona/system-prompt path can be reused for final story generation. The difference is that the prompt receives a structured requirements JSON instead of an open conversation transcript.

The final prompt should require:

- Age-appropriate vocabulary.
- StoryVault-safe content.
- Clear beginning, middle, and ending.
- Respect for every selected slot.
- No scary, violent, romantic, political, or adult themes.
- A complete story in one pass.

The server can stream the generated story text. The app can speak it through the current on-device TTS playback path.

## Future Flexibility

This design keeps V1 deterministic without pinning us down.

The `/advance` endpoint can start as a fixed decision tree, but later evolve internally without Flutter changes.

Future implementations can replace or enrich the transition logic with:

- LLM-selected next questions.
- Adaptive choices based on previous answers.
- Personalized memory.
- Parent-defined themes.
- Age-specific branching.
- Local small-model slot handling on capable devices.
- Hybrid deterministic plus LLM decision trees.

Because Flutter only renders server-returned wizard states, the client does not need to know whether the next state came from a static JSON tree, a server LLM, or a local model.

## V1 Recommendation

For V1, do not use child speech as input for story requirements. Use the Talk engine only for speaking prompts and narrating the generated story.

The first implementation should be:

1. Server-owned wizard configs.
2. Flutter generic wizard renderer.
3. Tap-only choices.
4. Structured requirement JSON.
5. Server-side final story generation.
6. Existing on-device TTS playback.

This gives StoryVault a coherent interactive feature while avoiding the highest-risk pieces of open-ended voice chat.

## Implementation Plan

### Phase 1: Persona Refresh

Replace open-chat personas with a small set of Story Wizard personas. This is a server-data change and should not require Flutter changes.

Active V1 personas:

- `bedtime_dream_keeper`: soft bedtime stories.
- `jungle_story_guide`: animal and jungle adventures.
- `magic_fairy_tale_maker`: gentle fairy tales.
- `space_adventure_captain`: rocket and planet stories.
- `ocean_explorer`: sea and island stories.
- `silly_story_spinner`: funny harmless stories.

Each persona should have:

- A portrait and thumbnail.
- A selected voice-library sample.
- A StoryVault-safe system prompt.
- A welcome prompt that frames the experience as guided story creation.
- Metadata hinting that the persona is a story wizard, not an open-ended chatbot.

For the initial rollout, keep `voice.photovault.live` as the active endpoint. A later clone to `voice.toystech.in` is useful only after the wizard APIs are stable enough to justify a separate production service.

### Phase 2: Server-Owned Wizard Automata

Add wizard configs on the voice server, separate from persona JSON. Persona JSON describes the character; wizard JSON describes the state machine.

Suggested layout:

```text
personas/*.json
wizards/*.json
```

The wizard config should own:

- Step order.
- Prompt text.
- Choice pools.
- Slot mappings.
- Display hints.
- Completion rules.
- Age-band eligibility.

The first implementation should use fixed JSON decision trees. The endpoint shape should still be generic enough that the transition engine can later become LLM-driven.

### Phase 3: Wizard API

Add a small API family to the voice server:

```text
GET  /api/story-wizards
POST /api/story-wizard-sessions
POST /api/story-wizard-sessions/{session_id}/advance
POST /api/story-wizard-sessions/{session_id}/generate
```

The `/advance` endpoint should accept the selected `choice_id` and return the next renderable state. Flutter should not calculate the next step.

The `/generate` endpoint should create the final structured requirements JSON and call the existing LLM path to produce the story.

### Phase 4: Flutter Branch

Create a Flutter branch when the server state API exists.

Recommended branch name:

```text
talk_wizard_v1
```

Flutter should:

- Fetch available wizards.
- Start a wizard session.
- Render prompt text and large tappable choices.
- Send selected choice IDs to the server.
- Render the next state returned by the server.
- Call final story generation when the session is complete.
- Speak prompts and generated story text through the existing Talk/TTS path.

No child ASR should be required for V1 wizard input.

### Phase 5: Final Story Generation

Reuse the existing persona/system-prompt path for story writing, but pass structured requirements instead of an open chat transcript.

The server should send the LLM a payload shaped like:

```json
{
  "wizard_id": "jungle_story_guide",
  "age_band": "5-8",
  "story_length": "short",
  "tone": "warm_adventurous",
  "slots": {
    "hero_type": "little elephant",
    "setting": "moonlit jungle",
    "companion": "talking parrot",
    "problem": "lost river path",
    "special_object": "glowing seed",
    "ending_style": "happy"
  }
}
```

This keeps the story writer bounded, reviewable, and product-coherent.

### Phase 6: Future Transition Engines

The client contract should not change when the transition engine changes.

Possible future engines behind `/advance`:

- Fixed JSON tree.
- Server LLM choosing the next state.
- Server LLM generating temporary choice pools.
- Local small-model transition logic on capable devices.
- Personalized wizard memory.

Flutter should continue to render only the server-returned state.
