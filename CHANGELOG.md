# Changelog

All notable changes to Fluent are documented here.

This project uses semantic versioning for public releases. Use `MAJOR.MINOR.PATCH`, where:

- `MAJOR` changes include breaking behavior or major compatibility changes.
- `MINOR` changes add user-visible features and improvements.
- `PATCH` changes fix bugs, polish existing behavior, or make small internal improvements.

## [1.2.0] - 2026-06-26

The project is now **Fluent**, a fork of Free Flow reworked for speed, transcription accuracy, and token efficiency. This release rebrands the app and folds in the improvements made since the fork.

### Changed

- Renamed the app and project from FreeFlow to Fluent, including the bundle identifier (`com.inhaq.fluent`), app menus, permission prompts, build tooling, and the project website.

### Added

- Post-Processing Reasoning setting (Automatic / Off / Low / Medium / High) that controls the cleanup model's `reasoning_effort`, letting you trade accuracy for fewer tokens and faster cleanup. This was not configurable in Free Flow.
- Optional warm-microphone session that keeps an idle capture session alive between dictations so recording starts without `AVCaptureSession` cold-start latency, with an automatic idle cool-down.
- Fast dictation mode that skips the screenshot and vision/context LLM call for plain dictation, with a "Capture screenshot for dictation" opt-in for when you want richer context.
- Custom vocabulary is now sent to the transcriber as a biasing prompt, so names, jargon, and acronyms are spelled correctly in the raw transcript.
- `os_signpost` instrumentation across the dictation pipeline (trigger, recorder ready, stop, audio finalized, transcript received, paste) for measuring end-to-end latency.
- Optional streamed multipart upload path for transcription requests.

### Improved

- Reworked speech-to-text using techniques from the Whisper paper ("Robust Speech Recognition via Large-Scale Weak Supervision"): robust per-segment decoding based on `no_speech_prob`, `avg_logprob`, and `compression_ratio` that rejects hallucinations while preserving quiet, low-confidence real speech.
- Added an audio front-end (80 Hz high-pass, loudness normalization with a safe peak ceiling and gain cap, and maximum-quality 16 kHz resampling) to improve recognition of soft or distant speech, with a full fallback to the original recording on any error.
- Transcription now decodes at `temperature=0` for stable, repeatable output.
- Rewrote the default cleanup system prompt from roughly 720 to about 370 words while preserving every behavioral rule, roughly halving the fixed prompt tokens per cleanup call.
- Lowered the default context screenshot dimension from 1024px to 768px (about 44% fewer pixels) and crop surrounding whitespace before upload.
- `<think>`/`<thinking>` reasoning blocks are now always stripped from model output across the whole model family, so reasoning models never paste their scratch work.
- Optimized the audio capture hot path (decode each buffer once, Accelerate/vDSP metering, throttled level updates), launch (async microphone discovery), run-history loading (lazy screenshots), and Settings rendering for a smoother, more responsive app.
- Added `qwen/qwen3.6-27b` to the model list and removed the GitHub star promo card and its launch-time network request.



### Added

- Model pickers in Settings for post-processing, fallback, context, and transcription models, including Qwen 3 32B and custom model entries.
- A recording overlay display picker for choosing the active window, primary display, or a specific connected monitor.
- In-pill error notifications so transient failures such as network or provider errors are visible without opening logs.
- Advanced timeout overrides for local model and slow network setups.

### Improved

- Retried dictations now place the successful transcript on the clipboard and update Paste Again.
- Paste Again now preserves the latest raw transcript earlier in the dictation flow, so it remains useful if later cleanup or pasting fails.
- Post-processing handles reasoning-oriented model output more cleanly, including Qwen thinking tags and providerless model aliases.

### Fixed

- Fixed cases where transcription could hang indefinitely when a provider accepted a connection but never returned a response.
- Fixed false screen-recording permission alerts from unrelated permission messages.
- Fixed duplicate in-pill error notifications being dismissed by an older timer.

## [1.0.0] - 2026-05-20

