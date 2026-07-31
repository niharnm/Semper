#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 <notarized-app-path> <output-dmg-path> <developer-id-identity>" >&2
}

if [[ $# -ne 3 ]]; then
    usage
    exit 64
fi

APP_PATH="$1"
OUTPUT_DMG="$2"
SIGNING_IDENTITY="$3"

if [[ ! -d "$APP_PATH" || "${APP_PATH##*.}" != "app" ]]; then
    echo "App bundle does not exist: $APP_PATH" >&2
    exit 66
fi

if [[ "${OUTPUT_DMG##*.}" != "dmg" ]]; then
    echo "Output path must end in .dmg: $OUTPUT_DMG" >&2
    exit 64
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "A Developer ID Application identity is required." >&2
    exit 64
fi

for command_name in codesign npx; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        echo "Required command is unavailable: $command_name" >&2
        exit 69
    fi
done

OUTPUT_DIR="$(dirname "$OUTPUT_DMG")"
mkdir -p "$OUTPUT_DIR"

PACKAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/semper-dmg.XXXXXX")"
cleanup() {
    rm -rf "$PACKAGE_DIR"
}
trap cleanup EXIT

npx --yes create-dmg@8.1.0 "$APP_PATH" "$PACKAGE_DIR" --overwrite

shopt -s nullglob
dmg_files=("$PACKAGE_DIR"/*.dmg)
if (( ${#dmg_files[@]} != 1 )); then
    echo "Expected one generated DMG, found ${#dmg_files[@]}." >&2
    exit 1
fi

rm -f "$OUTPUT_DMG"
mv "${dmg_files[0]}" "$OUTPUT_DMG"

codesign \
    --force \
    --timestamp \
    --sign "$SIGNING_IDENTITY" \
    "$OUTPUT_DMG"
codesign --verify --strict --verbose=2 "$OUTPUT_DMG"

DMG_SIGNATURE="$(mktemp "${TMPDIR:-/tmp}/semper-dmg-signature.XXXXXX")"
if ! codesign -dvvv "$OUTPUT_DMG" 2>"$DMG_SIGNATURE"; then
    cat "$DMG_SIGNATURE" >&2
    rm -f "$DMG_SIGNATURE"
    exit 1
fi

if ! grep -Fq "Authority=Developer ID Application:" "$DMG_SIGNATURE"; then
    cat "$DMG_SIGNATURE" >&2
    rm -f "$DMG_SIGNATURE"
    echo "DMG is not signed with a Developer ID Application certificate." >&2
    exit 1
fi
if ! grep -Fq "Timestamp=" "$DMG_SIGNATURE"; then
    cat "$DMG_SIGNATURE" >&2
    rm -f "$DMG_SIGNATURE"
    echo "DMG signature does not contain a secure timestamp." >&2
    exit 1
fi

rm -f "$DMG_SIGNATURE"
echo "Created signed DMG: $OUTPUT_DMG"
