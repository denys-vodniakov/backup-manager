#!/usr/bin/env bash
# shellcheck shell=bash
# File archive helpers using tar and gzip.

# How often to log archive size while tar runs (seconds)
: "${BACKUP_PROGRESS_SECONDS:=15}"

_ARCHIVE_TAR_PID=""

_archive_cleanup_tar() {
	if [[ -n "${_ARCHIVE_TAR_PID}" ]] && kill -0 "${_ARCHIVE_TAR_PID}" 2>/dev/null; then
		log_warn "Stopping archive process (pid ${_ARCHIVE_TAR_PID})"
		kill "${_ARCHIVE_TAR_PID}" 2>/dev/null || true
		wait "${_ARCHIVE_TAR_PID}" 2>/dev/null || true
	fi
	_ARCHIVE_TAR_PID=""
}

_dir_size_bytes() {
	local path="$1"
	local bytes

	# -sk is enough for progress estimates and faster than -sb on huge trees
	bytes="$(du -sk "${path}" 2>/dev/null | awk '{print $1 * 1024}')" || true
	if [[ -n "${bytes}" && "${bytes}" =~ ^[0-9]+$ ]]; then
		printf '%s' "${bytes}"
		return 0
	fi

	printf '0'
}

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

	local parent_dir base_name source_bytes interval
	parent_dir="$(cd "$(dirname "${source_path}")" && pwd)"
	base_name="$(basename "${source_path}")"
	interval="${BACKUP_PROGRESS_SECONDS}"

	log_info "Measuring source size (large folders may take a minute)…"
	source_bytes="$(_dir_size_bytes "${source_path}")"

	if [[ "${source_bytes}" -gt 0 ]]; then
		log_info "Source size (approx): $(format_bytes "${source_bytes}") — progress every ${interval}s"
	else
		log_info "Archiving… progress every ${interval}s"
	fi

	tar -czf "${output_file}" -C "${parent_dir}" "${base_name}" &
	_ARCHIVE_TAR_PID=$!
	trap '_archive_cleanup_tar' RETURN

	while kill -0 "${_ARCHIVE_TAR_PID}" 2>/dev/null; do
		sleep "${interval}"
		if ! kill -0 "${_ARCHIVE_TAR_PID}" 2>/dev/null; then
			break
		fi

		local cur pct=0
		cur="$(file_size_bytes "${output_file}")"
		if [[ "${source_bytes}" -gt 0 && "${cur}" -gt 0 ]]; then
			pct=$(( cur * 100 / source_bytes ))
			if [[ "${pct}" -ge 100 ]]; then
				pct=99
			fi
			log_info "Archive progress: $(format_bytes "${cur}") written (~${pct}% of source)"
		else
			log_info "Archive progress: $(format_bytes "${cur}") written"
		fi
	done

	local tar_status=0
	wait "${_ARCHIVE_TAR_PID}" || tar_status=$?
	_ARCHIVE_TAR_PID=""
	trap - RETURN

	# GNU tar: 0 = ok, 1 = warnings (e.g. "file changed as we read it"), 2+ = fatal
	if [[ "${tar_status}" -ge 2 ]]; then
		log_error "Failed to create archive (tar exit ${tar_status}): ${output_file}"
		return 1
	fi

	if [[ "${tar_status}" -eq 1 ]]; then
		log_warn "tar reported warnings (often 'file changed as we read it' on live uploads) — archive kept"
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
	log_file_size "Archive to extract" "${archive_file}"

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
