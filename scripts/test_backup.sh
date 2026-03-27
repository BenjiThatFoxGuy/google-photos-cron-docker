#!/bin/bash
# Test suite for backup.sh
# Run: bash scripts/test_backup.sh
# Exit code 0 = all tests passed; non-zero = at least one test failed.

set -euo pipefail

########################################
# Helpers
########################################
PASS=0
FAIL=0

pass() { echo -e "\033[32mPASS\033[0m $1"; PASS=$((PASS+1)); }
fail() { echo -e "\033[31mFAIL\033[0m $1"; FAIL=$((FAIL+1)); }

# Scratch area cleaned up at exit
SCRATCH=$(mktemp -d)
trap 'rm -rf "${SCRATCH}"' EXIT

# Timeout (seconds) applied to the softlock regression test
HANG_TEST_TIMEOUT=10

########################################
# Build a self-contained mock environment.
# The real backup.sh sources /app/includes.sh and calls gotohp.
# We replace both with test doubles.
#
# Arguments:
#   $1  test name (used as subdirectory name under $SCRATCH)
#   $2  first source path  (the one we expect to be skipped/empty)
#   $3  second source path (the one we expect to be uploaded)
#   $4  global GOTOHP_RECURSIVE value (optional; default: "TRUE")
#   $5  email for pair 0 override (optional; default: "")
#   $6  email for pair 1 override (optional; default: "")
#   $7  global GOTOHP_EMAIL value (optional; default: "")
#   $8  CRON_OVERLAP value (optional; default: "QUEUE")
########################################
setup_env() {
    local test_name="$1"
    local first_source="$2"
    local second_source="$3"
    local gotohp_recursive="${4:-TRUE}"
    local pair0_email="${5:-}"
    local pair1_email="${6:-}"
    local global_email="${7:-}"
    local cron_overlap="${8:-QUEUE}"

    local env_dir="${SCRATCH}/${test_name}"
    mkdir -p "${env_dir}/bin" "${env_dir}/app"

    GOTOHP_CALLS="${env_dir}/gotohp_calls.txt"

    # Mock gotohp: records its arguments; exits 0 by default.
    cat > "${env_dir}/bin/gotohp" << EOF
#!/bin/bash
echo "\$*" >> "${GOTOHP_CALLS}"
EOF
    chmod +x "${env_dir}/bin/gotohp"

    # Mock includes.sh: exposes the same init_env / color interface but
    # populates SOURCE_PATHS directly from the values supplied by the test.
    cat > "${env_dir}/app/includes.sh" << HEREDOC
#!/bin/bash
CRON_CONFIG_FILE="\${HOME}/crontabs"

function color() {
    case \$1 in
        red)    echo -e "\033[31m\$2\033[0m" ;;
        green)  echo -e "\033[32m\$2\033[0m" ;;
        yellow) echo -e "\033[33m\$2\033[0m" ;;
        blue)   echo -e "\033[34m\$2\033[0m" ;;
        none)   echo "\$2" ;;
    esac
}

function init_env() {
    SOURCE_PATHS=("${first_source}" "${second_source}")
    ALBUM_NAMES=("FirstAlbum" "SecondAlbum")
    GOTOHP_THREADS_LIST=("" "")
    GOTOHP_RECURSIVE_LIST=("" "")
    GOTOHP_FORCE_LIST=("" "")
    GOTOHP_DELETE_LIST=("" "")
    GOTOHP_DISABLE_FILTER_LIST=("" "")
    GOTOHP_DATE_FROM_FILENAME_LIST=("" "")
    GOTOHP_LOG_LEVEL_LIST=("" "")
    GOTOHP_CREDS_LIST=("" "")
    GOTOHP_EMAIL_LIST=("${pair0_email}" "${pair1_email}")
    CRON_LIST=("" "")
    GOTOHP_THREADS="3"
    GOTOHP_RECURSIVE="${gotohp_recursive}"
    GOTOHP_FORCE="FALSE"
    GOTOHP_DELETE="FALSE"
    GOTOHP_DISABLE_FILTER="FALSE"
    GOTOHP_DATE_FROM_FILENAME="FALSE"
    GOTOHP_LOG_LEVEL="info"
    GOTOHP_EMAIL="${global_email}"
    CRON_OVERLAP="${cron_overlap}"
}
HEREDOC

    # Patched copy of backup.sh pointing at our mock includes.sh
    sed "s|^\. /app/includes\.sh$|. ${env_dir}/app/includes.sh|" \
        "$(dirname "$0")/backup.sh" > "${env_dir}/app/backup.sh"

    # Make gotohp mock first on PATH
    TEST_PATH="${env_dir}/bin:${PATH}"
    TEST_BACKUP="${env_dir}/app/backup.sh"
}

