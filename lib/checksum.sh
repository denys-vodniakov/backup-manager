#!/usr/bin/env bash
# shellcheck shell=bash
# SHA256 checksum generation and verification.

_checksum_tool() {
	if command -v sha256sum >/dev/null 2>&1; then
		echo sha256sum
	elif command -v shasum >/dev/null 2>&1; then
		echo shasum
	else
		return 1
	fi
}

generate_checksums() {
	local backup_dir="$1"
	local checksum_file="${backup_dir}/checksums.sha256"
	local tool

	assert_path_under_parent "${backup_dir}" "${BACKUP_DIR}" "backup directory" || return 1

	tool="$(_checksum_tool)" || { log_error "No SHA256 tool available"; return 1; }

	log_info "Generating SHA256 checksums in: ${backup_dir}"

	(
		cd "${backup_dir}" || exit 1
		shopt -s nullglob
		local files=( ./* )
		shopt -u nullglob
		local file base
		for file in "${files[@]}"; do
			[[ -f "${file}" ]] || continue
			base="${file#./}"
			[[ "${base}" == "checksums.sha256" ]] && continue
			if [[ "${tool}" == "sha256sum" ]]; then
				sha256sum "${base}"
			else
				shasum -a 256 "${base}"
			fi
		done
	) > "${checksum_file}"

	if [[ ! -s "${checksum_file}" ]]; then
		log_error "Checksum file is empty: ${checksum_file}"
		return 1
	fi

	log_file_size "Checksums" "${checksum_file}"
	log_success "Checksums generated"
	return 0
}

verify_checksums() {
	local backup_dir="$1"
	local checksum_file="${backup_dir}/checksums.sha256"
	local tool

	assert_path_under_parent "${backup_dir}" "${BACKUP_DIR}" "backup directory" \
		|| assert_path_under_parent "${backup_dir}" "${TMP_DIR}" "backup directory" || return 1

	tool="$(_checksum_tool)" || { log_error "No SHA256 tool available"; return 1; }

	if [[ ! -f "${checksum_file}" ]]; then
		log_error "Checksum file not found: ${checksum_file}"
		return 1
	fi

	log_info "Verifying SHA256 checksums in: ${backup_dir}"

	(
		cd "${backup_dir}" || exit 1
		if [[ "${tool}" == "sha256sum" ]]; then
			sha256sum -c checksums.sha256
		else
			shasum -a 256 -c checksums.sha256
		fi
	) || {
		log_error "Checksum verification failed"
		return 1
	}

	log_success "Checksum verification passed"
	return 0
}
