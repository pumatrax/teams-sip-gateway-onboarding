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

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

join_url() {
    printf '%s/%s' "${1%/}" "$2"
}

redact_url() {
    printf '%s\n' "$1" |
        sed -E \
            -e 's#(/device/ob/)[^/]+#\1<OB-HASH>#' \
            -e 's#(/device/state/OnBoarding/mmiiaacc/)[^/]+#\1<STATE-TOKEN>#' \
            -e 's#(/device/mmiiaacc/)[^/]+#\1<STATE-TOKEN>#'
}

# Read a single line into the named variable, failing cleanly on EOF
# (e.g. piped/redirected stdin) instead of dying under `set -e` with no message.
# Returns 2 on EOF so callers can distinguish "no input" from other failures.
read_line() {
    local __var="$1"
    local __prompt="$2"
    local __value

    printf '%s' "$__prompt"

    if ! IFS= read -r __value; then
        echo >&2
        echo "Error: input ended before a response was received." >&2
        return 2
    fi

    printf -v "$__var" '%s' "$__value"
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

fetch_cfg() {
    local base_url="$1"
    local output="$2"
    local label="$3"
    local request_url
    local status

    request_url="$(join_url "$base_url" "${MAC}.cfg")"

    echo
    echo "$label"
    echo "  URL:        $(redact_url "$request_url")"
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
        echo "Error: curl failed for $(redact_url "$request_url")" >&2
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
            echo "Error: awk failed while parsing: $config_file" >&2
            return 2
            ;;
    esac
}

file_hash() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        echo "Error: no SHA-256 tool (shasum or sha256sum) found." >&2
        return 1
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

# Classify a downloaded Stage 3 config by reading what the stage itself provides,
# rather than pattern-matching a hard-coded SBC hostname.
#
# The onboarding flow's own signals:
#   - Temporary state: account uses an @onboarding.org user_name, and/or the
#     provisioning URL still points at the OnBoarding state path.
#   - Final state: the temporary @onboarding.org account is gone AND the
#     returned provisioning URL has explicitly moved to the persistent
#     /device/mmiiaacc/ device path.
#   - Anything else (including a parse/read failure, or a changed-but-ambiguous
#     config) is reported as unknown so the caller can save it for review
#     instead of acting on weak evidence.
#
# Prints one of: final | temporary | unknown
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

    # A parser or file-read failure must not be treated as a final config.
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

    # Strong final signal: the temporary identity is gone and the returned
    # provisioning URL has explicitly moved to a persistent device path.
    if [[ "$has_temp_account" == "no" &&
          "$rc" -eq 0 &&
          "$next_url" == *"/device/mmiiaacc/"* ]]; then
        printf 'final\n'
        return 0
    fi

    # The file changed, but there is not enough evidence to call it final.
    printf 'unknown\n'
    return 0
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

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------

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

echo "  Stage 2 URL: $(redact_url "$STAGE2_URL")"

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
echo "  $(redact_url "$STAGE3_URL")"
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

if ! require_confirmation "Has Stage 1 finished importing?"; then
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

if ! require_confirmation "Has Stage 2 finished importing and has the phone completed its reboot?"; then
    echo "Stopped. The preserved Stage 3 URL is saved in: $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# TAC verification.
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
    echo "Stopped. The preserved Stage 3 URL is saved in: $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Browser sign-in.
# ---------------------------------------------------------------------------

echo
echo "Complete Teams sign-in in a computer browser"
echo "using the Teams phone user account."

if ! require_confirmation "Is the browser sign-in fully completed?"; then
    echo "Stopped. The preserved Stage 3 URL is saved in: $SESSION_FILE"
    exit 0
fi

# ---------------------------------------------------------------------------
# Poll the same Stage 3 URL.
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
echo "Waiting ${WAIT_MINUTES} minute(s) before checking the preserved Stage 3 URL..."
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
    echo "  Reusing preserved URL:"
    echo "  $(redact_url "$STAGE3_URL")"

    if fetch_cfg "$STAGE3_URL" "$ATTEMPT_FILE" "Stage 3 download"; then
        ATTEMPT_HASH="$(file_hash "$ATTEMPT_FILE")"
        echo "  Stage 3 SHA-256: $ATTEMPT_HASH"

        if [[ "$ATTEMPT_HASH" == "$STAGE2_HASH" ]]; then
            echo "Stage 3 is still identical to Stage 2 (still onboarding)."
        else
            # The config changed. Classify it by the stage's own signals
            # (temporary onboarding account / provisioning URL transition),
            # not by a hard-coded SBC hostname.
            state="$(classify_config "$ATTEMPT_FILE")"
            echo "  Config changed from Stage 2. Classification: $state"

            case "$state" in
                final)
                    cp "$ATTEMPT_FILE" "$FINAL_FILE"
                    chmod 600 "$FINAL_FILE"
                    UPDATED=1

                    echo
                    echo "Final Stage 3 configuration detected."
                    echo "  (Temporary onboarding account cleared; provisioning URL"
                    echo "   moved to the persistent /device/mmiiaacc/ path.)"
                    echo "Final configuration saved as:"
                    echo "  $FINAL_FILE"

                    show_credential_summary "$FINAL_FILE"
                    break
                    ;;
                temporary)
                    echo "Config changed but still shows onboarding-stage indicators."
                    echo "Continuing to poll the same preserved URL."
                    ;;
                *)
                    # Changed, but neither clearly temporary nor clearly final.
                    # Do NOT discard it: save the most recent changed config as a
                    # candidate so a naming/convention surprise degrades to
                    # "here's a likely-final config, verify it" instead of a loss.
                    cp "$ATTEMPT_FILE" "$CANDIDATE_FILE"
                    chmod 600 "$CANDIDATE_FILE"
                    CANDIDATE_SAVED=1
                    echo "Config changed but could not be positively classified."
                    echo "Saved as a candidate for manual review:"
                    echo "  $CANDIDATE_FILE"
                    echo "Continuing to poll in case a clearer final config arrives."
                    ;;
            esac
        fi
    fi

    if [[ "$attempt" -lt "$POLL_ATTEMPTS" ]]; then
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
elif [[ "$CANDIDATE_SAVED" -eq 1 ]]; then
    echo "No positively-verified final config was detected, but the Stage 3"
    echo "configuration DID change from Stage 2. A candidate was saved:"
    echo "  $CANDIDATE_FILE"
    echo
    echo "Review it manually. If it contains your assigned user account and a"
    echo "production (non-onboarding) SIP server, it is likely the final config."
    echo "Do not rerun Stage 1 or Stage 2."
else
    echo "No Stage 3 change was detected during the polling window."
    echo "Do not rerun Stage 1 or Stage 2."
    echo "The preserved session is saved in:"
    echo "  $SESSION_FILE"
    echo
    echo "Manual retry command:"
    echo "  Source the protected session file first:"
    echo "    . \"$SESSION_FILE\""
    echo
    echo "  Then run:"
    echo "    curl -v -L \\"
    echo "      -A \"\$USER_AGENT\" \\"
    echo "      \"\${STAGE3_URL%/}/\${MAC}.cfg\" \\"
    echo "      -o \"\${MAC}-stage3-later.cfg\""
fi

echo
echo "All files and logs are in:"
echo "  $OUT_DIR/"
