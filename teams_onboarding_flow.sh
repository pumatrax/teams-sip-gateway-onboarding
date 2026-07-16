#!/usr/bin/env bash
set -Eeuo pipefail

# Protect generated credentials, session URLs, and logs.
umask 077

# Manual Microsoft Teams SIP Gateway onboarding workflow for tested Yealink devices.
#
# Usage:
#   ./teams_onboarding_flow.sh MAC [MODEL] [FIRMWARE]
#
# Example:
#   ./teams_onboarding_flow.sh 805eXXXXdc69 T57W 96.86.5.1
#
# Workflow:
#   1. Download Stage 1 once.
#   2. Parse Stage 1 and download Stage 2 once.
#   3. Preserve the exact Stage 3 URL created by Stage 2.
#   4. Pause for Stage 1 import.
#   5. Pause for Stage 2 import and phone reboot.
#   6. Prompt for the TAC verification code and display *55*<code>.
#   7. Pause for Teams sign-in in a computer browser.
#   8. Poll the same preserved Stage 3 URL until the configuration changes.
#
# Compatible with the Bash 3.2 version included with macOS.

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

fetch_cfg() {
    local base_url="$1"
    local output="$2"
    local label="$3"
    local request_url
    local status

    request_url="$(join_url "$base_url" "${MAC}.cfg")"

    echo
    echo "$label"
    echo "  URL:        $request_url"
    echo "  User-Agent: $USER_AGENT"

    status="$(
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
    )" || {
        echo "Error: curl failed for $request_url" >&2
        rm -f "$output"
        return 1
    }

    echo "  HTTP:       $status"

    if [[ "$status" =~ ^2[0-9][0-9]$ ]]; then
        return 0
    fi

    echo "Error: request failed with HTTP $status" >&2
    rm -f "$output"
    return 1
}

extract_next_url() {
    local config_file="$1"
    local value

    if [[ ! -r "$config_file" ]]; then
        echo "Error: cannot read configuration file: $config_file" >&2
        return 2
    fi

    if ! value="$(
        awk '
            {
                gsub(/\r/, "", $0)
            }

            /^[[:space:]]*(static\.)?auto_provision\.server\.url[[:space:]]*=/ {
                result = $0
                sub(/^[^=]*=[[:space:]]*/, "", result)
                sub(/[[:space:]]*(#.*)?$/, "", result)

                if (result != "") {
                    print result
                    found = 1
                    exit
                }
            }

            END {
                if (!found) {
                    exit 1
                }
            }
        ' "$config_file"
    )"; then
        return 1
    fi

    printf '%s\n' "$value"
}

file_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        sha256sum "$1" | awk '{print $1}'
    fi
}

show_credential_summary() {
    local config_file="$1"

    echo
    echo "Credential summary in $(basename "$config_file"):"
    echo "  Password values are intentionally not printed or written to workflow.log."

    grep -Ei \
        '^[[:space:]]*account\.[0-9]+\.(display_name|label|user_name|auth_name|sip_server\.[0-9]+\.address)[[:space:]]*=' \
        "$config_file" || echo "  No matching non-password fields found."

    if grep -Eiq \
        '^[[:space:]]*account\.[0-9]+\.password[[:space:]]*=' \
        "$config_file"; then
        echo "  account password: [present, redacted]"
    fi
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
echo "Stage 1 and Stage 2 will now be downloaded once."
echo "The exact Stage 3 URL will be preserved before any import prompts."

# ---------------------------------------------------------------------------
# Download Stage 1.
# ---------------------------------------------------------------------------

STAGE1_FILE="${OUT_DIR}/${MAC}-stage1.cfg"
fetch_cfg "$INITIAL_URL" "$STAGE1_FILE" "Stage 1 download" || exit 1

set +e
STAGE2_URL="$(extract_next_url "$STAGE1_FILE")"
rc=$?
set -e

case "$rc" in
    0) ;;
    1)
        echo "Error: Stage 1 did not contain an auto-provisioning URL." >&2
        exit 1
        ;;
    *)
        echo "Error: Stage 1 URL extraction failed." >&2
        exit 1
        ;;
esac

echo "  Stage 2 URL: $STAGE2_URL"

# ---------------------------------------------------------------------------
# Download Stage 2 immediately and preserve Stage 3.
# ---------------------------------------------------------------------------

STAGE2_FILE="${OUT_DIR}/${MAC}-stage2.cfg"
fetch_cfg "$STAGE2_URL" "$STAGE2_FILE" "Stage 2 download" || exit 1

set +e
STAGE3_URL="$(extract_next_url "$STAGE2_FILE")"
rc=$?
set -e

case "$rc" in
    0) ;;
    1)
        echo "Error: Stage 2 did not contain the Stage 3 URL." >&2
        exit 1
        ;;
    *)
        echo "Error: Stage 2 URL extraction failed." >&2
        exit 1
        ;;
esac

STAGE2_HASH="$(file_hash "$STAGE2_FILE")"
save_session

echo
echo "Both initial configuration files are ready:"
echo "  Stage 1: $STAGE1_FILE"
echo "  Stage 2: $STAGE2_FILE"
echo
echo "Preserved Stage 3 URL:"
echo "  $STAGE3_URL"
echo
echo "Stage 2 SHA-256:"
echo "  $STAGE2_HASH"

