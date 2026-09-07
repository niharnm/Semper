#!/bin/bash

set -euo pipefail

readonly REPOSITORY_URL="https://github.com/niharnm/Semper.git"
readonly RAW_BASE_URL="https://raw.githubusercontent.com/niharnm/Semper"
readonly ARCHIVE_BASE_URL="https://github.com/niharnm/Semper/archive"
readonly INSTALL_PATH="/Applications/Semper.app"
readonly EXPECTED_BUNDLE_ID="systems.semper.Semper"

workspace=""
staged_path=""
backup_path=""
had_existing_app=false
install_in_progress=false
needs_sudo=false

fail() {
    echo "Semper update failed: $*" >&2
    exit 1
}

cleanup() {
    exit_status=$?
    trap - EXIT INT TERM

    if [[ "$install_in_progress" == true ]]; then
        if [[ "$had_existing_app" == true && -n "$backup_path" \
            && -e "$backup_path" ]]; then
            if ! run_privileged rm -rf "$INSTALL_PATH" \
                || ! run_privileged mv "$backup_path" "$INSTALL_PATH"; then
                echo "Warning: the old app remains at $backup_path." >&2
            fi
        elif [[ "$had_existing_app" == false && -e "$INSTALL_PATH" ]]; then
            if ! run_privileged rm -rf "$INSTALL_PATH"; then
                echo "Warning: the incomplete app remains at $INSTALL_PATH." >&2
            fi
        fi
        if [[ -n "$staged_path" && -e "$staged_path" ]]; then
            if ! run_privileged rm -rf "$staged_path"; then
                echo "Warning: the staged app remains at $staged_path." >&2
            fi
        fi
    fi

    if [[ -n "$workspace" && -d "$workspace" ]]; then
        if ! rm -rf "$workspace"; then
            echo "Warning: update files remain at $workspace." >&2
        fi
    fi

    exit "$exit_status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ "$(uname -s)" != "Darwin" ]]; then
    fail "this updater requires macOS."
fi

for command_name in codesign curl ditto git open openssl osascript pgrep security shasum xcodebuild; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        fail "required command is unavailable: $command_name"
    fi
done

latest_revision="$(
    git ls-remote "$REPOSITORY_URL" refs/heads/main \
        | awk 'NR == 1 { print $1 }'
)"
if [[ ! "$latest_revision" =~ ^[0-9a-f]{40}$ ]]; then
    fail "could not resolve the current GitHub main commit."
fi

project_settings="$(
    curl -fsSL \
        "$RAW_BASE_URL/$latest_revision/Semper.xcodeproj/project.pbxproj"
)" || fail "could not read the current version from GitHub."

latest_version="$(
    printf '%s\n' "$project_settings" \
        | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / {
            value = $2
            sub(/;[[:space:]]*$/, "", value)
            print value
            exit
        }'
)"
if [[ ! "$latest_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    fail "GitHub main does not contain a valid Semper version."
fi

installed_version="Not installed"
if [[ -d "$INSTALL_PATH" ]]; then
    if [[ ! -x /usr/libexec/PlistBuddy ]]; then
        fail "required command is unavailable: /usr/libexec/PlistBuddy"
    fi
    if ! installed_version="$(
        /usr/libexec/PlistBuddy \
            -c 'Print :CFBundleShortVersionString' \
            "$INSTALL_PATH/Contents/Info.plist" 2>/dev/null
    )"; then
        installed_version="Unknown"
    fi
fi

echo "Semper source updater"
echo "Installed: $installed_version"
echo "GitHub main: $latest_version (${latest_revision:0:8})"
echo
echo "This will build the current GitHub source and replace $INSTALL_PATH."
printf "Continue? [y/N] "

if ! exec 3<>/dev/tty; then
    fail "run this command in an interactive Terminal window."
fi
IFS= read -r confirmation <&3 || confirmation=""
exec 3>&-

case "$confirmation" in
    y|Y|yes|YES|Yes)
        ;;
    *)
        echo "Update cancelled."
        exit 0
        ;;
esac

if [[ ! -x /usr/libexec/PlistBuddy ]]; then
    fail "required command is unavailable: /usr/libexec/PlistBuddy"
fi

if ! signing_identities="$(security find-identity -v -p codesigning 2>/dev/null)"; then
    fail "could not read code-signing identities from the keychain. Install the signed release from https://github.com/niharnm/Semper/releases/latest."
fi

