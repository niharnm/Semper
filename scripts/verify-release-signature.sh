#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <signed-path> <apple-team-id>" >&2
    exit 64
fi

SIGNED_PATH="$1"
APPLE_TEAM_ID="$2"

if [[ ! -e "$SIGNED_PATH" ]]; then
    echo "Signed path does not exist: $SIGNED_PATH" >&2
    exit 66
fi
if [[ -z "$APPLE_TEAM_ID" ]]; then
    echo "Apple Team ID is required." >&2
    exit 64
fi

codesign --verify --deep --strict --verbose=2 "$SIGNED_PATH"

SIGNATURE_REPORT="$(mktemp "${TMPDIR:-/tmp}/semper-signature.XXXXXX")"
cleanup() {
    rm -f "$SIGNATURE_REPORT"
}
trap cleanup EXIT

if ! codesign -dvvv "$SIGNED_PATH" 2>"$SIGNATURE_REPORT"; then
    cat "$SIGNATURE_REPORT" >&2
    exit 1
fi

required_lines=(
    "Authority=Developer ID Application:"
    "TeamIdentifier=$APPLE_TEAM_ID"
    "Timestamp="
)
for required_line in "${required_lines[@]}"; do
    if ! grep -Fq "$required_line" "$SIGNATURE_REPORT"; then
        cat "$SIGNATURE_REPORT" >&2
        echo "Signature is missing: $required_line" >&2
        exit 1
    fi
done

if ! grep -Eq '^CodeDirectory .*flags=.*runtime' "$SIGNATURE_REPORT"; then
    cat "$SIGNATURE_REPORT" >&2
    echo "Signature does not enable the hardened runtime." >&2
    exit 1
fi

echo "Verified Developer ID signature: $SIGNED_PATH"
