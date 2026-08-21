#!/usr/bin/env bash

# Shared helpers for Router IP Push Hardening.
# Intended to be sourced, not executed.

riph_log() {
    printf '[riph] %s\n' "$*" >&2
}

riph_die() {
    printf '[riph] ERROR: %s\n' "$*" >&2
    exit 1
}

riph_require_cmd() {
    command -v "$1" >/dev/null 2>&1 || riph_die "required command not found: $1"
}

riph_root_path() {
    local path="$1"
    [[ "${path}" == /* ]] || riph_die "expected absolute path, got: ${path}"
    if [[ "${RIPH_ROOT:-/}" == "/" ]]; then
        printf '%s\n' "${path}"
    else
        printf '%s%s\n' "${RIPH_ROOT%/}" "${path}"
    fi
}

riph_validate_root() {
    local root="${1:-/}"
    [[ "${root}" == /* ]] || riph_die "--root must be an absolute path"
    if command -v realpath >/dev/null 2>&1; then
        root="$(realpath -m -- "${root}")"
    fi
    case "${root}" in
        /|/tmp/*|/var/tmp/*)
            ;;
        *)
            # Non-production roots are a test/development feature. Restrict them to
            # conventional temporary trees so a typo cannot redirect writes into an
            # arbitrary mounted filesystem.
            riph_die "unsafe --root path: ${root} (allowed: /, /tmp/*, /var/tmp/*)"
            ;;
    esac
    printf '%s\n' "${root}"
}

riph_is_ipv4() {
    local ip="$1"
    local a b c d extra
    IFS=. read -r a b c d extra <<<"${ip}"
    [[ -z "${extra:-}" && -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || return 1
    local octet
    for octet in "$a" "$b" "$c" "$d"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        # Force base 10 so values like 08 are valid decimal octets.
        (( 10#${octet} >= 0 && 10#${octet} <= 255 )) || return 1
    done
}

riph_is_ipv4_cidr() {
    local value="$1"
    local ip prefix
    if [[ "${value}" == */* ]]; then
        ip="${value%/*}"
        prefix="${value##*/}"
        [[ "${prefix}" =~ ^[0-9]{1,2}$ ]] || return 1
        (( 10#${prefix} >= 0 && 10#${prefix} <= 32 )) || return 1
    else
        ip="${value}"
    fi
    riph_is_ipv4 "${ip}"
}

riph_normalize_ipv4_cidr() {
    local value="$1"
    if [[ "${value}" == */* ]]; then
        printf '%s\n' "${value}"
    else
        printf '%s/32\n' "${value}"
    fi
}

riph_is_router_id() {
    local router_id="$1"
    [[ "${router_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]
}

riph_validate_router_id() {
    local router_id="$1"
    riph_is_router_id "${router_id}" || riph_die "invalid router id: ${router_id}"
}

riph_read_single_line() {
    local file="$1"
    [[ -f "${file}" ]] || return 1
    local line
    IFS= read -r line <"${file}" || true
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "${line}" ]] || return 1
    printf '%s\n' "${line}"
}

riph_sha256_file() {
    local file="$1"
    sha256sum "${file}" | awk '{print $1}'
}

riph_json_escape() {
    # jq is already a core dependency for state handling.
    jq -Rn --arg value "$1" '$value'
}

riph_utc_iso_from_epoch() {
    date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'
}

riph_now_epoch() {
    if [[ -n "${RIPH_NOW_EPOCH_OVERRIDE:-}" ]]; then
        printf '%s\n' "${RIPH_NOW_EPOCH_OVERRIDE}"
    else
        date -u '+%s'
    fi
}

riph_router_id_is_effective() {
    local wanted="$1" existing
    for existing in "${RIPH_ROUTER_IDS[@]}"; do
        [[ "${existing}" == "${wanted}" ]] && return 0
    done
    return 1
}

riph_add_effective_router_id() {
    local router_id="$1"
    riph_validate_router_id "${router_id}"
    riph_router_id_is_effective "${router_id}" || RIPH_ROUTER_IDS+=("${router_id}")
}

riph_router_id_is_explicit() {
    local wanted="$1" existing
    ((${#RIPH_EXPLICIT_ROUTER_IDS[@]} == 0)) && return 0
    for existing in "${RIPH_EXPLICIT_ROUTER_IDS[@]}"; do
        [[ "${existing}" == "${wanted}" ]] && return 0
    done
    return 1
}

riph_load_router_ip_push_provider_state() {
    local state_file router_id ip status invalid_count

    RIPH_ROUTER_IDS=()
    declare -gA RIPH_ROUTER_IPS=()
    RIPH_ROUTER_IP_PUSH_PROVIDER_STATUS="absent"
    RIPH_ROUTER_IP_PUSH_PROVIDER_INVALID_COUNT=0

    state_file="$(riph_root_path "${RIPH_ROUTER_IP_PUSH_STATE}")"
    [[ -f "${state_file}" ]] || return 0

    riph_require_cmd jq
    if ! jq -e '
        .version == 1
        and .provider == "router-ip-push"
        and (.status == "available" or .status == "absent" or .status == "degraded")
        and (.routers | type == "object")
        and ((.invalid_entries // 0) | type == "number")
        and ((.invalid_entries // 0) >= 0)
    ' "${state_file}" >/dev/null 2>&1; then
        riph_log "WARNING: invalid RIPH Router IP Push provider state; dynamic router trust disabled: ${state_file}"
        return 0
    fi

    status="$(jq -r '.status' "${state_file}")"
    invalid_count="$(jq -r '(.invalid_entries // 0) | floor' "${state_file}")"
    # These globals are intentionally consumed by scripts that source this library.
    # shellcheck disable=SC2034
    RIPH_ROUTER_IP_PUSH_PROVIDER_STATUS="${status}"
    # shellcheck disable=SC2034
    RIPH_ROUTER_IP_PUSH_PROVIDER_INVALID_COUNT="${invalid_count}"

    while IFS=$'\t' read -r router_id ip; do
        [[ -n "${router_id}" ]] || continue
        if ! riph_is_router_id "${router_id}"; then
            riph_log "WARNING: invalid Router ID in RIPH provider state ignored: ${router_id}"
            continue
        fi
        if ! riph_is_ipv4 "${ip}"; then
            riph_log "WARNING: invalid IPv4 for ${router_id} in RIPH provider state ignored: ${ip}"
            continue
        fi
        riph_router_id_is_explicit "${router_id}" || continue
        RIPH_ROUTER_IPS["${router_id}"]="${ip}"
        riph_add_effective_router_id "${router_id}"
    done < <(jq -r '.routers | to_entries[] | [.key, (.value.current_ip // "")] | @tsv' "${state_file}")
}

riph_load_config() {
    local config_file="$1"
    [[ -f "${config_file}" ]] || riph_die "config file not found: ${config_file}"
    # shellcheck disable=SC1090
    source "${config_file}"

    [[ "${RIPH_CONFIG_VERSION:-}" == "1" ]] || riph_die "unsupported RIPH_CONFIG_VERSION"
    [[ "${PREVIOUS_IP_GRACE_HOURS:-}" =~ ^[0-9]+$ ]] \
        || riph_die "PREVIOUS_IP_GRACE_HOURS must be a non-negative integer"
    (( PREVIOUS_IP_GRACE_HOURS <= 168 )) \
        || riph_die "PREVIOUS_IP_GRACE_HOURS must not exceed 168"

    # Compatibility-only settings from the original direct Router IP Push coupling.
    # They are intentionally not used as core availability requirements anymore.
    [[ "${REQUIRE_ROUTER_IP:-1}" == "0" || "${REQUIRE_ROUTER_IP:-1}" == "1" ]] \
        || riph_die "REQUIRE_ROUTER_IP must be 0 or 1"
    ROUTER_IP_PUSH_DIR="${ROUTER_IP_PUSH_DIR:-/var/lib/router-ip-push}"

    RIPH_STATE_DIR="${RIPH_STATE_DIR:-/var/lib/router-ip-push-hardening}"
    RIPH_CONFIG_DIR="${RIPH_CONFIG_DIR:-/etc/router-ip-push-hardening}"
    RIPH_PROVIDER_DIR="${RIPH_PROVIDER_DIR:-${RIPH_STATE_DIR}/providers}"
    RIPH_ROUTER_IP_PUSH_STATE="${RIPH_ROUTER_IP_PUSH_STATE:-${RIPH_PROVIDER_DIR}/router-ip-push.json}"
    ALLOWLIST_OUTPUT="${ALLOWLIST_OUTPUT:-/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf}"

    local path_var path_value
    for path_var in ROUTER_IP_PUSH_DIR RIPH_STATE_DIR RIPH_CONFIG_DIR RIPH_PROVIDER_DIR RIPH_ROUTER_IP_PUSH_STATE ALLOWLIST_OUTPUT; do
        path_value="${!path_var}"
        [[ "${path_value}" == /* ]] || riph_die "${path_var} must be an absolute path"
    done

    RIPH_EXPLICIT_ROUTER_IDS=()
    local router_id
    if [[ -n "${ROUTER_IDS:-}" ]]; then
        read -r -a RIPH_EXPLICIT_ROUTER_IDS <<<"${ROUTER_IDS}"
        for router_id in "${RIPH_EXPLICIT_ROUTER_IDS[@]}"; do
            riph_validate_router_id "${router_id}"
        done
    fi

    # Dynamic routers are loaded only from RIPH-owned canonical provider state.
    # Missing provider state and an empty router set are normal supported states.
    riph_load_router_ip_push_provider_state
}

riph_current_router_ip() {
    local router_id="$1"
    riph_validate_router_id "${router_id}"
    [[ -n "${RIPH_ROUTER_IPS[${router_id}]:-}" ]] || return 1
    printf '%s\n' "${RIPH_ROUTER_IPS[${router_id}]}"
}

riph_prepare_dirs() {
    mkdir -p \
        "$(riph_root_path "${RIPH_STATE_DIR}/backups")" \
        "$(riph_root_path "${RIPH_STATE_DIR}/locks")" \
        "$(riph_root_path "${RIPH_STATE_DIR}/runtime")" \
        "$(riph_root_path "${RIPH_PROVIDER_DIR}")"
}
