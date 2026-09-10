#!/usr/bin/env bash

set -eo pipefail

# ==============================================================================
# LOGGING SETUP
# Each run gets its own timestamped log file under ~/baw-cicd-logs/ on the runner.
# On failure, response JSON files are preserved alongside the log for inspection.
# ==============================================================================
LOG_DIR="${HOME}/baw-cicd-logs"
mkdir -p "$LOG_DIR"
RUN_TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${LOG_DIR}/deploy_${RUN_TIMESTAMP}.log"

# log() writes to both stdout (visible in GitHub Actions UI) and the local log file.
log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

# is_2xx() returns 0 (true) if the given HTTP status code is in the 2xx range.
is_2xx() {
    [[ "$1" -ge 200 && "$1" -lt 300 ]]
}

# log_file_contents() dumps a file into the log (for response bodies, etc.)
log_file_contents() {
    local label="$1"
    local file="$2"
    log "--- $label ---"
    if [ -f "$file" ]; then
        cat "$file" | tee -a "$LOG_FILE"
    else
        log "(file not found: $file)"
    fi
    log "--- end $label ---"
}

# poll_async_url() polls a BAW async status URL (returned in the 'url' field of a 202 response)
# until it reports success, failure, or times out.
# Usage: poll_async_url <cookies_file> <poll_url> <status_file> <label> <poll_max>
poll_async_url() {
    local cookies_file="$1"
    local poll_url="$2"
    local status_file="$3"
    local label="$4"
    local poll_max="$5"
    local attempts=0

    while true; do
        attempts=$((attempts + 1))
        if [ "$attempts" -gt "$poll_max" ]; then
            DEPLOY_FAILED=1
            log "❌ Timed out waiting for $label after $((poll_max * 15 / 60)) minutes."
            exit 1
        fi

        curl -s $CURL_SSL_FLAGS -b "$cookies_file" "$poll_url" -o "$status_file"
        local STATUS
        STATUS=$(jq -r '.status // empty' "$status_file")
        log "⏱️ $label status: ${STATUS:-(empty)} (attempt $attempts/$poll_max)"

        if [ "$STATUS" = "success" ]; then
            log "✅ $label completed successfully."
            return 0
        elif [ "$STATUS" = "failed" ] || [ "$STATUS" = "error" ]; then
            DEPLOY_FAILED=1
            log "❌ $label failed."
            log_file_contents "$status_file" "$status_file"
            exit 1
        elif [ -z "$STATUS" ]; then
            log "⚠️  Empty status — logging raw response for inspection:"
            log_file_contents "$status_file (raw)" "$status_file"
        fi
        sleep 15
    done
}

log "====== BAW CICD Deploy Run Started ======"
log "Log file on runner: $LOG_FILE"

# --- Configuration Validation ---
REQUIRED_VARS=(
  CENTER_HOST CENTER_PORT CENTER_USER CENTER_PASSWORD 
  QA_HOST QA_PORT QA_USER QA_PASSWORD 
  PROCESS_APP_ACRONYM SNAPSHOT_NAME OFFLINE_SERVER_ACRONYM
)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR}" ]]; then
        log "❌ Error: Missing environment variable: $VAR"
        exit 1
    fi
done

# Log config (never log passwords)
log "CENTER_HOST=$CENTER_HOST  CENTER_PORT=$CENTER_PORT  CENTER_USER=$CENTER_USER"
log "QA_HOST=$QA_HOST  QA_PORT=$QA_PORT  QA_USER=$QA_USER"
log "PROCESS_APP_ACRONYM=$PROCESS_APP_ACRONYM  SNAPSHOT_NAME=$SNAPSHOT_NAME  OFFLINE_SERVER_ACRONYM=$OFFLINE_SERVER_ACRONYM"

# --- Configure SSL/TLS Validation Toggle ---
# Default to true (secure) if not explicitly set to false
CURL_SSL_FLAGS=""
if [[ "${VERIFY_SSL,,}" == "false" ]]; then
    log "⚠️ Warning: SSL verification is disabled (using self-signed certificates)."
    CURL_SSL_FLAGS="-k"
