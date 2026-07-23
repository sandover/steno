# Steno V1 specification

## Product brief

Steno is a tiny macOS utility for one moment: the user wants to capture what is
being said, clicks one visible button, and gets selectable text they can copy.

The complete loop is:

1. Click **Record**.
2. Speak or hold a meeting near the Mac microphone.
3. Click **Stop** and wait while the recording is transcribed locally.
4. Select any text or click **Copy** for the whole transcript.
5. Click **Done** to return to the initial state.

### Success

- Recording starts with one click after macOS permissions are granted.
- Only microphone input is captured.
- Compressed Whisper Large v3 Turbo runs on the Mac with networking disabled.
- The transcript is visible, selectable, and copyable in full.
- A fixed meeting-audio benchmark meets the accuracy gate below.
- Done removes the current transcript and returns to one Record button.
- Done clears visible data immediately. Temporary audio remains only until its
  owning task exits; forced-termination residue is removed on the next launch.
- The idle app is obvious enough to use on impulse. It keeps the prepared model
  resident so Stop never pays model-loading or specialization latency.
- The finished app is installed at
  `/Users/brandonharvey/Applications/Steno.app` and launched for immediate use.

### Non-goals

No accounts, cloud, network calls, system-audio capture, speaker labels,
calendar integration, bots, file management, saved history, search, editing
tools, export formats, settings screen, menu structure, transcript recovery,
live transcription, transcript persistence, other users, other Macs, distribution signing,
notarization, or a distributable installer/package. V1 supports one session at a time on Brandon's
current Apple Silicon Mac and lets Whisper detect the spoken language.

## Design brief

### Form

Use one small floating panel that stays above ordinary windows and can appear on
all Spaces. It has no sidebar, title hierarchy, navigation, or onboarding.

The app is a menu-bar accessory (`LSUIElement`) with no Dock icon. A single
status-bar item shows or hides the panel and offers Quit. Quitting has the same
data-clearing effect as Done.

- **Idle:** one prominent Record button in the same compact panel used while recording.
- **Recording:** show a compact red Recording label, live microphone-level bars,
  and one Stop button.
- **Transcribing:** show a spinner, Transcribing, and Reset.
- **Complete:** keep the compact width and grow the panel vertically to show the
  transcript. Put a subtle, borderless Copy icon at lower left and Done at lower
  right. When the result is empty, show the empty field and Done only.
- **Error:** show one plain sentence and Reset. Link to macOS Settings only when
  permission was denied.

Use standard macOS controls, system type, and strong contrast. Red means active
recording. Do not add decoration, animation beyond the panel resize, a waveform,
or an elapsed-time display. Keyboard shortcuts are optional only after the mouse
loop works.

### Interaction rules

- Record never overwrites an existing transcript; Done starts a new session.
- Copy writes the entire transcript as plain text and briefly changes its icon
  to a checkmark.
- Reset during recording or transcription stops capture, clears visible session
  data, and collapses the panel. Done has the same effect after completion.
  During transcription Reset returns the UI to idle immediately, invalidates the
  session generation, and requests cancellation. The engine discards late
  results and deletes temporary audio only after the in-flight task exits.
- Closing or quitting has the same data-clearing effect as Done.
- An empty result is valid. Complete state shows Copy only once the transcript
  contains text.

## Technical design

Build a native Swift Package for Brandon's current Apple Silicon Mac. Use
SwiftUI for the panel contents and the smallest AppKit bridge needed for a
floating `NSPanel`. Use `AVAudioRecorder` to write microphone input as 16 kHz,
mono, 16-bit PCM to one app-owned temporary WAV file. The package may retain
WhisperKit's macOS 14 minimum, but V1 makes no compatibility promise beyond the
current machine.

There is no Xcode project and no Xcode GUI workflow. `swift build` compiles and
`swift test` tests. One repository script performs the release build, assembles
and personally signs `Steno.app`, atomically installs it at
`/Users/brandonharvey/Applications/Steno.app`, and opens it. The script copies a
fixed `Info.plist` and entitlements. A separate one-time developer script
downloads and verifies one authoritative model and tokenizer tree at
`~/Library/Containers/com.brandonharvey.steno/Data/Library/Application Support/Steno/Resources`,
and the installer requires but never modifies that tree. The installed Apple
command-line toolchain, macOS SDK, and `uv` remain required.

Use the WhisperKit product from the `argmax-oss-swift` Swift package, pinned to
an exact release tag in `Package.swift`. Install the pinned Core ML model
`openai_whisper-large-v3-v20240930_turbo_632MB`, which is a compressed Large v3
Turbo variant, plus the complete `openai/whisper-large-v3` tokenizer snapshot.
Track only their immutable repositories, revisions, paths, and tree hashes in
`Resources/AssetManifest.json`. Do not commit model or tokenizer payloads.
`scripts/prepare-model.sh` uses the pinned developer-only Hugging Face CLI to
download exactly those assets and install them atomically. A clean checkout can
build and run ordinary tests without speech assets. Only explicit preparation
and SwiftPM resolution may use the network; the assembled app must not.

Before WhisperKit initialization, verify that the installed model directories
and local tokenizer files exist. Missing or malformed assets fail locally.
Initialize WhisperKit with explicit local `modelFolder` and `tokenizerFolder`
paths, `load: false`, and `download: false`.