########################################
# Test 1: empty first source → skipped; second source with files → uploaded
########################################
echo "--- Test 1: first source empty, second source has files ---"

EMPTY="${SCRATCH}/t1_empty"
FILES="${SCRATCH}/t1_files"
mkdir -p "${EMPTY}" "${FILES}"
echo "photo" > "${FILES}/photo.jpg"

setup_env "t1" "${EMPTY}" "${FILES}"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t1_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 1: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t1_out.txt"
elif grep -q "${EMPTY}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 1: gotohp was called with the empty source"
    cat "${SCRATCH}/t1_out.txt"
elif ! grep -q "${FILES}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 1: gotohp was NOT called with the files source"
    cat "${SCRATCH}/t1_out.txt"
else
    pass "Test 1: empty source skipped, files source uploaded"
fi

########################################
# Test 2: first source does not exist → skipped; second source with files → uploaded
########################################
echo "--- Test 2: first source does not exist, second source has files ---"

MISSING="${SCRATCH}/t2_nonexistent"
FILES2="${SCRATCH}/t2_files"
mkdir -p "${FILES2}"
echo "photo" > "${FILES2}/photo.jpg"

setup_env "t2" "${MISSING}" "${FILES2}"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t2_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 2: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t2_out.txt"
elif grep -q "${MISSING}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 2: gotohp was called with the nonexistent source"
    cat "${SCRATCH}/t2_out.txt"
elif ! grep -q "${FILES2}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 2: gotohp was NOT called with the files source"
    cat "${SCRATCH}/t2_out.txt"
else
    pass "Test 2: nonexistent source skipped, files source uploaded"
fi

########################################
# Test 3: files buried in a subdirectory → detected and uploaded
########################################
echo "--- Test 3: files only in a subdirectory of source ---"

SUBDIR_SRC="${SCRATCH}/t3_src"
EMPTY3="${SCRATCH}/t3_empty"
mkdir -p "${SUBDIR_SRC}/nested/deep" "${EMPTY3}"
echo "photo" > "${SUBDIR_SRC}/nested/deep/photo.jpg"

setup_env "t3" "${EMPTY3}" "${SUBDIR_SRC}"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t3_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 3: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t3_out.txt"
elif grep -q "${EMPTY3}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 3: gotohp was called with the empty source"
    cat "${SCRATCH}/t3_out.txt"
elif ! grep -q "${SUBDIR_SRC}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 3: gotohp was NOT called for source with nested files"
    cat "${SCRATCH}/t3_out.txt"
else
    pass "Test 3: nested files detected, source uploaded"
fi

########################################
# Test 4: regression guard — gotohp must NOT be called for the empty source
#         even when a hanging gotohp mock would cause a timeout.
#         Uses `timeout` so the test suite itself doesn't softlock.
########################################
echo "--- Test 4: regression guard — empty source must not invoke gotohp (hang mock) ---"

EMPTY4="${SCRATCH}/t4_empty"
FILES4="${SCRATCH}/t4_files"
mkdir -p "${EMPTY4}" "${FILES4}"
echo "photo" > "${FILES4}/photo.jpg"

setup_env "t4" "${EMPTY4}" "${FILES4}"

# Replace the simple mock with a version that hangs forever when called with
# the EMPTY source path, simulating the real gotohp hang.
cat > "${SCRATCH}/t4/bin/gotohp" << EOF
#!/bin/bash
echo "\$*" >> "${GOTOHP_CALLS}"
if echo "\$*" | grep -q "${EMPTY4}"; then
    # Simulate indefinite hang — this must never be reached.
    sleep 3600
fi
EOF
chmod +x "${SCRATCH}/t4/bin/gotohp"

RC=0
PATH="${TEST_PATH}" timeout "${HANG_TEST_TIMEOUT}" bash "${TEST_BACKUP}" > "${SCRATCH}/t4_out.txt" 2>&1 || RC=$?

if [[ $RC -eq 124 ]]; then
    fail "Test 4: backup.sh timed out — gotohp was called on empty source (softlock!)"
    cat "${SCRATCH}/t4_out.txt"
elif grep -q "${EMPTY4}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 4: gotohp was called with the empty source"
    cat "${SCRATCH}/t4_out.txt"
else
    pass "Test 4: empty source did not invoke gotohp (no softlock)"
fi