else
    log "🔒 SSL verification enabled. Strict certificate authority validation will occur."
fi

# Temp file targets
CENTER_COOKIES="center_cookies.txt"
QA_COOKIES="qa_cookies.txt"
PACKAGE_PATH="/tmp/downloaded_package.zip"

# Tracks whether the run ended in failure so cleanup can preserve debug files
DEPLOY_FAILED=0

cleanup() {
    log "🧹 Wiping runtime session files..."
    rm -f "$CENTER_COOKIES" "$QA_COOKIES" "$PACKAGE_PATH"

    if [ "$DEPLOY_FAILED" -eq 1 ]; then
        # On failure: preserve JSON response files next to the log for post-mortem
        for f in center_login.json center_queue.json center_queue_status.json \
                  qa_login.json qa_queue.json qa_queue_status.json; do
            if [ -f "$f" ]; then
                cp "$f" "${LOG_DIR}/$(basename "$f" .json)_${RUN_TIMESTAMP}.json"
                log "📎 Preserved for debug: ${LOG_DIR}/$(basename "$f" .json)_${RUN_TIMESTAMP}.json"
            fi
        done
        log "❌ Run FAILED. Full log + response files saved to: $LOG_DIR"
    else
        log "✅ Run completed successfully. Log: $LOG_FILE"
    fi

    rm -f center_login.json center_queue.json center_queue_status.json \
          qa_login.json qa_queue.json qa_queue_status.json
}
trap cleanup EXIT

# ==============================================================================
# STAGE 1: WORKFLOW CENTER OPERATIONS (Exporting Package)
# ==============================================================================
log "=== Phase 1: Workflow Center Package Extraction ==="
CENTER_BASE="https://${CENTER_HOST}:${CENTER_PORT}/ops"

log "🔒 Authenticating with Workflow Center..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -c "$CENTER_COOKIES" \
  -u "${CENTER_USER}:${CENTER_PASSWORD}" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"refresh_groups": true, "requested_lifetime": 7200}' \
  "${CENTER_BASE}/system/login" \
  -o center_login.json)

log "  → Login response HTTP status: $HTTP_STATUS"
if ! is_2xx "$HTTP_STATUS"; then
    DEPLOY_FAILED=1
    log "❌ Workflow Center authentication failed (HTTP $HTTP_STATUS). Response body:"
    log_file_contents "center_login.json" center_login.json
    exit 1
fi
CENTER_CSRF=$(jq -r '.csrf_token' center_login.json)
log "  → CSRF token acquired: ${CENTER_CSRF:0:8}... (truncated)"

log "🚀 Requesting offline package compilation for snapshot: $SNAPSHOT_NAME..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -b "$CENTER_COOKIES" \
  -H "BPMCSRFToken: ${CENTER_CSRF}" \
  -H "Accept: application/json" \
  "${CENTER_BASE}/std/bpm/containers/${PROCESS_APP_ACRONYM}/versions/${SNAPSHOT_NAME}/offline_package?server=${OFFLINE_SERVER_ACRONYM}" \
  -o center_queue.json)

log "  → Package request HTTP status: $HTTP_STATUS"
if ! is_2xx "$HTTP_STATUS"; then
    DEPLOY_FAILED=1
    log "❌ Package generation initiation failed ($HTTP_STATUS)."
    log_file_contents "center_queue.json" center_queue.json
    exit 1
fi

# Always log the raw response so the exact fields are visible
log_file_contents "center_queue.json (raw package request response)" center_queue.json

# BAW 202 response should contain a 'url' field per the async API spec.
# If absent (e.g. BAW returned 200 with a different schema), log all keys to help diagnose.
CENTER_POLL_URL=$(jq -r '.url // empty' center_queue.json)
if [ -z "$CENTER_POLL_URL" ] || [ "$CENTER_POLL_URL" = "null" ]; then
    log "⚠️  No 'url' field in response (HTTP $HTTP_STATUS). Available keys: $(jq -r 'keys[]' center_queue.json 2>/dev/null | tr '\n' ' ')"
    log "⏳ Falling back: waiting 30s for BAW to complete generation before attempting download..."
    sleep 30
