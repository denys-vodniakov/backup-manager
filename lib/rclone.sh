#!/usr/bin/env bash
# shellcheck shell=bash
# rclone remote upload, download, and retention helpers.

rclone_cmd() {
	"${RCLONE_BIN}" "$@"
}

remote_backup_path() {
	local backup_name="$1"
	printf '%s:%s/%s' "${RCLONE_REMOTE}" "${RCLONE_REMOTE_PATH%/}" "${backup_name}"
}

upload_backup_dir() {
	local backup_dir="$1"
	local backup_name

	assert_path_under_parent "${backup_dir}" "${BACKUP_DIR}" "backup directory" || return 1

	backup_name="$(basename "${backup_dir}")"
	validate_backup_name "${backup_name}" || return 1
	local remote_path
	remote_path="$(remote_backup_path "${backup_name}")"

	log_info "Uploading backup to remote: ${remote_path}"

	if ! rclone_cmd copy "${backup_dir}/" "${remote_path}/" --create-empty-src-dirs; then
		log_error "rclone upload failed for: ${backup_dir}"
		return 1
	fi

	log_success "Remote upload completed: ${remote_path}"
	return 0
}

download_backup_dir() {
	local backup_name="$1"
	local local_dir="$2"

	validate_backup_name "${backup_name}" || return 1
	assert_path_under_parent "${local_dir}" "${TMP_DIR}" "download directory" || return 1

	local remote_path
	remote_path="$(remote_backup_path "${backup_name}")"

	log_info "Downloading backup from remote: ${remote_path}"

	mkdir -p "${local_dir}"

	if ! rclone_cmd copy "${remote_path}/" "${local_dir}/" --create-empty-src-dirs; then
		log_error "rclone download failed for: ${remote_path}"
		return 1
	fi

	if [[ -z "$(ls -A "${local_dir}" 2>/dev/null)" ]]; then
		log_error "Downloaded backup directory is empty: ${local_dir}"
		return 1
	fi

	log_success "Remote download completed: ${local_dir}"
	return 0
}

remote_backup_exists() {
	local backup_name="$1"
	local remote_path
	remote_path="$(remote_backup_path "${backup_name}")"

	if rclone_cmd lsf "${remote_path}/" >/dev/null 2>&1; then
		return 0
	fi
	return 1
}

apply_remote_retention() {
	local retention_days="${RETENTION_REMOTE_DAYS:-0}"

	if [[ "${ENABLE_REMOTE_UPLOAD:-false}" != "true" ]]; then
		return 0
	fi

	if [[ "${retention_days}" -eq 0 ]]; then
		log_info "Remote retention disabled (RETENTION_REMOTE_DAYS=0)"
		return 0
	fi

	local remote_listing remote_root deleted=0
	remote_root="${RCLONE_REMOTE}:${RCLONE_REMOTE_PATH%/}/"

	log_info "Applying remote retention: ${retention_days} day(s) on ${remote_root}"

	if ! remote_listing="$(rclone_cmd lsf "${remote_root}" --dirs-only 2>/dev/null)"; then
		log_warn "Could not list remote backup directories"
		return 0
	fi

	while IFS= read -r backup_name; do
		[[ -z "${backup_name}" ]] && continue
		backup_name="${backup_name%/}"

		validate_backup_name "${backup_name}" || {
			log_warn "Skipping remote entry with unexpected name: ${backup_name}"
			continue
		}

		local backup_date cutoff_date
		backup_date="${backup_name%%_*}"
		cutoff_date="$(date -d "-${retention_days} days" '+%Y-%m-%d' 2>/dev/null || date -v-"${retention_days}"d '+%Y-%m-%d')"

		if [[ "${backup_date}" < "${cutoff_date}" ]]; then
			local remote_path
			remote_path="$(remote_backup_path "${backup_name}")"
			log_info "Removing remote backup: ${remote_path}"
			if rclone_cmd purge "${remote_path}/"; then
				((deleted++)) || true
			else
				log_warn "Failed to remove remote backup: ${remote_path}"
			fi
		fi
	done <<< "${remote_listing}"

	log_info "Remote retention complete: removed ${deleted} backup(s)"
	return 0
}
