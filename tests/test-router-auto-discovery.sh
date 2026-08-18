#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/src/usr/local/libexec/riph-common.sh"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

T="$(mktemp -d /tmp/riph-router-discovery.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/router-ip-push/routers.d" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/var/lib/router-ip-push/state"

cat >"${T}/etc/router-ip-push-hardening/config.env" <<'EOF_CONFIG'
RIPH_CONFIG_VERSION=1
ROUTER_IDS="AX3200"
PREVIOUS_IP_GRACE_HOURS=4
REQUIRE_ROUTER_IP=1
ROUTER_IP_PUSH_DIR="/var/lib/router-ip-push"
RIPH_STATE_DIR="/var/lib/router-ip-push-hardening"
RIPH_CONFIG_DIR="/etc/router-ip-push-hardening"
ALLOWLIST_OUTPUT="/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
EOF_CONFIG

printf '%s\n' '198.51.100.10' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
printf '%s\n' '198.51.100.20' >"${T}/var/lib/router-ip-push/ips/MOTHER.ipv4"
printf '%s\n' '198.51.100.30' >"${T}/var/lib/router-ip-push/ips/UNREGISTERED.ipv4"

cat >"${T}/etc/router-ip-push/routers.d/MOTHER.json" <<'EOF_MOTHER'
{"version":1,"router_id":"MOTHER","public_key":"ssh-ed25519 AAAA"}
EOF_MOTHER
cat >"${T}/etc/router-ip-push/routers.d/WAITING.json" <<'EOF_WAITING'
{"version":1,"router_id":"WAITING","public_key":"ssh-ed25519 BBBB"}
EOF_WAITING

load_ids() (
    RIPH_ROOT="${T}"
    # shellcheck source=../src/usr/local/libexec/riph-common.sh
    source "${COMMON}"
    riph_load_config "$(riph_root_path /etc/router-ip-push-hardening/config.env)"
    printf '%s\n' "${RIPH_ROUTER_IDS[*]}"
)

echo 'TEST RAD1: existing config automatically adds registered router after first push'
IDS="$(load_ids 2>"${T}/rad1.err")"
[[ "${IDS}" == 'AX3200 MOTHER' ]] || fail "effective router ids mismatch: ${IDS}"
grep -Fq 'registered router WAITING has no current IPv4 yet' "${T}/rad1.err" \
    || fail 'registered router without first push was not reported as waiting'
[[ "${IDS}" != *UNREGISTERED* ]] || fail 'unregistered .ipv4 file became trusted'
[[ "${IDS}" != *WAITING* ]] || fail 'registered router without current IP became active'

echo 'TEST RAD2: auto-discovery can be explicitly disabled'
printf '%s\n' 'ROUTER_AUTO_DISCOVER_REGISTERED=0' >>"${T}/etc/router-ip-push-hardening/config.env"
IDS="$(load_ids)"
[[ "${IDS}" == 'AX3200' ]] || fail "disabled auto-discovery still added routers: ${IDS}"

echo 'TEST RAD3: malformed/mismatched registration fails closed'
sed -i '/^ROUTER_AUTO_DISCOVER_REGISTERED=/d' "${T}/etc/router-ip-push-hardening/config.env"
cat >"${T}/etc/router-ip-push/routers.d/BAD.json" <<'EOF_BAD'
{"version":1,"router_id":"SOMEONE_ELSE","public_key":"ssh-ed25519 CCCC"}
EOF_BAD
if load_ids >"${T}/rad3.out" 2>"${T}/rad3.err"; then
    fail 'invalid registration was accepted'
fi
grep -Fq 'invalid Router IP Push registration' "${T}/rad3.err" \
    || fail 'invalid registration refusal message missing'

echo 'PASS: registered Router IP Push router auto-discovery tests'
