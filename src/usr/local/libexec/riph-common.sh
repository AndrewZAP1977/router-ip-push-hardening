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

riph_validate_router_id() {
    local router_id="$1"
    [[ "${router_id}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] \
        || riph_die "invalid router id: ${router_id}"
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

riph_discover_registered_router_ids() {
    local registry_dir registration router_id ip_file state_file
    local -a registrations=()

    registry_dir="$(riph_root_path "${ROUTER_REGISTRY_DIR}")"
    [[ -d "${registry_dir}" ]] || return 0
    riph_require_cmd jq

    shopt -s nullglob
    registrations=("${registry_dir}"/*.json)
    shopt -u nullglob

    for registration in "${registrations[@]}"; do
        router_id="$(basename "${registration}" .json)"
        riph_validate_router_id "${router_id}"

        jq -e --arg id "${router_id}" '
            .version == 1
            and .router_id == $id
            and (.public_key | type == "string")
            and (.public_key | test("^ssh-ed25519 [A-Za-z0-9+/=]+$"))
        ' "${registration}" >/dev/null \
            || riph_die "invalid Router IP Push registration: ${registration}"

        # Registration is the trust gate, but a just-registered router may not have
        # sent its first update yet. Only activate it after Router IP Push has
        # written a current IP/state. The first .ipv4 write wakes riph-router-ip.path.
        ip_file="$(riph_root_path "${ROUTER_IP_PUSH_DIR}/ips/${router_id}.ipv4")"
        state_file="$(riph_root_path "${ROUTER_IP_PUSH_DIR}/state/${router_id}.json")"
        if [[ -f "${ip_file}" || -f "${state_file}" ]]; then
            # Validate the current value now; malformed state must fail closed.
            riph_current_router_ip "${router_id}" >/dev/null
            riph_add_effective_router_id "${router_id}"
        else
            riph_log "registered router ${router_id} has no current IPv4 yet; waiting for first Router IP Push update"
        fi
    done
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
    [[ "${REQUIRE_ROUTER_IP:-1}" == "0" || "${REQUIRE_ROUTER_IP:-1}" == "1" ]] \
        || riph_die "REQUIRE_ROUTER_IP must be 0 or 1"

    ROUTER_AUTO_DISCOVER_REGISTERED="${ROUTER_AUTO_DISCOVER_REGISTERED:-1}"
    [[ "${ROUTER_AUTO_DISCOVER_REGISTERED}" == "0" || "${ROUTER_AUTO_DISCOVER_REGISTERED}" == "1" ]] \
        || riph_die "ROUTER_AUTO_DISCOVER_REGISTERED must be 0 or 1"

    ROUTER_IP_PUSH_DIR="${ROUTER_IP_PUSH_DIR:-/var/lib/router-ip-push}"
    ROUTER_REGISTRY_DIR="${ROUTER_REGISTRY_DIR:-/etc/router-ip-push/routers.d}"
    RIPH_STATE_DIR="${RIPH_STATE_DIR:-/var/lib/router-ip-push-hardening}"
    RIPH_CONFIG_DIR="${RIPH_CONFIG_DIR:-/etc/router-ip-push-hardening}"
    ALLOWLIST_OUTPUT="${ALLOWLIST_OUTPUT:-/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf}"

    local path_var path_value
    for path_var in ROUTER_IP_PUSH_DIR ROUTER_REGISTRY_DIR RIPH_STATE_DIR RIPH_CONFIG_DIR ALLOWLIST_OUTPUT; do
        path_value="${!path_var}"
        [[ "${path_value}" == /* ]] || riph_die "${path_var} must be an absolute path"
    done

    RIPH_ROUTER_IDS=()
    local router_id
    if [[ -n "${ROUTER_IDS:-}" ]]; then
        local -a explicit_router_ids=()
        read -r -a explicit_router_ids <<<"${ROUTER_IDS}"
        for router_id in "${explicit_router_ids[@]}"; do
            riph_add_effective_router_id "${router_id}"
        done
    fi

    if [[ "${ROUTER_AUTO_DISCOVER_REGISTERED}" == "1" ]]; then
        riph_discover_registered_router_ids
    fi

    ((${#RIPH_ROUTER_IDS[@]} > 0)) \
        || riph_die "no Router IP Push routers configured or registered with a current IPv4"
}

riph_current_router_ip() {
    local router_id="$1"
    local ip_file state_file ip
    ip_file="$(riph_root_path "${ROUTER_IP_PUSH_DIR}/ips/${router_id}.ipv4")"
    state_file="$(riph_root_path "${ROUTER_IP_PUSH_DIR}/state/${router_id}.json")"

    if ip="$(riph_read_single_line "${ip_file}")"; then
        :
    elif [[ -f "${state_file}" ]]; then
        ip="$(jq -r '.source_ip // empty' "${state_file}")"
    else
        return 1
    fi

    riph_is_ipv4 "${ip}" || riph_die "invalid current IPv4 for ${router_id}: ${ip}"
    printf '%s\n' "${ip}"
}

riph_prepare_dirs() {
    mkdir -p \
        "$(riph_root_path "${RIPH_STATE_DIR}/backups")" \
        "$(riph_root_path "${RIPH_STATE_DIR}/locks")" \
        "$(riph_root_path "${RIPH_STATE_DIR}/runtime")"
}
