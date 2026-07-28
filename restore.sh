#!/usr/bin/env bash
# restore.sh — Restore files and optional MySQL dump from a local or remote backup.
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logger.sh
source "${SCRIPT_DIR}/lib/logger.sh"
# shellcheck source=lib/env.sh
source "${SCRIPT_DIR}/lib/env.sh"
# shellcheck source=lib/mysql.sh
source "${SCRIPT_DIR}/lib/mysql.sh"
# shellcheck source=lib/archive.sh
source "${SCRIPT_DIR}/lib/archive.sh"
# shellcheck source=lib/rclone.sh
source "${SCRIPT_DIR}/lib/rclone.sh"
# shellcheck source=lib/checksum.sh
source "${SCRIPT_DIR}/lib/checksum.sh"

FORCE="${FORCE:-false}"

on_error() {
	log_error "Restore failed at line ${1}"
}

trap 'on_error "${LINENO}"; exit 1' ERR

usage() {
	cat <<'EOF'
Usage: restore.sh <backup-name|backup-path> [options]

Arguments:
  backup-name     Timestamp directory name (e.g. 2025-07-06_120000)
  backup-path     Full path to a local backup directory

Environment:
  FORCE=true      Skip confirmation prompts for destructive actions

Examples:
  ./restore.sh 2025-07-06_120000
  ./restore.sh /path/to/backups/2025-07-06_120000
  FORCE=true ./restore.sh 2025-07-06_120000
EOF
}

confirm_action() {
	local prompt="$1"
	if [[ "${FORCE}" == "true" ]]; then
		log_warn "FORCE=true — skipping confirmation: ${prompt}"
		return 0
	fi

	printf '%s [y/N]: ' "${prompt}" >&2
	local answer
	read -r answer
	case "${answer}" in
		[yY]|[yY][eE][sS]) return 0 ;;
		*) log_error "Restore cancelled by user"; return 1 ;;
	esac
}

resolve_backup_dir() {
	local input="$1"
	local resolved=""

	if [[ "${input}" == /* ]]; then
		if [[ ! -d "${input}" ]]; then
			log_error "Backup path does not exist: ${input}"
			return 1
		fi
		resolved="$(resolve_path "${input}")" || return 1
		assert_path_under_parent "${resolved}" "${BACKUP_DIR}" "backup path" || return 1
	elif [[ -d "${BACKUP_DIR%/}/${input}" ]]; then
		validate_backup_name "${input}" || return 1
		resolved="$(resolve_path "${BACKUP_DIR%/}/${input}")" || return 1
	elif [[ "${ENABLE_REMOTE_UPLOAD:-false}" == "true" ]]; then
		validate_backup_name "${input}" || return 1
		local download_dir="${TMP_DIR%/}/restore-${input}"
		assert_path_under_parent "${download_dir}" "${TMP_DIR}" "download directory" || return 1
		if [[ -d "${download_dir}" ]]; then
			safe_remove_directory "${download_dir}" "${TMP_DIR}" false || true
		fi
		download_backup_dir "${input}" "${download_dir}"
		resolved="$(resolve_path "${download_dir}")" || return 1
	else
		log_error "Backup not found locally: ${input}"
		log_info "Set ENABLE_REMOTE_UPLOAD=true to download from remote"
		return 1
	fi

	assert_path_under_parent "${resolved}" "${BACKUP_DIR}" "backup path" \
		|| assert_path_under_parent "${resolved}" "${TMP_DIR}" "backup path" || return 1

	printf '%s' "${resolved}"
}

main() {
	if [[ $# -lt 1 ]]; then
		usage
		return 1
	fi

	local backup_input="$1"

	cd "${SCRIPT_DIR}"

	local env_file
	env_file="$(resolve_env_file "${SCRIPT_DIR}")"
	load_env "${env_file}"

	init_logger
	log_info "=== Restore started (env: $(basename "${env_file}")) ==="

	validate_restore_env

	if [[ "${FORCE}" != "true" && "${FORCE}" != "false" ]]; then
		log_error "FORCE must be 'true' or 'false'"
		return 1
	fi

	local backup_dir
	backup_dir="$(resolve_backup_dir "${backup_input}")"
	log_info "Using backup directory: ${backup_dir}"

	verify_checksums "${backup_dir}"

	local site_archive=""
	if site_archive="$(find_site_archive "${backup_dir}" 2>/dev/null)"; then
		confirm_action "This will overwrite files in ${RESTORE_TARGET_PATH}. Continue?"
		confirm_action "Extract ${site_archive} into ${RESTORE_TARGET_PATH}?"
		extract_archive "${site_archive}" "${RESTORE_TARGET_PATH}"
	else
		log_warn "No site archive in backup; skipping file restore"
	fi

	if [[ "${ENABLE_MYSQL_BACKUP}" == "true" && -f "${backup_dir}/database.sql.gz" ]]; then
		confirm_action "This will overwrite database ${DB_NAME} on ${DB_HOST}. Continue?"
		mysql_restore "${backup_dir}/database.sql.gz"
	elif [[ "${ENABLE_MYSQL_BACKUP}" == "true" ]]; then
		log_warn "MySQL restore enabled but no database.sql.gz found in backup"
	fi

	log_duration
	log_success "=== Restore completed successfully ==="
	send_notification "SUCCESS" "Restore from ${backup_input} completed"
}

main "$@"
