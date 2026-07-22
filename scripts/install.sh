#!/bin/bash
# Builds, signs, installs, launches, and verifies Brandon's sole Steno app.
# Speech assets live once in Steno's sandbox container, outside the app bundle.
# An unchanged pinned asset tree preserves those files across app replacement.
# Changed or incomplete assets and the app bundle are staged and replaced atomically.
# An installed process receives TERM and must exit before either replacement.
# A fixed personal Apple Development identity keeps the sandbox identity stable.
# Signing grants only App Sandbox and microphone input; network access is absent.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_PARENT="/Users/brandonharvey/Applications"
INSTALL_APP="$INSTALL_PARENT/Steno.app"
INSTALL_EXECUTABLE="$INSTALL_APP/Contents/MacOS/Steno"
ASSET_PARENT="/Users/brandonharvey/Library/Containers/com.brandonharvey.steno/Data/Library/Application Support/Steno"
ASSET_ROOT="$ASSET_PARENT/Resources"
SOURCE_ASSETS="$ROOT_DIR/Resources"
SIGNING_IDENTITY="D48285CCB96EB4280D7921EF44E210AE3FCA316B"
SIGNING_AUTHORITY="Apple Development: sandover@gmail.com (AA7X6693E3)"
SIGNING_TEAM="GS88W79LPB"
STAGING_DIR=""
ASSET_STAGING_DIR=""
STAGED_ASSET_ROOT=""
AVAILABLE_IDENTITIES=""

cleanup() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        /bin/rm -rf "$STAGING_DIR"
    fi
    if [[ -n "$ASSET_STAGING_DIR" && -d "$ASSET_STAGING_DIR" ]]; then
        /bin/rm -rf "$ASSET_STAGING_DIR"
    fi
}

verify_assets() {
    local root="$1"
    local component file

    [[ -s "$root/AssetManifest.json" ]] || return 1
    for component in AudioEncoder MelSpectrogram TextDecoder; do
        [[ -d "$root/Models/openai_whisper-large-v3-v20240930_turbo_632MB/$component.mlmodelc" ]] \
            || return 1
    done
    for file in \
        added_tokens.json config.json generation_config.json merges.txt \
        normalizer.json preprocessor_config.json special_tokens_map.json \
        tokenizer.json tokenizer_config.json vocab.json; do
        [[ -s "$root/Tokenizers/openai-whisper-large-v3/$file" ]] || return 1
    done
    [[ -z "$(/usr/bin/find "$root" -type f -size 0 -print -quit)" ]]
}

stage_assets_if_needed() {
    if verify_assets "$ASSET_ROOT" \
        && /usr/bin/diff -qr "$SOURCE_ASSETS" "$ASSET_ROOT" >/dev/null; then
        return
    fi

    mkdir -p "$ASSET_PARENT"
    ASSET_STAGING_DIR="$(/usr/bin/mktemp -d "$ASSET_PARENT/.Resources-install.XXXXXX")"
    STAGED_ASSET_ROOT="$ASSET_STAGING_DIR/Resources"
    /usr/bin/ditto --clone --norsrc "$SOURCE_ASSETS" "$STAGED_ASSET_ROOT"
    verify_assets "$STAGED_ASSET_ROOT" \
        || { echo "Staged speech assets are incomplete." >&2; exit 1; }
    /usr/bin/diff -qr "$SOURCE_ASSETS" "$STAGED_ASSET_ROOT" >/dev/null \
        || { echo "Staged speech assets do not match the repository." >&2; exit 1; }
}
trap cleanup EXIT

installed_pids() {
    local pid pids
    pids="$(/usr/bin/pgrep -x Steno 2>/dev/null || true)"
    while read -r pid; do
        [[ -n "$pid" ]] || continue
        if /usr/sbin/lsof -a -p "$pid" -d txt -Fn 2>/dev/null \
            | /usr/bin/grep -Fxq "n$INSTALL_EXECUTABLE"; then
            printf '%s\n' "$pid"
        fi
    done <<< "$pids"
}

