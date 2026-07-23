# Steno

Steno is a one-button, microphone-only macOS recorder and local transcriber.
It records one session, transcribes it with WhisperKit, and exposes selectable
text plus Copy and Done. It has no accounts, cloud service, history, or file UI.

## Requirements

- Apple Silicon Mac running macOS 14 or later
- Apple command-line developer tools with Swift 6.2 or later
- [`uv`](https://docs.astral.sh/uv/) for one-time model preparation

Xcode and an Xcode project are not required.

## Develop

Clone the repository and run the tests:

```sh
git clone git@github.com:sandover/steno.git
cd steno
swift test
```

Building and testing do not download or require the speech model.

## Prepare and install

Download and verify the pinned model and tokenizer once, then install Steno:

```sh
./scripts/prepare-model.sh
./scripts/install.sh
```

Model preparation downloads about 632 MB into Steno's sandbox Application
Support directory. Later installations reuse that persistent copy. The app has
no network entitlement and cannot download anything at runtime.

The installer is intentionally configured only for Brandon's Mac. It hardcodes
his application path and personal Apple Development signing identity. Other
developers can build and test immediately, but installing the app requires
adapting that local signing configuration.

See [SPEC.md](SPEC.md) for the product and technical contract and
[AGENTS.md](AGENTS.md) for repository working rules.
