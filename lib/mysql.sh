#!/usr/bin/env bash
# shellcheck shell=bash
# MySQL database dump helpers.

: "${BACKUP_PROGRESS_SECONDS:=15}"

mysql_dump() {
	local output_file="$1"

	assert_path_under_parent "${output_file}" "${BACKUP_DIR}" "MySQL dump output" || return 1

	log_info "Starting MySQL dump for database: ${DB_NAME}"

	if [[ -z "${DB_PASSWORD:-}" ]]; then
		log_error "DB_PASSWORD is empty"
		return 1
	fi

	# Use MYSQL_PWD to avoid password on command line (still visible in env; prefer .env permissions)
	export MYSQL_PWD="${DB_PASSWORD}"

	local interval="${BACKUP_PROGRESS_SECONDS}"
	local dump_status=0

	(
		mysqldump \
			--host="${DB_HOST}" \
			--user="${DB_USER}" \
			--single-transaction \
			--quick \
			--lock-tables=false \
			--no-tablespaces \
			"${DB_NAME}" | gzip -c > "${output_file}"
	) &
	local dump_pid=$!

	if [[ "${interval}" -gt 0 ]]; then
		log_info "MySQL dump in progress… updates every ${interval}s"
		while kill -0 "${dump_pid}" 2>/dev/null; do
			log_info "MySQL dump progress: $(format_bytes "$(file_size_bytes "${output_file}")") written"
			local waited=0
			while [[ "${waited}" -lt "${interval}" ]]; do
				kill -0 "${dump_pid}" 2>/dev/null || break 2
				sleep 1
				waited=$(( waited + 1 ))
			done
		done
	fi

	wait "${dump_pid}" || dump_status=$?
	unset MYSQL_PWD

	if [[ "${dump_status}" -ne 0 ]]; then
		log_error "mysqldump failed for database: ${DB_NAME}"
		return 1
	fi

	if [[ ! -s "${output_file}" ]]; then
		log_error "MySQL dump file is empty: ${output_file}"
		return 1
	fi

	log_file_size "MySQL dump" "${output_file}"
	log_success "MySQL dump completed"
	return 0
}

mysql_restore() {
	local dump_file="$1"

	assert_path_under_parent "${dump_file}" "${BACKUP_DIR}" "MySQL dump file" \
		|| assert_path_under_parent "${dump_file}" "${TMP_DIR}" "MySQL dump file" || return 1

	log_info "Restoring MySQL database: ${DB_NAME}"

	if [[ ! -f "${dump_file}" ]]; then
		log_error "MySQL dump file not found: ${dump_file}"
		return 1
	fi

	export MYSQL_PWD="${DB_PASSWORD:-}"

	if ! gunzip -c "${dump_file}" | mysql \
		--host="${DB_HOST}" \
		--user="${DB_USER}" \
		"${DB_NAME}"; then
		unset MYSQL_PWD
		log_error "MySQL restore failed for database: ${DB_NAME}"
		return 1
	fi

	unset MYSQL_PWD
	log_success "MySQL restore completed"
	return 0
}
