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
    GOTOHP_EFFECTIVE_EMAIL="${effective_email}"
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
    # Expose for use by skip-unchanged handling in the main loop.
    GOTOHP_EFFECTIVE_FORCE="${FORCE}"
    local DELETE
    DELETE=$(echo "${GOTOHP_DELETE_LIST[${i}]:-${GOTOHP_DELETE}}" | tr '[:lower:]' '[:upper:]')
    # Expose for use by skip-unchanged state keys.
    GOTOHP_EFFECTIVE_DELETE="${DELETE}"
    local DISABLE_FILTER
    DISABLE_FILTER=$(echo "${GOTOHP_DISABLE_FILTER_LIST[${i}]:-${GOTOHP_DISABLE_FILTER}}" | tr '[:lower:]' '[:upper:]')
    # Expose for use by the pre-flight file check in the main loop.
    GOTOHP_EFFECTIVE_DISABLE_FILTER="${DISABLE_FILTER}"
    local DATE_FROM_FILENAME
    DATE_FROM_FILENAME=$(echo "${GOTOHP_DATE_FROM_FILENAME_LIST[${i}]:-${GOTOHP_DATE_FROM_FILENAME}}" | tr '[:lower:]' '[:upper:]')
    # Expose for use by skip-unchanged state keys.
    GOTOHP_EFFECTIVE_DATE_FROM_FILENAME="${DATE_FROM_FILENAME}"
    local EXCLUDE="${GOTOHP_EXCLUDE_LIST[${i}]:-${GOTOHP_EXCLUDE}}"
    # Expose for use by pre-flight scans and skip-unchanged fingerprints.
    GOTOHP_EFFECTIVE_EXCLUDE="${EXCLUDE}"

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
    if [[ -n "${EXCLUDE}" ]]; then
        GOTOHP_FLAGS+=("--exclude" "${EXCLUDE}")
    fi
}

########################################
# Build find prune arguments matching gotohp's recursive --exclude behaviour.
# The patched gotohp CLI excludes child directories whose basename equals the
# configured pattern.  The source root itself is still scanned.
# Arguments:
#     recursive flag (TRUE/FALSE)
#     exclude pattern
# Outputs:
#     FIND_PRUNE_ARGS array
########################################
function build_find_prune_args() {
    local recursive="$1"
    local exclude="$2"

    FIND_PRUNE_ARGS=()
    if [[ "${recursive}" == "TRUE" && -n "${exclude}" ]]; then
        FIND_PRUNE_ARGS=("(" "-mindepth" "1" "-type" "d" "-name" "${exclude}" "-prune" ")" "-o")
    fi
}

########################################
# Hash the effective source tree metadata without reading file contents.
# Includes file paths, entry type, size, mtime, ctime, ownership, inode,
# and symlink target. Excludes file mode bits to avoid false positives from
# umask changes. Directory timestamps are intentionally omitted so churn
# inside excluded child directories does not dirty the included parent tree.
# Arguments:
#     source path
#     recursive flag (TRUE/FALSE)
#     exclude pattern
# Outputs:
#     TREE_FINGERPRINT global variable
# Returns:
#     0 on success; non-zero on scan/hash failure
########################################
function compute_tree_fingerprint() {
    local source="$1"
    local recursive="$2"
    local exclude="$3"

    local -a depth_args=()
    if [[ "${recursive}" != "TRUE" ]]; then
        depth_args=("-maxdepth" "1")
    fi

    local -a prune_args=()
    if [[ "${recursive}" == "TRUE" && -n "${exclude}" ]]; then
        prune_args=("(" "-mindepth" "1" "-type" "d" "-name" "${exclude}" "-prune" ")" "-o")
    fi

    local manifest_file sorted_file error_file hash_line
    manifest_file="$(mktemp)" || return 1
    sorted_file="$(mktemp)" || {
        rm -f "${manifest_file}"
        return 1
    }
    error_file="$(mktemp)" || {
        rm -f "${manifest_file}" "${sorted_file}"
        return 1
    }

    if ! find -- "${source}" "${depth_args[@]}" "${prune_args[@]}" \
        "(" "-type" "d" "-printf" 'd\t%P\t\t\t\t%U\t%G\t%i\t\0' ")" "-o" \
        "(" "!" "-type" "d" "-printf" '%y\t%P\t%s\t%T@\t%C@\t%U\t%G\t%i\t%l\0' ")" \
        > "${manifest_file}" 2> "${error_file}"; then
        color red "Error fingerprinting source path (find failed): ${source}"
        color red "find output: $(<"${error_file}")"
        rm -f "${manifest_file}" "${sorted_file}" "${error_file}"
        return 1
    fi

    if ! LC_ALL=C sort -z "${manifest_file}" > "${sorted_file}"; then
        color red "Error fingerprinting source path (sort failed): ${source}"
        rm -f "${manifest_file}" "${sorted_file}" "${error_file}"
        return 1
    fi

    hash_line="$(sha256sum "${sorted_file}")" || {
        color red "Error fingerprinting source path (sha256sum failed): ${source}"
        rm -f "${manifest_file}" "${sorted_file}" "${error_file}"
        return 1
    }
    TREE_FINGERPRINT="${hash_line%% *}"

    rm -f "${manifest_file}" "${sorted_file}" "${error_file}"
    return 0
}

