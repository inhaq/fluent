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

Fluent is a free Mac dictation app for fast AI transcription, context-aware cleanup, and voice-driven text editing, with no monthly subscription. It started as a fork of [Free Flow](https://github.com/zachlatta/freeflow), and since the fork it has been reworked along three lines: it **feels faster from the moment you press the key**, it **converts speech to text more accurately**, and it **uses fewer tokens per dictation** while putting that cost under your control.

## Faster From Key-Press to Paste

Fluent attacks latency at both ends of a dictation, so recording begins almost the instant you press the shortcut and text lands shortly after you release it:

- **Instant start with a warm microphone (opt-in).** Starting an `AVCaptureSession` is one of the slowest steps when you press the key. Fluent can keep an idle capture session warm between dictations so the next recording starts without that cold-start delay, then automatically cools the session down after a short idle period to limit battery and mic-indicator impact.
- **Fast mode removes work from the release path.** For plain dictation, Fluent skips both the active-window screenshot and the vision/context LLM call entirely, so finishing a dictation no longer waits on a context request. Screenshot context is reserved for Edit Mode and an explicit opt-in.
- **A leaner audio hot path.** Each captured audio buffer is now decoded once and shared across the file writer, the realtime stream, and the level meter (instead of three separate decodes), RMS metering uses Accelerate/vDSP, and the live waveform is throttled to ~30 Hz, cutting CPU and main-thread wakeups during recording.
- **A faster launch and UI.** Microphone discovery moved off the launch path, run-history screenshots load lazily, and the Settings cards were made cheap to render, so the app opens and navigates without stalls.
- **Measured, not guessed.** A built-in `os_signpost` pipeline records each milestone (trigger to recorder-ready to stop to audio-finalized to transcript-received to paste), so end-to-end latency can be profiled in Instruments.

## More Accurate Speech-to-Text

Speech-to-text was reworked using techniques from speech-recognition research, in particular the Whisper paper ["Robust Speech Recognition via Large-Scale Weak Supervision"](https://arxiv.org/abs/2212.04356):

- **Robust per-segment decoding.** Instead of a brittle hardcoded list of phrases to discard, Fluent applies the paper's robust-decoding signals — `no_speech_prob`, `avg_logprob`, and `compression_ratio` — per segment to drop genuine non-speech and looping hallucinations while keeping quiet, low-confidence real speech that the old approach used to throw away.
- **An audio front-end tuned for quiet voices.** Before transcription, recordings pass through an 80 Hz high-pass that strips DC offset and sub-speech rumble (which lowers effective SNR), loudness normalization toward a consistent level with a safe peak ceiling and gain cap, and maximum-quality resampling to 16 kHz to avoid aliasing. Any failure falls back to the original recording untouched.
- **Vocabulary-biased, deterministic transcription.** Your custom vocabulary is now sent to the transcriber as a biasing prompt so names, jargon, and acronyms are spelled correctly in the raw transcript, and decoding runs at `temperature=0` for stable, repeatable output. Previously custom vocabulary only influenced the cleanup step, never the transcription itself.

## Fewer Tokens, On Your Terms

Fluent trims the fixed cost of every dictation and, unlike Free Flow, lets you decide how much the model is allowed to think:

- **User-configurable reasoning effort (new in Fluent).** A Post-Processing Reasoning setting (Automatic / Off / Low / Medium / High) controls the model's `reasoning_effort`. Turning it down — or Off — cuts the hidden reasoning tokens you pay for and speeds up cleanup. Free Flow gave you no control here; in Fluent it is a setting.
- **A leaner cleanup prompt.** The default cleanup system prompt was rewritten from roughly 720 to about 370 words while preserving every behavioral rule, roughly halving the fixed prompt tokens sent on every post-processing call.
- **Smaller, compressed screenshots when used.** When a screenshot is actually needed, it is captured at a 768px default dimension instead of 1024px (about 44% fewer pixels, and image tokens scale with pixel area), then whitespace-cropped before upload.
- **Reasoning tokens never leak through.** `<think>`/`<thinking>` reasoning blocks are always stripped from model output across the whole model family, so reasoning-oriented models stay fast and never paste their scratch work.

## Quick Start

1. Download the app from above, or [download Fluent.dmg directly](https://github.com/inhaq/fluent/releases/latest/download/Fluent.dmg)
2. Get a free Groq API key from [groq.com](https://groq.com/)
3. Hold `Fn` to talk, or tap `Command-Fn` to start and stop dictation, and have whatever you say pasted into the current text field

## Features

- **Custom shortcuts:** Customize both hold-to-talk and toggle dictation shortcuts. If your toggle shortcut extends your hold shortcut, you can start in hold mode and press the extra modifier keys to latch into tap mode without stopping the recording.
- **Context-aware cleanup:** Fluent can read nearby app context so names, terms, and phrases are spelled correctly when you dictate into email, terminals, docs, and other apps.
- **Custom vocabulary:** Add names, jargon, and project-specific terms. Fluent now feeds them to the transcriber as a biasing prompt so they are spelled correctly in the raw transcript, not just during cleanup.
- **Reasoning control:** Choose how hard the cleanup model thinks (Automatic / Off / Low / Medium / High) to trade accuracy for speed and token cost.
- **Speed toggles:** Optionally keep the microphone warm between dictations for instant starts, and opt into capturing a screenshot for plain dictation when you want richer context.
- **OpenAI-compatible providers:** Use Groq by default, or configure a custom model and API URL in settings.

## Edit Mode

Edit Mode lets you highlight existing text and transform it with a spoken instruction, like "make this shorter" or "turn this into bullets." Enable it in settings, then use your normal dictation shortcut on selected text, or choose Manual mode to require an extra modifier key.

## Privacy

There is no Fluent server, so Fluent does not store or retain your data on infrastructure we run. The audio and text of your dictations only ever leave your computer as API calls to the transcription and LLM provider you configure. The app also contacts GitHub to check for updates; that is the only other outbound request.

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
