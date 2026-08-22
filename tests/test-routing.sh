#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="${ROOT}/src/usr/local/sbin/riph-generate-routing"
BASE="$(mktemp -d /tmp/riph-routing-test.XXXXXX)"
trap 'rm -rf "${BASE}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

new_root() {
    local root="$1"
    mkdir -p "${root}/etc/router-ip-push-hardening"
    cp "${ROOT}/config/config.env.example" \
        "${root}/etc/router-ip-push-hardening/config.env"
}

expect_fail() {
    local label="$1"
    shift
    if "$@" >/dev/null 2>&1; then
        fail "${label}: command unexpectedly succeeded"
    fi
}

MAIN="${BASE}/main"
new_root "${MAIN}"
CONFIG="${MAIN}/etc/router-ip-push-hardening/config.env"
sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=0$/LEGACY_STREAM_AUDIT_COMPAT=1/' "${CONFIG}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=2/' "${CONFIG}"
cat >>"${CONFIG}" <<'EOF'
PASSTHROUGH_SNI_1="cloud.example.invalid"
PASSTHROUGH_UPSTREAM_1="127.0.0.1:10443"
PASSTHROUGH_SNI_2="files.example.invalid"
PASSTHROUGH_UPSTREAM_2="127.0.0.1:11443"
EOF

"${GEN}" --root "${MAIN}"
STREAM="${MAIN}/etc/nginx/stream-enabled/stream.conf"
BRIDGE="${MAIN}/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf"

