# Steno working agreement

## Aim

Steno is a one-button, microphone-only macOS recorder and local transcriber.
Protect this narrow product. The core loop is Record, Stop, Copy, Reset.

## Ruthless simplicity

- Build the smallest complete version of the current requirement.
- Prefer one direct implementation over adapters, service layers, plug-in
  systems, provider choices, or speculative extension points.
- Add no accounts, cloud services, network access, file browser, history,
  settings screen, audio library, transcript library, or export workflow.
- Keep audio and transcripts ephemeral. The clipboard is the only output.
- Treat transcription accuracy as core behavior. Do not trade it away for a
  smaller model or live text without evidence from the accuracy benchmark.
- Keep one source of truth for state and behavior. Do not preserve parallel or
  legacy paths during a change.
- Before adding an entity or abstraction, show why the core loop cannot remain
  clear without it.
- Accept a narrower V1 before adding machinery. State the limitation plainly.
- Delete unused code and stale documentation instead of leaving tombstones.

## Engineering

- Target Apple Silicon macOS with Swift, SwiftUI, AppKit only where SwiftUI is
  insufficient, AVFoundation, and WhisperKit.
- Add a focused dependency when it materially improves transcription quality or
  removes significant implementation risk. Do not add parallel implementations
  or general machinery merely because a dependency makes them possible.
- Build and test from the command line with Swift Package Manager. Keep no
  `.xcodeproj`, `.xcworkspace`, Xcode-only build step, or second build path.
- Use one small script to assemble and ad-hoc-sign the local `.app` bundle from
  `swift build`; do not introduce a project generator or packaging framework.
- Bundle the pinned compressed Large v3 Turbo Core ML model
  `openai_whisper-large-v3-v20240930_turbo_632MB` and
  the matching `openai/whisper-large-v3` tokenizer. The installed app runs
  inside App Sandbox. It must not have a network-client entitlement, download
  models at runtime, or fall back to remote recognition.
- Ship as a menu-bar accessory (`LSUIElement`, no Dock icon). Prove the complete
  loop with a headless test against the session model, not XCUITest, which would
  force a second build path.
- Record to one private temporary file and serialize inference through one
  transcription engine. Reset clears the UI immediately; audio and model cleanup
  happen when in-flight inference exits or on the next launch after a crash.
- Use explicit state with obvious transitions. Avoid hidden global state.
- Keep components small, independent, and testable; prefer pure state logic.
- Start every non-trivial source file with a 5-15 line comment stating its
  purpose, key exports, and invariants.
- Write a failing test for each behavior change, then write the least code that
  passes it. Keep all passing tests green.
- Update `SPEC.md` when product behavior or technical boundaries change.
- Stop for approval when a choice would widen product scope, add persistence or
  app networking, create a parallel implementation, or create a second source
  of truth.
- Optimize for Brandon's current Mac only. Do not add distribution,
  notarization, installer, or multi-user compatibility work.

## Communication

- Be crisp and concrete. Lead with observable behavior and tradeoffs.
- Recommend the simplest option. Call out what it cannot do.
- Do not create new documentation unless asked.