else
    log "⏳ Package generation submitted. Polling: $CENTER_POLL_URL"
    # Poll using the URL provided by BAW — timeout after 20 minutes (80 × 15s)
    poll_async_url "$CENTER_COOKIES" "$CENTER_POLL_URL" "center_queue_status.json" "Package generation" 80
fi

log "📥 Downloading generated archive to runner machine..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" \
  -b "$CENTER_COOKIES" \
  "${CENTER_BASE}/std/bpm/containers/${PROCESS_APP_ACRONYM}/versions/${SNAPSHOT_NAME}/install_package" \
  -o "$PACKAGE_PATH")

log "  → Download HTTP status: $HTTP_STATUS"
# Download must be exactly 200 with a non-empty body — 204 No Content would mean an empty file
if [ "$HTTP_STATUS" -ne 200 ] || [ ! -s "$PACKAGE_PATH" ]; then
    DEPLOY_FAILED=1
    log "❌ Archive download failed ($HTTP_STATUS)."
    exit 1
fi
log "  → Package saved to: $PACKAGE_PATH ($(du -h "$PACKAGE_PATH" | cut -f1))"

# ==============================================================================
# STAGE 2: QA SERVER OPERATIONS (Uploading & Deploying Package)
# ==============================================================================
log ""
log "=== Phase 2: QA Workflow Server Deployment ==="
QA_BASE="https://${QA_HOST}:${QA_PORT}/ops"

log "🔒 Authenticating with QA Server..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -c "$QA_COOKIES" \
  -u "${QA_USER}:${QA_PASSWORD}" \
  -H "accept: application/json" \
  -H "Content-Type: application/json" \
  -d '{"refresh_groups": true, "requested_lifetime": 7200}' \
  "${QA_BASE}/system/login" \
  -o qa_login.json)

log "  → Login response HTTP status: $HTTP_STATUS"
if ! is_2xx "$HTTP_STATUS"; then
    DEPLOY_FAILED=1
    log "❌ Target QA Server authentication failed (HTTP $HTTP_STATUS). Response body:"
    log_file_contents "qa_login.json" qa_login.json
    exit 1
fi
QA_CSRF=$(jq -r '.csrf_token' qa_login.json)
log "  → CSRF token acquired: ${QA_CSRF:0:8}... (truncated)"

log "🚀 Deploying and transferring package binary to QA server..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -b "$QA_COOKIES" \
  -H "BPMCSRFToken: ${QA_CSRF}" \
  -H "Accept: application/json" \
  -F "install_file=@${PACKAGE_PATH}" \
  "${QA_BASE}/std/bpm/containers/install?inactive=false&caseOverwrite=true" \
  -o qa_queue.json)

log "  → Deploy request HTTP status: $HTTP_STATUS"
if ! is_2xx "$HTTP_STATUS"; then
    DEPLOY_FAILED=1
    log "❌ Deployment intake failed on QA Server ($HTTP_STATUS)."
    log_file_contents "qa_queue.json" qa_queue.json
    exit 1
fi

# Log the full response — the 202 body contains a 'url' field pointing to the poll endpoint
log_file_contents "qa_queue.json (install request response)" qa_queue.json

QA_POLL_URL=$(jq -r '.url // empty' qa_queue.json)
if [ -z "$QA_POLL_URL" ] || [ "$QA_POLL_URL" = "null" ]; then
    DEPLOY_FAILED=1
    log "❌ Could not extract async poll URL from install request response."
    log "   Expected a 'url' field in the response body above."
    exit 1
fi
log "⏳ Installation submitted. Polling: $QA_POLL_URL"

# Poll using the URL provided by BAW — timeout after 30 minutes (120 × 15s)
poll_async_url "$QA_COOKIES" "$QA_POLL_URL" "qa_queue_status.json" "QA installation" 120

log "🎉 Success: Snapshot successfully deployed and live in QA!"
