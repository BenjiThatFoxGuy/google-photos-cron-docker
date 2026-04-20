#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="/.env"
MAX_BODY_BYTES=65535

function http_ok_text() {
    echo "Status: 200 OK"
    echo "Content-Type: text/plain"
    echo "Cache-Control: no-store"
    echo
}

function http_bad_request() {
    echo "Status: 400 Bad Request"
    echo "Content-Type: text/plain"
    echo
    echo "$1"
}

case "${REQUEST_METHOD:-GET}" in
    GET)
        http_ok_text
        if [[ -f "${CONFIG_FILE}" ]]; then
            cat "${CONFIG_FILE}"
        fi
        ;;
    POST)
        content_length="${CONTENT_LENGTH:-0}"
        if [[ ! "${content_length}" =~ ^[0-9]+$ ]]; then
            http_bad_request "Invalid CONTENT_LENGTH"
            exit 0
        fi
        if (( content_length > MAX_BODY_BYTES )); then
            http_bad_request "Body too large (max ${MAX_BODY_BYTES} bytes)"
            exit 0
        fi

        body="$(head -c "${content_length}" || true)"
        body_len="$(printf '%s' "${body}" | wc -c | tr -d ' ')"
        if [[ "${body_len}" != "${content_length}" ]]; then
            http_bad_request "Request body length mismatch (expected ${content_length}, got ${body_len})"
            exit 0
        fi
        body="${body//$'\r'/}"

        while IFS= read -r line || [[ -n "${line}" ]]; do
            # Trim leading/trailing whitespace
            trimmed="${line#"${line%%[![:space:]]*}"}"
            trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
            [[ -z "${trimmed}" || "${trimmed:0:1}" == "#" ]] && continue
            if [[ ! "${trimmed}" =~ ^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=[[:space:]]*.*$ ]]; then
                http_bad_request "Invalid line format: ${line}"
                exit 0
            fi
        done <<< "${body}"

        # Only persist overrides to file if the config file already exists
        # (i.e., config originally came from a file, not just environment variables)
        if [[ -f "${CONFIG_FILE}" ]]; then
            umask 077
            tmp_file="${CONFIG_FILE}.tmp.$$"
            printf '%s' "${body}" > "${tmp_file}"
            mv "${tmp_file}" "${CONFIG_FILE}"
            http_ok_text
            echo "Overrides saved to ${CONFIG_FILE}"
        else
            http_ok_text
            echo "Overrides applied for this session only (no config file to persist to)"
        fi
        ;;
    *)
        http_bad_request "Unsupported method: ${REQUEST_METHOD:-UNKNOWN}"
        ;;
esac
