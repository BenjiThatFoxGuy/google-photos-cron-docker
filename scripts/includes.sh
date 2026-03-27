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
        set -a
        source <(cat "/.env" | sed -e '/^#/d;/^\s*$/d' -e 's/\(\w*\)[ \t]*=[ \t]*\(.*\)/DOTENV_\1=\2/')
        set +a
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
    elif [[ -n "${!VAR_DOTENV_FILE:-}" ]]; then
        VALUE="$(cat "${!VAR_DOTENV_FILE}")"
    elif [[ -n "${!VAR_DOTENV:-}" ]]; then
        VALUE="${!VAR_DOTENV}"
    fi

    export "${VAR}=${VALUE}"
}

########################################
# Build SOURCE_PATHS and ALBUM_NAMES arrays from
# SOURCE_PATH_0/ALBUM_NAME_0, SOURCE_PATH_1/ALBUM_NAME_1, …
# Arguments:
#     None
# Outputs:
#     SOURCE_PATHS and ALBUM_NAMES arrays
########################################
function get_source_album_list() {
    SOURCE_PATHS=()
    ALBUM_NAMES=()

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
        ((i++))
    done
}

########################################
# Initialise all environment variables
# and print the resolved configuration.
# Arguments:
#     None
########################################
function init_env() {
    export_env_file

    # CRON
    get_env CRON
    CRON="${CRON:-"5 * * * *"}"

    # TIMEZONE
    get_env TIMEZONE
    local TIMEZONE_MATCHED_COUNT
    TIMEZONE_MATCHED_COUNT=$(ls "/usr/share/zoneinfo/${TIMEZONE}" 2>/dev/null | wc -l)
    if [[ "${TIMEZONE_MATCHED_COUNT}" -ne 1 ]]; then
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
    done
    color yellow "========================================"
}
