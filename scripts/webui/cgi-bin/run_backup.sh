#!/usr/bin/env bash

set -euo pipefail

BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-/tmp/backup-status.env}"
MANUAL_BACKUP_PID_FILE="${MANUAL_BACKUP_PID_FILE:-/tmp/webui-manual-backup.pid}"
MANUAL_BACKUP_LOG_FILE="${MANUAL_BACKUP_LOG_FILE:-/tmp/webui-manual-backup.log}"

function http_json() {
    local code="$1"
    echo "Status: ${code}"
    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo
}

function json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "${s}"
}

if [[ "${REQUEST_METHOD:-GET}" != "POST" ]]; then
    http_json "405 Method Not Allowed"
    echo '{"ok":false,"error":"Use POST"}'
    exit 0
fi

# Keep a single manual backup process at a time.
if [[ -f "${MANUAL_BACKUP_PID_FILE}" ]]; then
    existing_pid="$(cat "${MANUAL_BACKUP_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${existing_pid}" ]] && kill -0 "${existing_pid}" 2>/dev/null; then
        http_json "409 Conflict"
        cat <<EOF
{"ok":false,"error":"Manual backup already running","pid":"$(json_escape "${existing_pid}")"}
EOF
        exit 0
    fi
fi

# If backup status says RUNNING, avoid stacking another full run.
if [[ -f "${BACKUP_STATUS_FILE}" ]] && grep -q '^STATE=RUNNING$' "${BACKUP_STATUS_FILE}"; then
    http_json "409 Conflict"
    echo '{"ok":false,"error":"A backup run is already in progress"}'
    exit 0
fi

umask 077
: > "${MANUAL_BACKUP_LOG_FILE}"
nohup bash /app/backup.sh >> "${MANUAL_BACKUP_LOG_FILE}" 2>&1 &
manual_pid="$!"
echo "${manual_pid}" > "${MANUAL_BACKUP_PID_FILE}"

http_json "202 Accepted"
cat <<EOF
{"ok":true,"message":"Manual backup started","pid":"$(json_escape "${manual_pid}")","log_file":"$(json_escape "${MANUAL_BACKUP_LOG_FILE}")"}
EOF
