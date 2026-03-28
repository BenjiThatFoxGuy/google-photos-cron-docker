#!/bin/bash

CRON_CONFIG_FILE="${HOME}/crontabs"

#################### Functions ####################

########################################
# Print colorful message.
# Arguments:
#     color
#     message
# Outputs:
#     colorful message
########################################
function color() {
    case $1 in
        red)     echo -e "\033[31m$2\033[0m" ;;
        green)   echo -e "\033[32m$2\033[0m" ;;
        yellow)  echo -e "\033[33m$2\033[0m" ;;
        blue)    echo -e "\033[34m$2\033[0m" ;;
        none)    echo "$2" ;;
    esac
}

########################################
# Export variables from /.env file.
# Arguments:
#     None
########################################
function export_env_file() {
    if [[ -f "/.env" ]]; then
        color blue "Found /.env file, exporting variables"
        local line var_name value
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Trim leading whitespace
            line="${line#"${line%%[![:space:]]*}"}"
            # Trim trailing whitespace
            line="${line%"${line##*[![:space:]]}"}"
            # Skip empty lines and comments
            [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
            # Match VAR=VALUE where VAR is a valid shell variable name
            if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
                var_name=${BASH_REMATCH[1]}
                value=${BASH_REMATCH[2]}
                # Export as-is (no shell evaluation), prefixed with DOTENV_
                export "DOTENV_${var_name}=${value}"
            fi
        done < "/.env"
    fi
}

########################################
# Get a variable value from:
#     environment variables,
#     secret file in environment variables (_FILE suffix),
#     secret file in .env file,
#     environment variables in .env file.
# Arguments:
#     variable name
# Outputs:
#     exported variable with resolved value
########################################
function get_env() {
    local VAR="$1"
    local VAR_FILE="${VAR}_FILE"
    local VAR_DOTENV="DOTENV_${VAR}"
    local VAR_DOTENV_FILE="DOTENV_${VAR_FILE}"
    local VALUE=""

    if [[ -n "${!VAR:-}" ]]; then
        VALUE="${!VAR}"
    elif [[ -n "${!VAR_FILE:-}" ]]; then
        VALUE="$(cat "${!VAR_FILE}")"
        VALUE="${VALUE%$'\r\n'}"
        VALUE="${VALUE%$'\n'}"
        VALUE="${VALUE%$'\r'}"
    elif [[ -n "${!VAR_DOTENV_FILE:-}" ]]; then
        VALUE="$(cat "${!VAR_DOTENV_FILE}")"
        VALUE="${VALUE%$'\r\n'}"
        VALUE="${VALUE%$'\n'}"
        VALUE="${VALUE%$'\r'}"
    elif [[ -n "${!VAR_DOTENV:-}" ]]; then
        VALUE="${!VAR_DOTENV}"
    fi

    export "${VAR}=${VALUE}"
}

########################################
# Build SOURCE_PATHS, ALBUM_NAMES, and per-pair upload-option
# override arrays from SOURCE_PATH_N/ALBUM_NAME_N/GOTOHP_*_N, …
# Arguments:
#     None
# Outputs:
#     SOURCE_PATHS, ALBUM_NAMES, and GOTOHP_*_LIST arrays
########################################
function get_source_album_list() {
    SOURCE_PATHS=()
    ALBUM_NAMES=()
    GOTOHP_THREADS_LIST=()
    GOTOHP_RECURSIVE_LIST=()
    GOTOHP_FORCE_LIST=()
    GOTOHP_DELETE_LIST=()
    GOTOHP_DISABLE_FILTER_LIST=()
    GOTOHP_DATE_FROM_FILENAME_LIST=()
    GOTOHP_LOG_LEVEL_LIST=()
    GOTOHP_CREDS_LIST=()
    GOTOHP_EMAIL_LIST=()
    CRON_LIST=()

    local i=0
    local SOURCE_PATH_X_REFER
    local ALBUM_NAME_X_REFER

    while true; do
        SOURCE_PATH_X_REFER="SOURCE_PATH_${i}"
        ALBUM_NAME_X_REFER="ALBUM_NAME_${i}"
        get_env "${SOURCE_PATH_X_REFER}"
        get_env "${ALBUM_NAME_X_REFER}"

        if [[ -z "${!SOURCE_PATH_X_REFER}" ]]; then
            break
        fi

        SOURCE_PATHS+=("${!SOURCE_PATH_X_REFER}")
        ALBUM_NAMES+=("${!ALBUM_NAME_X_REFER}")

        # Per-pair upload option overrides (empty string → use global default)
        local THREADS_X="GOTOHP_THREADS_${i}"
        local RECURSIVE_X="GOTOHP_RECURSIVE_${i}"
        local FORCE_X="GOTOHP_FORCE_${i}"
        local DELETE_X="GOTOHP_DELETE_${i}"
        local DISABLE_FILTER_X="GOTOHP_DISABLE_FILTER_${i}"
        local DATE_FROM_FILENAME_X="GOTOHP_DATE_FROM_FILENAME_${i}"
        local LOG_LEVEL_X="GOTOHP_LOG_LEVEL_${i}"
        local CREDS_X="GOTOHP_CREDS_${i}"
        local EMAIL_X="GOTOHP_EMAIL_${i}"
        local CRON_X="CRON_${i}"

        get_env "${THREADS_X}"
        get_env "${RECURSIVE_X}"
        get_env "${FORCE_X}"
        get_env "${DELETE_X}"
        get_env "${DISABLE_FILTER_X}"
        get_env "${DATE_FROM_FILENAME_X}"
        get_env "${LOG_LEVEL_X}"
        get_env "${CREDS_X}"
        get_env "${EMAIL_X}"
        get_env "${CRON_X}"

        GOTOHP_THREADS_LIST+=("${!THREADS_X}")
        GOTOHP_RECURSIVE_LIST+=("${!RECURSIVE_X}")
        GOTOHP_FORCE_LIST+=("${!FORCE_X}")
        GOTOHP_DELETE_LIST+=("${!DELETE_X}")
        GOTOHP_DISABLE_FILTER_LIST+=("${!DISABLE_FILTER_X}")
        GOTOHP_DATE_FROM_FILENAME_LIST+=("${!DATE_FROM_FILENAME_X}")
        GOTOHP_LOG_LEVEL_LIST+=("${!LOG_LEVEL_X}")
        GOTOHP_CREDS_LIST+=("${!CREDS_X}")
        GOTOHP_EMAIL_LIST+=("${!EMAIL_X}")
        CRON_LIST+=("${!CRON_X}")

        ((i++))
    done
}

########################################
# Build an associative array (SCHEDULE_GROUPS) mapping each effective
# cron expression to a comma-separated list of pair indices that share it.
# Pairs without a CRON_N override use the global CRON value.
# Arguments:
#     None
# Outputs:
#     SCHEDULE_GROUPS associative array (global)
########################################
function build_schedule_groups() {
    declare -gA SCHEDULE_GROUPS=()
    local i cron_expr
    for i in "${!SOURCE_PATHS[@]}"; do
        cron_expr="${CRON_LIST[${i}]:-${CRON}}"
        if [[ -z "${SCHEDULE_GROUPS[${cron_expr}]+_}" ]]; then
            SCHEDULE_GROUPS["${cron_expr}"]="${i}"
        else
            SCHEDULE_GROUPS["${cron_expr}"]="${SCHEDULE_GROUPS[${cron_expr}]},${i}"
        fi
    done
}

########################################
# and print the resolved configuration.
# Arguments:
#     None
########################################
function init_env() {
    export_env_file

    # CRON
    get_env CRON
    CRON="${CRON:-"5 * * * *"}"

    # CRON_OVERLAP — intra-group overlap behaviour: queue (default), multithread, skip
    get_env CRON_OVERLAP
    CRON_OVERLAP=$(echo "${CRON_OVERLAP:-"queue"}" | tr '[:lower:]' '[:upper:]')

    # TIMEZONE
    get_env TIMEZONE
    if [[ -z "${TIMEZONE}" || ( ! -f "/usr/share/zoneinfo/${TIMEZONE}" && ! -L "/usr/share/zoneinfo/${TIMEZONE}" ) ]]; then
        TIMEZONE="UTC"
    fi

    # GOTOHP_CREDS — credential string (androidId=... from mobile device)
    get_env GOTOHP_CREDS

    # GOTOHP_EMAIL — active account email or partial match
    get_env GOTOHP_EMAIL

    # GOTOHP_THREADS — concurrent upload threads (default: 3)
    get_env GOTOHP_THREADS
    GOTOHP_THREADS="${GOTOHP_THREADS:-"3"}"

    # GOTOHP_RECURSIVE — include subdirectories (default: TRUE)
    get_env GOTOHP_RECURSIVE
    GOTOHP_RECURSIVE=$(echo "${GOTOHP_RECURSIVE:-"TRUE"}" | tr '[:lower:]' '[:upper:]')

    # GOTOHP_FORCE — re-upload even if file already exists (default: FALSE)
    get_env GOTOHP_FORCE
    GOTOHP_FORCE=$(echo "${GOTOHP_FORCE:-"FALSE"}" | tr '[:lower:]' '[:upper:]')

    # GOTOHP_DELETE — delete source file after successful upload (default: FALSE)
    get_env GOTOHP_DELETE
    GOTOHP_DELETE=$(echo "${GOTOHP_DELETE:-"FALSE"}" | tr '[:lower:]' '[:upper:]')

    # GOTOHP_DISABLE_FILTER — disable media file-type filtering (default: FALSE)
    get_env GOTOHP_DISABLE_FILTER
    GOTOHP_DISABLE_FILTER=$(echo "${GOTOHP_DISABLE_FILTER:-"FALSE"}" | tr '[:lower:]' '[:upper:]')

    # GOTOHP_DATE_FROM_FILENAME — parse media date from filename (default: FALSE)
    get_env GOTOHP_DATE_FROM_FILENAME
    GOTOHP_DATE_FROM_FILENAME=$(echo "${GOTOHP_DATE_FROM_FILENAME:-"FALSE"}" | tr '[:lower:]' '[:upper:]')

    # GOTOHP_LOG_LEVEL — log level: debug, info, warn, error (default: info)
    get_env GOTOHP_LOG_LEVEL
    GOTOHP_LOG_LEVEL="${GOTOHP_LOG_LEVEL:-"info"}"

    # SOURCE_PATH / ALBUM_NAME — single-source shorthand aliases for _0 slots
    get_env SOURCE_PATH
    get_env ALBUM_NAME
    if [[ -n "${SOURCE_PATH}" ]]; then
        SOURCE_PATH_0="${SOURCE_PATH_0:-${SOURCE_PATH}}"
        ALBUM_NAME_0="${ALBUM_NAME_0:-${ALBUM_NAME}}"
    fi

    get_source_album_list

    color yellow "========================================"
    color yellow "CRON: ${CRON}"
    color yellow "CRON_OVERLAP: ${CRON_OVERLAP}"
    color yellow "TIMEZONE: ${TIMEZONE}"
    color yellow "GOTOHP_THREADS: ${GOTOHP_THREADS}"
    color yellow "GOTOHP_RECURSIVE: ${GOTOHP_RECURSIVE}"
    color yellow "GOTOHP_FORCE: ${GOTOHP_FORCE}"
    color yellow "GOTOHP_DELETE: ${GOTOHP_DELETE}"
    color yellow "GOTOHP_DISABLE_FILTER: ${GOTOHP_DISABLE_FILTER}"
    color yellow "GOTOHP_DATE_FROM_FILENAME: ${GOTOHP_DATE_FROM_FILENAME}"
    color yellow "GOTOHP_LOG_LEVEL: ${GOTOHP_LOG_LEVEL}"

    for i in "${!SOURCE_PATHS[@]}"; do
        local ALB="${ALBUM_NAMES[${i}]:-<none>}"
        color yellow "SOURCE[${i}]: ${SOURCE_PATHS[${i}]} → ALBUM: ${ALB}"
        [[ -n "${GOTOHP_THREADS_LIST[${i}]}" ]]            && color yellow "  GOTOHP_THREADS_${i}: ${GOTOHP_THREADS_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_RECURSIVE_LIST[${i}]}" ]]          && color yellow "  GOTOHP_RECURSIVE_${i}: ${GOTOHP_RECURSIVE_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_FORCE_LIST[${i}]}" ]]              && color yellow "  GOTOHP_FORCE_${i}: ${GOTOHP_FORCE_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_DELETE_LIST[${i}]}" ]]             && color yellow "  GOTOHP_DELETE_${i}: ${GOTOHP_DELETE_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_DISABLE_FILTER_LIST[${i}]}" ]]     && color yellow "  GOTOHP_DISABLE_FILTER_${i}: ${GOTOHP_DISABLE_FILTER_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_DATE_FROM_FILENAME_LIST[${i}]}" ]] && color yellow "  GOTOHP_DATE_FROM_FILENAME_${i}: ${GOTOHP_DATE_FROM_FILENAME_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_LOG_LEVEL_LIST[${i}]}" ]]          && color yellow "  GOTOHP_LOG_LEVEL_${i}: ${GOTOHP_LOG_LEVEL_LIST[${i}]} (override)"
        [[ -n "${GOTOHP_CREDS_LIST[${i}]}" ]]              && color yellow "  GOTOHP_CREDS_${i}: <set> (override)"
        [[ -n "${GOTOHP_EMAIL_LIST[${i}]}" ]]              && color yellow "  GOTOHP_EMAIL_${i}: ${GOTOHP_EMAIL_LIST[${i}]} (override)"
        [[ -n "${CRON_LIST[${i}]}" ]]                      && color yellow "  CRON_${i}: ${CRON_LIST[${i}]} (override)"
    done
    color yellow "========================================"
}