Request microphone access at runtime with `AVCaptureDevice.requestAccess(for:
.audio)`. This requires both `NSMicrophoneUsageDescription` in `Info.plist` and
the sandbox entitlement `com.apple.security.device.audio-input`; without either,
the system denies access with no prompt. Sign with
`com.apple.security.app-sandbox = true` and
`com.apple.security.device.audio-input = true`. Do not grant
`com.apple.security.network.client`.

Load and retain the model when Steno launches; Record remains unavailable until
it is ready. Configuring WhisperKit decoding options — voice-activity detection
and the no-speech, log-probability, and compression-ratio thresholds — is in
scope and is how the silence hallucination limit in the accuracy gate is met.
This is distinct from changing the model, which the accuracy gate governs.

### State

One main-actor model owns the session and exposes exactly five states:

```text
idle -> recording -> transcribing -> complete -> idle
  |         |              |            |
  +-------> error <---------+------------+
```

The main-actor model owns the recorder, visible state, and current transcript. A
small `TranscriptionEngine` actor owns the sole WhisperKit instance and permits
one inference run at a time. Each session has a generation ID. Reset invalidates
that ID so late results cannot mutate current UI state. The engine retains the
model until app exit and each temporary WAV until its task really exits, then
deletes the WAV. Delete any stale Steno WAV on the next launch.

There is no database, document model, background agent, or persistence API.
Transcript text exists only in memory and on the clipboard after Copy.

Keep production structure to the fewest files that remain readable:

- Swift package manifest, fixed app metadata, and one build script;
- app and panel setup;
- session model plus speech capture;
- single-flight transcription engine;
- SwiftUI content view;
- focused unit tests, including the headless complete-loop test.

Do not introduce a general recorder framework or recognition-provider
abstraction. A tiny test seam for simulated recording and transcription results
is enough. The engine actor exists only to serialize inference and own cleanup.

### Permissions and failures

Request microphone permission when Record is first clicked. Handle only
actionable failures: denied permission, no available input device, loss of the
input device during capture (unplugged or changed default), a recorder encode
error, missing local assets, or transcription failure. macOS has no
`AVAudioSession`
interruption model; treat device loss and the `AVAudioRecorder` encode-error
delegate callback as the capture failures. Delete temporary audio after its
owning task exits. A failed transcription shows the error and Reset; V1 does not
retain the recording or offer retry because that creates file-management state.

## Test-driven delivery

Implement each behavior from a failing test. Unit-test state transitions and
side effects with simulated permission, audio, and transcription events. Cover
the complete Record, Stop, Copy, Done loop as a headless test that drives the
main-actor model through the test seam and asserts the state sequence and side
effects; do not use XCUITest, which would require an Xcode app host and a second
build path. The on-screen loop is proven by the manual offline session in
acceptance test 10. Use a manual microphone check only for the hardware and
framework boundary that automation cannot prove.

### Acceptance tests

1. From idle, Record creates one temporary WAV and starts one microphone capture.
2. Stop ends capture and starts exactly one local transcription.
3. Successful transcription deletes the WAV, retains the prepared model, preserves the
   returned text, and exposes Copy and Done.
4. Copy places the exact full transcript on the macOS pasteboard.
5. Reset from recording or Done from complete deletes the WAV, clears all session
   data, and returns to idle. Reset during transcription returns to idle immediately,
   discards late results, and deletes the WAV after the task exits.
6. Denied microphone permission does not create a recording and produces an
   actionable error.
7. A missing model or tokenizer fails local preflight before WhisperKit starts.
   A transcription failure deletes audio after the task exits. The sandboxed app
   cannot make a network connection.
8. Loss of the input device or a recorder encode error stops capture, deletes
   audio, shows the error, and permits Reset.
9. Launch cleanup removes a stale Steno WAV left by a forced termination, and
   concurrent tests prove that Reset cannot disrupt active inference or
   accept a late result from an invalid generation.
10. With network access disabled, a manual microphone session produces selectable
    text and completes the Record, Stop, Copy, Done loop.

### Accuracy gate

Before release, fix a local, consented English benchmark containing at least
three five-minute meeting samples: quiet speech, two-person discussion, and
moderate room noise. Keep corrected reference transcripts beside the private
fixtures and keep both out of Git. Commit a public `BenchmarkManifest.json`
containing stable sample IDs, durations, SHA-256 digests, and the normalization
contract so every run identifies the same corpus. Keep model weights out of Git.

Compute word error rate with one small, pinned script in the repository that
normalizes case and punctuation the same way for hypothesis and reference. The
aggregate word error rate must be 10% or lower, no sample may exceed 15%, and
ten seconds of silence must not produce five or more invented consecutive words.
The pinned model is already a compressed Turbo build; do not swap it for a
different model unless the replacement passes this same benchmark.

### Release gate

Finish V1 only when all automated tests, the accuracy gate, entitlement
inspection, and the manual offline loop pass on Brandon's current Mac. The final
gate installs the app at `/Users/brandonharvey/Applications/Steno.app`, launches
it, and completes one real Record, Stop, Copy, Done session. Report speech
accuracy as observed, not guaranteed.

## Deliberate V1 tradeoff

High-quality local transcription is not a tiny workload. V1 accepts one roughly
632 MB persistent compressed Turbo model, several hundred MB of idle memory,
and post-recording latency to get better text without cloud processing. It
avoids live chunking, model choices, and a second recognition path. If the
accuracy gate fails, stop and reconsider the model; do not hide the failure with
UI features.