installed_signing_authority=""
if [[ -d "$INSTALL_PATH" ]] \
    && codesign --verify --deep --strict "$INSTALL_PATH" >/dev/null 2>&1 \
    && installed_signature_report="$(codesign -dvvv "$INSTALL_PATH" 2>&1)" \
    && ! printf '%s\n' "$installed_signature_report" \
        | grep -Eq '(^Signature=adhoc$|^CodeDirectory .*flags=.*adhoc)'; then
    installed_signing_authority="$(
        printf '%s\n' "$installed_signature_report" \
            | awk -F '=' '
                !found && /^Authority=(Developer ID Application|Apple Development): / {
                    sub(/^Authority=/, "")
                    print
                    found = 1
                }
            '
    )"
fi

signing_identity_line="$(
    printf '%s\n' "$signing_identities" \
        | awk -F '"' -v preferred="$installed_signing_authority" '
            $2 ~ /^(Developer ID Application|Apple Development): / {
                name = $2
                if (preferred != "" && name != preferred) {
                    next
                }
                identity_hash = $1
                sub(/^[[:space:]]*[0-9]+\)[[:space:]]*/, "", identity_hash)
                priority = name ~ /^Developer ID Application: / ? 0 : 1
                if (!found ||
                    priority < best_priority ||
                    (priority == best_priority && name < best_name) ||
                    (priority == best_priority && name == best_name &&
                        identity_hash < best_hash)) {
                    selected = $0
                    best_priority = priority
                    best_name = name
                    best_hash = identity_hash
                    found = 1
                }
            }
            END {
                if (found) {
                    print selected
                }
            }
        '
)"
if [[ -z "$signing_identity_line" ]]; then
    if [[ -n "$installed_signing_authority" ]] \
        && printf '%s\n' "$signing_identities" \
            | grep -Eq '"(Developer ID Application|Apple Development): '; then
        fail "no valid identity matches the current Semper signer: $installed_signing_authority. Install the signed release from https://github.com/niharnm/Semper/releases/latest."
    fi
    fail "no valid Developer ID Application or Apple Development signing identity was found. Install the signed release from https://github.com/niharnm/Semper/releases/latest, or add an Apple Development certificate in Xcode Settings > Accounts."
fi

signing_identity_hash="$(
    printf '%s\n' "$signing_identity_line" | awk '{ print $2 }' \
        | tr '[:lower:]' '[:upper:]'
)"
signing_identity_name="$(
    printf '%s\n' "$signing_identity_line" | awk -F '"' '{ print $2 }'
)"
if [[ ! "$signing_identity_hash" =~ ^[0-9A-F]{40}$ \
    || -z "$signing_identity_name" ]]; then
    fail "the selected code-signing identity is malformed."
fi

if ! certificate_list="$(security find-certificate -a -Z -p 2>/dev/null)"; then
    fail "could not read the selected code-signing certificate."
fi
signing_certificate="$(
    printf '%s\n' "$certificate_list" \
        | awk -v selected_hash="$signing_identity_hash" '
            captured {
                next
            }
            /^SHA-1 hash: / {
                matches = (toupper($3) == selected_hash)
                capturing = 0
                next
            }
            matches && /^-----BEGIN CERTIFICATE-----$/ {
                capturing = 1
            }
            capturing {
                print
            }
            capturing && /^-----END CERTIFICATE-----$/ {
                capturing = 0
                captured = 1
            }
        '
)"
if [[ -z "$signing_certificate" ]]; then
    fail "could not match the selected code-signing identity to its certificate."
fi
if ! certificate_subject="$(
    printf '%s\n' "$signing_certificate" \
        | openssl x509 -noout -subject -nameopt RFC2253 2>/dev/null
)"; then
    fail "could not read the selected code-signing certificate subject."
fi
signing_team_id="$(
    printf '%s\n' "$certificate_subject" \
        | awk -F ',' '
            {
                for (field_index = 1; field_index <= NF; field_index++) {
                    field = $field_index
                    sub(/^subject=/, "", field)
                    if (field ~ /^OU=/) {
                        sub(/^OU=/, "", field)
                        print field
                        exit
                    }
                }
            }
        '
)"
if [[ ! "$signing_team_id" =~ ^[A-Z0-9]{10}$ ]]; then
    fail "the selected code-signing certificate does not contain a valid Apple Team ID."
fi

echo "Signing with $signing_identity_name ($signing_team_id)."

