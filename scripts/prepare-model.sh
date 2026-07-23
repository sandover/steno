#!/bin/bash
# Downloads Steno's pinned speech assets into its sole persistent resource root.
# AssetManifest.json is the only source for repositories, revisions, paths, and hashes.
# The developer-only pinned hf CLI may use the network; the installed app never does.
# Downloads enter a same-volume staging directory and replace the installed tree atomically.
# Existing verified assets are reused, including migration from an older manifest.
# --check performs the same integrity check without downloading or changing files.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="$ROOT_DIR/Resources/AssetManifest.json"
ASSET_PARENT="$HOME/Library/Containers/com.brandonharvey.steno/Data/Library/Application Support/Steno"
ASSET_ROOT="$ASSET_PARENT/Resources"
MODE="${1:-prepare}"
DOWNLOAD_STAGING=""
MANIFEST_STAGING=""

cleanup() {
    if [[ -n "$DOWNLOAD_STAGING" && -d "$DOWNLOAD_STAGING" ]]; then
        /bin/rm -rf "$DOWNLOAD_STAGING"
    fi
    if [[ -n "$MANIFEST_STAGING" && -e "$MANIFEST_STAGING" ]]; then
        /bin/rm -f "$MANIFEST_STAGING"
    fi
}
trap cleanup EXIT

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

tree_digest() {
    local root="$1"
    /usr/bin/find "$root" -type f -print \
        | LC_ALL=C /usr/bin/sort \
        | while IFS= read -r file; do
            local digest relative
            digest="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
            relative="${file#"$root"/}"
            /usr/bin/printf '%s  %s\n' "$digest" "$relative"
        done \
        | /usr/bin/shasum -a 256 \
        | /usr/bin/awk '{print $1}'
}

verify_data() {
    local root="$1"
    local model_directory tokenizer_directory expected_model expected_tokenizer
    local index file

    model_directory="$(manifest_value model.directory)"
    tokenizer_directory="$(manifest_value tokenizer.directory)"
    expected_model="$(manifest_value model.sha256)"
    expected_tokenizer="$(manifest_value tokenizer.sha256)"

    [[ -d "$root/$model_directory" ]] || return 1
    [[ -d "$root/$tokenizer_directory" ]] || return 1
    [[ "$(tree_digest "$root/$model_directory")" == "$expected_model" ]] || return 1
    [[ "$(tree_digest "$root/$tokenizer_directory")" == "$expected_tokenizer" ]] || return 1

    index=0
    while file="$(/usr/bin/plutil -extract "tokenizer.files.$index" raw -o - "$MANIFEST" 2>/dev/null)"; do
        [[ -s "$root/$tokenizer_directory/$file" ]] || return 1
        index=$((index + 1))
    done
    [[ "$index" -gt 0 ]]
}

verify_current() {
    local root="$1"
    [[ -f "$root/AssetManifest.json" ]] || return 1
    /usr/bin/cmp -s "$MANIFEST" "$root/AssetManifest.json" || return 1
    verify_data "$root"
}

install_current_manifest() {
    mkdir -p "$ASSET_ROOT"
    MANIFEST_STAGING="$(/usr/bin/mktemp "$ASSET_ROOT/.AssetManifest.XXXXXX")"
    /bin/cp "$MANIFEST" "$MANIFEST_STAGING"
    /bin/mv -f "$MANIFEST_STAGING" "$ASSET_ROOT/AssetManifest.json"
    MANIFEST_STAGING=""
}

download_assets() {
    local model_repository model_revision model_source model_directory
    local tokenizer_repository tokenizer_revision tokenizer_directory
    local hf_version model_download tokenizer_download staged_root index file file_parent
    local -a tokenizer_files

    command -v uv >/dev/null 2>&1 \
        || { echo "uv is required to prepare Steno's speech model." >&2; exit 1; }

    model_repository="$(manifest_value model.repository)"
    model_revision="$(manifest_value model.revision)"
    model_source="$(manifest_value model.sourceDirectory)"
    model_directory="$(manifest_value model.directory)"
    tokenizer_repository="$(manifest_value tokenizer.repository)"
    tokenizer_revision="$(manifest_value tokenizer.revision)"
    tokenizer_directory="$(manifest_value tokenizer.directory)"
    hf_version="$(manifest_value downloader.version)"

    mkdir -p "$ASSET_PARENT"
    DOWNLOAD_STAGING="$(/usr/bin/mktemp -d "$ASSET_PARENT/.Resources-download.XXXXXX")"
    staged_root="$DOWNLOAD_STAGING/Resources"
    model_download="$DOWNLOAD_STAGING/model"
    tokenizer_download="$DOWNLOAD_STAGING/tokenizer"
    mkdir -p "$staged_root/Models" "$staged_root/Tokenizers"

    HF_HOME="$DOWNLOAD_STAGING/hf-cache" \
    HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    HF_HUB_DISABLE_UPDATE_CHECK=1 \
        uvx --from "hf==$hf_version" hf download "$model_repository" \
            --revision "$model_revision" \
            --include "$model_source/*" \
            --local-dir "$model_download"

    /usr/bin/ditto --clone --norsrc \
        "$model_download/$model_source" \
        "$staged_root/$model_directory"

    index=0
    while file="$(/usr/bin/plutil -extract "tokenizer.files.$index" raw -o - "$MANIFEST" 2>/dev/null)"; do
        tokenizer_files+=("$file")
        index=$((index + 1))
    done
    [[ "${#tokenizer_files[@]}" -gt 0 ]] \
        || { echo "Asset manifest contains no tokenizer files." >&2; exit 1; }

    HF_HOME="$DOWNLOAD_STAGING/hf-cache" \
    HF_HUB_DISABLE_IMPLICIT_TOKEN=1 \
    HF_HUB_DISABLE_TELEMETRY=1 \
    HF_HUB_DISABLE_UPDATE_CHECK=1 \
        uvx --from "hf==$hf_version" hf download "$tokenizer_repository" \
            "${tokenizer_files[@]}" \
            --revision "$tokenizer_revision" \
            --local-dir "$tokenizer_download"

    for file in "${tokenizer_files[@]}"; do
        file_parent="$(/usr/bin/dirname "$staged_root/$tokenizer_directory/$file")"
        mkdir -p "$file_parent"
        /bin/cp "$tokenizer_download/$file" "$staged_root/$tokenizer_directory/$file"
    done
    /bin/cp "$MANIFEST" "$staged_root/AssetManifest.json"

    verify_current "$staged_root" \
        || { echo "Downloaded speech assets failed integrity verification." >&2; exit 1; }
    /usr/bin/swift "$ROOT_DIR/scripts/AtomicReplace.swift" "$staged_root" "$ASSET_ROOT"
}

case "$MODE" in
    --check)
        verify_current "$ASSET_ROOT" \
            || { echo "Installed Steno speech assets are missing or do not match." >&2; exit 1; }
        ;;
    prepare)
        if verify_current "$ASSET_ROOT"; then
            echo "Steno speech assets are already prepared."
        elif verify_data "$ASSET_ROOT"; then
            install_current_manifest
            verify_current "$ASSET_ROOT"
            echo "Updated Steno's installed asset manifest."
        else
            download_assets
            verify_current "$ASSET_ROOT"
            echo "Prepared Steno's pinned speech assets."
        fi
        ;;
    *)
        echo "usage: scripts/prepare-model.sh [--check]" >&2
        exit 64
        ;;
esac
