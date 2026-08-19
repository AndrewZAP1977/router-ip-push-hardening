#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=src/usr/local/libexec/riph-common.sh
source "${REPO_ROOT}/src/usr/local/libexec/riph-common.sh"

RIPH_ROOT="/"
STREAM_PATH="/etc/nginx/stream-enabled/stream.conf"
TEMPLATE_FILE="${REPO_ROOT}/config/config.env.example"
OUTPUT_FILE=""

usage() {
    cat <<'USAGE'
Usage: bootstrap-config-from-stream.sh [options]

Build a first-install RIPH config from the standard stream.conf produced by
3x-ui-installer. The source is read-only; the output is written only after all
checks pass.

Options:
  --root DIR       Root prefix for the source Nginx installation.
  --stream PATH    stream.conf path inside root.
  --template FILE  RIPH config template on the real filesystem.
  --output FILE    Output config path on the real filesystem.
  -h, --help       Show this help.
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            (($# >= 2)) || riph_die "--root requires a value"
            RIPH_ROOT="$(riph_validate_root "$2")"
            shift 2
            ;;
        --stream)
            (($# >= 2)) || riph_die "--stream requires a value"
            STREAM_PATH="$2"
            shift 2
            ;;
        --template)
            (($# >= 2)) || riph_die "--template requires a value"
            TEMPLATE_FILE="$2"
            shift 2
            ;;
        --output)
            (($# >= 2)) || riph_die "--output requires a value"
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            riph_die "unknown argument: $1"
            ;;
    esac
done

[[ "${STREAM_PATH}" == /* ]] || riph_die "--stream must be an absolute path inside root"
[[ -n "${OUTPUT_FILE}" ]] || riph_die "--output is required"
[[ -f "${TEMPLATE_FILE}" ]] || riph_die "config template not found: ${TEMPLATE_FILE}"

STREAM_FILE="$(riph_root_path "${STREAM_PATH}")"
[[ -f "${STREAM_FILE}" ]] || riph_die "existing Nginx stream config not found: ${STREAM_FILE}"

if grep -Fq 'Managed by router-ip-push-hardening' "${STREAM_FILE}" \
    || grep -Fq '$router_ip_push_source_allowed' "${STREAM_FILE}"; then
    riph_die "source stream config is already RIPH-managed; bootstrap is only for first adoption"
fi

grep -Eq '^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$sni_name([[:space:]]*\{)?[[:space:]]*$' "${STREAM_FILE}" \
    || riph_die "unsupported stream config: expected map \$ssl_preread_server_name -> \$sni_name"
grep -Eq '^[[:space:]]*proxy_pass[[:space:]]+\$sni_name;[[:space:]]*$' "${STREAM_FILE}" \
    || riph_die "unsupported stream config: external server does not proxy_pass \$sni_name"
grep -Eq '^[[:space:]]*ssl_preread[[:space:]]+on;[[:space:]]*$' "${STREAM_FILE}" \
    || riph_die "unsupported stream config: ssl_preread is not enabled"
grep -Eq '^[[:space:]]*listen[[:space:]]+443;[[:space:]]*$' "${STREAM_FILE}" \
    || riph_die "unsupported stream config: IPv4 listen 443 is missing"

MAP_FILE="$(mktemp)"
TMP_OUTPUT="$(mktemp)"
trap 'rm -f "${MAP_FILE}" "${TMP_OUTPUT}"' EXIT

if ! awk '
    BEGIN { in_map=0; seen=0; done=0 }
    {
        line=$0
        sub(/\r$/, "", line)
        if (!in_map) {
            if (line ~ /^[[:space:]]*map[[:space:]]+\$ssl_preread_server_name[[:space:]]+\$sni_name([[:space:]]*\{)?[[:space:]]*$/) {
                in_map=1
                seen=1
            }
            next
        }
        if (line ~ /^[[:space:]]*\{[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*\}[[:space:]]*$/) {
            done=1
            exit
        }
        sub(/[[:space:]]*#.*/, "", line)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
        if (line == "" || line == "hostnames;") next
        if (line !~ /;$/) exit 3
        sub(/;$/, "", line)
        n=split(line, field, /[[:space:]]+/)
        if (n != 2) exit 3
        print field[1] "\t" field[2]
    }
    END {
        if (!seen || !done) exit 4
    }
' "${STREAM_FILE}" >"${MAP_FILE}"; then
    riph_die "unsupported stream config: could not parse SNI map"
fi

PUBLIC_SNI=""
PRIVATE_SNI_1=""
PRIVATE_SNI_2=""
DEFAULT_OK=0

while IFS=$'\t' read -r key target; do
    [[ -n "${key}" && -n "${target}" ]] || continue
    case "${target}" in
        www)
            [[ "${key}" != default && -z "${PUBLIC_SNI}" ]] \
                || riph_die "unsupported stream config: duplicate/invalid www mapping"
            PUBLIC_SNI="${key}"
            ;;
        xray)
            [[ "${key}" != default && -z "${PRIVATE_SNI_1}" ]] \
                || riph_die "unsupported stream config: duplicate/invalid xray mapping"
            PRIVATE_SNI_1="${key}"
            ;;
        xray2)
            [[ "${key}" != default && -z "${PRIVATE_SNI_2}" ]] \
                || riph_die "unsupported stream config: duplicate/invalid xray2 mapping"
            PRIVATE_SNI_2="${key}"
            ;;
        reject)
            [[ "${key}" == default && "${DEFAULT_OK}" == 0 ]] \
                || riph_die "unsupported stream config: invalid reject mapping"
            DEFAULT_OK=1
            ;;
        *)
            riph_die "unsupported stream config: unexpected map target ${target}"
            ;;
    esac
done <"${MAP_FILE}"

[[ -n "${PUBLIC_SNI}" ]] || riph_die "unsupported stream config: public www SNI not found"
[[ -n "${PRIVATE_SNI_1}" ]] || riph_die "unsupported stream config: xray SNI not found"
(( DEFAULT_OK == 1 )) || riph_die "unsupported stream config: default reject mapping not found"

is_hostname() {
    local host="$1" label
    [[ ${#host} -le 253 && "${host}" == *.* ]] || return 1
    IFS=. read -r -a labels <<<"${host}"
    for label in "${labels[@]}"; do
        [[ -n "${label}" && ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] || return 1
    done
}

is_hostname "${PUBLIC_SNI}" || riph_die "invalid public SNI discovered in stream config: ${PUBLIC_SNI}"
is_hostname "${PRIVATE_SNI_1}" || riph_die "invalid private SNI discovered in stream config: ${PRIVATE_SNI_1}"
if [[ -n "${PRIVATE_SNI_2}" ]]; then
    is_hostname "${PRIVATE_SNI_2}" || riph_die "invalid second private SNI discovered in stream config: ${PRIVATE_SNI_2}"
fi

extract_upstream_server() {
    local wanted="$1"
    awk -v wanted="${wanted}" '
        BEGIN { state=0; blocks=0; servers=0; value="" }
        {
            line=$0
            sub(/#.*/, "", line)
            gsub(/([{};])/, " & ", line)
            n=split(line, token, /[[:space:]]+/)
            for (i=1; i<=n; i++) {
                t=token[i]
                if (t == "") continue
                if (state == 0) {
                    if (t == "upstream" && i < n && token[i+1] == wanted) {
                        blocks++
                        state=1
                        i++
                    }
                    continue
                }
                if (state == 1) {
                    if (t == "{") state=2
                    continue
                }
                if (state == 2) {
                    if (t == "server") {
                        if (i >= n) exit 5
                        value=token[i+1]
                        servers++
                        i++
                        continue
                    }
                    if (t == "}") state=0
                }
            }
        }
        END {
            if (blocks != 1 || servers != 1 || value == "") exit 6
            print value
        }
    ' "${STREAM_FILE}"
}

PUBLIC_UPSTREAM="$(extract_upstream_server www)" \
    || riph_die "unsupported stream config: could not parse upstream www"
XRAY_UPSTREAM_1="$(extract_upstream_server xray)" \
    || riph_die "unsupported stream config: could not parse upstream xray"
REJECT_UPSTREAM="$(extract_upstream_server reject)" \
    || riph_die "unsupported stream config: could not parse upstream reject"

PRIVATE_ROUTE_COUNT=1
XRAY_UPSTREAM_2="127.0.0.1:8444"
if [[ -n "${PRIVATE_SNI_2}" ]]; then
    PRIVATE_ROUTE_COUNT=2
    XRAY_UPSTREAM_2="$(extract_upstream_server xray2)" \
        || riph_die "unsupported stream config: xray2 mapping exists but upstream xray2 is invalid/missing"
elif grep -Eq '^[[:space:]]*upstream[[:space:]]+xray2([[:space:]]|\{)' "${STREAM_FILE}"; then
    riph_die "unsupported stream config: upstream xray2 exists without an xray2 SNI mapping"
fi

validate_loopback_upstream() {
    local name="$1" value="$2" host port
    [[ "${value}" == *:* ]] || riph_die "${name} must be HOST:PORT"
    host="${value%:*}"
    port="${value##*:}"
    [[ "${host}" == "127.0.0.1" ]] || riph_die "${name} must use 127.0.0.1"
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || riph_die "${name} has invalid port: ${port}"
    (( 10#${port} >= 1 && 10#${port} <= 65535 )) || riph_die "${name} port out of range: ${port}"
}

validate_loopback_upstream PUBLIC_UPSTREAM "${PUBLIC_UPSTREAM}"
validate_loopback_upstream XRAY_UPSTREAM_1 "${XRAY_UPSTREAM_1}"
validate_loopback_upstream REJECT_UPSTREAM "${REJECT_UPSTREAM}"
if (( PRIVATE_ROUTE_COUNT == 2 )); then
    validate_loopback_upstream XRAY_UPSTREAM_2 "${XRAY_UPSTREAM_2}"
fi

extract_fake_site() {
    local logical="$1" expected_sni="$2"
    local file server_name listen
    file="$(riph_root_path "${logical}")"
    [[ -f "${file}" ]] || riph_die "matching fake-site config not found: ${file}"
    server_name="$(awk '
        /^[[:space:]]*server_name[[:space:]]+/ {
            value=$2
            sub(/;$/, "", value)
            print value
            exit
        }
    ' "${file}")"
    [[ "${server_name}" == "${expected_sni}" ]] \
        || riph_die "fake-site server_name mismatch in ${file}: expected ${expected_sni}, got ${server_name:-empty}"
    listen="$(awk '
        /^[[:space:]]*listen[[:space:]]+127\.0\.0\.1:[0-9]+/ {
            value=$2
            sub(/;$/, "", value)
            print value
            exit
        }
    ' "${file}")"
    [[ -n "${listen}" ]] || riph_die "loopback fake-site listen not found in ${file}"
    validate_loopback_upstream FAKE_SITE_UPSTREAM "${listen}"
    printf '%s\n' "${listen}"
}

FAKE_SITE_UPSTREAM_1="$(extract_fake_site /etc/nginx/sites-available/reality.conf "${PRIVATE_SNI_1}")"
FAKE_SITE_UPSTREAM_2="127.0.0.1:9444"
if (( PRIVATE_ROUTE_COUNT == 2 )); then
    FAKE_SITE_UPSTREAM_2="$(extract_fake_site /etc/nginx/sites-available/xhttp.conf "${PRIVATE_SNI_2}")"
fi

cp "${TEMPLATE_FILE}" "${TMP_OUTPUT}"

replace_setting() {
    local key="$1" value="$2" tmp
    tmp="${TMP_OUTPUT}.replace"
    awk -v key="${key}" -v value="${value}" '
        BEGIN { done=0 }
        index($0, key "=") == 1 {
            print key "=" value
            done=1
            next
        }
        { print }
        END { if (!done) exit 7 }
    ' "${TMP_OUTPUT}" >"${tmp}" \
        || riph_die "config template is missing required setting: ${key}"
    mv "${tmp}" "${TMP_OUTPUT}"
}

replace_setting ROUTER_IDS '""'
replace_setting PUBLIC_SNI "\"${PUBLIC_SNI}\""
replace_setting PUBLIC_UPSTREAM "\"${PUBLIC_UPSTREAM}\""
replace_setting PRIVATE_ROUTE_COUNT "${PRIVATE_ROUTE_COUNT}"
replace_setting PRIVATE_SNI_1 "\"${PRIVATE_SNI_1}\""
replace_setting XRAY_UPSTREAM_1 "\"${XRAY_UPSTREAM_1}\""
replace_setting FAKE_SITE_UPSTREAM_1 "\"${FAKE_SITE_UPSTREAM_1}\""
replace_setting BRIDGE_LISTEN_1 '"127.0.0.1:9543"'
replace_setting REJECT_UPSTREAM "\"${REJECT_UPSTREAM}\""

if (( PRIVATE_ROUTE_COUNT == 2 )); then
    replace_setting PRIVATE_SNI_2 "\"${PRIVATE_SNI_2}\""
    replace_setting XRAY_UPSTREAM_2 "\"${XRAY_UPSTREAM_2}\""
    replace_setting FAKE_SITE_UPSTREAM_2 "\"${FAKE_SITE_UPSTREAM_2}\""
    replace_setting BRIDGE_LISTEN_2 '"127.0.0.1:9544"'
fi

mkdir -p "$(dirname "${OUTPUT_FILE}")"
install -m 0600 "${TMP_OUTPUT}" "${OUTPUT_FILE}"

riph_log "bootstrapped first-install config from existing Nginx stream routing"
riph_log "public SNI: ${PUBLIC_SNI} -> ${PUBLIC_UPSTREAM}"
riph_log "private SNI 1: ${PRIVATE_SNI_1} -> ${XRAY_UPSTREAM_1}; fake ${FAKE_SITE_UPSTREAM_1}"
if (( PRIVATE_ROUTE_COUNT == 2 )); then
    riph_log "private SNI 2: ${PRIVATE_SNI_2} -> ${XRAY_UPSTREAM_2}; fake ${FAKE_SITE_UPSTREAM_2}"
fi