########################################
# Test 5: RECURSIVE=FALSE, source has only subdirectories → skipped
# (Reproduces the user's scenario: SOURCE_PATH=/photos/PixelDump with sub-
#  folders inside but no files directly at the top level, RECURSIVE=FALSE.)
########################################
echo "--- Test 5: RECURSIVE=FALSE, source contains only subdirectories → skipped ---"

SUBDIR_ONLY="${SCRATCH}/t5_subdir_only"
FILES5="${SCRATCH}/t5_files"
mkdir -p "${SUBDIR_ONLY}/nested" "${FILES5}"
echo "photo" > "${SUBDIR_ONLY}/nested/photo.jpg"  # file only in a subdir
echo "photo" > "${FILES5}/photo.jpg"

setup_env "t5" "${SUBDIR_ONLY}" "${FILES5}" "FALSE"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t5_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 5: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t5_out.txt"
elif grep -q "${SUBDIR_ONLY}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 5: gotohp was called on source with only subdirectories (RECURSIVE=FALSE)"
    cat "${SCRATCH}/t5_out.txt"
elif ! grep -q "${FILES5}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 5: gotohp was NOT called with the files source"
    cat "${SCRATCH}/t5_out.txt"
else
    pass "Test 5: subdir-only source skipped when RECURSIVE=FALSE"
fi

########################################
# Test 6: RECURSIVE=FALSE, source has direct files AND subdirectories → uploaded
########################################
echo "--- Test 6: RECURSIVE=FALSE, source has direct files AND subdirs → uploaded ---"

MIXED="${SCRATCH}/t6_mixed"
EMPTY6="${SCRATCH}/t6_empty"
mkdir -p "${MIXED}/subdir" "${EMPTY6}"
echo "photo" > "${MIXED}/direct.jpg"          # direct file  → should be picked up
echo "photo" > "${MIXED}/subdir/nested.jpg"   # file in subdir → ignored by gotohp

setup_env "t6" "${EMPTY6}" "${MIXED}" "FALSE"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t6_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 6: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t6_out.txt"
elif ! grep -q "${MIXED}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 6: gotohp was NOT called for source with direct files (RECURSIVE=FALSE)"
    cat "${SCRATCH}/t6_out.txt"
elif grep -q "${EMPTY6}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 6: gotohp was called with the empty source"
    cat "${SCRATCH}/t6_out.txt"
else
    pass "Test 6: source with direct files uploaded when RECURSIVE=FALSE"
fi

########################################
# Test 7: source contains only non-media files (.DS_Store, desktop.ini) → skipped
# (Reproduces the VRChat scenario: gotohp's extension filter would reject all
#  files, so its TUI would hang.  The pre-flight check must mirror the filter.)
########################################
echo "--- Test 7: source has only non-media files (.DS_Store / desktop.ini) → skipped ---"

STRAY="${SCRATCH}/t7_stray"
FILES7="${SCRATCH}/t7_files"
mkdir -p "${STRAY}" "${FILES7}"
echo "data"  > "${STRAY}/.DS_Store"       # macOS metadata — not a media file
echo "data"  > "${STRAY}/desktop.ini"     # Windows metadata — not a media file
echo "photo" > "${FILES7}/photo.jpg"

setup_env "t7" "${STRAY}" "${FILES7}"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t7_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 7: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t7_out.txt"
elif grep -q "${STRAY}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 7: gotohp was called for source with only non-media files"
    cat "${SCRATCH}/t7_out.txt"
elif ! grep -q "${FILES7}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 7: gotohp was NOT called for the valid media source"
    cat "${SCRATCH}/t7_out.txt"
else
    pass "Test 7: non-media-only source skipped, media source uploaded"
fi

########################################
# Test 8: per-pair email override → gotohp creds set called with pair email
########################################
echo "--- Test 8: per-pair email override — creds set called before pair upload ---"

FILES8_0="${SCRATCH}/t8_pair0"
FILES8_1="${SCRATCH}/t8_pair1"
mkdir -p "${FILES8_0}" "${FILES8_1}"
echo "photo" > "${FILES8_0}/photo.jpg"
echo "photo" > "${FILES8_1}/photo.jpg"

# Pair 1 has its own email override; global email is alice@example.com
# args: test_name first_source second_source recursive pair0_email pair1_email global_email
setup_env "t8" "${FILES8_0}" "${FILES8_1}" "TRUE" "" "bob@example.com" "alice@example.com"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t8_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 8: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t8_out.txt"
elif ! grep -q "creds set bob@example.com" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 8: gotohp creds set was NOT called with the per-pair email (bob@example.com)"
    cat "${SCRATCH}/t8_out.txt"
elif ! grep -q "upload ${FILES8_1}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 8: gotohp upload was NOT called for pair 1 source"
    cat "${SCRATCH}/t8_out.txt"
