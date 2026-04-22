#!/usr/bin/env bash

. /app/includes.sh

########################################
# Symlink the configured timezone into /etc/localtime.
########################################
function configure_timezone() {
    ln -sf "/usr/share/zoneinfo/${TIMEZONE}" "${LOCALTIME_FILE}"
}

########################################
# Write crontab entries for each schedule group.
# Each group is one cron expression with one or more pair indices.
# Requires SCHEDULE_GROUPS to be built before calling (see build_schedule_groups).
########################################
function configure_cron() {
    if grep -q 'backup.sh' "${CRON_CONFIG_FILE}" 2>/dev/null; then
        return
    fi

    local cron_expr pair_indices
    for cron_expr in "${!SCHEDULE_GROUPS[@]}"; do
        pair_indices="${SCHEDULE_GROUPS[${cron_expr}]}"
        echo "${cron_expr} env PAIR_INDICES=${pair_indices} bash /app/backup.sh" >> "${CRON_CONFIG_FILE}"
        color blue "Cron job registered: ${cron_expr} (pairs: ${pair_indices})"
    done
}

########################################
# Ensure /.env is readable/writable by the container process when present.
# This helps the web UI config editor avoid falling back to env-generated
# content due to permission-only failures on bind-mounted files.
########################################
function ensure_dotenv_permissions() {
    if [[ ! -e "/.env" ]]; then
        return
    fi

    if [[ -d "/.env" ]]; then
        color yellow "Found /.env but it is a directory; expected a regular file"
        return
    fi

    if [[ ! -r "/.env" || ! -w "/.env" ]]; then
        color yellow "Adjusting /.env permissions for runtime config access"
        if chmod 600 "/.env" 2>/dev/null; then
            color blue "Updated /.env permissions to 600"
        else
            color yellow "Could not chmod /.env (likely read-only bind mount); web UI save may fail"
        fi
    fi

    if [[ ! -r "/.env" ]]; then
        color yellow "Warning: /.env is still not readable by this container process"
    fi
}

########################################
# Start an optional, lightweight web UI for status and runtime overrides.
# Auto-enables if WEBUI_BIND/WEBUI_PORT are configured via env or /.env.
# The web UI is served by the gotohp binary ("gotohp serve" subcommand)
# which embeds index.html at compile time and exposes /api/* endpoints.
########################################
function start_webui() {
    # Resolve from environment and /.env first.
    get_env WEBUI_BIND
    get_env WEBUI_PORT
    get_env WEBUI_AUTH
    get_env WEBUI_USERNAME
    get_env WEBUI_PASSWORD
    get_env WEBUI_TOKEN

    # Auto-detect if web UI should be enabled based on configured values.
    if [[ -z "${WEBUI_BIND}" && -z "${WEBUI_PORT}" ]]; then
        color blue "Web UI disabled: set WEBUI_BIND and/or WEBUI_PORT to enable"
        return
    fi

    if [[ -z "${WEBUI_BIND}" ]]; then
        # Default to loopback unless auth appears configured; this avoids
        # accidentally exposing an unauthenticated UI when only WEBUI_PORT is set.
        if [[ -n "${WEBUI_AUTH}" || -n "${WEBUI_USERNAME}" || -n "${WEBUI_PASSWORD}" || -n "${WEBUI_TOKEN}" ]]; then
            WEBUI_BIND="0.0.0.0"
        else
            WEBUI_BIND="127.0.0.1"
        fi
    fi
    WEBUI_PORT="${WEBUI_PORT:-5572}"

    color blue "Starting web UI at http://${WEBUI_BIND}:${WEBUI_PORT}"
    color yellow "Warning: web UI has no built-in authentication. Restrict access with WEBUI_BIND, firewall rules, or a reverse proxy."
    gotohp serve --bind "${WEBUI_BIND}" --port "${WEBUI_PORT}" &
    WEBUI_PID=$!
    sleep 1
    if ! kill -0 "${WEBUI_PID}" 2>/dev/null; then
        color red "Web UI failed to start (bind ${WEBUI_BIND}:${WEBUI_PORT})"
    else
        color blue "Web UI started with PID ${WEBUI_PID}"
    fi
}

