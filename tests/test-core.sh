#!/usr/bin/env bash

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="${REPO_ROOT}/src/usr/local/sbin/riph-generate-allowlist"
APPLY="${REPO_ROOT}/src/usr/local/sbin/riph-apply"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_contains() {
    local file="$1"
    local expected="$2"
    grep -F -- "${expected}" "${file}" >/dev/null || fail "${file} does not contain: ${expected}"
}

assert_not_contains() {
    local file="$1"
    local unexpected="$2"
    if grep -F -- "${unexpected}" "${file}" >/dev/null; then
        fail "${file} unexpectedly contains: ${unexpected}"
    fi
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"
    [[ "${actual}" == "${expected}" ]] || fail "${message}: expected=${expected} actual=${actual}"
}

TEST_ROOT="$(mktemp -d /tmp/riph-test.XXXXXX)"
trap 'rm -rf "${TEST_ROOT}"' EXIT

mkdir -p \
    "${TEST_ROOT}/etc/router-ip-push-hardening" \
    "${TEST_ROOT}/etc/nginx/stream-enabled" \
    "${TEST_ROOT}/var/lib/router-ip-push/ips" \
    "${TEST_ROOT}/var/lib/router-ip-push/state" \
    "${TEST_ROOT}/usr/local/bin"

cp "${REPO_ROOT}/config/config.env.example" \
   "${TEST_ROOT}/etc/router-ip-push-hardening/config.env"

cat >"${TEST_ROOT}/etc/router-ip-push-hardening/trusted-static.list" <<'EOF'
127.0.0.1/32 # localhost
5.61.39.137/32 # VPS_GR
EOF

cat >"${TEST_ROOT}/etc/router-ip-push-hardening/previous-ip-grace.json" <<'EOF'
{"version":1,"routers":{}}
EOF

printf '%s\n' '78.111.155.187' \
    >"${TEST_ROOT}/var/lib/router-ip-push/ips/AX3200.ipv4"

CALL_LOG="${TEST_ROOT}/calls.log"
cat >"${TEST_ROOT}/usr/local/bin/nginx-stub" <<EOF
#!/usr/bin/env bash
echo "nginx \$*" >>"${CALL_LOG}"
exit "\${RIPH_TEST_NGINX_EXIT:-0}"
EOF
cat >"${TEST_ROOT}/usr/local/bin/systemctl-stub" <<EOF
#!/usr/bin/env bash
echo "systemctl \$*" >>"${CALL_LOG}"
exit "\${RIPH_TEST_SYSTEMCTL_EXIT:-0}"
EOF
chmod +x \
    "${TEST_ROOT}/usr/local/bin/nginx-stub" \
    "${TEST_ROOT}/usr/local/bin/systemctl-stub"

export RIPH_NGINX_BIN="${TEST_ROOT}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${TEST_ROOT}/usr/local/bin/systemctl-stub"

echo "TEST 1: generator includes static + current"
GEN_OUT="${TEST_ROOT}/generated.conf"
"${GEN}" --root "${TEST_ROOT}" --output /generated.conf --now-epoch 1000
assert_contains "${GEN_OUT}" '127.0.0.1/32'
assert_contains "${GEN_OUT}" '5.61.39.137/32'
assert_contains "${GEN_OUT}" '78.111.155.187/32'
assert_contains "${GEN_OUT}" 'router-ip-push:AX3200 current'

echo "TEST 2: first apply writes trusted/routing state and reloads once"
"${APPLY}" --root "${TEST_ROOT}" --reason "initial test" --now-epoch 1000
ALLOWLIST="${TEST_ROOT}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
STATE="${TEST_ROOT}/etc/router-ip-push-hardening/last-apply-state.json"
GRACE="${TEST_ROOT}/etc/router-ip-push-hardening/previous-ip-grace.json"
STREAM="${TEST_ROOT}/etc/nginx/stream-enabled/stream.conf"
BRIDGE="${TEST_ROOT}/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf"
assert_contains "${ALLOWLIST}" '78.111.155.187/32'
assert_contains "${STREAM}" 'private-a.example.invalid|1'
assert_contains "${BRIDGE}" 'listen 127.0.0.1:9543 proxy_protocol;'
assert_eq "$(jq -r '.routers.AX3200.current_ip' "${STATE}")" '78.111.155.187' 'first current ip'
assert_eq "$(grep -c '^systemctl reload nginx$' "${CALL_LOG}")" '1' 'first reload count'

echo "TEST 3: unchanged apply performs no reload"
"${APPLY}" --root "${TEST_ROOT}" --reason "same ip" --now-epoch 1100
assert_eq "$(grep -c '^systemctl reload nginx$' "${CALL_LOG}")" '1' 'unchanged reload count'

