#!/usr/bin/env bash
# shellcheck shell=bash
# Local backup retention with strict path safety checks.

apply_local_retention() {
	local retention_days="${RETENTION_LOCAL_DAYS:-0}"

	if [[ "${retention_days}" -eq 0 ]]; then
		log_info "Local retention disabled (RETENTION_LOCAL_DAYS=0)"
		return 0
	fi

	if ! is_safe_path "${BACKUP_DIR}" "BACKUP_DIR"; then
		log_error "Refusing local retention: unsafe BACKUP_DIR"
		return 1
	fi

	local resolved_backup_dir
	resolved_backup_dir="$(cd "${BACKUP_DIR}" && pwd -P)"

	log_info "Applying local retention: ${retention_days} day(s) in ${resolved_backup_dir}"

	local cutoff_date deleted=0
	cutoff_date="$(date -d "-${retention_days} days" '+%Y-%m-%d' 2>/dev/null || date -v-"${retention_days}"d '+%Y-%m-%d')"

	for entry in "${resolved_backup_dir}"/*; do
		[[ -e "${entry}" ]] || continue
		[[ -d "${entry}" ]] || continue

		local entry_name entry_date resolved_entry
		entry_name="$(basename "${entry}")"
		resolved_entry="$(cd "${entry}" && pwd -P)"

		if ! path_is_under "${resolved_entry}" "${resolved_backup_dir}"; then
			log_warn "Skipping entry outside BACKUP_DIR: ${resolved_entry}"
			continue
		fi

		if [[ ! "${entry_name}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$ ]]; then
			log_warn "Skipping entry with unexpected name: ${entry_name}"
			continue
		fi

		entry_date="${entry_name%%_*}"

		if [[ "${entry_date}" < "${cutoff_date}" ]]; then
			log_info "Removing local backup: ${resolved_entry}"
			if safe_remove_directory "${resolved_entry}" "${resolved_backup_dir}" true; then
				((deleted++)) || true
			else
				log_warn "Failed to remove: ${resolved_entry}"
			fi
		fi
	done

	log_info "Local retention complete: removed ${deleted} backup(s)"
	return 0
}
