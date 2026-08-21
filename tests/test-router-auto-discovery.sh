#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMON="${ROOT}/src/usr/local/libexec/riph-common.sh"
SYNC="${ROOT}/src/usr/local/sbin/riph-provider-router-ip-push-sync"
fail() { echo "FAIL: $*" >&2; exit 1; }

T="$(mktemp -d /tmp/riph-provider-state.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/etc/router-ip-push-hardening"

cat >"${T}/etc/router-ip-push-hardening/config.env" <<'EOF_CONFIG'
RIPH_CONFIG_VERSION=1
ROUTER_IDS=""
PREVIOUS_IP_GRACE_HOURS=4
REQUIRE_ROUTER_IP=1
ROUTER_IP_PUSH_DIR="/var/lib/router-ip-push"
RIPH_STATE_DIR="/var/lib/router-ip-push-hardening"
RIPH_CONFIG_DIR="/etc/router-ip-push-hardening"
ALLOWLIST_OUTPUT="/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
EOF_CONFIG

sync_provider() {
    bash "${SYNC}" --root "${T}" --no-reconcile >/dev/null
}

load_state() (
    # riph-common consumes this global after being sourced.
    # shellcheck disable=SC2034
    RIPH_ROOT="${T}"
    # shellcheck disable=SC1090
    source "${COMMON}"
    riph_load_config "$(riph_root_path /etc/router-ip-push-hardening/config.env)"
    printf 'status=%s\n' "${RIPH_ROUTER_IP_PUSH_PROVIDER_STATUS}"
    printf 'ids=%s\n' "${RIPH_ROUTER_IDS[*]}"
    local router_id
    for router_id in "${RIPH_ROUTER_IDS[@]}"; do
        printf '%s=%s\n' "${router_id}" "$(riph_current_router_ip "${router_id}")"
    done
)

STATE="${T}/var/lib/router-ip-push-hardening/providers/router-ip-push.json"

echo 'TEST RAD1: missing provider is a normal zero-router state'
sync_provider
[[ -f "${STATE}" ]] || fail 'absent provider snapshot was not created'
[[ "$(jq -r '.status' "${STATE}")" == absent ]] || fail 'missing provider status is not absent'
[[ "$(jq '.routers | length' "${STATE}")" -eq 0 ]] || fail 'missing provider created dynamic routers'
OUT="$(load_state)"
grep -Fxq 'status=absent' <<<"${OUT}" || fail 'core did not load absent provider state'
grep -Fxq 'ids=' <<<"${OUT}" || fail 'zero-router state was not accepted'

echo 'TEST RAD2: two Router IDs materialize independently'
mkdir -p "${T}/var/lib/router-ip-push/ips"
printf '%s\n' '198.51.100.10' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
printf '%s\n' '198.51.100.20' >"${T}/var/lib/router-ip-push/ips/WR3000S.ipv4"
sync_provider
[[ "$(jq -r '.status' "${STATE}")" == available ]] || fail 'valid provider status is not available'
[[ "$(jq '.routers | length' "${STATE}")" -eq 2 ]] || fail 'two provider routers were not materialized'
OUT="$(load_state)"
grep -Fxq 'ids=AX3200 WR3000S' <<<"${OUT}" || fail "effective router ids mismatch: ${OUT}"
grep -Fxq 'AX3200=198.51.100.10' <<<"${OUT}" || fail 'AX3200 current IP mismatch'
grep -Fxq 'WR3000S=198.51.100.20' <<<"${OUT}" || fail 'WR3000S current IP mismatch'

echo 'TEST RAD3: revoke one router withdraws only that Router ID'
rm -f "${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
sync_provider
[[ "$(jq '.routers | length' "${STATE}")" -eq 1 ]] || fail 'single-router revoke did not leave exactly one router'
[[ "$(jq -r '.routers.WR3000S.current_ip' "${STATE}")" == '198.51.100.20' ]] || fail 'remaining WR3000S router was disturbed'
[[ "$(jq -r '.routers.AX3200 // empty' "${STATE}")" == '' ]] || fail 'revoked AX3200 remained in canonical state'

echo 'TEST RAD4: revoke last router is a normal available zero-router state'
rm -f "${T}/var/lib/router-ip-push/ips/WR3000S.ipv4"
sync_provider
[[ "$(jq -r '.status' "${STATE}")" == available ]] || fail 'existing empty provider directory is not available'
[[ "$(jq '.routers | length' "${STATE}")" -eq 0 ]] || fail 'last router revoke left stale dynamic trust'
OUT="$(load_state)"
grep -Fxq 'ids=' <<<"${OUT}" || fail 'core rejected zero-router provider state'

echo 'TEST RAD5: provider disappearance and reappearance are normal'
rm -rf "${T}/var/lib/router-ip-push"
sync_provider
[[ "$(jq -r '.status' "${STATE}")" == absent ]] || fail 'provider disappearance did not become absent'
mkdir -p "${T}/var/lib/router-ip-push/ips"
printf '%s\n' '203.0.113.31' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
sync_provider
[[ "$(jq -r '.routers.AX3200.current_ip' "${STATE}")" == '203.0.113.31' ]] || fail 'provider reappearance did not restore AX3200'

echo 'TEST RAD6: malformed entries fail closed per Router ID while valid routers survive'
printf '%s\n' 'not-an-ip' >"${T}/var/lib/router-ip-push/ips/BROKEN.ipv4"
printf '%s\n' '203.0.113.32' >"${T}/var/lib/router-ip-push/ips/WR3000S.ipv4"
sync_provider 2>"${T}/degraded.err"
[[ "$(jq -r '.status' "${STATE}")" == degraded ]] || fail 'malformed provider input did not set degraded status'
[[ "$(jq -r '.invalid_entries' "${STATE}")" -eq 1 ]] || fail 'invalid provider entry count mismatch'
[[ "$(jq '.routers | length' "${STATE}")" -eq 2 ]] || fail 'valid routers were lost because another entry was malformed'
[[ "$(jq -r '.routers.BROKEN // empty' "${STATE}")" == '' ]] || fail 'malformed Router ID entry became trusted'
grep -Fq 'ignoring malformed Router IP Push IPv4 for BROKEN' "${T}/degraded.err" || fail 'malformed input warning missing'

echo 'TEST RAD7: explicit ROUTER_IDS remains a compatibility filter, not a provider requirement'
printf '%s\n' 'ROUTER_IDS="AX3200"' >>"${T}/etc/router-ip-push-hardening/config.env"
OUT="$(load_state)"
grep -Fxq 'ids=AX3200' <<<"${OUT}" || fail "explicit Router ID filter mismatch: ${OUT}"
! grep -Fq 'WR3000S=' <<<"${OUT}" || fail 'explicit Router ID filter leaked WR3000S'

echo 'TEST RAD8: legacy registration settings are ignored during upgrade compatibility'
cat >>"${T}/etc/router-ip-push-hardening/config.env" <<'EOF_LEGACY'
ROUTER_AUTO_DISCOVER_REGISTERED=1
ROUTER_REGISTRY_DIR="/etc/router-ip-push/routers.d-does-not-exist"
EOF_LEGACY
OUT="$(load_state)"
grep -Fxq 'ids=AX3200' <<<"${OUT}" || fail 'legacy registration settings changed canonical provider selection'
[[ ! -e "${T}/etc/router-ip-push" ]] || fail 'test unexpectedly created Router IP Push registration state'

echo 'PASS: RIPH canonical Router IP Push provider lifecycle tests'
