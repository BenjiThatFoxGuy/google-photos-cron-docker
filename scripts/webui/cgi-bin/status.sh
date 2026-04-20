#!/usr/bin/env bash

set -euo pipefail

CRON_CONFIG_FILE="${HOME}/crontabs"
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-/tmp/backup-status.env}"
CONFIG_FILE="/.env"
MANUAL_BACKUP_PID_FILE="${MANUAL_BACKUP_PID_FILE:-/tmp/webui-manual-backup.pid}"
MANUAL_BACKUP_LOG_FILE="${MANUAL_BACKUP_LOG_FILE:-/tmp/webui-manual-backup.log}"

function json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "${s}"
}

function read_status_var() {
    local key="$1"
    local value=""
    if [[ -f "${BACKUP_STATUS_FILE}" ]]; then
        value="$(grep -E "^${key}=" "${BACKUP_STATUS_FILE}" | tail -n1 | cut -d'=' -f2- || true)"
    fi
    printf '%s' "${value}"
}

backup_state="$(read_status_var STATE)"
backup_last_start="$(read_status_var LAST_START)"
backup_last_end="$(read_status_var LAST_END)"
backup_exit_code="$(read_status_var EXIT_CODE)"
backup_pair_indices="$(read_status_var PAIR_INDICES)"

[[ -n "${backup_state}" ]] || backup_state="UNKNOWN"
[[ -n "${backup_pair_indices}" ]] || backup_pair_indices="ALL"

cron_entries_json="[]"
if [[ -f "${CRON_CONFIG_FILE}" ]]; then
    cron_entries_json="["
    first=1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        if [[ ${first} -eq 0 ]]; then
            cron_entries_json+="," 
        fi
        cron_entries_json+="\"$(json_escape "${line}")\""
        first=0
    done < "${CRON_CONFIG_FILE}"
    cron_entries_json+="]"
fi

manual_running="false"
manual_pid=""
if [[ -f "${MANUAL_BACKUP_PID_FILE}" ]]; then
    manual_pid="$(cat "${MANUAL_BACKUP_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${manual_pid}" ]] && kill -0 "${manual_pid}" 2>/dev/null; then
        manual_running="true"
    else
        rm -f "${MANUAL_BACKUP_PID_FILE}"
        manual_pid=""
    fi
fi

manual_log_tail=""
if [[ -f "${MANUAL_BACKUP_LOG_FILE}" ]]; then
    manual_log_tail="$(tail -n 80 "${MANUAL_BACKUP_LOG_FILE}" || true)"
fi

echo "Content-Type: application/json"
echo "Cache-Control: no-store"
echo

cat <<EOF
{
  "timestamp_utc": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "backup": {
    "state": "$(json_escape "${backup_state}")",
    "last_start": "$(json_escape "${backup_last_start}")",
    "last_end": "$(json_escape "${backup_last_end}")",
    "exit_code": "$(json_escape "${backup_exit_code}")",
    "pair_indices": "$(json_escape "${backup_pair_indices}")",
    "status_file": "$(json_escape "${BACKUP_STATUS_FILE}")"
  },
  "runtime": {
    "hostname": "$(json_escape "$(hostname)")",
    "config_file_exists": $( [[ -f "${CONFIG_FILE}" ]] && echo true || echo false ),
    "manual_backup_running": ${manual_running},
    "manual_backup_pid": "$(json_escape "${manual_pid}")"
  },
  "cron": {
    "config_file": "$(json_escape "${CRON_CONFIG_FILE}")",
    "entries": ${cron_entries_json}
  },
  "manual_backup_log_tail": "$(json_escape "${manual_log_tail}")"
}
EOF
