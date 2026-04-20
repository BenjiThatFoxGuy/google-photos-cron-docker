#!/usr/bin/env bash
# CGI endpoint: GET /cgi-bin/status.sh
# Returns a JSON document describing scheduler state, live upload progress,
# per-thread status, recent file results, and cron configuration.
# Consumed exclusively by index.html's polling loop.

set -euo pipefail

CRON_CONFIG_FILE="${HOME}/crontabs"
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-/tmp/backup-status.env}"
PROGRESS_FILE="${GOTOHP_PROGRESS_FILE:-/tmp/gotohp-progress.json}"
CONFIG_FILE="/.env"
MANUAL_BACKUP_PID_FILE="${MANUAL_BACKUP_PID_FILE:-/tmp/webui-manual-backup.pid}"
MANUAL_BACKUP_LOG_FILE="${MANUAL_BACKUP_LOG_FILE:-/tmp/webui-manual-backup.log}"

printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'

# ── helpers ────────────────────────────────────────────────────────────────────
function je() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "${s}"
}

function read_status_var() {
    local key="$1"
    if [[ -f "${BACKUP_STATUS_FILE}" ]]; then
        grep -E "^${key}=" "${BACKUP_STATUS_FILE}" | tail -n1 | cut -d'=' -f2- || true
    fi
}

# ── scheduler state (written by backup.sh) ────────────────────────────────────
backup_state="$(read_status_var STATE)"
backup_last_start="$(read_status_var LAST_START)"
backup_last_end="$(read_status_var LAST_END)"
backup_exit_code="$(read_status_var EXIT_CODE)"
backup_pair_indices="$(read_status_var PAIR_INDICES)"

[[ -n "${backup_state}" ]]        || backup_state="UNKNOWN"
[[ -n "${backup_pair_indices}" ]] || backup_pair_indices="ALL"

# ── cron entries ──────────────────────────────────────────────────────────────
cron_entries_json="[]"
if [[ -f "${CRON_CONFIG_FILE}" ]]; then
    cron_entries_json="["
    first=1
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -z "${line}" ]] && continue
        [[ ${first} -eq 0 ]] && cron_entries_json+=","
        cron_entries_json+="\"$(je "${line}")\""
        first=0
    done < "${CRON_CONFIG_FILE}"
    cron_entries_json+="]"
fi

# ── manual backup process tracking ───────────────────────────────────────────
manual_running="false"
manual_pid=""
manual_started_at=""
if [[ -f "${MANUAL_BACKUP_PID_FILE}" ]]; then
    manual_pid="$(cat "${MANUAL_BACKUP_PID_FILE}" 2>/dev/null || true)"
    if [[ -n "${manual_pid}" ]] && kill -0 "${manual_pid}" 2>/dev/null; then
        manual_running="true"
        pid_mtime="$(stat -c %Y "${MANUAL_BACKUP_PID_FILE}" 2>/dev/null || true)"
        [[ -n "${pid_mtime}" ]] && manual_started_at="$(date -d "@${pid_mtime}" -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || true)"
    else
        rm -f "${MANUAL_BACKUP_PID_FILE}"
        manual_pid=""
    fi
fi

# ── log tail (last 80 lines, ANSI stripped) ───────────────────────────────────
manual_log_tail=""
if [[ -f "${MANUAL_BACKUP_LOG_FILE}" ]]; then
    manual_log_tail="$(sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' "${MANUAL_BACKUP_LOG_FILE}" | tail -n 80 || true)"
fi

# ── progress JSON (written by gotohp's progress_writer.go) ───────────────────
# Pass through the entire progress blob directly; if missing, emit a sentinel.
progress_json='{"state":"idle","total_files":0,"total_bytes":0,"completed":0,"failed":0,"bytes_uploaded":0,"speed_bytes_per_sec":0,"eta_seconds":0,"threads":[],"recent_results":[]}'
if [[ -f "${PROGRESS_FILE}" ]]; then
    read_progress="$(cat "${PROGRESS_FILE}" 2>/dev/null || true)"
    [[ -n "${read_progress}" ]] && progress_json="${read_progress}"
fi

# ── assemble output ───────────────────────────────────────────────────────────
timestamp_utc="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
config_file_exists="false"
[[ -f "${CONFIG_FILE}" ]] && config_file_exists="true"

cat <<JSON
{
  "timestamp_utc": "$(je "${timestamp_utc}")",
  "backup": {
    "state":        "$(je "${backup_state}")",
    "last_start":   "$(je "${backup_last_start}")",
    "last_end":     "$(je "${backup_last_end}")",
    "exit_code":    "$(je "${backup_exit_code}")",
    "pair_indices": "$(je "${backup_pair_indices}")"
  },
  "runtime": {
    "hostname":              "$(je "$(hostname)")",
    "config_file_exists":    ${config_file_exists},
    "manual_backup_running": ${manual_running},
    "manual_backup_pid":     "$(je "${manual_pid}")",
    "manual_started_at":     "$(je "${manual_started_at}")"
  },
  "progress": ${progress_json},
  "cron": {
    "entries": ${cron_entries_json}
  },
  "manual_backup_log_tail": "$(je "${manual_log_tail}")"
}
JSON
