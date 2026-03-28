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
