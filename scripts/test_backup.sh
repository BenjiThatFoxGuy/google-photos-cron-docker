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
########################################
setup_env() {
    local test_name="$1"
    local first_source="$2"
    local second_source="$3"
    local gotohp_recursive="${4:-TRUE}"
    local pair0_email="${5:-}"
    local pair1_email="${6:-}"
    local global_email="${7:-}"

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
    GOTOHP_THREADS="3"
    GOTOHP_RECURSIVE="${gotohp_recursive}"
    GOTOHP_FORCE="FALSE"
    GOTOHP_DELETE="FALSE"
    GOTOHP_DISABLE_FILTER="FALSE"
    GOTOHP_DATE_FROM_FILENAME="FALSE"
    GOTOHP_LOG_LEVEL="info"
    GOTOHP_EMAIL="${global_email}"
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
# Tests 10–14: cron_is_interval — validate the interval-detection logic
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
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