verify_bundle() {
    local app="$1"
    local entitlement_dump="$STAGING_DIR/verified-entitlements.plist"
    local signature_details
    /usr/bin/codesign --verify --deep --strict "$app"
    signature_details="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
    /usr/bin/grep -Fq "Authority=$SIGNING_AUTHORITY" <<< "$signature_details" \
        || { echo "Personal Apple Development authority is missing." >&2; exit 1; }
    /usr/bin/grep -Fq "TeamIdentifier=$SIGNING_TEAM" <<< "$signature_details" \
        || { echo "Personal Apple Development signature is missing." >&2; exit 1; }
    if /usr/bin/grep -Fq "Signature=adhoc" <<< "$signature_details"; then
        echo "Ad-hoc signatures are not accepted." >&2
        exit 1
    fi
    /bin/rm -f "$entitlement_dump"
    /usr/bin/codesign --display --entitlements "$entitlement_dump" --xml "$app" 2>/dev/null
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$entitlement_dump")" == "true" ]] \
        || { echo "App Sandbox entitlement is missing." >&2; exit 1; }
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - "$entitlement_dump")" == "true" ]] \
        || { echo "Audio-input entitlement is missing." >&2; exit 1; }
    if /usr/bin/plutil -extract 'com\.apple\.security\.network\.client' raw -o - \
        "$entitlement_dump" >/dev/null 2>&1; then
        echo "Unexpected network-client entitlement." >&2
        exit 1
    fi
}

stop_installed_app() {
    local pids attempt
    pids="$(installed_pids)"
    if [[ -z "$pids" ]]; then
        return
    fi

    while read -r pid; do
        /bin/kill -TERM "$pid"
    done <<< "$pids"
    for attempt in {1..50}; do
        if [[ -z "$(installed_pids)" ]]; then
            return
        fi
        /bin/sleep 0.1
    done
    echo "Steno did not terminate; the installed bundle was not replaced." >&2
    exit 1
}

mkdir -p "$INSTALL_PARENT" "$ASSET_PARENT"
cd "$ROOT_DIR"
AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
/usr/bin/grep -Fq "$SIGNING_IDENTITY" <<< "$AVAILABLE_IDENTITIES" \
    || { echo "Personal Apple Development signing identity is unavailable." >&2; exit 1; }
/usr/bin/swift build -c release
BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"
[[ -x "$BIN_DIR/Steno" ]] || { echo "Release executable is missing." >&2; exit 1; }
verify_assets "$SOURCE_ASSETS" \
    || { echo "Repository speech assets are incomplete." >&2; exit 1; }
stage_assets_if_needed

STAGING_DIR="$(/usr/bin/mktemp -d "$INSTALL_PARENT/.Steno-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/Steno.app"
mkdir -p "$STAGED_APP/Contents/MacOS"
/usr/bin/install -m 755 "$BIN_DIR/Steno" "$STAGED_APP/Contents/MacOS/Steno"
/bin/cp "$ROOT_DIR/Support/Info.plist" "$STAGED_APP/Contents/Info.plist"

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
[[ ! -e "$STAGED_APP/Contents/Resources/Models" ]]
[[ ! -e "$STAGED_APP/Contents/Resources/Tokenizers" ]]
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
    --entitlements "$ROOT_DIR/Support/Steno.entitlements" "$STAGED_APP"
verify_bundle "$STAGED_APP"

stop_installed_app
if [[ -n "$STAGED_ASSET_ROOT" ]]; then
    /usr/bin/swift "$ROOT_DIR/scripts/AtomicReplace.swift" "$STAGED_ASSET_ROOT" "$ASSET_ROOT"
fi
/usr/bin/swift "$ROOT_DIR/scripts/AtomicReplace.swift" "$STAGED_APP" "$INSTALL_APP"
verify_bundle "$INSTALL_APP"
verify_assets "$ASSET_ROOT" \
    || { echo "Installed speech assets are incomplete." >&2; exit 1; }
/usr/bin/open -n "$INSTALL_APP"

for attempt in {1..100}; do
    pids="$(installed_pids)"
    if [[ "$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { count++ } END { print count + 0 }')" -eq 1 ]]; then
        exit 0
    fi
    /bin/sleep 0.1
done

echo "The installed Steno executable did not become the sole running Steno app." >&2
exit 1