grep -F 'log_format riph_stream_sni' "${STREAM}" >/dev/null
grep -F 'src=$remote_addr route=$sni_name' "${STREAM}" >/dev/null
grep -F 'access_log /var/log/nginx/stream-sni.log sni_watch buffer=32k flush=5s;' "${STREAM}" >/dev/null
grep -F 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${STREAM}" >/dev/null
[[ "$(grep -Fc 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${STREAM}")" == 1 ]] \
    || fail 'unexpected RIPH audit access_log count'
[[ "$(grep -Fc 'access_log /var/log/nginx/stream-sni.log sni_watch buffer=32k flush=5s;' "${STREAM}")" == 1 ]] \
    || fail 'legacy external audit compatibility missing'
! grep -F 'access_log /var/log/nginx/riph-stream-sni.log' "${BRIDGE}" >/dev/null \
    || fail 'bridge traffic must not enter RIPH audit log'

# Existing public/private/default routing contract must stay unchanged.
grep -Eq '^[[:space:]]+public\.example\.invalid\|0[[:space:]]+www;$' "${STREAM}" || fail 'public |0 route changed'
grep -Eq '^[[:space:]]+public\.example\.invalid\|1[[:space:]]+www;$' "${STREAM}" || fail 'public |1 route changed'
grep -Eq '^[[:space:]]+private-a\.example\.invalid\|1[[:space:]]+xray_1;$' "${STREAM}" || fail 'private trusted route changed'
grep -Eq '^[[:space:]]+private-a\.example\.invalid\|0[[:space:]]+fake_1;$' "${STREAM}" || fail 'private untrusted route changed'
grep -Eq '^[[:space:]]+private-b\.example\.invalid\|1[[:space:]]+xray_2;$' "${STREAM}" || fail 'second private trusted route changed'
grep -Eq '^[[:space:]]+private-b\.example\.invalid\|0[[:space:]]+fake_2;$' "${STREAM}" || fail 'second private untrusted route changed'
grep -F 'default                                  reject;' "${STREAM}" >/dev/null || fail 'default reject changed'

# Passthrough routes must ignore Router IP Push trust: both trust states hit one backend.
grep -Eq '^[[:space:]]+cloud\.example\.invalid\|0[[:space:]]+passthrough_1;$' "${STREAM}" || fail 'passthrough 1 |0 missing'
grep -Eq '^[[:space:]]+cloud\.example\.invalid\|1[[:space:]]+passthrough_1;$' "${STREAM}" || fail 'passthrough 1 |1 missing'
grep -Eq '^[[:space:]]+files\.example\.invalid\|0[[:space:]]+passthrough_2;$' "${STREAM}" || fail 'passthrough 2 |0 missing'
grep -Eq '^[[:space:]]+files\.example\.invalid\|1[[:space:]]+passthrough_2;$' "${STREAM}" || fail 'passthrough 2 |1 missing'
grep -F 'upstream passthrough_1' "${STREAM}" >/dev/null || fail 'passthrough 1 upstream missing'
grep -F 'server 127.0.0.1:10443;' "${STREAM}" >/dev/null || fail 'passthrough 1 backend missing'
grep -F 'upstream passthrough_2' "${STREAM}" >/dev/null || fail 'passthrough 2 upstream missing'
grep -F 'server 127.0.0.1:11443;' "${STREAM}" >/dev/null || fail 'passthrough 2 backend missing'

grep -F 'server 127.0.0.1:8443;' "${STREAM}" >/dev/null
grep -F 'server 127.0.0.1:8444;' "${STREAM}" >/dev/null
grep -F 'listen 127.0.0.1:9543 proxy_protocol;' "${BRIDGE}" >/dev/null
grep -F 'proxy_pass 127.0.0.1:9443;' "${BRIDGE}" >/dev/null
grep -F 'listen 127.0.0.1:9544 proxy_protocol;' "${BRIDGE}" >/dev/null
grep -F 'proxy_pass 127.0.0.1:9444;' "${BRIDGE}" >/dev/null

# Quiesce mode affects only the legacy audit feed, not routing classes.
sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=1$/LEGACY_STREAM_AUDIT_COMPAT=0/' "${CONFIG}"
"${GEN}" \
    --root "${MAIN}" \
    --stream-output /etc/nginx/stream-enabled/stream-quiesced.conf \
    --bridge-output /etc/nginx/stream-enabled/bridges-quiesced.conf
QUIESCED_STREAM="${MAIN}/etc/nginx/stream-enabled/stream-quiesced.conf"
QUIESCED_BRIDGE="${MAIN}/etc/nginx/stream-enabled/bridges-quiesced.conf"
[[ "$(grep -Fc 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${QUIESCED_STREAM}")" == 1 ]] \
    || fail 'quiesced routing lost or duplicated RIPH audit log'
! grep -F 'access_log /var/log/nginx/stream-sni.log sni_watch' "${QUIESCED_STREAM}" >/dev/null \
    || fail 'quiesced routing still feeds legacy external audit log'
! grep -F 'access_log /var/log/nginx/riph-stream-sni.log' "${QUIESCED_BRIDGE}" >/dev/null \
    || fail 'quiesced bridge traffic entered RIPH audit log'
grep -Eq 'cloud\.example\.invalid\|0[[:space:]]+passthrough_1;' "${QUIESCED_STREAM}" \
    || fail 'quiesced routing lost passthrough route'

# Default zero routes and pre-feature configs (setting absent) stay compatible.
ZERO="${BASE}/zero"
new_root "${ZERO}"
"${GEN}" --root "${ZERO}"
! grep -F 'passthrough_' "${ZERO}/etc/nginx/stream-enabled/stream.conf" >/dev/null \
    || fail 'PASSTHROUGH_ROUTE_COUNT=0 generated passthrough routing'

LEGACY="${BASE}/legacy-config"
new_root "${LEGACY}"
sed -i '/^PASSTHROUGH_ROUTE_COUNT=/d' "${LEGACY}/etc/router-ip-push-hardening/config.env"
"${GEN}" --root "${LEGACY}"
! grep -F 'passthrough_' "${LEGACY}/etc/nginx/stream-enabled/stream.conf" >/dev/null \
    || fail 'config without PASSTHROUGH_ROUTE_COUNT generated passthrough routing'

# Collision checks across every route class.
COL_PUBLIC="${BASE}/collision-public"
new_root "${COL_PUBLIC}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=1/' "${COL_PUBLIC}/etc/router-ip-push-hardening/config.env"
cat >>"${COL_PUBLIC}/etc/router-ip-push-hardening/config.env" <<'EOF'
PASSTHROUGH_SNI_1="public.example.invalid"
PASSTHROUGH_UPSTREAM_1="127.0.0.1:10443"
EOF
expect_fail 'public/passthrough collision accepted' "${GEN}" --root "${COL_PUBLIC}"

COL_PRIVATE="${BASE}/collision-private"
new_root "${COL_PRIVATE}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=1/' "${COL_PRIVATE}/etc/router-ip-push-hardening/config.env"
cat >>"${COL_PRIVATE}/etc/router-ip-push-hardening/config.env" <<'EOF'
PASSTHROUGH_SNI_1="private-a.example.invalid"
PASSTHROUGH_UPSTREAM_1="127.0.0.1:10443"
EOF
expect_fail 'private/passthrough collision accepted' "${GEN}" --root "${COL_PRIVATE}"

COL_DUP="${BASE}/collision-passthrough"
new_root "${COL_DUP}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=2/' "${COL_DUP}/etc/router-ip-push-hardening/config.env"
cat >>"${COL_DUP}/etc/router-ip-push-hardening/config.env" <<'EOF'
PASSTHROUGH_SNI_1="same.example.invalid"
PASSTHROUGH_UPSTREAM_1="127.0.0.1:10443"
PASSTHROUGH_SNI_2="same.example.invalid"
PASSTHROUGH_UPSTREAM_2="127.0.0.1:11443"
EOF
expect_fail 'duplicate passthrough SNI accepted' "${GEN}" --root "${COL_DUP}"

# Passthrough backend is deliberately loopback-only and port-bounded.
BAD_HOST="${BASE}/bad-host"
new_root "${BAD_HOST}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=1/' "${BAD_HOST}/etc/router-ip-push-hardening/config.env"
cat >>"${BAD_HOST}/etc/router-ip-push-hardening/config.env" <<'EOF'
PASSTHROUGH_SNI_1="cloud.example.invalid"
PASSTHROUGH_UPSTREAM_1="192.0.2.10:10443"
EOF
expect_fail 'non-loopback passthrough backend accepted' "${GEN}" --root "${BAD_HOST}"

BAD_PORT="${BASE}/bad-port"
new_root "${BAD_PORT}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=1/' "${BAD_PORT}/etc/router-ip-push-hardening/config.env"
cat >>"${BAD_PORT}/etc/router-ip-push-hardening/config.env" <<'EOF'
PASSTHROUGH_SNI_1="cloud.example.invalid"
PASSTHROUGH_UPSTREAM_1="127.0.0.1:65536"
EOF
expect_fail 'out-of-range passthrough port accepted' "${GEN}" --root "${BAD_PORT}"

BAD_COUNT="${BASE}/bad-count"
new_root "${BAD_COUNT}"
sed -i 's/^PASSTHROUGH_ROUTE_COUNT=0$/PASSTHROUGH_ROUTE_COUNT=21/' "${BAD_COUNT}/etc/router-ip-push-hardening/config.env"
expect_fail 'oversized passthrough route count accepted' "${GEN}" --root "${BAD_COUNT}"

echo 'PASS: routing tests'
