#!/usr/bin/env bash
# shellcheck shell=bash
# Path validation, safe deletion, and archive safety helpers.

# Matches backup directory names produced by backup.sh
BACKUP_NAME_PATTERN='^[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{6}$'
# Safe identifiers for DB names, remotes, project slugs
SAFE_IDENTIFIER_PATTERN='^[A-Za-z0-9][A-Za-z0-9._-]*$'

require_absolute_path() {
	local path="$1"
	local label="${2:-path}"

	if [[ "${path}" != /* ]]; then
		log_error "${label} must be an absolute path (got: ${path})"
		return 1
	fi

	if [[ "${path}" == *'..'* ]]; then
		log_error "${label} must not contain '..' components (got: ${path})"
		return 1
	fi

	return 0
}

resolve_path() {
	local path="$1"
	cd "${path}" 2>/dev/null && pwd -P
}

path_device_inode() {
	local path="$1"
	stat -c '%d:%i' "${path}" 2>/dev/null || stat -f '%d:%i' "${path}" 2>/dev/null
}

# True if both paths exist and refer to the same directory (OVH /home vs /homez.N).
same_directory() {
	local a="$1"
	local b="$2"
	local ia ib

	[[ -d "${a}" && -d "${b}" ]] || return 1
	ia="$(path_device_inode "${a}")" || return 1
	ib="$(path_device_inode "${b}")" || return 1
	[[ -n "${ia}" && "${ia}" == "${ib}" ]]
}

# Canonicalize a path that may not exist yet (OVH: /home/user vs /homez.N/user).
canonicalize_path() {
	local path="$1"
	local dir base resolved_dir

	# Prefer GNU realpath when available (handles non-existent tails).
	if command -v realpath >/dev/null 2>&1; then
		realpath -m "${path}" 2>/dev/null && return 0
	fi

	if [[ -d "${path}" ]]; then
		resolve_path "${path}"
		return $?
	fi

	if [[ -e "${path}" ]]; then
		dir="$(dirname -- "${path}")"
		base="$(basename -- "${path}")"
		resolved_dir="$(resolve_path "${dir}")" || return 1
		printf '%s/%s' "${resolved_dir}" "${base}"
		return 0
	fi

	# Walk up until an existing directory is found, then rejoin the suffix.
	dir="${path}"
	base=""
	while [[ ! -d "${dir}" ]]; do
		if [[ "${dir}" == "/" || "${dir}" == "." || -z "${dir}" ]]; then
			return 1
		fi
		if [[ -n "${base}" ]]; then
			base="$(basename -- "${dir}")/${base}"
		else
			base="$(basename -- "${dir}")"
		fi
		dir="$(dirname -- "${dir}")"
	done

	resolved_dir="$(resolve_path "${dir}")" || return 1
	printf '%s/%s' "${resolved_dir}" "${base}"
}

assert_path_under_parent() {
	local child="$1"
	local parent="$2"
	local label="${3:-path}"
	local resolved_parent resolved_child child_dir

	if [[ "${child}" == *'..'* ]]; then
		log_error "${label} must not contain '..' components"
		return 1
	fi

	resolved_parent="$(canonicalize_path "${parent}")" || {
		log_error "${label}: cannot resolve parent path: ${parent}"
		return 1
	}
	resolved_child="$(canonicalize_path "${child}")" || {
		log_error "${label}: cannot resolve path: ${child}"
		return 1
	}

	case "${resolved_child}" in
		"${resolved_parent}"|"${resolved_parent}"/*) return 0 ;;
	esac

	# Fallback for hosts where /home/user and /homez.N/user are the same dir
	# but canonicalize to different string prefixes.
	child_dir="$(dirname -- "${child}")"
	if same_directory "${parent}" "${child_dir}"; then
		return 0
	fi
	if [[ -d "${resolved_parent}" ]]; then
		local walk="${child_dir}"
		while [[ -n "${walk}" && "${walk}" != "/" ]]; do
			if same_directory "${resolved_parent}" "${walk}" || same_directory "${parent}" "${walk}"; then
				return 0
			fi
			walk="$(dirname -- "${walk}")"
		done
	fi

	log_error "${label} must be under ${resolved_parent} (got: ${resolved_child})"
	return 1
}

validate_backup_name() {
	local name="$1"

	if [[ ! "${name}" =~ ${BACKUP_NAME_PATTERN} ]]; then
		log_error "Invalid backup name (expected YYYY-MM-DD_HHMMSS): ${name}"
		return 1
	fi
}

validate_safe_identifier() {
	local value="$1"
	local label="$2"

	if [[ ! "${value}" =~ ${SAFE_IDENTIFIER_PATTERN} ]]; then
		log_error "${label} contains unsafe characters (use letters, numbers, ., _, -): ${value}"
		return 1
	fi
}

validate_db_identifiers() {
	validate_safe_identifier "${DB_NAME}" "DB_NAME" || return 1
	validate_safe_identifier "${DB_USER}" "DB_USER" || return 1

	# Host is typically localhost or a hostname
	if [[ ! "${DB_HOST}" =~ ^[A-Za-z0-9._-]+$ ]]; then
		log_error "DB_HOST contains unsafe characters: ${DB_HOST}"
		return 1
	fi

	return 0
}

validate_rclone_config() {
	validate_safe_identifier "${RCLONE_REMOTE}" "RCLONE_REMOTE" || return 1

	if [[ "${RCLONE_REMOTE_PATH}" == *'..'* ]]; then
		log_error "RCLONE_REMOTE_PATH contains unsafe characters"
		return 1
	fi

	if [[ ! "${RCLONE_BIN}" =~ ^[A-Za-z0-9/._-]+$ ]]; then
		log_error "RCLONE_BIN contains unsafe characters"
		return 1
	fi

	return 0
}

validate_env_file_permissions() {
	local env_file="$1"
	local mode

	if [[ ! -f "${env_file}" ]]; then
		return 0
	fi

	mode="$(stat -c '%a' "${env_file}" 2>/dev/null || stat -f '%OLp' "${env_file}" 2>/dev/null || echo "")"
	if [[ -z "${mode}" ]]; then
		log_warn "Could not read permissions for ${env_file}"
		return 0
	fi

	# Warn when group/other can read (last two octal digits non-zero for world, etc.)
	local world=$(( mode % 10 ))
	local group=$(( (mode / 10) % 10 ))

	if [[ "${world}" -ne 0 ]] || [[ "${group}" -ge 4 ]]; then
		log_warn "${env_file} is readable by group or others (mode ${mode}); run: chmod 600 ${env_file}"
	fi
}

is_safe_path() {
	local path="$1"
	local label="${2:-path}"

	if [[ -z "${path}" ]]; then
		log_error "${label} must not be empty"
		return 1
	fi

	if [[ "${path}" == "/" ]]; then
		log_error "${label} must not be root (/)"
		return 1
	fi

	if [[ "${path}" == "." || "${path}" == ".." ]]; then
		log_error "${label} must not be '.' or '..'"
		return 1
	fi

	local trimmed="${path%/}"
	if [[ -z "${trimmed}" || "${trimmed}" == "/" ]]; then
		log_error "${label} resolves to an unsafe path: ${path}"
		return 1
	fi

	require_absolute_path "${path}" "${label}" || return 1

	return 0
}

# Refuse paths that are too broad for destructive restore/extract operations.
reject_home_root_path() {
	local path="$1"
	local label="$2"
	local resolved home_resolved

	resolved="$(resolve_path "${path}" 2>/dev/null || printf '%s' "${path}")"
	home_resolved="$(resolve_path "${HOME}" 2>/dev/null || true)"

	if [[ -n "${home_resolved}" && "${resolved}" == "${home_resolved}" ]]; then
		log_error "${label} must not be the home directory root (${resolved})"
		return 1
	fi

	return 0
}

safe_remove_directory() {
	local target="$1"
	local allowed_parent="$2"
	local require_backup_name="${3:-false}"

	if [[ ! -e "${target}" ]]; then
		return 0
	fi

	if ! is_safe_path "${target}" "removal target"; then
		log_error "Refusing to remove unsafe path: ${target}"
		return 1
	fi

	local resolved_target resolved_parent
	resolved_target="$(resolve_path "${target}")" || {
		log_error "Refusing to remove unresolvable path: ${target}"
		return 1
	}
	resolved_parent="$(resolve_path "${allowed_parent}")" || {
		log_error "Refusing removal: invalid parent path: ${allowed_parent}"
		return 1
	}

	case "${resolved_target}" in
		"${resolved_parent}"|"${resolved_parent}"/*) ;;
		*)
			log_error "Refusing to remove path outside allowed parent: ${resolved_target}"
			return 1
			;;
	esac

	if [[ "${require_backup_name}" == "true" ]]; then
		validate_backup_name "$(basename "${resolved_target}")" || return 1
	fi

	if [[ "${resolved_target}" == "${resolved_parent}" ]]; then
		log_error "Refusing to remove parent directory itself: ${resolved_target}"
		return 1
	fi

	rm -rf -- "${resolved_target}"
}

validate_tar_archive_safety() {
	local archive_file="$1"
	local unsafe=0

	while IFS= read -r member; do
		[[ -z "${member}" ]] && continue

		if [[ "${member}" == /* ]]; then
			log_error "Archive contains absolute path: ${member}"
			unsafe=1
		fi

		if [[ "${member}" == *'..'* ]]; then
			log_error "Archive contains path traversal: ${member}"
			unsafe=1
		fi
	done < <(tar -tzf "${archive_file}")

	if [[ "${unsafe}" -ne 0 ]]; then
		return 1
	fi

	return 0
}

json_escape_string() {
	local input="$1"
	input="${input//\\/\\\\}"
	input="${input//\"/\\\"}"
	input="${input//$'\n'/\\n}"
	input="${input//$'\r'/\\r}"
	input="${input//$'\t'/\\t}"
	printf '%s' "${input}"
}
