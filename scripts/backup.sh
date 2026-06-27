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

########################################
# Extract a simple top-level string field from gotohp's compact progress JSON.
# Returns empty string if field not found. Validates JSON structure exists first.
# Arguments:
#     JSON content
#     field name
########################################
function progress_json_string() {
    local json="$1"
    local field="$2"
    [[ -n "${json}" && "${json:0:1}" == "{" ]] || return 0
    local regex="\"${field}\":\"([^\"]*)\""
    if [[ "${json}" =~ ${regex} ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    fi
}

########################################
# Extract a simple top-level numeric field from gotohp's compact progress JSON.
# Returns 0 if field not found. Validates JSON structure exists first.
# Arguments:
#     JSON content
#     field name
########################################
function progress_json_number() {
    local json="$1"
    local field="$2"
    [[ -n "${json}" && "${json:0:1}" == "{" ]] || { printf '0'; return 0; }
    local regex="\"${field}\":([0-9]+(\.[0-9]+)?)"
    if [[ "${json}" =~ ${regex} ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '0'
    fi
}

########################################
# Build a compact worker summary from gotohp's progress JSON threads array.
# This intentionally avoids raw Bubble Tea output while preserving the useful
# TUI information: worker id, status, and current filename.
# Arguments:
#     JSON content
########################################
function progress_json_threads_summary() {
    local json="$1"
    local threads_json thread worker_id status file_name summary

    threads_json="${json#*\"threads\":[}"
    [[ "${threads_json}" == "${json}" ]] && return 0
    threads_json="${threads_json%%],\"recent_results\"*}"
    [[ -z "${threads_json}" || "${threads_json}" == "]" ]] && return 0

    summary=""
    while [[ "${threads_json}" =~ \{([^{}]*)\} ]]; do
        thread="${BASH_REMATCH[1]}"
        threads_json="${threads_json#*\}}"

        worker_id="$(progress_json_number "{${thread}}" "worker_id")"
        status="$(progress_json_string "{${thread}}" "status")"
        file_name="$(progress_json_string "{${thread}}" "file_name")"
        [[ -z "${status}" && -z "${file_name}" ]] && continue

        if [[ -n "${summary}" ]]; then
            summary="${summary}; "
        fi
        summary="${summary}[${worker_id}] ${status:-unknown}"
        if [[ -n "${file_name}" ]]; then
            summary="${summary}: ${file_name}"
        fi
    done

    printf '%s' "${summary}"
}

########################################
# Emit one Docker-log progress line from gotohp's progress JSON file.
# Arguments:
#     source path
#     progress JSON file path
#     label (optional; e.g. final)
########################################
function log_upload_progress() {
    local source="$1"
    local progress_file="$2"
    local label="${3:-progress}"

    [[ -r "${progress_file}" ]] || return 0

    local progress_json state total completed failed bytes_uploaded total_bytes threads_summary
    progress_json="$(<"${progress_file}")"
    [[ -n "${progress_json}" ]] || return 0

    state="$(progress_json_string "${progress_json}" "state")"
    total="$(progress_json_number "${progress_json}" "total_files")"
    completed="$(progress_json_number "${progress_json}" "completed")"
    failed="$(progress_json_number "${progress_json}" "failed")"
    bytes_uploaded="$(progress_json_number "${progress_json}" "bytes_uploaded")"
    total_bytes="$(progress_json_number "${progress_json}" "total_bytes")"
    threads_summary="$(progress_json_threads_summary "${progress_json}")"

    if [[ "${state:-idle}" == "idle" && "${total}" == "0" && "${completed}" == "0" && "${failed}" == "0" ]]; then
        return 0
    fi

    if [[ -n "${threads_summary}" && "${state:-unknown}" == "running" ]]; then
        color blue "Upload ${label} $(color yellow "[${source}]"): ${completed}/${total} succeeded, ${failed} failed, ${bytes_uploaded}/${total_bytes} bytes uploaded (state: ${state:-unknown}) | workers: ${threads_summary}"
    else
        color blue "Upload ${label} $(color yellow "[${source}]"): ${completed}/${total} succeeded, ${failed} failed, ${bytes_uploaded}/${total_bytes} bytes uploaded (state: ${state:-unknown})"
    fi
}

########################################
# Run gotohp upload and periodically mirror progress JSON into Docker logs.
# Uses unique temp files per invocation to avoid conflicts in concurrent scenarios.
# Arguments:
#     source path
#     gotohp upload flags...
########################################
function run_gotohp_upload_with_progress() {
    local source="$1"
    shift

    local interval="${GOTOHP_PROGRESS_LOG_INTERVAL:-60}"
    if ! [[ "${interval}" =~ ^[0-9]+$ ]]; then
        interval="60"
    fi

    local progress_file upload_log_file
    progress_file=$(mktemp /tmp/gotohp-progress.XXXXXX.json) || progress_file="/tmp/gotohp-progress.$$.json"
    upload_log_file=$(mktemp /tmp/gotohp-upload.XXXXXX.log) || upload_log_file="/tmp/gotohp-upload.$$.log"

    if [[ "${interval}" == "0" ]]; then
        if [[ "${GOTOHP_UPLOAD_RAW_LOGS:-FALSE}" == "TRUE" ]]; then
            gotohp upload "${source}" "$@"
        else
            gotohp upload "${source}" "$@" >"${upload_log_file}" 2>&1
        fi
        rm -f "${progress_file}" "${upload_log_file}"
        return $?
    fi

    local upload_pid elapsed rc

    if [[ "${GOTOHP_UPLOAD_RAW_LOGS:-FALSE}" == "TRUE" ]]; then
        gotohp upload "${source}" "$@" &
    else
        gotohp upload "${source}" "$@" >"${upload_log_file}" 2>&1 &
    fi
    upload_pid=$!
    elapsed=0

    while kill -0 "${upload_pid}" 2>/dev/null; do
        sleep 1
        elapsed=$((elapsed + 1))
        if (( elapsed >= interval )); then
            log_upload_progress "${source}" "${progress_file}"
            elapsed=0
        fi
    done

    wait "${upload_pid}"
    rc=$?
    log_upload_progress "${source}" "${progress_file}" "final"
    rm -f "${progress_file}" "${upload_log_file}"
    return ${rc}
}

exec >/proc/1/fd/1 2>&1

color blue "Running backup at $(date +"%Y-%m-%d %H:%M:%S %Z")"

init_env

BACKUP_STATUS_FILE="${BACKUP_STATUS_FILE:-/tmp/backup-status.env}"
mkdir -p "$(dirname "${BACKUP_STATUS_FILE}")"
STATUS_LAST_START="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

function write_backup_status() {
    local state="$1"
    local exit_code="$2"
    local last_end=""
    if [[ "${state}" != "RUNNING" ]]; then
        last_end="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    fi
    local status_dir status_base tmp_status_file
    status_dir="$(dirname "${BACKUP_STATUS_FILE}")"
    status_base="$(basename "${BACKUP_STATUS_FILE}")"
    tmp_status_file="$(mktemp "${status_dir}/${status_base}.tmp.XXXXXX")" || return 1
    if ! {
        echo "STATE=${state}"
        echo "LAST_START=${STATUS_LAST_START}"
        echo "LAST_END=${last_end}"
        echo "EXIT_CODE=${exit_code}"
        echo "PAIR_INDICES=${PAIR_INDICES:-ALL}"
    } > "${tmp_status_file}"; then
        rm -f "${tmp_status_file}"
        return 1
    fi
    if ! mv -f "${tmp_status_file}" "${BACKUP_STATUS_FILE}"; then
        rm -f "${tmp_status_file}"
        return 1
    fi
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

    run_gotohp_upload_with_progress "${SOURCE}" "${UPLOAD_FLAGS[@]}"

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
