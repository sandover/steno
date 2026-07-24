#!/bin/bash
# Builds a separate, Developer ID-signed Steno archive for internal release.
# The script never installs, launches, or modifies Brandon's local Steno.app.
# The app remains sandboxed, microphone-only, and without network entitlement.
# --notarize uses a pre-existing notarytool Keychain profile and staples the app.
# --include-assets makes a self-contained first-download app without networking.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR=""
NOTARIZE=0
NOTARY_KEYCHAIN_PROFILE=""
INCLUDE_ASSETS=0
VERSION_OVERRIDE=""
SIGNING_IDENTITY="Developer ID Application: Fourier Partners LLC (2N634QL2T4)"
SIGNING_AUTHORITY="Developer ID Application: Fourier Partners LLC (2N634QL2T4)"
SIGNING_TEAM="2N634QL2T4"
STAGING_DIR=""

usage() {
    cat <<'USAGE'
usage: scripts/release.sh --output DIRECTORY [--version VERSION] [--include-assets] [--notarize --notary-keychain-profile PROFILE]

Builds a Developer ID archive. --include-assets embeds Steno's already verified
offline speech assets for a first-download release. --notarize submits the
archive to Apple using an existing notarytool Keychain profile, waits for
acceptance, staples the resulting ticket to Steno.app, and recreates the archive.
--version overrides both bundle-version fields in the staged release only.
USAGE
}

cleanup() {
    if [[ -n "$STAGING_DIR" && -d "$STAGING_DIR" ]]; then
        /bin/rm -rf "$STAGING_DIR"
    fi
}
trap cleanup EXIT

fail() {
    echo "$*" >&2
    exit 1
}

verify_bundle() {
    local app="$1"
    local entitlement_dump="$STAGING_DIR/verified-entitlements.plist"
    local signature_details

    /usr/bin/codesign --verify --deep --strict --verbose=2 "$app"
    signature_details="$(/usr/bin/codesign --display --verbose=4 "$app" 2>&1)"
    /usr/bin/grep -Fq "Authority=$SIGNING_AUTHORITY" <<< "$signature_details" \
        || fail "Developer ID Application authority is missing."
    /usr/bin/grep -Fq "TeamIdentifier=$SIGNING_TEAM" <<< "$signature_details" \
        || fail "Developer ID team identifier is missing."
    /usr/bin/grep -Fq "Runtime Version=" <<< "$signature_details" \
        || fail "Hardened Runtime is missing."
    /bin/rm -f "$entitlement_dump"
    /usr/bin/codesign --display --entitlements "$entitlement_dump" --xml "$app" 2>/dev/null
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$entitlement_dump")" == "true" ]] \
        || fail "App Sandbox entitlement is missing."
    [[ "$(/usr/bin/plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - "$entitlement_dump")" == "true" ]] \
        || fail "Audio-input entitlement is missing."
    if /usr/bin/plutil -extract 'com\.apple\.security\.network\.client' raw -o - \
        "$entitlement_dump" >/dev/null 2>&1; then
        fail "Unexpected network-client entitlement."
    fi
}

