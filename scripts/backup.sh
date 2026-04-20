#!/bin/bash

. /app/includes.sh

########################################
# Switch the active gotohp credential for a given source/album pair.
# Per-pair GOTOHP_EMAIL_N takes precedence; falls back to global GOTOHP_EMAIL.
# Arguments:
#     pair index (integer)
# Returns:
#     0 on success or when no switch is needed; 1 on switch failure
########################################
function switch_credential_for_pair() {
    local i="$1"
    local effective_email="${GOTOHP_EMAIL_LIST[${i}]:-${GOTOHP_EMAIL}}"
    if [[ -n "${effective_email}" ]]; then
        color blue "Setting active credential: ${effective_email}"
        if ! gotohp creds set "${effective_email}"; then
            color red "Failed to set active credential for ${SOURCE_PATHS[${i}]}: ${effective_email}"
            return 1
        fi
    fi
    return 0
}

########################################
# Build an array of gotohp upload flags for a given source/album pair.
# Per-pair override variables (GOTOHP_*_N) take precedence; the global
# GOTOHP_* values are used as defaults when no override is set.
# Arguments:
#     pair index (integer)
# Outputs:
#     GOTOHP_FLAGS array
########################################
function build_gotohp_flags() {
    local i="$1"
    GOTOHP_FLAGS=()

    local THREADS="${GOTOHP_THREADS_LIST[${i}]:-${GOTOHP_THREADS}}"
    local LOG_LEVEL="${GOTOHP_LOG_LEVEL_LIST[${i}]:-${GOTOHP_LOG_LEVEL}}"
    local RECURSIVE
    RECURSIVE=$(echo "${GOTOHP_RECURSIVE_LIST[${i}]:-${GOTOHP_RECURSIVE}}" | tr '[:lower:]' '[:upper:]')
    # Expose for use by the pre-flight file check in the main loop.
    GOTOHP_EFFECTIVE_RECURSIVE="${RECURSIVE}"
    local FORCE
    FORCE=$(echo "${GOTOHP_FORCE_LIST[${i}]:-${GOTOHP_FORCE}}" | tr '[:lower:]' '[:upper:]')
    local DELETE
    DELETE=$(echo "${GOTOHP_DELETE_LIST[${i}]:-${GOTOHP_DELETE}}" | tr '[:lower:]' '[:upper:]')
    local DISABLE_FILTER
    DISABLE_FILTER=$(echo "${GOTOHP_DISABLE_FILTER_LIST[${i}]:-${GOTOHP_DISABLE_FILTER}}" | tr '[:lower:]' '[:upper:]')
    # Expose for use by the pre-flight file check in the main loop.
    GOTOHP_EFFECTIVE_DISABLE_FILTER="${DISABLE_FILTER}"
    local DATE_FROM_FILENAME
    DATE_FROM_FILENAME=$(echo "${GOTOHP_DATE_FROM_FILENAME_LIST[${i}]:-${GOTOHP_DATE_FROM_FILENAME}}" | tr '[:lower:]' '[:upper:]')

    GOTOHP_FLAGS+=("--threads" "${THREADS}")
    GOTOHP_FLAGS+=("--log-level" "${LOG_LEVEL}")

    if [[ "${RECURSIVE}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--recursive")
    fi
    if [[ "${FORCE}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--force")
    fi
    if [[ "${DELETE}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--delete")
    fi
    if [[ "${DISABLE_FILTER}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--disable-filter")
    fi
    if [[ "${DATE_FROM_FILENAME}" == "TRUE" ]]; then
        GOTOHP_FLAGS+=("--date-from-filename")
    fi
}

color blue "Running backup at $(date +"%Y-%m-%d %H:%M:%S %Z")"

init_env

BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-/tmp/backup-status.env}"
mkdir -p "$(dirname "${BACKUP_STATUS_FILE}")"
STATUS_LAST_START="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

function write_backup_status() {
    local state="$1"
    local exit_code="$2"
    local last_end
    last_end="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    {
        echo "STATE=${state}"
        echo "LAST_START=${STATUS_LAST_START}"
        echo "LAST_END=${last_end}"
        echo "EXIT_CODE=${exit_code}"
        echo "PAIR_INDICES=${PAIR_INDICES:-ALL}"
    } > "${BACKUP_STATUS_FILE}"
}

# 255 is used as a sentinel while a run is still in progress.
write_backup_status "RUNNING" "255"

function finalize_backup_status() {
    local rc=$?
    if [[ ${rc} -eq 0 ]]; then
        write_backup_status "SUCCESS" "${rc}"
    else
        write_backup_status "FAILED" "${rc}"
    fi
}

trap finalize_backup_status EXIT

########################################
# Handle per-group overlap locking when PAIR_INDICES is set.
# Uses a lockfile keyed to PAIR_INDICES so different groups never block
# each other, while same-group concurrency is controlled by CRON_OVERLAP.
########################################
if [[ -n "${PAIR_INDICES:-}" ]]; then
    GROUP_HASH=$(printf '%s' "${PAIR_INDICES}" | md5sum | cut -d' ' -f1)
    LOCK_FILE="/tmp/schedule-group-${GROUP_HASH}.lock"

    case "${CRON_OVERLAP}" in
        SKIP)
            exec 9>"${LOCK_FILE}"
            if ! flock -n 9; then
                color yellow "Skipping — previous run of schedule group '${PAIR_INDICES}' is still active"
                exit 0
            fi
            ;;
        MULTITHREAD)
            color blue "Concurrent run of schedule group '${PAIR_INDICES}' starting (multithread mode)"
            ;;
        QUEUE|*)
            exec 9>"${LOCK_FILE}"
            if ! flock -n 9; then
                color blue "Waiting for previous run of schedule group '${PAIR_INDICES}' to finish…"
                flock 9
            fi
            ;;
    esac