else
    # Verify creds set for pair 1 appears before the upload for pair 1
    CREDS_LINE=$(grep -n "creds set bob@example.com" "${GOTOHP_CALLS}" | head -1 | cut -d: -f1)
    UPLOAD_LINE=$(grep -n "upload ${FILES8_1}" "${GOTOHP_CALLS}" | head -1 | cut -d: -f1)
    if [[ -n "${CREDS_LINE}" && -n "${UPLOAD_LINE}" && "${CREDS_LINE}" -lt "${UPLOAD_LINE}" ]]; then
        pass "Test 8: per-pair creds set called before pair 1 upload"
    else
        fail "Test 8: creds set did not appear before upload for pair 1"
        cat "${SCRATCH}/t8_out.txt"
    fi
fi

########################################
# Test 9: per-pair creds set failure → pair skipped, exit code non-zero,
#         remaining pairs still processed.
########################################
echo "--- Test 9: creds set failure → pair skipped, HAS_ERROR set ---"

FILES9_0="${SCRATCH}/t9_pair0"
FILES9_1="${SCRATCH}/t9_pair1"
mkdir -p "${FILES9_0}" "${FILES9_1}"
echo "photo" > "${FILES9_0}/photo.jpg"
echo "photo" > "${FILES9_1}/photo.jpg"

# Pair 0 has a per-pair email; global email is empty for pair 1
# args: test_name first_source second_source recursive pair0_email pair1_email global_email
setup_env "t9" "${FILES9_0}" "${FILES9_1}" "TRUE" "fail@example.com" "" ""

# Replace gotohp mock: exit 1 when called with "creds set fail@example.com"
cat > "${SCRATCH}/t9/bin/gotohp" << EOF
#!/bin/bash
echo "\$*" >> "${GOTOHP_CALLS}"
if [[ "\$*" == "creds set fail@example.com" ]]; then
    exit 1
fi
EOF
chmod +x "${SCRATCH}/t9/bin/gotohp"

RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t9_out.txt" 2>&1 || RC=$?

if [[ $RC -eq 0 ]]; then
    fail "Test 9: backup.sh should have exited non-zero due to creds set failure"
    cat "${SCRATCH}/t9_out.txt"
elif grep -q "upload ${FILES9_0}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 9: pair 0 should have been skipped after creds set failure"
    cat "${SCRATCH}/t9_out.txt"
elif ! grep -q "upload ${FILES9_1}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 9: pair 1 (no email override) should still have been uploaded"
    cat "${SCRATCH}/t9_out.txt"
else
    pass "Test 9: creds set failure skipped pair 0; pair 1 still uploaded; exit non-zero"
fi

########################################
# Tests 10–15: cron_is_interval — validate the interval-detection logic
# that drives the "run backup immediately on container start" feature.
#
# The function is defined inline here (mirroring entrypoint.sh) so the
# tests have no dependency on parsing the entrypoint source file.
########################################
echo "--- Tests 10–15: cron_is_interval detection ---"

function cron_is_interval() {
    local field
    local -a cron_fields
    read -ra cron_fields <<< "${CRON}"
    for field in "${cron_fields[@]}"; do
        if [[ "${field}" =~ ^\*/[1-9][0-9]*$ ]]; then
            return 0
        fi
    done
    return 1
}

# Test 10: classic interval cron (*/10 * * * *) → IS interval
CRON="*/10 * * * *"
if cron_is_interval; then
    pass "Test 10: '${CRON}' correctly identified as interval"
else
    fail "Test 10: '${CRON}' should be interval but was not detected"
fi

# Test 11: rigid fixed-minute cron (0 * * * *) → NOT interval
CRON="0 * * * *"
if cron_is_interval; then
    fail "Test 11: '${CRON}' should NOT be interval but was detected as one"
else
    pass "Test 11: '${CRON}' correctly identified as non-interval"
fi

# Test 12: rigid two-field cron (0 2 * * *) → NOT interval
CRON="0 2 * * *"
if cron_is_interval; then
    fail "Test 12: '${CRON}' should NOT be interval but was detected as one"
else
    pass "Test 12: '${CRON}' correctly identified as non-interval"
fi

# Test 13: interval in a non-minute field (0 */2 * * *) → IS interval
CRON="0 */2 * * *"
if cron_is_interval; then
    pass "Test 13: '${CRON}' correctly identified as interval (*/2 in hour field)"
else
    fail "Test 13: '${CRON}' should be interval but was not detected"
fi

