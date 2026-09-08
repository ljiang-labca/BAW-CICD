#!/usr/bin/env bash

set -eo pipefail

# --- Configuration Validation ---
REQUIRED_VARS=(
  CENTER_HOST CENTER_PORT CENTER_USER CENTER_PASSWORD 
  QA_HOST QA_PORT QA_USER QA_PASSWORD 
  PROCESS_APP_ACRONYM SNAPSHOT_NAME OFFLINE_SERVER_ACRONYM
)
for VAR in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!VAR}" ]]; then
        echo "❌ Error: Missing environment variable: $VAR"
        exit 1
    fi
done

# --- Configure SSL/TLS Validation Toggle ---
# Default to true (secure) if not explicitly set to false
CURL_SSL_FLAGS=""
if [[ "${VERIFY_SSL,,}" == "false" ]]; then
    echo "⚠️ Warning: SSL verification is disabled (using self-signed certificates)."
    CURL_SSL_FLAGS="-k"
else
    echo "🔒 SSL verification enabled. Strict certificate authority validation will occur."
fi

# Temp file targets
CENTER_COOKIES="center_cookies.txt"
QA_COOKIES="qa_cookies.txt"
PACKAGE_PATH="/tmp/downloaded_package.zip"

cleanup() {
    echo "🧹 Wiping runtime session files..."
    rm -f "$CENTER_COOKIES" "$QA_COOKIES" "$PACKAGE_PATH" \
          center_login.json center_queue.json center_queue_status.json qa_login.json qa_queue.json qa_queue_status.json
}
trap cleanup EXIT

# ==============================================================================
# STAGE 1: WORKFLOW CENTER OPERATIONS (Exporting Package)
# ==============================================================================
echo "=== Phase 1: Workflow Center Package Extraction ==="
CENTER_BASE="https://${CENTER_HOST}:${CENTER_PORT}/ops"

echo "🔒 Authenticating with Workflow Center..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -c "$CENTER_COOKIES" \
  -u "${CENTER_USER}:${CENTER_PASSWORD}" \
  "${CENTER_BASE}/system/login" \
  -o center_login.json)

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "❌ Workflow Center authentication failed ($HTTP_STATUS)."
    cat center_login.json
    exit 1
fi
CENTER_CSRF=$(jq -r '.properties.BPMCSRFToken' center_login.json)

echo "🚀 Requesting offline package compilation for snapshot: $SNAPSHOT_NAME..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -b "$CENTER_COOKIES" \
  -H "BPMCSRFToken: ${CENTER_CSRF}" \
  -H "Accept: application/json" \
  "${CENTER_BASE}/std/bpm/containers/${PROCESS_APP_ACRONYM}/versions/${SNAPSHOT_NAME}/offline_package?server=${OFFLINE_SERVER_ACRONYM}" \
  -o center_queue.json)

if [ "$HTTP_STATUS" -ne 200 ] && [ "$HTTP_STATUS" -ne 201 ]; then
    echo "❌ Package generation initiation failed ($HTTP_STATUS)."
    cat center_queue.json
    exit 1
fi

CENTER_QUEUE_ID=$(jq -r '.id' center_queue.json)
echo "⏳ Generation task accepted. Tracking Queue ID: $CENTER_QUEUE_ID"

# Poll Center Generation Queue
while true; do
    curl -s $CURL_SSL_FLAGS -b "$CENTER_COOKIES" "${CENTER_BASE}/system/queue/${CENTER_QUEUE_ID}" -o center_queue_status.json
    STATUS=$(jq -r '.status // empty' center_queue_status.json)
    echo "⏱️ Extraction Status: $STATUS"
    
    if [ "$STATUS" = "success" ]; then
        echo "✅ Package has been compiled successfully."
        break
    elif [ "$STATUS" = "failed" ] || [ "$STATUS" = "error" ]; then
        echo "❌ Compilation failed on Workflow Center."
        jq -r '.message' center_queue_status.json
        exit 1
    fi
    sleep 15
done

echo "📥 Downloading generated archive to runner machine..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" \
  -b "$CENTER_COOKIES" \
  "${CENTER_BASE}/std/bpm/containers/${PROCESS_APP_ACRONYM}/versions/${SNAPSHOT_NAME}/install_package" \
  -o "$PACKAGE_PATH")

if [ "$HTTP_STATUS" -ne 200 ] || [ ! -s "$PACKAGE_PATH" ]; then
    echo "❌ Archive download failed ($HTTP_STATUS)."
    exit 1
fi

# ==============================================================================
# STAGE 2: QA SERVER OPERATIONS (Uploading & Deploying Package)
# ==============================================================================
echo -e "\n=== Phase 2: QA Workflow Server Deployment ==="
QA_BASE="https://${QA_HOST}:${QA_PORT}/ops"

echo "🔒 Authenticating with QA Server..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -c "$QA_COOKIES" \
  -u "${QA_USER}:${QA_PASSWORD}" \
  "${QA_BASE}/system/login" \
  -o qa_login.json)

if [ "$HTTP_STATUS" -ne 200 ]; then
    echo "❌ Target QA Server authentication failed ($HTTP_STATUS)."
    cat qa_login.json
    exit 1
fi
QA_CSRF=$(jq -r '.properties.BPMCSRFToken' qa_login.json)

echo "🚀 Deploying and transferring package binary to QA server..."
HTTP_STATUS=$(curl -s $CURL_SSL_FLAGS -w "%{http_code}" -X POST \
  -b "$QA_COOKIES" \
  -H "BPMCSRFToken: ${QA_CSRF}" \
  -H "Accept: application/json" \
  -F "install_file=@${PACKAGE_PATH}" \
  "${QA_BASE}/std/bpm/containers/install?inactive=false&caseOverwrite=true" \
  -o qa_queue.json)

if [ "$HTTP_STATUS" -ne 200 ] && [ "$HTTP_STATUS" -ne 201 ]; then
    echo "❌ Deployment intake failed on QA Server ($HTTP_STATUS)."
    cat qa_queue.json
    exit 1
fi

QA_QUEUE_ID=$(jq -r '.id' qa_queue.json)
echo "⏳ Installation running asynchronously. Tracking Queue ID: $QA_QUEUE_ID"

# Poll QA Installation Queue
while true; do
    curl -s $CURL_SSL_FLAGS -b "$QA_COOKIES" "${QA_BASE}/system/queue/${QA_QUEUE_ID}" -o qa_queue_status.json
    STATUS=$(jq -r '.status // empty' qa_queue_status.json)
    echo "⏱️ Installation Status: $STATUS"
    
    if [ "$STATUS" = "success" ]; then
        echo "🎉 Success: Snapshot successfully deployed and live in QA!"
        exit 0
    elif [ "$STATUS" = "failed" ] || [ "$STATUS" = "error" ]; then
        echo "❌ Installation failed on QA Environment."
        jq -r '.message' qa_queue_status.json
        exit 1
    fi
    sleep 15
done
