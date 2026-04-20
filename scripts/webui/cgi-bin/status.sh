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
manual_started="0"
manual_completed="0"
manual_failed="0"
manual_progress_percent="0"
manual_last_upload_target=""
manual_started_at_epoch=""
manual_runtime_seconds=""
if [[ -f "${MANUAL_BACKUP_LOG_FILE}" ]]; then
    manual_log_sanitized="$(sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "${MANUAL_BACKUP_LOG_FILE}" || true)"
    manual_log_tail="$(printf '%s' "${manual_log_sanitized}" | tail -n 80 || true)"

    manual_started="$(printf '%s' "${manual_log_sanitized}" | grep -c 'Uploading ' || true)"
    manual_completed="$(printf '%s' "${manual_log_sanitized}" | grep -c 'Upload complete:' || true)"
    manual_failed="$(printf '%s' "${manual_log_sanitized}" | grep -c 'Upload failed for:' || true)"
    manual_last_upload_target="$(printf '%s' "${manual_log_sanitized}" | grep 'Uploading ' | tail -n1 | cut -d'[' -f2- | cut -d']' -f1 || true)"
fi

if [[ -f "${MANUAL_BACKUP_PID_FILE}" ]]; then
    manual_started_at_epoch="$(stat -c %Y "${MANUAL_BACKUP_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${manual_started_at_epoch}" ]] && [[ "${manual_started_at_epoch}" =~ ^[0-9]+$ ]]; then
        now_epoch="$(date +%s)"
        manual_runtime_seconds="$(( now_epoch - manual_started_at_epoch ))"
    fi
fi

if [[ "${manual_started}" =~ ^[0-9]+$ ]] && [[ "${manual_started}" -gt 0 ]]; then
    if [[ "${manual_completed}" =~ ^[0-9]+$ ]] && [[ "${manual_failed}" =~ ^[0-9]+$ ]]; then
        processed="$(( manual_completed + manual_failed ))"
        manual_progress_percent="$(( (processed * 100) / manual_started ))"
        if [[ "${manual_running}" == "true" ]] && [[ "${manual_progress_percent}" -ge 100 ]]; then
            manual_progress_percent="99"
        fi
        if [[ "${manual_running}" != "true" ]]; then
            manual_progress_percent="100"
        fi
    fi
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
    "manual_progress": {
        "started": ${manual_started},
        "completed": ${manual_completed},
        "failed": ${manual_failed},
        "percent": ${manual_progress_percent},
        "runtime_seconds": "$(json_escape "${manual_runtime_seconds}")",
        "last_upload_target": "$(json_escape "${manual_last_upload_target}")"
    },
  "cron": {
    "config_file": "$(json_escape "${CRON_CONFIG_FILE}")",
    "entries": ${cron_entries_json}
  },
  "manual_backup_log_tail": "$(json_escape "${manual_log_tail}")"
}
EOF
