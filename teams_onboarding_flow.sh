#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# Interactive Microsoft Teams SIP Gateway onboarding capture for tested Yealink devices.
#
# Usage:
#   ./teams_onboarding_flow.sh MAC [MODEL] [FIRMWARE]
#
# Example:
#   ./teams_onboarding_flow.sh 60-22-32-ed-e5-e2 T57W 96.86.5.1
#
# IMPORTANT:
# - This script prints and logs the REAL Stage 2 and Stage 3 URLs so failures
#   can be diagnosed. Treat workflow.log and session.env as sensitive.
# - Stage 1 is downloaded once, then imported into the phone.
# - Stage 2 is not requested until you confirm Stage 1 finished importing.
# - Stage 2 is downloaded once.
# - The exact Stage 3 URL returned by Stage 2 is preserved and reused.
# - Do not publish generated CFG files, workflow.log, or session.env.

INITIAL_URL="http://noam.ipp.sdg.teams.microsoft.com"

MAC_INPUT="${1:?Usage: $0 MAC [MODEL] [FIRMWARE]}"
MODEL="${2:-T57W}"
FIRMWARE="${3:-96.86.5.1}"

MAC="$(printf '%s' "$MAC_INPUT" | tr '[:upper:]' '[:lower:]' | tr -d ':-.')"

if [[ ! "$MAC" =~ ^[0-9a-f]{12}$ ]]; then
    echo "Error: invalid MAC address: $MAC_INPUT" >&2
    exit 2
fi

MAC_COLON="$(printf '%s' "$MAC" | sed 's/../&:/g; s/:$//')"
USER_AGENT="Yealink SIP-${MODEL} ${FIRMWARE} ${MAC_COLON}"

RUN_ID="$(date '+%Y%m%d-%H%M%S')"
OUT_DIR="${MAC}-onboarding-${RUN_ID}"
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

SESSION_FILE="${OUT_DIR}/session.env"
LOG_FILE="${OUT_DIR}/workflow.log"

exec > >(tee -a "$LOG_FILE") 2>&1

join_url() {
    printf '%s/%s' "${1%/}" "$2"
}

read_line() {
    local variable_name="$1"
    local prompt="$2"
    local value

    printf '%s' "$prompt"

    if ! IFS= read -r value; then
        echo >&2
        echo "Error: input ended before a response was received." >&2
        return 2
    fi

    printf -v "$variable_name" '%s' "$value"
}

confirm() {
    local prompt="$1"
    local answer
    local normalized

    while true; do
        printf '%s [yes/no]: ' "$prompt"

        if ! IFS= read -r answer; then
            echo >&2
            echo "Error: input ended before a response was received." >&2
            return 2
        fi

        normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"

        case "$normalized" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) echo "Please enter yes or no." ;;
        esac
    done
}

require_confirmation() {
    local prompt="$1"
    local rc

    if confirm "$prompt"; then
        return 0
    else
        rc=$?
    fi

    case "$rc" in
        1) return 1 ;;
        *)
            echo "Error: confirmation input failed." >&2
            exit 1
            ;;
    esac
}

extract_next_url() {
    local config_file="$1"
    local value
    local rc

    if [[ ! -r "$config_file" ]]; then
        echo "Error: cannot read configuration file: $config_file" >&2
        return 2
    fi

    if value="$(
        awk '
            {
                gsub(/\r/, "", $0)
            }

            /^[[:space:]]*(static\.)?auto_provision\.server\.url[[:space:]]*=/ {
                value = $0
                sub(/^[^=]*=[[:space:]]*/, "", value)
                sub(/[[:space:]]*(#.*)?$/, "", value)

                if (value != "") {
                    print value
                    found = 1
                    exit
                }
            }

            END {
                if (!found) {
                    exit 10
                }
            }
        ' "$config_file"
    )"; then
        printf '%s\n' "$value"
        return 0
    else
        rc=$?
    fi

    case "$rc" in
        10) return 1 ;;
        *)
            echo "Error: failed to parse provisioning URL from: $config_file" >&2
            return 2
            ;;
    esac
}

