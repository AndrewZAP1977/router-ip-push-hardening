#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BOOTSTRAP="${ROOT}/tools/bootstrap-config-from-stream.sh"
T="$(mktemp -d /tmp/riph-bootstrap-stream.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_dirs() {
    local root="$1"
    mkdir -p \
        "${root}/etc/nginx/stream-enabled" \
        "${root}/etc/nginx/sites-available"
}

write_reality_site() {
    local root="$1" domain="$2" port="$3"
    cat >"${root}/etc/nginx/sites-available/reality.conf" <<EOF
server
{
    server_name ${domain};
    listen 127.0.0.1:${port} ssl;
}
EOF
}

write_xhttp_site() {
    local root="$1" domain="$2" port="$3"
    cat >"${root}/etc/nginx/sites-available/xhttp.conf" <<EOF
server
{
    server_name ${domain};
    listen 127.0.0.1:${port} ssl;
}
EOF
}

ONE="${T}/one"
make_dirs "${ONE}"
cat >"${ONE}/etc/nginx/stream-enabled/stream.conf" <<'EOF_ONE'
map $ssl_preread_server_name $sni_name
{
    hostnames;
    public.example.net      www;
    reality.example.net     xray;
    default                 reject;
}

upstream www
{
    server 127.0.0.1:7443;
}

upstream xray
{
    server 127.0.0.1:8443;
}

upstream reject
{
    server 127.0.0.1:9;
}

server
{
    proxy_protocol on;
    listen 443;
    listen [::]:443;
    proxy_pass $sni_name;
    ssl_preread on;
}
EOF_ONE
write_reality_site "${ONE}" reality.example.net 9443
cp "${ONE}/etc/nginx/stream-enabled/stream.conf" "${ONE}/stream.before"

echo 'TEST B1: bootstrap standard Reality-only stream config'
bash "${BOOTSTRAP}" \
    --root "${ONE}" \
    --output "${ONE}/config.env" >/dev/null
cmp -s "${ONE}/stream.before" "${ONE}/etc/nginx/stream-enabled/stream.conf" \
    || fail 'bootstrap modified source stream.conf'
grep -Fx 'ROUTER_IDS=""' "${ONE}/config.env" >/dev/null || fail 'explicit router IDs were not cleared'
grep -Fx 'PUBLIC_SNI="public.example.net"' "${ONE}/config.env" >/dev/null || fail 'public SNI import mismatch'
grep -Fx 'PUBLIC_UPSTREAM="127.0.0.1:7443"' "${ONE}/config.env" >/dev/null || fail 'public upstream import mismatch'
grep -Fx 'PRIVATE_ROUTE_COUNT=1' "${ONE}/config.env" >/dev/null || fail 'Reality-only route count mismatch'
grep -Fx 'PRIVATE_SNI_1="reality.example.net"' "${ONE}/config.env" >/dev/null || fail 'Reality SNI import mismatch'
grep -Fx 'XRAY_UPSTREAM_1="127.0.0.1:8443"' "${ONE}/config.env" >/dev/null || fail 'Reality upstream import mismatch'
grep -Fx 'FAKE_SITE_UPSTREAM_1="127.0.0.1:9443"' "${ONE}/config.env" >/dev/null || fail 'Reality fake-site import mismatch'

TWO="${T}/two"
make_dirs "${TWO}"
cat >"${TWO}/etc/nginx/stream-enabled/stream.conf" <<'EOF_TWO'
map $ssl_preread_server_name $sni_name
{
    hostnames;
    public.example.net      www;
    reality.example.net     xray;
    xhttp.example.net       xray2;
    default                 reject;
}

upstream www { server 127.0.0.1:7443; }
upstream xray { server 127.0.0.1:8443; }
upstream reject { server 127.0.0.1:9; }
upstream xray2 { server 127.0.0.1:8444; }

server
{
    proxy_protocol on;
    listen 443;
    listen [::]:443;
    proxy_pass $sni_name;
    ssl_preread on;
}
EOF_TWO
write_reality_site "${TWO}" reality.example.net 9443
write_xhttp_site "${TWO}" xhttp.example.net 9444

echo 'TEST B2: bootstrap standard Reality + XHTTP stream config'
bash "${BOOTSTRAP}" \
    --root "${TWO}" \
    --output "${TWO}/config.env" >/dev/null
grep -Fx 'PRIVATE_ROUTE_COUNT=2' "${TWO}/config.env" >/dev/null || fail 'two-route count mismatch'
grep -Fx 'PRIVATE_SNI_2="xhttp.example.net"' "${TWO}/config.env" >/dev/null || fail 'XHTTP SNI import mismatch'
grep -Fx 'XRAY_UPSTREAM_2="127.0.0.1:8444"' "${TWO}/config.env" >/dev/null || fail 'XHTTP upstream import mismatch'
grep -Fx 'FAKE_SITE_UPSTREAM_2="127.0.0.1:9444"' "${TWO}/config.env" >/dev/null || fail 'XHTTP fake-site import mismatch'

BAD="${T}/bad"
make_dirs "${BAD}"
cat >"${BAD}/etc/nginx/stream-enabled/stream.conf" <<'EOF_BAD'
map $ssl_preread_server_name $sni_name
{
    public.example.net  www;
    reality.example.net custom_target;
    default reject;
}
upstream www { server 127.0.0.1:7443; }
upstream xray { server 127.0.0.1:8443; }
upstream reject { server 127.0.0.1:9; }
server
{
    listen 443;
    proxy_pass $sni_name;
    ssl_preread on;
}
EOF_BAD
write_reality_site "${BAD}" reality.example.net 9443

echo 'TEST B3: unknown map shape fails closed'
if bash "${BOOTSTRAP}" --root "${BAD}" --output "${BAD}/config.env" >/dev/null 2>&1; then
    fail 'bootstrap accepted unsupported map target'
fi
[[ ! -e "${BAD}/config.env" ]] || fail 'failed bootstrap wrote an output config'

MISMATCH="${T}/mismatch"
make_dirs "${MISMATCH}"
cp "${ONE}/stream.before" "${MISMATCH}/etc/nginx/stream-enabled/stream.conf"
write_reality_site "${MISMATCH}" wrong.example.net 9443

echo 'TEST B4: fake-site/SNI mismatch fails closed'
if bash "${BOOTSTRAP}" --root "${MISMATCH}" --output "${MISMATCH}/config.env" >/dev/null 2>&1; then
    fail 'bootstrap accepted fake-site server_name mismatch'
fi
[[ ! -e "${MISMATCH}/config.env" ]] || fail 'mismatched bootstrap wrote an output config'

echo 'PASS: stream bootstrap tests'