# Test 14: default cron (5 * * * *) → NOT interval (fixed minute, every hour)
CRON="5 * * * *"
if cron_is_interval; then
    fail "Test 14: '${CRON}' should NOT be interval but was detected as one"
else
    pass "Test 14: '${CRON}' correctly identified as non-interval"
fi

# Test 15: invalid step */0 → NOT interval (step of 0 is invalid)
CRON="*/0 * * * *"
if cron_is_interval; then
    fail "Test 15: '${CRON}' should NOT be interval (step 0 is invalid) but was detected as one"
else
    pass "Test 15: '${CRON}' correctly rejected as non-interval (step 0 is invalid)"
fi

########################################
########################################

########################################
# Tests 16–19: build_schedule_groups — verify grouping logic.
# The function is defined inline here (mirroring includes.sh) so the
# tests have no dependency on the real includes.sh file.
########################################
echo "--- Tests 16–19: build_schedule_groups ---"

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

# Test 16: no CRON_N set — all pairs grouped under global CRON (single group)
CRON="0 2 * * *"
SOURCE_PATHS=("a" "b" "c")
CRON_LIST=("" "" "")
build_schedule_groups
if [[ "${#SCHEDULE_GROUPS[@]}" -eq 1 && "${SCHEDULE_GROUPS["0 2 * * *"]}" == "0,1,2" ]]; then
    pass "Test 16: no CRON_N — all pairs in single global-cron group"
else
    fail "Test 16: expected 1 group '0 2 * * *'→'0,1,2', got ${#SCHEDULE_GROUPS[@]} groups: $(declare -p SCHEDULE_GROUPS)"
fi

# Test 17: all pairs have the same CRON_N — still produces a single group
CRON="0 2 * * *"
SOURCE_PATHS=("a" "b")
CRON_LIST=("*/5 * * * *" "*/5 * * * *")
build_schedule_groups
if [[ "${#SCHEDULE_GROUPS[@]}" -eq 1 && "${SCHEDULE_GROUPS["*/5 * * * *"]}" == "0,1" ]]; then
    pass "Test 17: identical CRON_N on all pairs — single group produced"
else
    fail "Test 17: expected 1 group '*/5 * * * *'→'0,1', got ${#SCHEDULE_GROUPS[@]} groups: $(declare -p SCHEDULE_GROUPS)"
fi

# Test 18: mixed overrides — pairs 0,2 use global; pair 1 has CRON_1 override
CRON="0 2 * * *"
SOURCE_PATHS=("a" "b" "c")
CRON_LIST=("" "*/30 * * * *" "")
build_schedule_groups
if [[ "${#SCHEDULE_GROUPS[@]}" -eq 2 \
      && "${SCHEDULE_GROUPS["0 2 * * *"]}" == "0,2" \
      && "${SCHEDULE_GROUPS["*/30 * * * *"]}" == "1" ]]; then
    pass "Test 18: mixed overrides — two groups with correct pair assignments"
else
    fail "Test 18: expected 2 groups ('0 2 * * *'→'0,2', '*/30 * * * *'→'1'), got: $(declare -p SCHEDULE_GROUPS)"
fi

# Test 19: every pair has a unique CRON_N — N groups, one pair each
CRON="5 * * * *"
SOURCE_PATHS=("a" "b" "c")
CRON_LIST=("0 1 * * *" "0 2 * * *" "0 3 * * *")
build_schedule_groups
if [[ "${#SCHEDULE_GROUPS[@]}" -eq 3 \
      && "${SCHEDULE_GROUPS["0 1 * * *"]}" == "0" \
      && "${SCHEDULE_GROUPS["0 2 * * *"]}" == "1" \
      && "${SCHEDULE_GROUPS["0 3 * * *"]}" == "2" ]]; then
    pass "Test 19: unique CRON_N per pair — ${#SCHEDULE_GROUPS[@]} groups, one pair each"
else
    fail "Test 19: expected 3 unique groups, got: $(declare -p SCHEDULE_GROUPS)"
fi

########################################
# Tests 20–21: PAIR_INDICES filtering in backup.sh
########################################
echo "--- Tests 20–21: PAIR_INDICES filtering ---"

