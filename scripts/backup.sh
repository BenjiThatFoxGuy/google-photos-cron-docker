#!/bin/bash

. /app/includes.sh

########################################
# Build an array of gotohp upload flags
# from the resolved environment variables.
# Outputs:
#     GOTOHP_FLAGS array
########################################
function build_gotohp_flags() {
    GOTOHP_FLAGS=()

    GOTOHP_FLAGS+=("--threads" "${GOTOHP_THREADS}")
    GOTOHP_FLAGS+=("--log-level" "${GOTOHP_LOG_LEVEL}")

    if [[ "${GOTOHP_RECURSIVE}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--recursive")
    fi
    if [[ "${GOTOHP_FORCE}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--force")
    fi
    if [[ "${GOTOHP_DELETE}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--delete")
    fi
    if [[ "${GOTOHP_DISABLE_FILTER}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--disable-filter")
    fi
    if [[ "${GOTOHP_DATE_FROM_FILENAME}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--date-from-filename")
    fi
}

color blue "Running backup at $(date +"%Y-%m-%d %H:%M:%S %Z")"

init_env

if [[ "${#SOURCE_PATHS[@]}" -eq 0 ]]; then
    color red "No source paths configured."
    color red "Set SOURCE_PATH (single source) or SOURCE_PATH_0, SOURCE_PATH_1, … (multiple sources)."
    exit 1
fi

build_gotohp_flags

HAS_ERROR="FALSE"

for i in "${!SOURCE_PATHS[@]}"; do
    SOURCE="${SOURCE_PATHS[${i}]}"
    ALBUM="${ALBUM_NAMES[${i}]}"

    if [[ ! -e "${SOURCE}" ]]; then
        color yellow "Source path does not exist, skipping: ${SOURCE}"
        continue
    fi

    UPLOAD_FLAGS=("${GOTOHP_FLAGS[@]}")
    if [[ -n "${ALBUM}" ]]; then
        UPLOAD_FLAGS+=("--album" "${ALBUM}")
    fi

    color blue "Uploading $(color yellow "[${SOURCE}]") → album $(color yellow "[${ALBUM:-<library root>}]")"

    gotohp upload "${SOURCE}" "${UPLOAD_FLAGS[@]}"

    if [[ $? -ne 0 ]]; then
        color red "Upload failed for: ${SOURCE}"
        HAS_ERROR="TRUE"
    else
        color green "Upload complete: ${SOURCE}"
    fi
done

if [[ "${HAS_ERROR}" == "TRUE" ]]; then
    color red "One or more uploads failed at $(date +"%Y-%m-%d %H:%M:%S %Z")"
    exit 1
fi

color green "All uploads completed successfully at $(date +"%Y-%m-%d %H:%M:%S %Z")"
