#!/usr/bin/env bash

set -euo pipefail

MANUAL_BACKUP_PID_FILE="${MANUAL_BACKUP_PID_FILE:-/tmp/webui-manual-backup.pid}"

function http_json() {
    local code="$1"
    echo "Status: ${code}"
    echo "Content-Type: application/json"
    echo "Cache-Control: no-store"
    echo
}

if [[ "${REQUEST_METHOD:-GET}" != "POST" ]]; then
    http_json "405 Method Not Allowed"
    echo '{"ok":false,"error":"Use POST"}'
    exit 0
fi

if [[ ! -f "${MANUAL_BACKUP_PID_FILE}" ]]; then
    http_json "409 Conflict"
    echo '{"ok":false,"error":"No manual backup is currently tracked"}'
    exit 0
fi

pid="$(cat "${MANUAL_BACKUP_PID_FILE}" 2>/dev/null || true)"
if [[ -z "${pid}" ]] || [[ ! "${pid}" =~ ^[0-9]+$ ]]; then
    rm -f "${MANUAL_BACKUP_PID_FILE}"
    http_json "409 Conflict"
    echo '{"ok":false,"error":"Invalid tracked PID"}'
    exit 0
fi

if kill -0 "${pid}" 2>/dev/null; then
    pkill -TERM -P "${pid}" 2>/dev/null || true
    kill -TERM "${pid}" 2>/dev/null || true

    # Escalate if it survives TERM.
    if kill -0 "${pid}" 2>/dev/null; then
        pkill -KILL -P "${pid}" 2>/dev/null || true
        kill -KILL "${pid}" 2>/dev/null || true
    fi
fi

rm -f "${MANUAL_BACKUP_PID_FILE}"

http_json "200 OK"
echo '{"ok":true,"message":"Manual backup cancellation requested"}'