show_credential_summary "$STAGE2_FILE"

# ---------------------------------------------------------------------------
# Import Stage 1.
# ---------------------------------------------------------------------------

echo
echo "ACTION REQUIRED - STAGE 1:"
echo "  Upload/import Stage 1 into the phone:"
echo "  $STAGE1_FILE"

if ! confirm "Has Stage 1 finished importing?"; then
    echo "Stopped. All downloaded files remain in: $OUT_DIR"
    exit 0
fi

# ---------------------------------------------------------------------------
# Import Stage 2 and reboot.
# ---------------------------------------------------------------------------

echo
echo "ACTION REQUIRED - STAGE 2:"
echo "  Upload/import Stage 2 into the phone:"
echo "  $STAGE2_FILE"
echo
echo "  The phone should reboot after Stage 2 is applied."
echo "  When it returns, it should show connected and ready for onboarding."

if ! confirm "Has Stage 2 finished importing and has the phone completed its reboot?"; then
    echo "Stopped. The preserved Stage 3 URL is saved in: $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# TAC verification.
# ---------------------------------------------------------------------------

echo
printf 'Enter the TAC provisioning verification code: '
IFS= read -r VERIFY_CODE

if [[ -z "$VERIFY_CODE" ]]; then
    echo "Error: no verification code entered." >&2
    exit 1
fi

echo
echo "Dial this from the phone:"
echo "  *55*${VERIFY_CODE}"

if ! confirm "Did the *55* call complete and place the device into sign-in mode?"; then
    echo "Stopped. The preserved Stage 3 URL is saved in: $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Browser sign-in.
# ---------------------------------------------------------------------------

echo
echo "Complete Teams sign-in in a computer browser"
echo "using the Teams phone user account."

if ! confirm "Is the browser sign-in fully completed?"; then
    echo "Stopped. The preserved Stage 3 URL is saved in: $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Poll the same Stage 3 URL.
# ---------------------------------------------------------------------------

echo
printf 'Minutes to wait before the first Stage 3 check [3]: '
IFS= read -r WAIT_MINUTES
WAIT_MINUTES="${WAIT_MINUTES:-3}"

if [[ ! "$WAIT_MINUTES" =~ ^[0-9]+$ ]]; then
    echo "Error: wait time must be a whole number." >&2
    exit 2
fi

printf 'Maximum minutes to poll Stage 3 [10]: '
IFS= read -r POLL_MINUTES
POLL_MINUTES="${POLL_MINUTES:-10}"

if [[ ! "$POLL_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: polling time must be a positive whole number." >&2
    exit 2
fi

echo
echo "Waiting ${WAIT_MINUTES} minute(s) before checking the preserved Stage 3 URL..."
sleep "$((WAIT_MINUTES * 60))"

FINAL_FILE="${OUT_DIR}/${MAC}-stage3-final.cfg"
UPDATED=0
attempt=1

while [[ "$attempt" -le "$POLL_MINUTES" ]]; do
    ATTEMPT_FILE="${OUT_DIR}/${MAC}-stage3-attempt${attempt}.cfg"

    echo
    echo "Stage 3 check $attempt of $POLL_MINUTES"
    echo "  Reusing preserved URL:"
    echo "  $STAGE3_URL"

    if fetch_cfg "$STAGE3_URL" "$ATTEMPT_FILE" "Stage 3 download"; then
        ATTEMPT_HASH="$(file_hash "$ATTEMPT_FILE")"
        echo "  Stage 3 SHA-256: $ATTEMPT_HASH"

        if [[ "$ATTEMPT_HASH" != "$STAGE2_HASH" ]]; then
            cp "$ATTEMPT_FILE" "$FINAL_FILE"
            UPDATED=1

            echo
            echo "Stage 3 changed from the temporary Stage 2 configuration."
            echo "Final configuration saved as:"
            echo "  $FINAL_FILE"

            show_credential_summary "$FINAL_FILE"
            break
        fi

        echo "Stage 3 is still identical to Stage 2."
    fi

    if [[ "$attempt" -lt "$POLL_MINUTES" ]]; then
        echo "Waiting 60 seconds before checking the same URL again..."
        sleep 60
    fi

    attempt=$((attempt + 1))
done

echo
echo "============================================================"

if [[ "$UPDATED" -eq 1 ]]; then
    echo "Final onboarding configuration detected."
    echo "Upload/import this file into the phone:"
    echo "  $FINAL_FILE"
else
    echo "No Stage 3 change was detected during the polling window."
    echo "Do not rerun Stage 1 or Stage 2."
    echo "The preserved session is saved in:"
    echo "  $SESSION_FILE"
    echo
    echo "Manual retry command:"
    echo "curl -v -L \\"
    echo "  -A \"$USER_AGENT\" \\"
    echo "  \"$(join_url "$STAGE3_URL" "${MAC}.cfg")\" \\"
    echo "  -o \"${MAC}-stage3-later.cfg\""
fi

echo
echo "All files and logs are in:"
echo "  $OUT_DIR/"