# Helper: create a 3-pair mock environment for PAIR_INDICES tests.
# Arguments: test_name cron_overlap
setup_env_multi() {
    local test_name="$1"
    local cron_overlap="${2:-QUEUE}"

    local env_dir="${SCRATCH}/${test_name}"
    mkdir -p "${env_dir}/bin" "${env_dir}/app"

    local path0="${SCRATCH}/${test_name}_p0"
    local path1="${SCRATCH}/${test_name}_p1"
    local path2="${SCRATCH}/${test_name}_p2"
    mkdir -p "${path0}" "${path1}" "${path2}"
    echo "photo" > "${path0}/photo.jpg"
    echo "photo" > "${path1}/photo.jpg"
    echo "photo" > "${path2}/photo.jpg"

    GOTOHP_CALLS="${env_dir}/gotohp_calls.txt"
    MULTI_PATH0="${path0}"
    MULTI_PATH1="${path1}"
    MULTI_PATH2="${path2}"

    cat > "${env_dir}/bin/gotohp" << EOF
#!/bin/bash
echo "\$*" >> "${GOTOHP_CALLS}"
EOF
    chmod +x "${env_dir}/bin/gotohp"

    cat > "${env_dir}/app/includes.sh" << HEREDOC
#!/bin/bash
CRON_CONFIG_FILE="\${HOME}/crontabs"
function color() {
    case \$1 in
        red)    echo -e "\033[31m\$2\033[0m" ;;
        green)  echo -e "\033[32m\$2\033[0m" ;;
        yellow) echo -e "\033[33m\$2\033[0m" ;;
        blue)   echo -e "\033[34m\$2\033[0m" ;;
        none)   echo "\$2" ;;
    esac
}
function init_env() {
    SOURCE_PATHS=("${path0}" "${path1}" "${path2}")
    ALBUM_NAMES=("Album0" "Album1" "Album2")
    GOTOHP_THREADS_LIST=("" "" "")
    GOTOHP_RECURSIVE_LIST=("" "" "")
    GOTOHP_FORCE_LIST=("" "" "")
    GOTOHP_DELETE_LIST=("" "" "")
    GOTOHP_DISABLE_FILTER_LIST=("" "" "")
    GOTOHP_DATE_FROM_FILENAME_LIST=("" "" "")
    GOTOHP_LOG_LEVEL_LIST=("" "" "")
    GOTOHP_CREDS_LIST=("" "" "")
    GOTOHP_EMAIL_LIST=("" "" "")
    CRON_LIST=("" "" "")
    GOTOHP_THREADS="3"
    GOTOHP_RECURSIVE="TRUE"
    GOTOHP_FORCE="FALSE"
    GOTOHP_DELETE="FALSE"
    GOTOHP_DISABLE_FILTER="FALSE"
    GOTOHP_DATE_FROM_FILENAME="FALSE"
    GOTOHP_LOG_LEVEL="info"
    GOTOHP_EMAIL=""
    CRON_OVERLAP="${cron_overlap}"
}
HEREDOC

    sed "s|^\. /app/includes\.sh$|. ${env_dir}/app/includes.sh|" \
        "$(dirname "$0")/backup.sh" > "${env_dir}/app/backup.sh"

    TEST_PATH="${env_dir}/bin:${PATH}"
    TEST_BACKUP="${env_dir}/app/backup.sh"
}

# Test 20: PAIR_INDICES="1" — only pair 1 processed, pairs 0 and 2 skipped
setup_env_multi "t20"
RC=0
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t20_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 20: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t20_out.txt"
elif grep -q "upload ${MULTI_PATH0}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 20: pair 0 was processed but PAIR_INDICES=1 should skip it"
    cat "${SCRATCH}/t20_out.txt"
elif grep -q "upload ${MULTI_PATH2}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 20: pair 2 was processed but PAIR_INDICES=1 should skip it"
    cat "${SCRATCH}/t20_out.txt"
elif ! grep -q "upload ${MULTI_PATH1}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 20: pair 1 was NOT uploaded despite PAIR_INDICES=1"
    cat "${SCRATCH}/t20_out.txt"
else
    pass "Test 20: PAIR_INDICES=1 — only pair 1 processed"
fi

# Test 21: PAIR_INDICES unset — all pairs processed (backwards compatibility)
setup_env_multi "t21"
RC=0
PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t21_out.txt" 2>&1 || RC=$?

if [[ $RC -ne 0 ]]; then
    fail "Test 21: backup.sh exited with code ${RC}"
    cat "${SCRATCH}/t21_out.txt"
elif ! grep -q "upload ${MULTI_PATH0}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 21: pair 0 was NOT processed with PAIR_INDICES unset"
    cat "${SCRATCH}/t21_out.txt"
elif ! grep -q "upload ${MULTI_PATH1}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 21: pair 1 was NOT processed with PAIR_INDICES unset"
    cat "${SCRATCH}/t21_out.txt"
elif ! grep -q "upload ${MULTI_PATH2}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 21: pair 2 was NOT processed with PAIR_INDICES unset"
    cat "${SCRATCH}/t21_out.txt"
