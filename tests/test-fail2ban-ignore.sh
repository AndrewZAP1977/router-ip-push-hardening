#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IGNORE="${ROOT}/src/usr/local/sbin/riph-fail2ban-ignore"
T="$(mktemp -d /tmp/riph-f2b-ignore.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/etc/router-ip-push-hardening" "${T}/var/lib/router-ip-push/ips"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '127.0.0.1/32 # localhost' '5.61.39.137/32 # VPS_GR' >"${T}/etc/router-ip-push-hardening/trusted-static.list"
printf '%s\n' '{"version":1,"routers":{}}' >"${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '78.111.155.187' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"

"${IGNORE}" --root "${T}" 78.111.155.187
"${IGNORE}" --root "${T}" 5.61.39.137
if "${IGNORE}" --root "${T}" 203.0.113.9; then
    echo 'FAIL: untrusted IP was ignored' >&2
    exit 1
fi

echo 'PASS: fail2ban ignore tests'
