#!/usr/bin/env bash
set -Eeuo pipefail

# Interactive Teams SIP onboarding capture
#
# Usage:
#   ./teams_onboarding_flow.sh MAC [MODEL] [FIRMWARE]
#
# Example:
#   ./teams_onboarding_flow.sh 805ec033dc69 T57W 96.86.5.1
#
# Important:
# - Stage 1 is requested only once.
# - Stage 2 is requested only once.
# - The exact Stage 3 URL minted by Stage 2 is preserved and reused.
# - After browser sign-in, the script polls that same Stage 3 URL until
#   the returned configuration changes or the timeout is reached.
# - Compatible with the older Bash version included with macOS.

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
        IFS= read -r answer
        normalized="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"

        case "$normalized" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
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

    case "$status" in
        2??) return 0 ;;
        *)
            echo "Error: request failed with HTTP $status" >&2
            rm -f "$output"
            return 1
            ;;
    esac
}

extract_next_url() {
    local config_file="$1"

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
                exit
            }
        }
    ' "$config_file"
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
    echo "Credential-related values in $(basename "$config_file"):"
    grep -Ei \
        '^[[:space:]]*account\.[0-9]+\.(user_name|auth_name|password|sip_server\.[0-9]+\.address)[[:space:]]*=' \
        "$config_file" || echo "  No matching credential fields found."
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
echo "Do not rerun Stage 1 or Stage 2 during this onboarding session."
echo "The Stage 3 URL minted below will be preserved and reused."

STAGE1_FILE="${OUT_DIR}/${MAC}-stage1.cfg"

fetch_cfg "$INITIAL_URL" "$STAGE1_FILE" "Stage 1 download" || exit 1

STAGE2_URL="$(extract_next_url "$STAGE1_FILE" || true)"

if [[ -z "$STAGE2_URL" ]]; then
    echo "Error: Stage 1 did not contain auto_provision.server.url." >&2
    exit 1
fi

echo "  Stage 2 URL: $STAGE2_URL"

echo
echo "ACTION REQUIRED:"
echo "  Upload/apply this file to the phone:"
echo "  $STAGE1_FILE"

if ! confirm "Have you uploaded/applied Stage 1 and are you ready to continue?"; then
    echo "Stopped. Resume manually using the files in $OUT_DIR."
    exit 0
fi

STAGE2_FILE="${OUT_DIR}/${MAC}-stage2.cfg"

fetch_cfg "$STAGE2_URL" "$STAGE2_FILE" "Stage 2 download" || exit 1

STAGE3_URL="$(extract_next_url "$STAGE2_FILE" || true)"

if [[ -z "$STAGE3_URL" ]]; then
    echo "Error: Stage 2 did not contain the Stage 3 URL." >&2
    exit 1
fi

STAGE2_HASH="$(file_hash "$STAGE2_FILE")"
save_session

echo "  Stage 3 URL preserved as:"
echo "  $STAGE3_URL"
echo
echo "  Stage 2 SHA-256: $STAGE2_HASH"

show_credential_summary "$STAGE2_FILE"

echo
echo "ACTION REQUIRED:"
echo "  1. Upload/apply this Stage 2 file to the phone:"
echo "     $STAGE2_FILE"
echo "  2. Reboot the phone if your workflow requires it."

if ! confirm "Have you uploaded/applied Stage 2 and completed the reboot?"; then
    echo "Stopped. The preserved Stage 3 URL is in:"
    echo "  $SESSION_FILE"
    exit 0
fi

echo
printf 'Enter the provisioning verification code shown to you: '
IFS= read -r VERIFY_CODE

if [[ -z "$VERIFY_CODE" ]]; then
    echo "No verification code entered." >&2
    exit 1
fi

echo
echo "Dial this on the phone:"
echo "  *55*${VERIFY_CODE}"

if ! confirm "Have you dialed *55*${VERIFY_CODE} and completed the verification step?"; then
    echo "Stopped. The Stage 3 URL remains saved in $SESSION_FILE."
    exit 0
fi

echo
echo "Now complete Teams sign-in in a computer browser using the Teams phone user account."

if ! confirm "Is Teams sign-in fully completed in the computer browser?"; then
    echo "Stopped. The Stage 3 URL remains saved in $SESSION_FILE."
    exit 0
fi

printf 'Minutes to wait before the first Stage 3 check [3]: '
IFS= read -r WAIT_MINUTES
WAIT_MINUTES="${WAIT_MINUTES:-3}"

if [[ ! "$WAIT_MINUTES" =~ ^[0-9]+$ ]]; then
    echo "Error: wait time must be a whole number of minutes." >&2
    exit 2
fi

printf 'Maximum minutes to poll Stage 3 for updated credentials [10]: '
IFS= read -r POLL_MINUTES
POLL_MINUTES="${POLL_MINUTES:-10}"

if [[ ! "$POLL_MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "Error: polling time must be a positive whole number." >&2
    exit 2
fi

echo
echo "Waiting ${WAIT_MINUTES} minute(s) before using the preserved Stage 3 URL..."
sleep "$((WAIT_MINUTES * 60))"

POLL_INTERVAL=60
MAX_ATTEMPTS=$((POLL_MINUTES * 60 / POLL_INTERVAL))
if (( MAX_ATTEMPTS < 1 )); then
    MAX_ATTEMPTS=1
fi

FINAL_FILE="${OUT_DIR}/${MAC}-stage3-final.cfg"
UPDATED=0

for ((attempt = 1; attempt <= MAX_ATTEMPTS; attempt++)); do
    ATTEMPT_FILE="${OUT_DIR}/${MAC}-stage3-attempt${attempt}.cfg"

    echo
    echo "Stage 3 check $attempt of $MAX_ATTEMPTS"
    echo "  Reusing the original Stage 3 URL:"
    echo "  $STAGE3_URL"

    if fetch_cfg "$STAGE3_URL" "$ATTEMPT_FILE" "Stage 3 download"; then
        ATTEMPT_HASH="$(file_hash "$ATTEMPT_FILE")"

        echo "  Stage 3 SHA-256: $ATTEMPT_HASH"

        if [[ "$ATTEMPT_HASH" != "$STAGE2_HASH" ]]; then
            cp "$ATTEMPT_FILE" "$FINAL_FILE"
            UPDATED=1

            echo
            echo "Stage 3 content changed from Stage 2."
            echo "Updated configuration saved as:"
            echo "  $FINAL_FILE"

            show_credential_summary "$FINAL_FILE"
            break
        fi

        echo "Stage 3 is still identical to Stage 2."
    fi

    if (( attempt < MAX_ATTEMPTS )); then
        echo "Waiting 60 seconds before checking the same Stage 3 URL again..."
        sleep "$POLL_INTERVAL"
    fi
done

echo
echo "============================================================"

if (( UPDATED == 1 )); then
    echo "Onboarding update detected."
    echo "Use the final Stage 3 file:"
    echo "  $FINAL_FILE"
else
    echo "No Stage 3 change was detected during the polling window."
    echo "The exact session URL was preserved; do not restart Stage 1 or Stage 2."
    echo "Session details:"
    echo "  $SESSION_FILE"
    echo
    echo "You can manually retry the same Stage 3 URL with:"
    echo "  curl -v -L -A \"$USER_AGENT\" \\"
    echo "    \"$(join_url "$STAGE3_URL" "${MAC}.cfg")\" \\"
    echo "    -o \"${MAC}-stage3-later.cfg\""
fi

echo "All files and logs are in:"
echo "  $OUT_DIR/"