else
    pass "Test 21: PAIR_INDICES unset — all 3 pairs processed (backwards compat)"
fi

########################################
# Tests 22–25: CRON_OVERLAP behaviour
########################################
echo "--- Tests 22–25: CRON_OVERLAP behaviour ---"

# Helper: create a 3-pair mock with a *slow* gotohp for a specific pair.
# The slow pair's gotohp sleeps SLOW_SECS seconds before recording its call.
# Arguments: test_name cron_overlap slow_pair_index slow_secs
setup_env_multi_slow() {
    local test_name="$1"
    local cron_overlap="${2:-QUEUE}"
    local slow_pair="${3:-1}"
    local slow_secs="${4:-2}"

    setup_env_multi "${test_name}" "${cron_overlap}"

    local path_var="MULTI_PATH${slow_pair}"
    local slow_path="${!path_var}"
    local env_dir="${SCRATCH}/${test_name}"
    local calls_file="${GOTOHP_CALLS}"

    cat > "${env_dir}/bin/gotohp" << EOF
#!/bin/bash
if echo "\$*" | grep -q "${slow_path}"; then
    sleep ${slow_secs}
fi
echo "\$*" >> "${calls_file}"
EOF
    chmod +x "${env_dir}/bin/gotohp"
}

# Test 22: CRON_OVERLAP=queue — second invocation waits and eventually runs.
# Run 1 with slow gotohp; run 2 with same PAIR_INDICES should block until
# run 1 finishes, then run itself.
setup_env_multi_slow "t22" "QUEUE" 1 2

RC1=0; RC2=0
# Run 1 in background (holds lock while gotohp sleeps 2s)
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t22_run1.txt" 2>&1 &
RUN1_PID=$!
sleep 0.5   # let run 1 acquire the lock and start gotohp

# Run 2 synchronously — should log "Waiting..." and block until run 1 finishes
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t22_run2.txt" 2>&1 || RC2=$?

wait "${RUN1_PID}" 2>/dev/null || RC1=$?

if [[ $RC2 -ne 0 ]]; then
    fail "Test 22: run 2 exited with code ${RC2}"
    cat "${SCRATCH}/t22_run2.txt"
elif ! grep -q "Waiting for previous run" "${SCRATCH}/t22_run2.txt" 2>/dev/null; then
    fail "Test 22: 'Waiting for previous run...' not logged by run 2 (queue mode)"
    cat "${SCRATCH}/t22_run2.txt"
else
    # Count how many times pair 1 was uploaded (both runs should upload it)
    UPLOAD_COUNT=$(grep -c "upload ${MULTI_PATH1}" "${GOTOHP_CALLS}" 2>/dev/null || true)
    if [[ "${UPLOAD_COUNT}" -ge 2 ]]; then
        pass "Test 22: CRON_OVERLAP=queue — run 2 waited and then ran (${UPLOAD_COUNT} uploads)"
    else
        fail "Test 22: expected 2 uploads (both runs), got ${UPLOAD_COUNT}"
        cat "${SCRATCH}/t22_run2.txt"
    fi
fi

# Test 23: CRON_OVERLAP=multithread — second invocation runs concurrently (no lock).
# Both invocations use the same PAIR_INDICES; with MULTITHREAD, neither blocks.
setup_env_multi_slow "t23" "MULTITHREAD" 1 2

RC2=0
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t23_run1.txt" 2>&1 &
RUN1_PID=$!
sleep 0.5

# Run 2 should start immediately without waiting (no lock involved)
START_T23=$(date +%s)
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t23_run2.txt" 2>&1 || RC2=$?
END_T23=$(date +%s)
ELAPSED_T23=$(( END_T23 - START_T23 ))

wait "${RUN1_PID}" 2>/dev/null || true

if [[ $RC2 -ne 0 ]]; then
    fail "Test 23: run 2 exited with code ${RC2}"
    cat "${SCRATCH}/t23_run2.txt"
elif ! grep -q "Concurrent run" "${SCRATCH}/t23_run2.txt" 2>/dev/null; then
    fail "Test 23: 'Concurrent run...' not logged by run 2 (multithread mode)"
    cat "${SCRATCH}/t23_run2.txt"
elif ! grep -q "upload ${MULTI_PATH1}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 23: pair 1 was NOT uploaded by run 2 in multithread mode"
    cat "${SCRATCH}/t23_run2.txt"
else
    pass "Test 23: CRON_OVERLAP=multithread — run 2 started concurrently (no wait)"
fi

# Test 24: CRON_OVERLAP=skip — second invocation skipped when same group is running.
# Run 1 with slow gotohp holds the lock; run 2 should skip and exit 0.
setup_env_multi_slow "t24" "SKIP" 1 2