Fluent is now considered feature-complete and stable enough for a 1.0 release.

### Added

- Paste Again shortcut for re-pasting the most recent dictation.
- Recent transcript history in the menu bar, with copy actions for quickly reusing previous dictations.
- Run Log copy controls for both literal and cleaned transcript output.
- Menu bar actions for opening the Run Log and checking for updates.
- Debug settings for troubleshooting overlays and update prompts.
- A polished drag-to-Applications DMG background for installer builds.

### Improved

- Recording feedback now uses a cleaner minimalist menu-bar overlay, with clearer command-mode state.
- Transcribing and processing feedback appears sooner and more consistently after recording stops.
- Shortcut labels now use friendlier modifier names alongside symbols.
- Setup and recovery flows are more resilient when restoring app state.
- Sentence-ending dictations now paste with trailing spacing that better matches normal writing.
- Development builds and main-branch release automation are easier to identify and validate.

### Fixed

- Fixed shortcut collision checks for edit mode and manual modifier bindings.
- Fixed cases where dictation could terminate automatically while still in progress.
- Fixed clipboard restoration after dictation when the original clipboard content is unchanged.
- Marked transient dictation clipboard contents so clipboard managers can avoid saving them.
- Preserved spoken instructions verbatim during post-processing.
- Simplified transcription submission errors into clearer one-line messages.

## [0.3.3] - 2026-04-25

### Added

- Output Language setting for automatically translating dictated text before it is pasted.
- Transcription Language setting for choosing the language Fluent listens for during dictation.
- Recording state flag file for external tools that need to know when Fluent is actively recording.
- Distinct Fluent Dev app and menu bar icons so development builds are easier to tell apart from release builds.

### Improved

- Permission prompts and setup screens now use the correct app name for the installed build.
- Release notes in update prompts now render changelog formatting more clearly.
- Development builds now have clearer bundle naming and icon handling.

### Fixed

- Fixed audio recording crashes caused by unexpected input formats, resampling, and upload-path conversion.
- Fixed cases where Fluent could silently fall back when the selected microphone was unavailable.
- Fixed paste shortcuts on Colemak-DH and other non-QWERTY keyboard layouts.
- Fixed output language handling when custom system prompts are enabled.

## [0.3.2] - 2026-04-23

### Fixed

- Removed the pause-based audio interruption mode that could misfire and resume playback unexpectedly; dictation now only mutes audio.

## [0.3.1] - 2026-04-23

### Added

- Faster live dictation with realtime transcription support.
- A setting for choosing the realtime transcription model.
- Run log exports, so you can save a full dictation run for debugging or sharing.
- A Copy Transcript action in the run log.
- A voice command for submitting text: say "press enter" at the end of a dictation.
- Audio controls that can mute or pause other audio while you dictate, then restore it when recording stops.
- Build details in Settings for easier troubleshooting.
- Direct shortcuts from Fluent to the right macOS permission settings.
- A What’s New popup when an update is available.

### Improved

- Recording feedback now feels more responsive.
- The run log is easier to scan and use.
- Exported run logs include more useful context for reproducing issues.
- Realtime transcription is more reliable when recordings are cancelled, retried, or finish with no text.
- Provider settings are easier to edit without accidental whitespace or half-saved values.
- Fluent now warns you if alert sounds may be hard to hear because system audio is muted or very low.
- Update prompts now show the version, release date, and release notes more clearly.
- Fluent now uses proper version numbers for updates instead of internal build names.

### Fixed

- Fixed cases where arrow or navigation keys could be mistaken for Fn shortcut input.
- Fixed a clipboard timing issue that could paste the wrong content.
- Fixed empty realtime transcriptions getting stuck instead of finishing cleanly.
- Fixed waveform glitches caused by invalid audio levels.
- Filtered out more common transcription artifacts.
- Fixed alert sound hints staying visible after alert sounds are turned off.
- Fixed update checks so users only see real app releases, not internal builds.
- Fixed update checks so the app does not offer an older or already-installed version.
