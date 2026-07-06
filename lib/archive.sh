#!/usr/bin/env bash
# shellcheck shell=bash
# File archive helpers using tar and gzip.

create_archive() {
	local source_path="$1"
	local output_file="$2"
	local archive_name

	assert_path_under_parent "${output_file}" "${BACKUP_DIR}" "archive output" || return 1
	archive_name="$(basename "${source_path}")"

	log_info "Creating archive of: ${source_path}"

	if [[ ! -d "${source_path}" ]]; then
		log_error "Source path is not a directory: ${source_path}"
		return 1
	fi

	local parent_dir base_name
	parent_dir="$(cd "$(dirname "${source_path}")" && pwd)"
	base_name="$(basename "${source_path}")"

	if ! tar -czf "${output_file}" -C "${parent_dir}" "${base_name}"; then
		log_error "Failed to create archive: ${output_file}"
		return 1
	fi

	if [[ ! -s "${output_file}" ]]; then
		log_error "Archive file is empty: ${output_file}"
		return 1
	fi

	log_file_size "Archive (${archive_name})" "${output_file}"
	log_success "Archive created"
	return 0
}

extract_archive() {
	local archive_file="$1"
	local target_path="$2"

	log_info "Extracting archive to: ${target_path}"

	if [[ ! -f "${archive_file}" ]]; then
		log_error "Archive file not found: ${archive_file}"
		return 1
	fi

	is_safe_path "${target_path}" "RESTORE_TARGET_PATH" || return 1
	reject_home_root_path "${target_path}" "RESTORE_TARGET_PATH" || return 1
	validate_tar_archive_safety "${archive_file}" || return 1

	mkdir -p "${target_path}"

	# --no-absolute-names: GNU tar; pre-scan above covers BSD tar without this flag
	if tar -xzf "${archive_file}" -C "${target_path}" --no-absolute-names 2>/dev/null \
		|| tar -xzf "${archive_file}" -C "${target_path}"; then
		:
	else
		log_error "Failed to extract archive: ${archive_file}"
		return 1
	fi

	log_success "Archive extracted to ${target_path}"
	return 0
}

find_site_archive() {
	local backup_dir="$1"
	local archive=""

	assert_path_under_parent "${backup_dir}" "${BACKUP_DIR}" "backup directory" \
		|| assert_path_under_parent "${backup_dir}" "${TMP_DIR}" "backup directory" || return 1

	if [[ -f "${backup_dir}/site.tar.gz" ]]; then
		printf '%s' "${backup_dir}/site.tar.gz"
		return 0
	fi

	shopt -s nullglob
	local candidates=( "${backup_dir}"/*.tar.gz )
	shopt -u nullglob

	if [[ ${#candidates[@]} -eq 0 ]]; then
		log_error "No site archive found in: ${backup_dir}"
		return 1
	fi

	archive="${candidates[0]}"
	printf '%s' "${archive}"
	return 0
}
