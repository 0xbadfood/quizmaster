# StoryVault Product Intent

Date: 2026-07-18

StoryVault is primarily a story and rhyme app. The product should be excellent at helping children find, request, and listen to stories. Conversational AI is useful only when it strengthens that core job.

## Direction Change

The earlier persona-chat direction is not the long-term product shape. Persona characters are amusing for the first few turns, but the novelty fades quickly. They should not become the center of the app.

The assistant should instead act as a child-friendly story guide:

- understand what the child wants to hear
- search StoryVault's growing story and rhyme catalog
- ask short clarifying questions when the request is incomplete
- capture new story requirements in a structured way
- route to the best available story source
- support light smalltalk without taking over the experience

## Assistant Responsibilities

### 1. Story Discovery

StoryVault will contain a large and growing stash of stories and rhymes. The assistant's most important job is to map a child's spoken request to suitable existing content.

Examples:

- "Tell me a rabbit story"
- "I want Akbar Birbal"
- "Something funny before bed"
- "A Panchatantra story with animals"
- "A rhyme about rain"

The assistant should search through available layers before asking for new generation:

1. device cache
2. CDN or downloaded catalog
3. StoryVault server index
4. cloud generation only when no acceptable match exists

### 2. Guided Story Requests

When a child asks for something new, the assistant should collect the missing pieces rather than immediately generating a full story.

Useful fields include:

- topic
- characters
- age range
- mood
- language
- desired length
- lesson or theme
- bedtime/funny/adventure/rhyme mode
- any situational context, such as a bad day at school

This structured request can then be matched against existing stories or sent to the server for generation.

### 3. Situational Story Generation

Generic LLMs are unlikely to produce consistently great children's literature from scratch. However, generated stories are still valuable for situational needs.

Examples:

- a child had a bad day at school
- a child is scared of sleeping alone
- a child wants a story about their own toy
- a child asks for a specific unusual combination

The cloud LLM path should be used for these personalized or unmatched requests. Story generation should remain server/cloud controlled, not delegated to the small on-device model.

### 4. Light Smalltalk

Smalltalk is acceptable, but it should stay small. The assistant can tell short jokes, respond warmly, and keep the child engaged between story requests.

This behavior can be trained or tuned with app-specific examples. It should not drift into long open-ended persona chat.

## On-device LLM Role

For V1, the app should not ship an on-device language model. The intelligence layer stays
behind the StoryVault voice server and its LLM router. Small on-device models
remain a future research path only.

If that path is revisited after V1, a local model should be judged on whether
it can:

- classify intent
- extract requirements
- ask one useful clarifying question
- decide whether to retrieve or escalate
- produce compact structured output
- handle simple smalltalk

It does not need to write final stories.

## Future Training Direction

If local intent handling is revisited, the model can be trained or adapted with
StoryVault's own data:

- story titles
- summaries
- characters
- categories
- moods
- language metadata
- retrieval labels
- sample child requests
- expected routing decisions

The useful target is a compact assistant that already knows the StoryVault catalog well enough to navigate it.

## Cloud LLM Role

OpenAI or another frontier model should handle:

- final new story generation
- complex personalization
- safety-sensitive rewriting
- fallback when compact intent handling is weak
- high-quality transformations of structured story requirements

The app should avoid becoming a model-hosting business. For V1, server-side
routing and cloud APIs handle jobs where quality matters most.

## Product Principle

The assistant is not the product. The stories are the product.

AI should make StoryVault feel easier, smarter, and more personal, but the child should mostly remember the story they heard, not the chatbot they talked to.
