#!/usr/bin/env bash
# backup.sh — Create timestamped backups with optional MySQL dump and rclone upload.
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
# shellcheck source=lib/retention.sh
source "${SCRIPT_DIR}/lib/retention.sh"

BACKUP_RUN_DIR=""

on_error() {
	log_error "Backup failed at line ${1}"
}

cleanup_on_exit() {
	local status=$?
	if [[ "${status}" -ne 0 ]]; then
		send_notification "FAILURE" "Backup failed — see logs in ${LOG_DIR:-./logs}"
		if [[ -n "${BACKUP_RUN_DIR}" && -d "${BACKUP_RUN_DIR}" && -n "${BACKUP_DIR:-}" ]]; then
			log_warn "Removing incomplete backup directory: ${BACKUP_RUN_DIR}"
			safe_remove_directory "${BACKUP_RUN_DIR}" "${BACKUP_DIR}" true || true
		fi
	fi
	return "${status}"
}

trap 'on_error "${LINENO}"; exit 1' ERR
trap cleanup_on_exit EXIT

main() {
	cd "${SCRIPT_DIR}"

	local env_file
	env_file="$(resolve_env_file "${SCRIPT_DIR}")"
	load_env "${env_file}"

	init_logger
	log_info "=== Backup started: ${PROJECT_NAME:-unknown} (env: $(basename "${env_file}")) ==="

	validate_backup_env
	validate_backup_tools

	local timestamp backup_run_dir
	timestamp="$(date '+%Y-%m-%d_%H%M%S')"
	backup_run_dir="${BACKUP_DIR%/}/${timestamp}"
	BACKUP_RUN_DIR="${backup_run_dir}"

	mkdir -p "${backup_run_dir}"
	log_info "Backup directory: ${backup_run_dir}"

	# Write manifest
	{
		printf 'project=%s\n' "${PROJECT_NAME}"
		printf 'timestamp=%s\n' "${timestamp}"
		printf 'source_path=%s\n' "${SOURCE_PATH}"
		printf 'mysql_backup=%s\n' "${ENABLE_MYSQL_BACKUP}"
		printf 'file_backup=%s\n' "${ENABLE_FILE_BACKUP:-true}"
		printf 'remote_upload=%s\n' "${ENABLE_REMOTE_UPLOAD}"
	} > "${backup_run_dir}/manifest.txt"

	if [[ "${ENABLE_MYSQL_BACKUP}" == "true" ]]; then
		mysql_dump "${backup_run_dir}/database.sql.gz"
	fi

	if [[ "${ENABLE_FILE_BACKUP:-true}" == "true" ]]; then
		create_archive "${SOURCE_PATH}" "${backup_run_dir}/site.tar.gz"
	fi
	generate_checksums "${backup_run_dir}"

	if [[ "${ENABLE_REMOTE_UPLOAD}" == "true" ]]; then
		upload_backup_dir "${backup_run_dir}"
		apply_remote_retention
	fi

	apply_local_retention

	log_duration
	log_success "=== Backup completed successfully ==="
	send_notification "SUCCESS" "Backup ${timestamp} completed"
	BACKUP_RUN_DIR=""
}

main "$@"