########################################
# Build the persistent state path for a source/album pair and effective upload
# configuration.  Config changes intentionally use a different state file so a
# pair is uploaded once to seed a clean state for the new behaviour.
# State filename includes readable identifiers (source, album) plus a hash of
# all effective config for debugging and cleanup.
# Outputs:
#     PAIR_STATE_FILE global variable
########################################
function build_pair_state_file() {
    local source="$1"
    local album="$2"
    local email="$3"
    local recursive="$4"
    local force="$5"
    local delete="$6"
    local disable_filter="$7"
    local date_from_filename="$8"
    local exclude="$9"

    local key_hash_line key_hash source_slug album_slug
    key_hash_line="$(printf '%q\n' \
        "schema=skip-unchanged-v1" \
        "source=${source}" \
        "album=${album}" \
        "email=${email}" \
        "recursive=${recursive}" \
        "force=${force}" \
        "delete=${delete}" \
        "disable_filter=${disable_filter}" \
        "date_from_filename=${date_from_filename}" \
        "exclude=${exclude}" \
        | sha256sum)" || return 1
    key_hash="${key_hash_line%% *}"

    source_slug="$(printf '%s' "${source}" | sed 's|/|_|g' | cut -c1-20)"
    album_slug="$(printf '%s' "${album}" | sed 's|[^a-zA-Z0-9._-]|_|g' | cut -c1-20)"
    PAIR_STATE_FILE="${SKIP_UNCHANGED_STATE_DIR}/${source_slug}_${album_slug:+${album_slug}_}${key_hash:0:8}.state"
}