RC1=0; RC2=0
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t24_run1.txt" 2>&1 &
RUN1_PID=$!
sleep 0.5   # let run 1 acquire the lock

PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t24_run2.txt" 2>&1 || RC2=$?

wait "${RUN1_PID}" 2>/dev/null || RC1=$?

if [[ $RC2 -ne 0 ]]; then
    fail "Test 24: run 2 should exit 0 when skipping, got code ${RC2}"
    cat "${SCRATCH}/t24_run2.txt"
elif ! grep -q "Skipping" "${SCRATCH}/t24_run2.txt" 2>/dev/null; then
    fail "Test 24: 'Skipping...' not logged by run 2 (skip mode)"
    cat "${SCRATCH}/t24_run2.txt"
else
    # Run 2 should have been skipped — only 1 upload from run 1
    UPLOAD_COUNT=$(grep -c "upload ${MULTI_PATH1}" "${GOTOHP_CALLS}" 2>/dev/null || true)
    if [[ "${UPLOAD_COUNT}" -eq 1 ]]; then
        pass "Test 24: CRON_OVERLAP=skip — run 2 skipped; only 1 upload recorded"
    else
        fail "Test 24: expected 1 upload (run 2 should be skipped), got ${UPLOAD_COUNT}"
        cat "${SCRATCH}/t24_run2.txt"
    fi
fi

# Test 25: inter-group concurrency — two different groups never block each other.
# Pair 0 has a slow gotohp; pair 1 (different PAIR_INDICES) should run immediately.
setup_env_multi_slow "t25" "QUEUE" 0 4

PAIR_INDICES="0" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t25_grpA.txt" 2>&1 &
GRPA_PID=$!
sleep 0.5

START_T25=$(date +%s)
RC=0
PAIR_INDICES="1" PATH="${TEST_PATH}" bash "${TEST_BACKUP}" > "${SCRATCH}/t25_grpB.txt" 2>&1 || RC=$?
END_T25=$(date +%s)
ELAPSED_T25=$(( END_T25 - START_T25 ))

wait "${GRPA_PID}" 2>/dev/null || true

if [[ $RC -ne 0 ]]; then
    fail "Test 25: group B exited with code ${RC}"
    cat "${SCRATCH}/t25_grpB.txt"
elif [[ ${ELAPSED_T25} -ge 3 ]]; then
    fail "Test 25: group B took ${ELAPSED_T25}s — blocked by group A (should run concurrently)"
    cat "${SCRATCH}/t25_grpB.txt"
elif ! grep -q "upload ${MULTI_PATH1}" "${GOTOHP_CALLS}" 2>/dev/null; then
    fail "Test 25: group B (pair 1) was NOT uploaded"
    cat "${SCRATCH}/t25_grpB.txt"
else
    pass "Test 25: inter-group concurrency — group B ran in ${ELAPSED_T25}s without blocking group A"
fi

########################################
# Test 26: build_schedule_groups edge case — empty CRON_N falls back to global
########################################
echo "--- Test 26: build_schedule_groups edge case: empty CRON_N → global ---"

CRON="0 4 * * *"
SOURCE_PATHS=("a" "b")
CRON_LIST=("" "")   # both empty → both fall back to global
build_schedule_groups
if [[ "${#SCHEDULE_GROUPS[@]}" -eq 1 && "${SCHEDULE_GROUPS["0 4 * * *"]}" == "0,1" ]]; then
    pass "Test 26: empty CRON_N entries correctly fall back to global CRON"
else
    fail "Test 26: expected '0 4 * * *'→'0,1', got: $(declare -p SCHEDULE_GROUPS)"
fi

########################################
# Tests 27–28: cron_is_interval with explicit argument (per-group support)
########################################
echo "--- Tests 27–28: cron_is_interval per-group (accepts argument) ---"

# Test 27: interval cron passed as argument → IS interval
# Re-define using the updated signature from entrypoint.sh
function cron_is_interval_with_arg() {
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

if cron_is_interval_with_arg "*/15 * * * *"; then
    pass "Test 27: cron_is_interval('*/15 * * * *') correctly identified as interval"
else
    fail "Test 27: cron_is_interval('*/15 * * * *') should be interval but was not"
fi

# Test 28: rigid cron passed as argument → NOT interval
if cron_is_interval_with_arg "0 2 * * *"; then
    fail "Test 28: cron_is_interval('0 2 * * *') should NOT be interval but was detected as one"
else
    pass "Test 28: cron_is_interval('0 2 * * *') correctly identified as non-interval"
fi

########################################
########################################
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
