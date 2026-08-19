#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IGNORE="${ROOT}/src/usr/local/sbin/riph-fail2ban-ignore"
T="$(mktemp -d /tmp/riph-f2b-ignore.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/nginx/stream-enabled" \
    "${T}/var/lib/router-ip-push/ips"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '127.0.0.1/32 # localhost' '198.51.100.10/32 # static trusted test VPS' >"${T}/etc/router-ip-push-hardening/trusted-static.list"
printf '%s\n' '{"version":1,"routers":{}}' >"${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '192.0.2.25' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"

"${IGNORE}" --root "${T}" 192.0.2.25
"${IGNORE}" --root "${T}" 198.51.100.10
if "${IGNORE}" --root "${T}" 203.0.113.9; then
    echo 'FAIL: untrusted IP was ignored' >&2
    exit 1
fi

echo 'TEST F2BI2: current Router IP survives malformed hardening config'
printf '%s\n' 'BROKEN CONFIG CONTENT' >"${T}/etc/router-ip-push-hardening/config.env"
"${IGNORE}" --root "${T}" 192.0.2.25

echo 'TEST F2BI3: last-known-good allowlist survives malformed config'
cat >"${T}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<'EOF_ALLOW'
geo $router_ip_push_source_allowed {
        default 0;
        198.51.100.10/32   1; # static trusted test VPS
        198.51.100.0/24    1; # grace/static test range
}
EOF_ALLOW
"${IGNORE}" --root "${T}" 198.51.100.10
"${IGNORE}" --root "${T}" 198.51.100.77
if "${IGNORE}" --root "${T}" 203.0.113.9; then
    echo 'FAIL: malformed-config fallback ignored unrelated IP' >&2
    exit 1
fi

echo 'PASS: fail2ban ignore tests'