archive_app() {
    local app="$1"
    local archive="$2"
    local archive_staging="$STAGING_DIR/$(basename "$archive")"

    /usr/bin/ditto -c -k --keepParent "$app" "$archive_staging"
    /bin/mv "$archive_staging" "$archive"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --output)
            [[ $# -ge 2 ]] || fail "--output requires a directory."
            OUTPUT_DIR="$2"
            shift 2
            ;;
        --notarize)
            NOTARIZE=1
            shift
            ;;
        --include-assets)
            INCLUDE_ASSETS=1
            shift
            ;;
        --version)
            [[ $# -ge 2 ]] || fail "--version requires a value."
            VERSION_OVERRIDE="$2"
            shift 2
            ;;
        --notary-keychain-profile)
            [[ $# -ge 2 ]] || fail "--notary-keychain-profile requires a profile name."
            NOTARY_KEYCHAIN_PROFILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n "$OUTPUT_DIR" ]] || { usage >&2; fail "--output is required."; }
if [[ "$NOTARIZE" -eq 1 && -z "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    fail "--notarize requires --notary-keychain-profile."
fi
if [[ "$NOTARIZE" -eq 0 && -n "$NOTARY_KEYCHAIN_PROFILE" ]]; then
    fail "--notary-keychain-profile requires --notarize."
fi
if [[ -n "$VERSION_OVERRIDE" && ! "$VERSION_OVERRIDE" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    fail "--version must contain one to three dot-separated numeric components."
fi

cd "$ROOT_DIR"
AVAILABLE_IDENTITIES="$(/usr/bin/security find-identity -v -p codesigning)"
/usr/bin/grep -Fq "$SIGNING_IDENTITY" <<< "$AVAILABLE_IDENTITIES" \
    || fail "Developer ID Application signing identity is unavailable."

VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw -o - Support/Info.plist)"
if [[ -n "$VERSION_OVERRIDE" ]]; then
    VERSION="$VERSION_OVERRIDE"
fi
[[ -n "$VERSION" ]] || fail "Steno version is missing from Support/Info.plist."
/bin/mkdir -p "$OUTPUT_DIR"
ARCHIVE="$OUTPUT_DIR/Steno-$VERSION.zip"
[[ ! -e "$ARCHIVE" ]] || fail "Refusing to overwrite existing archive: $ARCHIVE"
if [[ "$INCLUDE_ASSETS" -eq 1 ]]; then
    "$ROOT_DIR/scripts/prepare-model.sh" --check \
        || fail "Prepare Steno's pinned speech assets before an offline release."
fi

/usr/bin/swift build -c release
BIN_DIR="$(/usr/bin/swift build -c release --show-bin-path)"
[[ -x "$BIN_DIR/Steno" ]] || fail "Release executable is missing."

STAGING_DIR="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/Steno-release.XXXXXX")"
STAGED_APP="$STAGING_DIR/Steno.app"
/bin/mkdir -p "$STAGED_APP/Contents/MacOS"
/usr/bin/install -m 755 "$BIN_DIR/Steno" "$STAGED_APP/Contents/MacOS/Steno"
/bin/cp Support/Info.plist "$STAGED_APP/Contents/Info.plist"
if [[ -n "$VERSION_OVERRIDE" ]]; then
    /usr/bin/plutil -replace CFBundleShortVersionString -string "$VERSION" "$STAGED_APP/Contents/Info.plist"
    /usr/bin/plutil -replace CFBundleVersion -string "$VERSION" "$STAGED_APP/Contents/Info.plist"
fi
/usr/bin/plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
if [[ "$INCLUDE_ASSETS" -eq 1 ]]; then
    /bin/mkdir -p "$STAGED_APP/Contents/Resources"
    /usr/bin/ditto --clone --norsrc \
        "$HOME/Library/Containers/com.brandonharvey.steno/Data/Library/Application Support/Steno/Resources" \
        "$STAGED_APP/Contents/Resources/BundledAssets"
fi
[[ ! -e "$STAGED_APP/Contents/Resources/Models" ]]
[[ ! -e "$STAGED_APP/Contents/Resources/Tokenizers" ]]

/usr/bin/codesign --force --timestamp --options runtime --sign "$SIGNING_IDENTITY" \
    --entitlements Support/Steno.entitlements "$STAGED_APP"
verify_bundle "$STAGED_APP"
archive_app "$STAGED_APP" "$ARCHIVE"

if [[ "$NOTARIZE" -eq 1 ]]; then
    /usr/bin/xcrun notarytool submit "$ARCHIVE" \
        --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
    /usr/bin/xcrun stapler staple "$STAGED_APP"
    /usr/bin/xcrun stapler validate "$STAGED_APP"
    /bin/rm -f "$ARCHIVE"
    archive_app "$STAGED_APP" "$ARCHIVE"
    /usr/sbin/spctl --assess --type execute --verbose=4 "$STAGED_APP"
fi

echo "Created $ARCHIVE"
if [[ "$NOTARIZE" -eq 0 ]]; then
    echo "Notarization was not requested; distribute this archive only after notarization."
fi