echo "TEST 4: IP change adds previous grace and reloads"
printf '%s\n' '78.111.160.55' \
    >"${TEST_ROOT}/var/lib/router-ip-push/ips/AX3200.ipv4"
"${APPLY}" --root "${TEST_ROOT}" --reason "router ip changed" --now-epoch 2000
assert_contains "${ALLOWLIST}" '78.111.160.55/32'
assert_contains "${ALLOWLIST}" '78.111.155.187/32'
assert_contains "${ALLOWLIST}" 'previous grace until'
assert_eq "$(jq -r '.routers.AX3200.ip' "${GRACE}")" '78.111.155.187' 'grace previous ip'
assert_eq "$(jq -r '.routers.AX3200.expires_at_epoch' "${GRACE}")" "$((2000 + 4 * 3600))" 'grace expiry'
assert_eq "$(grep -c '^systemctl reload nginx$' "${CALL_LOG}")" '2' 'changed reload count'

echo "TEST 5: reconcile after grace expiry removes previous IP"
"${APPLY}" --root "${TEST_ROOT}" --reason "reconcile" --now-epoch "$((2000 + 4 * 3600 + 1))"
assert_contains "${ALLOWLIST}" '78.111.160.55/32'
assert_not_contains "${ALLOWLIST}" '78.111.155.187/32'
assert_eq "$(jq -r '.routers | length' "${GRACE}")" '0' 'expired grace count'
assert_eq "$(grep -c '^systemctl reload nginx$' "${CALL_LOG}")" '3' 'expiry reload count'

echo "TEST 6: failed nginx validation restores all previous files"
printf '%s\n' '78.111.170.99' \
    >"${TEST_ROOT}/var/lib/router-ip-push/ips/AX3200.ipv4"
cp "${ALLOWLIST}" "${TEST_ROOT}/allowlist.before-failure"
cp "${STATE}" "${TEST_ROOT}/state.before-failure"
cp "${GRACE}" "${TEST_ROOT}/grace.before-failure"
cp "${STREAM}" "${TEST_ROOT}/stream.before-failure"
cp "${BRIDGE}" "${TEST_ROOT}/bridge.before-failure"
export RIPH_TEST_NGINX_EXIT=1
if "${APPLY}" --root "${TEST_ROOT}" --reason "expected failure" --now-epoch 20000; then
    fail "apply unexpectedly succeeded while nginx stub failed"
fi
unset RIPH_TEST_NGINX_EXIT
cmp -s "${ALLOWLIST}" "${TEST_ROOT}/allowlist.before-failure" || fail "allowlist rollback mismatch"
cmp -s "${STATE}" "${TEST_ROOT}/state.before-failure" || fail "state rollback mismatch"
cmp -s "${GRACE}" "${TEST_ROOT}/grace.before-failure" || fail "grace rollback mismatch"
cmp -s "${STREAM}" "${TEST_ROOT}/stream.before-failure" || fail "stream rollback mismatch"
cmp -s "${BRIDGE}" "${TEST_ROOT}/bridge.before-failure" || fail "bridge rollback mismatch"

echo "TEST 7: routing-only config change triggers reload"
sed -i 's/PUBLIC_UPSTREAM="127.0.0.1:7443"/PUBLIC_UPSTREAM="127.0.0.1:7555"/' \
    "${TEST_ROOT}/etc/router-ip-push-hardening/config.env"
"${APPLY}" --root "${TEST_ROOT}" --reason "routing change" --now-epoch 21000
assert_contains "${STREAM}" 'server 127.0.0.1:7555;'
assert_eq "$(grep -c '^systemctl reload nginx$' "${CALL_LOG}")" '4' 'routing reload count'

echo "TEST 8: failed routing validation restores previous routing"
cp "${STREAM}" "${TEST_ROOT}/stream.before-routing-failure"
cp "${STATE}" "${TEST_ROOT}/state.before-routing-failure"
sed -i 's/PUBLIC_UPSTREAM="127.0.0.1:7555"/PUBLIC_UPSTREAM="127.0.0.1:7666"/' \
    "${TEST_ROOT}/etc/router-ip-push-hardening/config.env"
export RIPH_TEST_NGINX_EXIT=1
if "${APPLY}" --root "${TEST_ROOT}" --reason "routing failure" --now-epoch 22000; then
    fail "routing apply unexpectedly succeeded while nginx stub failed"
fi
unset RIPH_TEST_NGINX_EXIT
cmp -s "${STREAM}" "${TEST_ROOT}/stream.before-routing-failure" || fail "routing stream rollback mismatch"
cmp -s "${STATE}" "${TEST_ROOT}/state.before-routing-failure" || fail "routing state rollback mismatch"

echo "PASS: core tests"