workspace="$(mktemp -d "${TMPDIR:-/tmp}/semper-update.XXXXXX")"
archive_path="$workspace/Semper.zip"
source_parent="$workspace/source"
derived_data_path="$workspace/DerivedData"
build_log="$workspace/xcodebuild.log"

mkdir -p "$source_parent"
echo "Downloading GitHub main ${latest_revision:0:8}..."
curl -fL "$ARCHIVE_BASE_URL/$latest_revision.zip" -o "$archive_path"
ditto -x -k "$archive_path" "$source_parent"

source_path="$(
    find "$source_parent" -mindepth 1 -maxdepth 1 -type d -name 'Semper-*' \
        -print -quit
)"
if [[ -z "$source_path" || ! -f "$source_path/Semper.xcodeproj/project.pbxproj" ]]; then
    fail "the downloaded source archive is invalid."
fi

echo "Building Semper $latest_version..."
if ! xcodebuild \
    -project "$source_path/Semper.xcodeproj" \
    -scheme Semper \
    -configuration Release \
    -derivedDataPath "$derived_data_path" \
    CODE_SIGN_IDENTITY="$signing_identity_hash" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="$signing_team_id" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES \
    build >"$build_log" 2>&1; then
    tail -80 "$build_log" >&2
    fail "the Release build did not complete."
fi

built_app="$derived_data_path/Build/Products/Release/Semper.app"
built_info="$built_app/Contents/Info.plist"
built_executable="$built_app/Contents/MacOS/Semper"
if [[ ! -d "$built_app" || ! -f "$built_info" || ! -x "$built_executable" ]]; then
    fail "the Release build did not produce a valid Semper.app."
fi

built_version="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built_info"
)"
built_bundle_id="$(
    /usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$built_info"
)"
if [[ "$built_version" != "$latest_version" ]]; then
    fail "the built version is $built_version, expected $latest_version."
fi
if [[ "$built_bundle_id" != "$EXPECTED_BUNDLE_ID" ]]; then
    fail "the built app has an unexpected bundle identifier: $built_bundle_id"
fi

verify_app_signature() {
    local app_path="$1"
    local requirement_report
    local signature_report

    if ! codesign --verify --deep --strict --verbose=2 "$app_path"; then
        return 1
    fi
    if ! signature_report="$(codesign -dvvv "$app_path" 2>&1)"; then
        printf '%s\n' "$signature_report" >&2
        return 1
    fi
    if printf '%s\n' "$signature_report" \
        | grep -Eq '(^Signature=adhoc$|^CodeDirectory .*flags=.*adhoc)'; then
        echo "The app has an ad hoc signature." >&2
        return 1
    fi
    if ! printf '%s\n' "$signature_report" \
        | grep -Fqx "Identifier=$EXPECTED_BUNDLE_ID"; then
        echo "The code signature has an unexpected identifier." >&2
        return 1
    fi
    if ! printf '%s\n' "$signature_report" \
        | grep -Fqx "TeamIdentifier=$signing_team_id"; then
        echo "The code signature has an unexpected Apple Team ID." >&2
        return 1
    fi
    if ! requirement_report="$(codesign -d -r- "$app_path" 2>&1)"; then
        printf '%s\n' "$requirement_report" >&2
        return 1
    fi
    if ! printf '%s\n' "$requirement_report" | grep -Eq '^designated => .+'; then
        echo "The app has no designated requirement." >&2
        return 1
    fi
    if printf '%s\n' "$requirement_report" | grep -Eq '^designated => .*cdhash[[:space:]]'; then
        echo "The app's designated requirement contains a code-hash constraint." >&2
        return 1
    fi
    if ! printf '%s\n' "$requirement_report" \
        | grep -Fq "identifier \"$EXPECTED_BUNDLE_ID\""; then
        echo "The app's designated requirement has an unexpected identifier." >&2
        return 1
    fi
    if ! printf '%s\n' "$requirement_report" \
        | grep -Eq '^designated => .*anchor apple'; then
        echo "The app's designated requirement is not anchored to Apple." >&2
        return 1
    fi
    if ! printf '%s\n' "$requirement_report" \
        | grep -Eq "certificate leaf\\[subject\\.OU\\] = \"?$signing_team_id\"?"; then
        echo "The app's designated requirement has no matching Apple Team ID." >&2
        return 1
    fi
}

if ! verify_app_signature "$built_app"; then
    fail "the built app does not have a valid persistent code signature."
fi

install_directory="${INSTALL_PATH%/*}"
if [[ ! -w "$install_directory" ]]; then
    echo "Administrator permission is required to replace $INSTALL_PATH."
    /usr/bin/sudo -v
    needs_sudo=true