########################################
# Atomically persist a successful post-upload fingerprint.
# Arguments:
#     state file path
#     fingerprint hash
########################################
function write_skip_unchanged_state() {
    local state_file="$1"
    local fingerprint="$2"
    local state_dir state_base tmp_state_file

    state_dir="$(dirname "${state_file}")"
    state_base="$(basename "${state_file}")"
    mkdir -p "${state_dir}" || return 1
    tmp_state_file="$(mktemp "${state_dir}/${state_base}.tmp.XXXXXX")" || return 1

    if ! {
        printf '%s\n' "${fingerprint}"
        printf 'UPDATED_AT=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    } > "${tmp_state_file}"; then
        rm -f "${tmp_state_file}"
        return 1
    fi

    if ! mv -f "${tmp_state_file}" "${state_file}"; then
        rm -f "${tmp_state_file}"
        return 1
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
STATE_UPDATES=()
SKIP_UNCHANGED_STATE_DIR="${GOTOHP_SKIP_UNCHANGED_STATE_DIR:-/config/gotohp-wrapper/skip-unchanged/v1}"

########################################
# Clean up old skip-unchanged state files to prevent directory bloat.
# Removes state files not accessed in the last 60 days.
########################################
function cleanup_old_state_files() {
    [[ ! -d "${SKIP_UNCHANGED_STATE_DIR}" ]] && return 0
    find "${SKIP_UNCHANGED_STATE_DIR}" -maxdepth 1 -name "*.state" -type f -atime +60 -delete 2>/dev/null || true
}

cleanup_old_state_files

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
    GOTOHP_EFFECTIVE_SKIP_UNCHANGED=$(echo "${GOTOHP_SKIP_UNCHANGED_LIST[${i}]:-${GOTOHP_SKIP_UNCHANGED}}" | tr '[:lower:]' '[:upper:]')

    # When not in recursive mode, gotohp only processes files directly inside
    # SOURCE (not in subdirectories).  Limit the pre-flight search depth to
    # match so we don't call gotohp on a directory that holds only subdirs.
    FIND_DEPTH_ARGS=()
    if [[ "${GOTOHP_EFFECTIVE_RECURSIVE}" != "TRUE" ]]; then
        FIND_DEPTH_ARGS=("-maxdepth" "1")
    fi

    build_find_prune_args "${GOTOHP_EFFECTIVE_RECURSIVE}" "${GOTOHP_EFFECTIVE_EXCLUDE}"

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
    FIND_OUTPUT="$(find -- "${SOURCE}" "${FIND_DEPTH_ARGS[@]}" "${FIND_PRUNE_ARGS[@]}" -type f "${FIND_NAME_ARGS[@]}" -print -quit 2>&1)"
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

    SHOULD_TRACK_STATE="FALSE"
    CURRENT_FINGERPRINT=""
    CURRENT_STATE_FILE=""
    if [[ "${GOTOHP_EFFECTIVE_SKIP_UNCHANGED}" == "TRUE" ]]; then
        if [[ "${GOTOHP_EFFECTIVE_FORCE}" == "TRUE" ]]; then
            color yellow "Skip-unchanged disabled for this run because GOTOHP_FORCE is TRUE: ${SOURCE}"
        elif compute_tree_fingerprint "${SOURCE}" "${GOTOHP_EFFECTIVE_RECURSIVE}" "${GOTOHP_EFFECTIVE_EXCLUDE}"; then
            CURRENT_FINGERPRINT="${TREE_FINGERPRINT}"
            if build_pair_state_file \
                "${SOURCE}" \
                "${ALBUM}" \
                "${GOTOHP_EFFECTIVE_EMAIL:-}" \
                "${GOTOHP_EFFECTIVE_RECURSIVE}" \
                "${GOTOHP_EFFECTIVE_FORCE}" \
                "${GOTOHP_EFFECTIVE_DELETE}" \
                "${GOTOHP_EFFECTIVE_DISABLE_FILTER}" \
                "${GOTOHP_EFFECTIVE_DATE_FROM_FILENAME}" \
                "${GOTOHP_EFFECTIVE_EXCLUDE}"; then
                CURRENT_STATE_FILE="${PAIR_STATE_FILE}"
                SHOULD_TRACK_STATE="TRUE"
                if [[ -f "${CURRENT_STATE_FILE}" ]]; then
                    IFS= read -r PREVIOUS_FINGERPRINT < "${CURRENT_STATE_FILE}" || PREVIOUS_FINGERPRINT=""
                    if [[ "${PREVIOUS_FINGERPRINT}" == "${CURRENT_FINGERPRINT}" ]]; then
                        color green "Source tree unchanged since previous successful run, skipping gotohp: ${SOURCE}"
                        continue
                    fi
                fi
                color blue "Source tree changed or no previous clean state found: ${SOURCE}"
            else
                color red "Error building skip-unchanged state key, skipping: ${SOURCE}"
                HAS_ERROR="TRUE"
                continue
            fi
        else
            HAS_ERROR="TRUE"
            continue
        fi
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
        if [[ "${SHOULD_TRACK_STATE}" == "TRUE" ]]; then
            if compute_tree_fingerprint "${SOURCE}" "${GOTOHP_EFFECTIVE_RECURSIVE}" "${GOTOHP_EFFECTIVE_EXCLUDE}"; then
                STATE_UPDATES+=("${CURRENT_STATE_FILE}" "${TREE_FINGERPRINT}")
            else
                HAS_ERROR="TRUE"
            fi
        fi
    fi
done

if [[ "${HAS_ERROR}" == "TRUE" ]]; then
    color red "One or more uploads failed at $(date +"%Y-%m-%d %H:%M:%S %Z")"
    exit 1
fi

for ((state_i = 0; state_i < ${#STATE_UPDATES[@]}; state_i += 2)); do
    if ! write_skip_unchanged_state "${STATE_UPDATES[${state_i}]}" "${STATE_UPDATES[$((state_i + 1))]}"; then
        color red "Failed to persist skip-unchanged state: ${STATE_UPDATES[${state_i}]}"
        exit 1
    fi
done

color green "All uploads completed successfully at $(date +"%Y-%m-%d %H:%M:%S %Z")"