########################################
# Return 0 if the cron expression contains at least one interval-style
# step field (*/N), meaning it fires "once every N" units rather than at
# a fixed point in time (e.g. "*/10 * * * *" → true; "0 * * * *" → false).
# Arguments:
#     cron expression (optional; defaults to global $CRON)
########################################
function cron_is_interval() {
    local cron_expr="${1:-${CRON}}"
    local field
    local -a cron_fields
    read -ra cron_fields <<< "${cron_expr}"
    for field in "${cron_fields[@]}"; do
        if [[ "${field}" =~ ^\*/[1-9][0-9]*$ ]]; then
            return 0
        fi
    done
    return 1
}

########################################
# Add credentials from env vars if provided,
# and set the active account if GOTOHP_EMAIL is set.
########################################
function setup_credentials() {
    mkdir -p "${XDG_CONFIG_HOME}/gotohp"

    if [[ -n "${GOTOHP_CREDS}" ]]; then
        color blue "Adding Google Photos credentials"
        gotohp creds add "${GOTOHP_CREDS}" || \
            color yellow "Note: credential may already exist in config (non-fatal)"
    fi

    # Register any per-pair credentials, skipping duplicates and the global credential
    local -A _seen_creds=()
    if [[ -n "${GOTOHP_CREDS}" ]]; then
        _seen_creds["${GOTOHP_CREDS}"]=1
    fi
    local pair_cred
    for i in "${!GOTOHP_CREDS_LIST[@]}"; do
        pair_cred="${GOTOHP_CREDS_LIST[${i}]}"
        if [[ -n "${pair_cred}" && -z "${_seen_creds[${pair_cred}]:-}" ]]; then
            color blue "Adding Google Photos credentials for pair ${i}"
            gotohp creds add "${pair_cred}" || \
                color yellow "Note: credential may already exist in config (non-fatal)"
            _seen_creds["${pair_cred}"]=1
        fi
    done

    if [[ -n "${GOTOHP_EMAIL}" ]]; then
        color blue "Setting active credential: ${GOTOHP_EMAIL}"
        if ! gotohp creds set "${GOTOHP_EMAIL}"; then
            color red "Failed to set active credential: ${GOTOHP_EMAIL}"
            exit 1
        fi
    fi
}

ensure_dotenv_permissions
init_env
build_schedule_groups
configure_timezone
setup_credentials
configure_cron

# One-shot manual backup: run once and exit.
if [[ "$1" == "backup" ]]; then
    color yellow "Running a one-shot backup (container will exit after completion)"
    bash /app/backup.sh
    exit $?
fi

start_webui

# Interval-style crons (e.g. "*/10 * * * *") imply "once every N units", so
# the first scheduled fire could be almost a full interval away.  Run an
# immediate backup so users don't wait unnecessarily on container start.
# Rigid crons (e.g. "0 * * * *") fire at a predictable fixed time and are
# left to fire naturally on their own schedule.
# This check is applied per schedule group.
for cron_expr in "${!SCHEDULE_GROUPS[@]}"; do
    if cron_is_interval "${cron_expr}"; then
        pair_indices="${SCHEDULE_GROUPS[${cron_expr}]}"
        color blue "Interval-style cron detected — running initial backup immediately (pairs: ${pair_indices})"
        initial_backup_rc=0
        PAIR_INDICES="${pair_indices}" bash /app/backup.sh || initial_backup_rc=$?
        if [[ ${initial_backup_rc} -ne 0 ]]; then
            color red "Initial backup failed with exit code ${initial_backup_rc}; continuing to start scheduler"
        fi
    fi
done

color blue "Starting supercronic scheduler"
exec supercronic -passthrough-logs -no-reap -quiet "${CRON_CONFIG_FILE}"