fi

run_privileged() {
    if [[ "$needs_sudo" == true ]]; then
        /usr/bin/sudo "$@"
    else
        "$@"
    fi
}

staged_path="$install_directory/.Semper.app.update.$$"
backup_path="$install_directory/.Semper.app.backup.$$"
if [[ -e "$staged_path" || -e "$backup_path" ]]; then
    fail "a temporary Semper update path already exists."
fi
if [[ -e "$INSTALL_PATH" ]]; then
    had_existing_app=true
fi

install_in_progress=true
echo "Preparing the replacement app..."
if ! run_privileged ditto "$built_app" "$staged_path"; then
    fail "could not copy the new app into $install_directory."
fi
if ! verify_app_signature "$staged_path"; then
    fail "the staged app does not have a valid persistent code signature."
fi

if pgrep -x Semper >/dev/null 2>&1; then
    echo "Quitting Semper..."
    osascript -e 'tell application id "systems.semper.Semper" to quit' \
        >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if ! pgrep -x Semper >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
    if pgrep -x Semper >/dev/null 2>&1; then
        run_privileged rm -rf "$staged_path"
        fail "Semper is still running. Quit it and run the command again."
    fi
fi

if [[ "$had_existing_app" == true ]]; then
    if ! run_privileged mv "$INSTALL_PATH" "$backup_path"; then
        run_privileged rm -rf "$staged_path"
        fail "could not move the old Semper.app aside."
    fi
fi

restore_previous_app() {
    if ! run_privileged rm -rf "$INSTALL_PATH"; then
        return 1
    fi
    if [[ "$had_existing_app" == true && -e "$backup_path" ]]; then
        if ! run_privileged mv "$backup_path" "$INSTALL_PATH"; then
            return 1
        fi
    fi
    if [[ -e "$staged_path" ]]; then
        if ! run_privileged rm -rf "$staged_path"; then
            return 1
        fi
    fi
    install_in_progress=false
}

fail_with_restore() {
    failure_message="$1"
    if restore_previous_app; then
        if [[ "$had_existing_app" == true ]]; then
            fail "$failure_message The old app was restored."
        fi
        fail "$failure_message The new app was removed."
    fi
    if [[ "$had_existing_app" == false ]]; then
        fail "$failure_message Cleanup failed; the new app remains at $INSTALL_PATH."
    fi
    fail "$failure_message Restore failed; the backup remains at $backup_path."
}

if ! run_privileged mv "$staged_path" "$INSTALL_PATH"; then
    fail_with_restore "could not put the new Semper.app in place."
fi

installed_info="$INSTALL_PATH/Contents/Info.plist"
installed_executable="$INSTALL_PATH/Contents/MacOS/Semper"
if [[ ! -f "$installed_info" || ! -x "$installed_executable" ]]; then
    fail_with_restore "the installed app is incomplete."
fi
if ! verify_app_signature "$INSTALL_PATH"; then
    fail_with_restore "the installed app does not have a valid persistent code signature."
fi

if ! verified_version="$(
    /usr/libexec/PlistBuddy \
        -c 'Print :CFBundleShortVersionString' \
        "$installed_info"
)"; then
    fail_with_restore "the installed app version could not be read."
fi
if ! built_checksum="$(
    shasum -a 256 "$built_executable" | awk '{ print $1 }'
)"; then
    fail_with_restore "the built app checksum could not be read."
fi
if ! installed_checksum="$(
    shasum -a 256 "$installed_executable" | awk '{ print $1 }'
)"; then
    fail_with_restore "the installed app checksum could not be read."
fi
if [[ ! "$built_checksum" =~ ^[0-9a-f]{64}$ \
    || ! "$installed_checksum" =~ ^[0-9a-f]{64}$ ]]; then
    fail_with_restore "replacement verification produced an invalid checksum."
fi
if [[ "$verified_version" != "$latest_version" \
    || "$installed_checksum" != "$built_checksum" ]]; then
    fail_with_restore "replacement verification failed."
fi

if ! open "$INSTALL_PATH"; then
    fail_with_restore "Semper was installed, but macOS could not open it."
fi

if [[ "$had_existing_app" == true ]]; then
    if ! run_privileged rm -rf "$backup_path"; then
        echo "Warning: the update succeeded, but the backup remains at $backup_path." >&2
    fi
fi
install_in_progress=false

echo "Semper $verified_version (${latest_revision:0:8}) is installed and open."
