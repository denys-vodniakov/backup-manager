#!/usr/bin/env bash
# shellcheck shell=bash
# Environment loading and validation.
# Requires logger.sh to be sourced before this file.

_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/safety.sh
source "${_LIB_DIR}/safety.sh"

# Resolve ENV_FILE / default .env; must stay under the project directory.
resolve_env_file() {
	local script_dir="$1"
	local requested="${ENV_FILE:-.env}"
	local base resolved

	base="$(basename "${requested}")"
	case "${base}" in
		.env|.env.daily|.env.weekly|.env.example|.env.daily.example|.env.weekly.example) ;;
		*)
			printf 'ERROR: ENV_FILE basename not allowed: %s\n' "${base}" >&2
			printf 'Allowed: .env, .env.daily, .env.weekly (or their *.example templates).\n' >&2
			return 1
			;;
	esac

	if [[ "${requested}" == /* ]]; then
		resolved="${requested}"
	else
		resolved="${script_dir}/${base}"
	fi

	# Absolute path must still resolve under script_dir (no path escape)
	case "${resolved}" in
		"${script_dir}"|"${script_dir}"/*) ;;
		*)
			printf 'ERROR: ENV_FILE must be inside project directory: %s\n' "${resolved}" >&2
			return 1
			;;
	esac

	printf '%s' "${resolved}"
}

load_env() {
	local env_file="${1:-.env}"
	if [[ ! -f "${env_file}" ]]; then
		printf 'ERROR: Environment file not found: %s\n' "${env_file}" >&2
		printf 'Copy .env.daily.example to .env.daily (or .env.weekly.example / .env.example).\n' >&2
		return 1
	fi

	validate_env_file_permissions "${env_file}"

	# Preserve CLI/cron overrides that were set before sourcing .env
	local _had_file_backup=0 _had_mysql_backup=0 _had_progress=0
	local _file_backup="" _mysql_backup="" _progress=""
	if [[ -n "${ENABLE_FILE_BACKUP+x}" ]]; then
		_had_file_backup=1
		_file_backup="${ENABLE_FILE_BACKUP}"
	fi
	if [[ -n "${ENABLE_MYSQL_BACKUP+x}" ]]; then
		_had_mysql_backup=1
		_mysql_backup="${ENABLE_MYSQL_BACKUP}"
	fi
	if [[ -n "${BACKUP_PROGRESS_SECONDS+x}" ]]; then
		_had_progress=1
		_progress="${BACKUP_PROGRESS_SECONDS}"
	fi

	# shellcheck disable=SC1090
	set -a
	# shellcheck source=/dev/null
	source "${env_file}"
	set +a

	if [[ "${_had_file_backup}" -eq 1 ]]; then
		ENABLE_FILE_BACKUP="${_file_backup}"
	fi
	if [[ "${_had_mysql_backup}" -eq 1 ]]; then
		ENABLE_MYSQL_BACKUP="${_mysql_backup}"
	fi
	if [[ "${_had_progress}" -eq 1 ]]; then
		BACKUP_PROGRESS_SECONDS="${_progress}"
	fi
}

path_is_under() {
	local child="$1"
	local parent="$2"
	local resolved_child resolved_parent

	resolved_child="$(resolve_path "${child}" 2>/dev/null || true)"
	resolved_parent="$(resolve_path "${parent}" 2>/dev/null || true)"

	[[ -n "${resolved_child}" && -n "${resolved_parent}" ]] || return 1

	case "${resolved_child}" in
		"${resolved_parent}"|"${resolved_parent}"/*) return 0 ;;
		*) return 1 ;;
	esac
}

require_command() {
	local cmd="$1"
	if ! command -v "${cmd}" >/dev/null 2>&1; then
		log_error "Required command not found: ${cmd}"
		return 1
	fi
}

validate_bool() {
	local name="$1"
	local value="${!name:-}"
	case "${value}" in
		true|false) return 0 ;;
		*)
			log_error "${name} must be 'true' or 'false' (got: '${value}')"
			return 1
			;;
	esac
}

validate_positive_int() {
	local name="$1"
	local value="${!name:-}"
	if ! [[ "${value}" =~ ^[0-9]+$ ]] || [[ "${value}" -lt 0 ]]; then
		log_error "${name} must be a non-negative integer (got: '${value}')"
		return 1
	fi
}

validate_shared_env() {
	local errors=0

	: "${PROJECT_NAME:?PROJECT_NAME is required}"
	: "${BACKUP_DIR:?BACKUP_DIR is required}"
	: "${TMP_DIR:?TMP_DIR is required}"
	: "${LOG_DIR:?LOG_DIR is required}"

	is_safe_path "${BACKUP_DIR}" "BACKUP_DIR" || ((errors++)) || true
	is_safe_path "${TMP_DIR}" "TMP_DIR" || ((errors++)) || true
	is_safe_path "${LOG_DIR}" "LOG_DIR" || ((errors++)) || true

	validate_safe_identifier "${PROJECT_NAME}" "PROJECT_NAME" || ((errors++)) || true

	validate_bool ENABLE_MYSQL_BACKUP || ((errors++)) || true
	validate_bool ENABLE_REMOTE_UPLOAD || ((errors++)) || true
	validate_bool ENABLE_NOTIFICATIONS || ((errors++)) || true
	validate_positive_int RETENTION_LOCAL_DAYS || ((errors++)) || true

	if [[ "${ENABLE_MYSQL_BACKUP}" == "true" ]]; then
		: "${DB_HOST:?DB_HOST is required when ENABLE_MYSQL_BACKUP=true}"
		: "${DB_NAME:?DB_NAME is required when ENABLE_MYSQL_BACKUP=true}"
		: "${DB_USER:?DB_USER is required when ENABLE_MYSQL_BACKUP=true}"
		: "${DB_PASSWORD+set}" || { log_error "DB_PASSWORD is required when ENABLE_MYSQL_BACKUP=true"; ((errors++)) || true; }
		validate_db_identifiers || ((errors++)) || true
	fi

	if [[ "${ENABLE_REMOTE_UPLOAD}" == "true" ]]; then
		: "${RCLONE_BIN:?RCLONE_BIN is required when ENABLE_REMOTE_UPLOAD=true}"
		: "${RCLONE_REMOTE:?RCLONE_REMOTE is required when ENABLE_REMOTE_UPLOAD=true}"
		: "${RCLONE_REMOTE_PATH:?RCLONE_REMOTE_PATH is required when ENABLE_REMOTE_UPLOAD=true}"
		validate_rclone_config || ((errors++)) || true
		validate_positive_int RETENTION_REMOTE_DAYS || ((errors++)) || true
	fi

	if [[ "${ENABLE_NOTIFICATIONS}" == "true" ]]; then
		: "${WEBHOOK_URL:?WEBHOOK_URL is required when ENABLE_NOTIFICATIONS=true}"
	fi

	if [[ "${errors}" -gt 0 ]]; then
		log_error "Configuration validation failed with ${errors} error(s)"
		return 1
	fi

	return 0
}

validate_backup_env() {
	local errors=0

	validate_shared_env || ((errors++)) || true

	: "${SOURCE_PATH:?SOURCE_PATH is required}"
	ENABLE_FILE_BACKUP="${ENABLE_FILE_BACKUP:-true}"

	is_safe_path "${SOURCE_PATH}" "SOURCE_PATH" || ((errors++)) || true
	validate_bool ENABLE_FILE_BACKUP || ((errors++)) || true

	if [[ "${ENABLE_FILE_BACKUP}" == "true" && ! -d "${SOURCE_PATH}" ]]; then
		log_error "SOURCE_PATH does not exist or is not a directory: ${SOURCE_PATH}"
		((errors++)) || true
	fi

	if [[ "${ENABLE_FILE_BACKUP}" != "true" && "${ENABLE_MYSQL_BACKUP}" != "true" ]]; then
		log_error "At least one of ENABLE_FILE_BACKUP or ENABLE_MYSQL_BACKUP must be true"
		((errors++)) || true
	fi

	if [[ "${errors}" -gt 0 ]]; then
		return 1
	fi

	mkdir -p "${BACKUP_DIR}" "${TMP_DIR}" "${LOG_DIR}"

	# OVH shared hosting: $HOME may be a symlink (/home/user → /homez.N/user).
	# Canonicalize so later path checks compare the same physical paths.
	BACKUP_DIR="$(canonicalize_path "${BACKUP_DIR}")"
	TMP_DIR="$(canonicalize_path "${TMP_DIR}")"
	LOG_DIR="$(canonicalize_path "${LOG_DIR}")"
	if [[ -d "${SOURCE_PATH}" ]]; then
		SOURCE_PATH="$(canonicalize_path "${SOURCE_PATH}")"
	fi

	return 0
}

validate_backup_tools() {
	local errors=0

	ENABLE_FILE_BACKUP="${ENABLE_FILE_BACKUP:-true}"

	if [[ "${ENABLE_FILE_BACKUP}" == "true" ]]; then
		require_command tar || ((errors++)) || true
		require_command gzip || ((errors++)) || true
	fi

	require_command sha256sum || require_command shasum || ((errors++)) || true

	if [[ "${ENABLE_MYSQL_BACKUP}" == "true" ]]; then
		require_command mysqldump || ((errors++)) || true
	fi

	if [[ "${ENABLE_REMOTE_UPLOAD}" == "true" ]]; then
		if [[ ! -x "${RCLONE_BIN}" ]] && ! command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
			log_error "rclone not found: ${RCLONE_BIN}"
			((errors++)) || true
		fi
	fi

	if [[ "${errors}" -gt 0 ]]; then
		return 1
	fi
	return 0
}

validate_restore_env() {
	local errors=0

	validate_shared_env || ((errors++)) || true

	: "${RESTORE_TARGET_PATH:?RESTORE_TARGET_PATH is required for restore}"

	is_safe_path "${RESTORE_TARGET_PATH}" "RESTORE_TARGET_PATH" || ((errors++)) || true
	reject_home_root_path "${RESTORE_TARGET_PATH}" "RESTORE_TARGET_PATH" || ((errors++)) || true

	if [[ "${ENABLE_MYSQL_BACKUP}" == "true" ]]; then
		validate_db_identifiers || ((errors++)) || true
		: "${DB_HOST:?DB_HOST is required when ENABLE_MYSQL_BACKUP=true}"
		: "${DB_NAME:?DB_NAME is required when ENABLE_MYSQL_BACKUP=true}"
		: "${DB_USER:?DB_USER is required when ENABLE_MYSQL_BACKUP=true}"
	fi

	if [[ "${ENABLE_REMOTE_UPLOAD:-false}" == "true" ]]; then
		if [[ ! -x "${RCLONE_BIN}" ]] && ! command -v "${RCLONE_BIN}" >/dev/null 2>&1; then
			log_error "rclone not found: ${RCLONE_BIN}"
			((errors++)) || true
		fi
	fi

	if [[ "${ENABLE_MYSQL_BACKUP}" == "true" ]]; then
		require_command mysql || ((errors++)) || true
		require_command gunzip || ((errors++)) || true
	fi

	require_command tar || ((errors++)) || true

	if [[ "${errors}" -gt 0 ]]; then
		return 1
	fi

	mkdir -p "${TMP_DIR}" "${LOG_DIR}"
	TMP_DIR="$(canonicalize_path "${TMP_DIR}")"
	LOG_DIR="$(canonicalize_path "${LOG_DIR}")"
	BACKUP_DIR="$(canonicalize_path "${BACKUP_DIR}")"
	if [[ -d "${RESTORE_TARGET_PATH}" ]]; then
		RESTORE_TARGET_PATH="$(canonicalize_path "${RESTORE_TARGET_PATH}")"
	fi

	return 0
}

send_notification() {
	local status="$1"
	local message="$2"

	if [[ "${ENABLE_NOTIFICATIONS:-false}" != "true" ]]; then
		return 0
	fi

	if ! command -v curl >/dev/null 2>&1; then
		log_warn "curl not available; skipping notification"
		return 0
	fi

	local payload escaped_project escaped_status escaped_message
	escaped_project="$(json_escape_string "${PROJECT_NAME}")"
	escaped_status="$(json_escape_string "${status}")"
	escaped_message="$(json_escape_string "${message}")"
	payload="$(printf '{"text":"[%s] %s: %s"}' "${escaped_project}" "${escaped_status}" "${escaped_message}")"

	if [[ "${WEBHOOK_URL}" != https://* ]]; then
		log_warn "WEBHOOK_URL does not use HTTPS; skipping notification"
		return 0
	fi

	if ! curl -fsS -X POST -H 'Content-Type: application/json' --data-binary "${payload}" "${WEBHOOK_URL}" >/dev/null 2>&1; then
		log_warn "Failed to send notification webhook"
	fi
}
