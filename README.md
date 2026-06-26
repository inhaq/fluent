<p align="center">
  <img src="Resources/AppIcon-Source.png" width="128" height="128" alt="Fluent icon">
</p>

<h1 align="center">Fluent</h1>

<p align="center">
  A faster, leaner Mac dictation app. Free and open source alternative to <a href="https://wisprflow.ai">Wispr Flow</a>, <a href="https://superwhisper.com">Superwhisper</a>, and <a href="https://monologue.to">Monologue</a>.
</p>

<p align="center">
  <a href="https://github.com/inhaq/fluent/releases/latest/download/Fluent.dmg"><b>⬇ Download Fluent.dmg</b></a><br>
  <sub>Works on all Macs (Apple Silicon + Intel)</sub>
</p>

---

<p align="center">
  <img src="Resources/demo.gif" alt="Fluent demo" width="600">
</p>

<p align="center">
  <i>Fluent is a faster, more token-efficient fork of <a href="https://github.com/zachlatta/freeflow">Free Flow</a>.</i>
</p>

## Overview

Fluent is a free Mac dictation app for fast AI transcription, context-aware cleanup, and voice-driven text editing, with no monthly subscription. It started as a fork of [Free Flow](https://github.com/zachlatta/freeflow) and has been reworked to be **more efficient, to use fewer tokens per dictation, and to feel noticeably faster** end to end.

## Why Fluent Is Faster and Cheaper

Fluent keeps Free Flow's full feature set but trims the expensive parts of the dictation pipeline so you spend fewer tokens and wait less:

- **No screenshot on plain dictation.** Capturing and uploading a screenshot to the vision context model is the single most expensive step of context collection. For ordinary dictation, the app and window metadata are enough, so Fluent skips the screenshot entirely. Image capture only happens for Edit Mode (and an explicit opt-in). This removes thousands of image tokens from the typical dictation and cuts a slow step out of the hot path.
- **Smaller, compressed screenshots when they are used.** When a screenshot is needed, Fluent sends it at a 768px default dimension instead of 1024px (about 44% fewer pixels, and image tokens scale with pixel area), JPEG-compresses it, and crops surrounding whitespace before upload.
- **A lean default cleanup model.** Cleanup runs on `openai/gpt-oss-20b` with reasoning effort set to low and reasoning output disabled, so you pay for the cleaned text instead of a long hidden chain of thought.
- **Reasoning tokens never leak through.** Any `<think>`-style reasoning blocks are always stripped from model output, so reasoning-heavy models stay fast and never paste their scratch work.

The result is the same dictation quality with a smaller token bill and lower latency on every dictation.

## Quick Start

1. Download the app from above or [click here](https://github.com/inhaq/fluent/releases/latest/download/Fluent.dmg)
2. Get a free Groq API key from [groq.com](https://groq.com/)
3. Hold `Fn` to talk, or tap `Command-Fn` to start and stop dictation, and have whatever you say pasted into the current text field

## Features

- **Custom shortcuts:** Customize both hold-to-talk and toggle dictation shortcuts. If your toggle shortcut extends your hold shortcut, you can start in hold mode and press the extra modifier keys to latch into tap mode without stopping the recording.
- **Context-aware cleanup:** Fluent can read nearby app context so names, terms, and phrases are spelled correctly when you dictate into email, terminals, docs, and other apps.
- **Custom vocabulary:** Add names, jargon, and project-specific words that Fluent should preserve during cleanup.
- **OpenAI-compatible providers:** Use Groq by default, or configure a custom model and API URL in settings.

## Edit Mode

Edit Mode lets you highlight existing text and transform it with a spoken instruction, like "make this shorter" or "turn this into bullets." Enable it in settings, then use your normal dictation shortcut on selected text, or choose Manual mode to require an extra modifier key.

## Privacy

There is no Fluent server, so Fluent does not store or retain your data. The only information that leaves your computer are API calls to your configured transcription and LLM provider.

## Custom Cleanup

If you'd rather keep cleanup more literal and less context-aware, you can paste this simpler prompt into the custom system prompt setting:

<details>
  <summary>Simple post-processing prompt</summary>

  <pre><code>You are a dictation post-processor. You receive raw speech-to-text output and return clean text ready to be typed into an application.

Your job:
- Remove filler words (um, uh, you know, like) unless they carry meaning.
- Fix spelling, grammar, and punctuation errors.
- When the transcript already contains a word that is a close misspelling of a name or term from the context or custom vocabulary, correct the spelling. Never insert names or terms from context that the speaker did not say.
- Preserve the speaker's intent, tone, and meaning exactly.

Output rules:
- Return ONLY the cleaned transcript text, nothing else. So NEVER output words like "Here is the cleaned transcript text:"
- If the transcription is empty, return exactly: EMPTY
- Do not add words, names, or content that are not in the transcription. The context is only for correcting spelling of words already spoken.
- Do not change the meaning of what was said.

Example:
RAW_TRANSCRIPTION: "hey um so i just wanted to like follow up on the meating from yesterday i think we should definately move the dedline to next friday becuz the desine team still needs more time to finish the mock ups and um yeah let me know if that works for you ok thanks"

Then your response would be ONLY the cleaned up text, so here your response is ONLY:
"Hey, I just wanted to follow up on the meeting from yesterday. I think we should definitely move the deadline to next Friday because the design team still needs more time to finish the mockups. Let me know if that works for you. Thanks."</code></pre>
</details>

## Using a Local Model

Fluent can use OpenAI-compatible local or self-hosted providers instead of Groq. In settings, configure the API base URL and model IDs for your local LLM provider, such as Ollama, LM Studio, or another OpenAI-compatible server. If your transcription backend uses a different endpoint from your LLM backend, set the transcription API URL separately.

Local models are often slower than hosted providers, especially on cold start, long recordings, or busy hardware.

<details>
  <summary>Configure longer timeouts for local models</summary>

  Fluent keeps the default network timeout at 20 seconds, but you can extend it with macOS defaults:

```bash
defaults write com.inhaq.fluent transcription_timeout_seconds -float 120
defaults write com.inhaq.fluent post_processing_timeout_seconds -float 120
defaults write com.inhaq.fluent context_request_timeout_seconds -float 120
```

The timeout keys are:

- `transcription_timeout_seconds`: audio transcription requests
- `post_processing_timeout_seconds`: transcript cleanup and edit mode requests
- `context_request_timeout_seconds`: nearby app context requests

Only positive values are used. Remove a custom timeout to return to the 20-second default:

```bash
defaults delete com.inhaq.fluent transcription_timeout_seconds
defaults delete com.inhaq.fluent post_processing_timeout_seconds
defaults delete com.inhaq.fluent context_request_timeout_seconds
```

</details>

## Credits

Fluent is built on top of [Free Flow](https://github.com/zachlatta/freeflow) by [@zachlatta](https://github.com/zachlatta) and its contributors. Thank you for the foundation.

## License

Licensed under the MIT license.