validate_runtime_url() {
    local url="$1"
    local label="$2"

    case "$url" in
        *'<OB-HASH>'*|*'<STATE-TOKEN>'*)
            echo "Error: $label contains a literal documentation placeholder:" >&2
            echo "  $url" >&2
            return 1
            ;;
    esac

    case "$url" in
        http://*|https://*) return 0 ;;
        *)
            echo "Error: $label is not an HTTP/HTTPS URL:" >&2
            echo "  $url" >&2
            return 1
            ;;
    esac
}

fetch_cfg() {
    local base_url="$1"
    local output="$2"
    local label="$3"
    local request_url
    local status
    local failed_file

    request_url="$(join_url "$base_url" "${MAC}.cfg")"

    echo
    echo "$label"
    echo "  REAL URL:   $request_url"
    echo "  User-Agent: $USER_AGENT"
    echo "  Output:     $output"

    if status="$(
        curl \
            --silent \
            --show-error \
            --location \
            --connect-timeout 15 \
            --max-time 90 \
            --retry 2 \
            --retry-delay 3 \
            --user-agent "$USER_AGENT" \
            --output "$output" \
            --write-out '%{http_code}' \
            "$request_url"
    )"; then
        :
    else
        echo "Error: curl failed before a valid HTTP response was completed." >&2

        if [[ -e "$output" ]]; then
            failed_file="${output}.curl-failed"
            mv "$output" "$failed_file"
            chmod 600 "$failed_file"
            echo "Partial response retained as:"
            echo "  $failed_file"
        fi

        return 1
    fi

    echo "  HTTP:       $status"

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        chmod 600 "$output"
        return 0
    fi

    failed_file="${output}.http-${status}"

    if [[ -e "$output" ]]; then
        mv "$output" "$failed_file"
        chmod 600 "$failed_file"
        echo "Failed HTTP response retained as:"
        echo "  $failed_file"
    else
        echo "No response body was saved."
    fi

    echo "Error: request failed with HTTP $status" >&2
    return 1
}

file_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "Error: no SHA-256 tool found." >&2
        return 1
    fi
}

show_credential_summary() {
    local config_file="$1"

    echo
    echo "Credential summary in $(basename "$config_file"):"
    echo "  Password values are present in the CFG but are not printed here."

    grep -Ei \
        '^[[:space:]]*account\.[0-9]+\.(display_name|label|user_name|auth_name|sip_server\.[0-9]+\.address)[[:space:]]*=' \
        "$config_file" || echo "  No matching non-password fields found."

    if grep -Eiq \
        '^[[:space:]]*account\.[0-9]+\.password[[:space:]]*=' \
        "$config_file"; then
        echo "  account password: [present, redacted]"
    fi
}

