#!/usr/bin/env bash
# shellcheck shell=bash
# Human-readable logging with per-run log files.

: "${LOG_DIR:=./logs}"

LOG_FILE=""
LOG_START_TIME=""

init_logger() {
	local timestamp
	timestamp="$(date '+%Y-%m-%d_%H%M%S')"
	mkdir -p "${LOG_DIR}"
	LOG_FILE="${LOG_DIR}/backup-${timestamp}.log"
	LOG_START_TIME="$(date +%s)"
	_log_write "INFO" "Log started: ${LOG_FILE}"
}

_log_write() {
	local level="$1"
	local message="$2"
	local line
	line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}"
	if [[ -n "${LOG_FILE}" ]]; then
		printf '%s\n' "${line}" >> "${LOG_FILE}"
	fi
	printf '%s\n' "${line}" >&2
}

log_info()    { _log_write "INFO"  "$*"; }
log_warn()    { _log_write "WARN"  "$*"; }
log_error()   { _log_write "ERROR" "$*"; }
log_success() { _log_write "OK"    "$*"; }

format_bytes() {
	local bytes="${1:-0}"
	if command -v numfmt >/dev/null 2>&1; then
		numfmt --to=iec-i --suffix=B "${bytes}" 2>/dev/null || printf '%s B' "${bytes}"
	else
		printf '%s B' "${bytes}"
	fi
}

file_size_bytes() {
	local path="$1"
	if [[ -f "${path}" ]]; then
		stat -c '%s' "${path}" 2>/dev/null || stat -f '%z' "${path}" 2>/dev/null || echo 0
	else
		echo 0
	fi
}

log_file_size() {
	local label="$1"
	local path="$2"
	local size
	size="$(file_size_bytes "${path}")"
	log_info "${label}: $(format_bytes "${size}") (${path})"
}

log_duration() {
	local end_time elapsed
	end_time="$(date +%s)"
	elapsed=$(( end_time - LOG_START_TIME ))
	log_info "Duration: ${elapsed}s"
}
