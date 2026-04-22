#!/bin/bash
# Focused tests for includes.sh environment resolution.
# Run: bash scripts/test_includes.sh

set -euo pipefail

PASS=0
FAIL=0

pass() { echo -e "\033[32mPASS\033[0m $1"; PASS=$((PASS+1)); }
fail() { echo -e "\033[31mFAIL\033[0m $1"; FAIL=$((FAIL+1)); }

SCRATCH=$(mktemp -d)
trap 'rm -rf "${SCRATCH}"' EXIT

# shellcheck source=/dev/null
. "$(dirname "$0")/includes.sh"

reset_vars() {
    unset GOTOHP_THREADS GOTOHP_THREADS_FILE DOTENV_GOTOHP_THREADS DOTENV_GOTOHP_THREADS_FILE \
          WEBUI_OVERRIDE_GOTOHP_THREADS WEBUI_OVERRIDE_GOTOHP_THREADS_FILE WEBUI_OVERRIDE_FILE || true
}

echo "--- Test 1: WEBUI override takes precedence over environment value ---"
reset_vars
override_file="${SCRATCH}/overrides.env"
cat > "${override_file}" << EOF
GOTOHP_THREADS=9
EOF
export WEBUI_OVERRIDE_FILE="${override_file}"
export GOTOHP_THREADS="3"
export_env_file
get_env GOTOHP_THREADS
if [[ "${GOTOHP_THREADS}" == "9" ]]; then
    pass "Test 1: override file value won over environment variable"
else
    fail "Test 1: expected GOTOHP_THREADS=9, got ${GOTOHP_THREADS}"
fi

echo "--- Test 2: WEBUI override *_FILE resolves and trims trailing newline ---"
reset_vars
override_file="${SCRATCH}/overrides_file.env"
secret_file="${SCRATCH}/threads_secret.txt"
printf '11\n' > "${secret_file}"
cat > "${override_file}" << EOF
GOTOHP_THREADS_FILE=${secret_file}
EOF
export WEBUI_OVERRIDE_FILE="${override_file}"
export_env_file
get_env GOTOHP_THREADS
if [[ "${GOTOHP_THREADS}" == "11" ]]; then
    pass "Test 2: *_FILE override resolved correctly"
else
    fail "Test 2: expected GOTOHP_THREADS=11, got ${GOTOHP_THREADS}"
fi

echo "--- Test 3: invalid override lines are ignored ---"
reset_vars
override_file="${SCRATCH}/invalid_overrides.env"
cat > "${override_file}" << EOF
not a valid line
GOTOHP_THREADS=7
EOF
export WEBUI_OVERRIDE_FILE="${override_file}"
export_env_file
get_env GOTOHP_THREADS
if [[ "${GOTOHP_THREADS}" == "7" ]]; then
    pass "Test 3: invalid line ignored, valid line accepted"
else
    fail "Test 3: expected GOTOHP_THREADS=7, got ${GOTOHP_THREADS}"
fi

echo "--- Test 4: *_FILE handles CRLF and multiple trailing newlines ---"
reset_vars
override_file="${SCRATCH}/overrides_crlf.env"
secret_file="${SCRATCH}/threads_crlf.txt"
printf '13\r\n\r\n' > "${secret_file}"
cat > "${override_file}" << EOF
GOTOHP_THREADS_FILE=${secret_file}
EOF
export WEBUI_OVERRIDE_FILE="${override_file}"
export_env_file
get_env GOTOHP_THREADS
if [[ "${GOTOHP_THREADS}" == "13" ]]; then
    pass "Test 4: CRLF and extra trailing newlines trimmed correctly"
else
    fail "Test 4: expected GOTOHP_THREADS=13, got ${GOTOHP_THREADS}"
fi

echo
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -ne 0 ]]; then
    exit 1
fi