classify_config() {
    local config_file="$1"
    local next_url=""
    local rc
    local has_temp_account="no"
    local url_is_onboarding="no"

    if next_url="$(extract_next_url "$config_file")"; then
        rc=0
    else
        rc=$?
    fi

    if [[ "$rc" -eq 2 ]]; then
        printf 'unknown\n'
        return 0
    fi

    if grep -Eiq \
        '^[[:space:]]*account\.[0-9]+\.user_name[[:space:]]*=.*@onboarding\.org' \
        "$config_file"; then
        has_temp_account="yes"
    fi

    if [[ "$rc" -eq 0 ]]; then
        case "$next_url" in
            */device/state/OnBoarding/*|*/device/ob/*)
                url_is_onboarding="yes"
                ;;
        esac
    fi

    if [[ "$has_temp_account" == "yes" || "$url_is_onboarding" == "yes" ]]; then
        printf 'temporary\n'
        return 0
    fi

    if [[ "$has_temp_account" == "no" &&
          "$rc" -eq 0 &&
          "$next_url" == *"/device/mmiiaacc/"* ]]; then
        printf 'final\n'
        return 0
    fi

    printf 'unknown\n'
}

save_session() {
    cat > "$SESSION_FILE" <<EOF_SESSION
MAC='$MAC'
MAC_COLON='$MAC_COLON'
MODEL='$MODEL'
FIRMWARE='$FIRMWARE'
USER_AGENT='$USER_AGENT'
STAGE1_URL='$INITIAL_URL'
STAGE2_URL='$STAGE2_URL'
STAGE3_URL='$STAGE3_URL'
EOF_SESSION

    chmod 600 "$SESSION_FILE"
}

echo "============================================================"
echo "Teams SIP onboarding workflow"
echo "============================================================"
echo "MAC:        $MAC"
echo "Model:      $MODEL"
echo "Firmware:   $FIRMWARE"
echo "User-Agent: $USER_AGENT"
echo "Run folder: $OUT_DIR"
echo
echo "WARNING:"
echo "  This run prints and logs the real provisioning URLs."
echo "  Do not share or commit $LOG_FILE or $SESSION_FILE."

# ---------------------------------------------------------------------------
# Stage 1
# ---------------------------------------------------------------------------

STAGE1_FILE="${OUT_DIR}/${MAC}-stage1.cfg"
fetch_cfg "$INITIAL_URL" "$STAGE1_FILE" "Stage 1 download" || exit 1

if STAGE2_URL="$(extract_next_url "$STAGE1_FILE")"; then
    :
else
    rc=$?
    case "$rc" in
        1) echo "Error: Stage 1 did not contain an auto-provisioning URL." >&2 ;;
        *) echo "Error: Stage 1 URL extraction failed." >&2 ;;
    esac
    exit 1
fi

validate_runtime_url "$STAGE2_URL" "Stage 2 URL" || exit 1

echo
echo "Stage 1 supplied this REAL Stage 2 base URL:"
echo "  $STAGE2_URL"
echo
echo "ACTION REQUIRED - STAGE 1:"
echo "  Upload/import this file into the phone:"
echo "  $STAGE1_FILE"
echo
echo "  Wait for the import to finish before answering yes."

if ! require_confirmation "Has Stage 1 finished importing?"; then
    echo "Stopped. Files remain in:"
    echo "  $OUT_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Stage 2
# ---------------------------------------------------------------------------

STAGE2_FILE="${OUT_DIR}/${MAC}-stage2.cfg"

if ! fetch_cfg "$STAGE2_URL" "$STAGE2_FILE" "Stage 2 download"; then
    echo
    echo "Stage 2 failed."
    echo "Verify the REAL URL printed above matches Stage 1 exactly, followed by:"
    echo "  ${MAC}.cfg"
    echo
    echo "Do not rerun Stage 1 yet. Inspect the retained HTTP response and log:"
    echo "  $LOG_FILE"
    exit 1
fi

if STAGE3_URL="$(extract_next_url "$STAGE2_FILE")"; then
    :
else
    rc=$?
    case "$rc" in
        1) echo "Error: Stage 2 did not contain a Stage 3 URL." >&2 ;;
        *) echo "Error: Stage 2 URL extraction failed." >&2 ;;
    esac
    exit 1
fi

validate_runtime_url "$STAGE3_URL" "Stage 3 URL" || exit 1

STAGE2_HASH="$(file_hash "$STAGE2_FILE")" || exit 1
save_session

echo
echo "Stage 2 saved successfully:"
echo "  $STAGE2_FILE"
echo
echo "REAL Stage 3 URL preserved:"
echo "  $STAGE3_URL"
echo
echo "Protected session file:"
echo "  $SESSION_FILE"
echo
echo "Stage 2 SHA-256:"
echo "  $STAGE2_HASH"

show_credential_summary "$STAGE2_FILE"

echo
echo "ACTION REQUIRED - STAGE 2:"
echo "  Upload/import this file into the phone:"
echo "  $STAGE2_FILE"
echo
echo "  Allow the phone to reboot."
echo "  When it returns, it should show connected and ready for onboarding."

if ! require_confirmation "Has Stage 2 finished importing and has the phone rebooted?"; then
    echo "Stopped. The preserved Stage 3 URL remains in:"
    echo "  $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# TAC verification
# ---------------------------------------------------------------------------

echo
if ! read_line VERIFY_CODE 'Enter the TAC provisioning verification code: '; then
    exit 1
fi

if [[ -z "$VERIFY_CODE" ]]; then
    echo "Error: no verification code entered." >&2
    exit 1
fi

echo
echo "Dial this from the phone:"
echo "  *55*${VERIFY_CODE}"

if ! require_confirmation "Did the *55* call complete and place the device into sign-in mode?"; then
    echo "Stopped. Session retained in:"
    echo "  $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Browser sign-in
# ---------------------------------------------------------------------------

echo
echo "Complete Teams sign-in in a computer browser"
echo "using the Teams phone user account."

if ! require_confirmation "Is browser sign-in fully complete?"; then
    echo "Stopped. Session retained in:"
    echo "  $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Stage 3 polling
# ---------------------------------------------------------------------------

echo
if ! read_line WAIT_MINUTES 'Minutes to wait before the first Stage 3 check [3]: '; then
    exit 1
fi
WAIT_MINUTES="${WAIT_MINUTES:-3}"

if [[ ! "$WAIT_MINUTES" =~ ^[0-9]+$ ]]; then
    echo "Error: wait time must be a whole number." >&2
    exit 2
fi

if ! read_line POLL_ATTEMPTS 'Maximum number of Stage 3 checks [10]: '; then
    exit 1
fi
POLL_ATTEMPTS="${POLL_ATTEMPTS:-10}"

if [[ ! "$POLL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: number of checks must be a positive whole number." >&2
    exit 2
fi

echo
echo "Waiting ${WAIT_MINUTES} minute(s)..."
sleep "$((WAIT_MINUTES * 60))"

FINAL_FILE="${OUT_DIR}/${MAC}-stage3-final.cfg"
CANDIDATE_FILE="${OUT_DIR}/${MAC}-stage3-changed.cfg"
UPDATED=0
CANDIDATE_SAVED=0
attempt=1

while [[ "$attempt" -le "$POLL_ATTEMPTS" ]]; do
    ATTEMPT_FILE="${OUT_DIR}/${MAC}-stage3-attempt${attempt}.cfg"

    echo
    echo "Stage 3 check $attempt of $POLL_ATTEMPTS"
    echo "  REAL URL: $(join_url "$STAGE3_URL" "${MAC}.cfg")"

    if fetch_cfg "$STAGE3_URL" "$ATTEMPT_FILE" "Stage 3 download"; then
        ATTEMPT_HASH="$(file_hash "$ATTEMPT_FILE")" || exit 1
        echo "  Stage 3 SHA-256: $ATTEMPT_HASH"

        if [[ "$ATTEMPT_HASH" == "$STAGE2_HASH" ]]; then
            echo "Stage 3 is still identical to Stage 2."
        else
            STATE="$(classify_config "$ATTEMPT_FILE")"
            echo "  Classification: $STATE"

            case "$STATE" in
                final)
                    cp "$ATTEMPT_FILE" "$FINAL_FILE"
                    chmod 600 "$FINAL_FILE"
                    UPDATED=1

                    echo
                    echo "Final Stage 3 configuration detected:"
                    echo "  $FINAL_FILE"
                    show_credential_summary "$FINAL_FILE"
                    break
                    ;;
                temporary)
                    echo "The config changed but still contains onboarding indicators."
                    ;;
                *)
                    cp "$ATTEMPT_FILE" "$CANDIDATE_FILE"
                    chmod 600 "$CANDIDATE_FILE"
                    CANDIDATE_SAVED=1

                    echo "Changed config saved for manual review:"
                    echo "  $CANDIDATE_FILE"
                    ;;
            esac
        fi
    fi

    if [[ "$attempt" -lt "$POLL_ATTEMPTS" ]]; then
        echo "Waiting 60 seconds before the next check..."
        sleep 60
    fi

    attempt=$((attempt + 1))
done

echo
echo "============================================================"

if [[ "$UPDATED" -eq 1 ]]; then
    echo "Upload/import the final file:"
    echo "  $FINAL_FILE"
elif [[ "$CANDIDATE_SAVED" -eq 1 ]]; then
    echo "No positively classified final config was found."
    echo "Review the changed candidate:"
    echo "  $CANDIDATE_FILE"
    echo "Do not rerun Stage 1 or Stage 2."
else
    echo "No Stage 3 change was detected."
    echo "Do not rerun Stage 1 or Stage 2."
    echo "Session details remain in:"
    echo "  $SESSION_FILE"
fi

echo
echo "All files and logs are in:"
echo "  $OUT_DIR/"
