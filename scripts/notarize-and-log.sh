#!/bin/bash
set -euo pipefail

if [[ $# -ne 5 ]]; then
    echo "Usage: $0 <submission-path> <label> <log-directory> <keychain-profile> <keychain-path>" >&2
    exit 64
fi

SUBMISSION_PATH="$1"
LABEL="$2"
LOG_DIRECTORY="$3"
KEYCHAIN_PROFILE="$4"
KEYCHAIN_PATH="$5"

if [[ ! -f "$SUBMISSION_PATH" ]]; then
    echo "Submission does not exist: $SUBMISSION_PATH" >&2
    exit 66
fi
if [[ ! "$LABEL" =~ ^[a-z0-9-]+$ ]]; then
    echo "Label must contain lowercase letters, numbers, or hyphens." >&2
    exit 64
fi

mkdir -p "$LOG_DIRECTORY"
SUBMISSION_REPORT="$LOG_DIRECTORY/$LABEL-submission.json"
DEVELOPER_LOG="$LOG_DIRECTORY/$LABEL-developer-log.json"

submit_exit=0
xcrun notarytool submit "$SUBMISSION_PATH" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --keychain "$KEYCHAIN_PATH" \
    --wait \
    --timeout 60m \
    --output-format json \
    >"$SUBMISSION_REPORT" || submit_exit=$?

if [[ ! -s "$SUBMISSION_REPORT" ]]; then
    echo "Notary service did not return a submission report." >&2
    if (( submit_exit == 0 )); then
        submit_exit=1
    fi
    exit "$submit_exit"
fi

SUBMISSION_ID="$(plutil -extract id raw "$SUBMISSION_REPORT" 2>/dev/null || true)"
SUBMISSION_STATUS="$(plutil -extract status raw "$SUBMISSION_REPORT" 2>/dev/null || true)"

if [[ -z "$SUBMISSION_ID" ]]; then
    cat "$SUBMISSION_REPORT" >&2
    echo "Notary submission report does not contain an ID." >&2
    exit 1
fi

if ! xcrun notarytool log "$SUBMISSION_ID" "$DEVELOPER_LOG" \
    --keychain-profile "$KEYCHAIN_PROFILE" \
    --keychain "$KEYCHAIN_PATH"; then
    cat "$SUBMISSION_REPORT" >&2
    echo "Could not retain the developer log for submission $SUBMISSION_ID." >&2
    exit 1
fi

if (( submit_exit != 0 )) || [[ "$SUBMISSION_STATUS" != "Accepted" ]]; then
    cat "$SUBMISSION_REPORT" >&2
    cat "$DEVELOPER_LOG" >&2
    echo "Notarization was not accepted for $SUBMISSION_PATH." >&2
    exit 1
fi

echo "Accepted notarization submission $SUBMISSION_ID for $SUBMISSION_PATH"
