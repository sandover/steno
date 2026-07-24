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
his application path and Fourier Apple Development signing identity. Other
developers can build and test immediately, but installing the app requires
adapting that local signing configuration.

See [SPEC.md](SPEC.md) for the product and technical contract and
[AGENTS.md](AGENTS.md) for repository working rules.

## Internal release archive

`scripts/release.sh` builds a separate Developer ID-signed, hardened-runtime
archive. It never changes the development app in `~/Applications`.

```sh
./scripts/release.sh --output dist
./scripts/release.sh --output dist --notarize --notary-keychain-profile StenoNotary
./scripts/release.sh --output dist --version 1.0.1 --include-assets --notarize --notary-keychain-profile StenoNotary
```

The notarized forms require a preconfigured `notarytool` Keychain profile and
submit the archive to Apple, wait for acceptance, staple the app ticket, and
recreate the archive. Use `--version` for every external release. Add
`--include-assets` for the colleague-ready, drag-and-drop release: it
embeds the verified ~632 MB offline assets under the app's signed resources. On
first launch Steno promotes them into its sandbox; later updates reuse that
persistent copy. The app has no network entitlement and never downloads speech
assets at runtime.
