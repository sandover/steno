#!/bin/bash
# Builds, assembles, signs, installs, launches, and verifies the sole Steno app.
# The fixed destination is Brandon's local Applications directory.
# Staging occurs beside the destination so the final rename is atomic.
# An existing installed process receives TERM and must exit before replacement.
# Signing grants only App Sandbox and microphone input; network access is absent.
# Re-running this script replaces the bundle and leaves one verified process.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL_PARENT="/Users/brandonharvey/Applications"
INSTALL_APP="$INSTALL_PARENT/Steno.app"
INSTALL_EXECUTABLE="$INSTALL_APP/Contents/MacOS/Steno"
STAGING_DIR=""

cleanup() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        /bin/rm -rf "$STAGING_DIR"
    fi
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
    /usr/bin/codesign --verify --deep --strict "$app"
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

mkdir -p "$INSTALL_PARENT"
cd "$ROOT_DIR"
/usr/bin/swift build -c release
BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"
[[ -x "$BIN_DIR/Steno" ]] || { echo "Release executable is missing." >&2; exit 1; }

STAGING_DIR="$(/usr/bin/mktemp -d "$INSTALL_PARENT/.Steno-install.XXXXXX")"
STAGED_APP="$STAGING_DIR/Steno.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
/usr/bin/install -m 755 "$BIN_DIR/Steno" "$STAGED_APP/Contents/MacOS/Steno"
/usr/bin/ditto --clone --norsrc "$ROOT_DIR/Resources" "$STAGED_APP/Contents/Resources"
/bin/cp "$ROOT_DIR/Support/Info.plist" "$STAGED_APP/Contents/Info.plist"

/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
[[ -s "$STAGED_APP/Contents/Resources/AssetManifest.json" ]]
[[ -d "$STAGED_APP/Contents/Resources/Models/openai_whisper-large-v3-v20240930_turbo_632MB/AudioEncoder.mlmodelc" ]]
[[ -s "$STAGED_APP/Contents/Resources/Tokenizers/openai-whisper-large-v3/tokenizer.json" ]]
/usr/bin/codesign --force --sign - \
    --entitlements "$ROOT_DIR/Support/Steno.entitlements" "$STAGED_APP"
verify_bundle "$STAGED_APP"

stop_installed_app
/usr/bin/swift "$ROOT_DIR/scripts/AtomicReplace.swift" "$STAGED_APP" "$INSTALL_APP"
verify_bundle "$INSTALL_APP"
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
