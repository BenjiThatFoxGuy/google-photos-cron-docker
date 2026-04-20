#!/usr/bin/env bash

set -euo pipefail

CRON_CONFIG_FILE="${HOME}/crontabs"
BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-/tmp/backup-status.env}"
WEBUI_OVERRIDE_FILE="${WEBUI_OVERRIDE_FILE:-/config/webui-overrides.env}"

echo "Content-Type: text/plain"
echo "Cache-Control: no-store"
echo

echo "Timestamp (UTC): $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo

echo "Last backup status:"
if [[ -f "${BACKUP_STATUS_FILE}" ]]; then
    cat "${BACKUP_STATUS_FILE}"
else
    echo "No status file yet (${BACKUP_STATUS_FILE})"
fi
echo

echo "Registered cron entries:"
if [[ -f "${CRON_CONFIG_FILE}" ]]; then
    cat "${CRON_CONFIG_FILE}"
else
    echo "No cron config file yet (${CRON_CONFIG_FILE})"
fi
echo

echo "Override file path: ${WEBUI_OVERRIDE_FILE}"
if [[ -f "${WEBUI_OVERRIDE_FILE}" ]]; then
    echo "Override file present: yes"
else
    echo "Override file present: no"
fi