fi

if [[ "${#SOURCE_PATHS[@]}" -eq 0 ]]; then
    color red "No source paths configured."
    color red "Set SOURCE_PATH (single source) or SOURCE_PATH_0, SOURCE_PATH_1, … (multiple sources)."
    exit 1
fi

HAS_ERROR="FALSE"

# Determine which pair indices to process.
# If PAIR_INDICES is set (comma-separated), process only those pairs.
# If unset, process all pairs (backwards compatibility).
INDICES_TO_PROCESS=()
if [[ -n "${PAIR_INDICES:-}" ]]; then
    IFS=',' read -ra INDICES_TO_PROCESS <<< "${PAIR_INDICES}"
else
    INDICES_TO_PROCESS=("${!SOURCE_PATHS[@]}")
fi

for i in "${INDICES_TO_PROCESS[@]}"; do
    SOURCE="${SOURCE_PATHS[${i}]}"
    ALBUM="${ALBUM_NAMES[${i}]}"

    if [[ ! -e "${SOURCE}" ]]; then
        color yellow "Source path does not exist, skipping: ${SOURCE}"
        continue
    fi

    # Switch to the effective account for this pair (per-pair override > global)
    if ! switch_credential_for_pair "${i}"; then
        HAS_ERROR="TRUE"
        continue
    fi

    build_gotohp_flags "${i}"

    # When not in recursive mode, gotohp only processes files directly inside
    # SOURCE (not in subdirectories).  Limit the pre-flight search depth to
    # match so we don't call gotohp on a directory that holds only subdirs.
    FIND_DEPTH_ARGS=()
    if [[ "${GOTOHP_EFFECTIVE_RECURSIVE}" != "TRUE" ]]; then
        FIND_DEPTH_ARGS=("-maxdepth" "1")
    fi

    # Build a find name expression that mirrors gotohp's own extension filter.
    # When the filter is disabled, any regular file counts; otherwise only
    # known Google Photos media types are considered.  This prevents directories
    # containing solely non-media files (e.g. .DS_Store, desktop.ini) from
    # reaching gotohp, which would hang indefinitely on an empty upload queue.
    #
    # Extension list sourced from backend/upload.go:supportedFormats in
    # gotohp v0.7.0 (https://github.com/xob0t/gotohp).  Update here if the
    # GOTOHP_VERSION in the Dockerfile changes and gotohp adds new formats.
    FIND_NAME_ARGS=()
    if [[ "${GOTOHP_EFFECTIVE_DISABLE_FILTER}" != "TRUE" ]]; then
        FIND_NAME_ARGS=("(")
        _FIRST_EXT=true
        for _EXT in avif bmp gif heic heif ico jpg jpeg png tif tiff webp \
                    cr2 cr3 nef arw orf raf rw2 pef sr2 dng \
                    3gp 3g2 asf avi divx m2t m2ts m4v mkv mmv mod mov mp4 \
                    mpg mpeg mts tod wmv ts; do
            [[ "${_FIRST_EXT}" == "true" ]] || FIND_NAME_ARGS+=("-o")
            FIND_NAME_ARGS+=("-iname" "*.${_EXT}")
            _FIRST_EXT=false
        done
        FIND_NAME_ARGS+=(")")
    fi

    # Pre-flight check: distinguish "no files" from a real find failure so that
    # permission errors or unreadable mounts are not silently treated as empty.
    FIND_OUTPUT="$(find -- "${SOURCE}" "${FIND_DEPTH_ARGS[@]}" -type f "${FIND_NAME_ARGS[@]}" -print -quit 2>&1)"
    FIND_STATUS=$?
    if [[ ${FIND_STATUS} -ne 0 ]]; then
        color red "Error scanning source path (find failed), skipping: ${SOURCE}"
        color red "find output: ${FIND_OUTPUT}"
        HAS_ERROR="TRUE"
        continue
    fi
    if [[ -z "${FIND_OUTPUT}" ]]; then
        color yellow "No files found in source path, skipping: ${SOURCE}"
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
