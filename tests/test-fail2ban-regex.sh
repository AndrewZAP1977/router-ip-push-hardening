#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! command -v fail2ban-regex >/dev/null 2>&1; then
    echo 'SKIP: fail2ban-regex not installed locally'
    exit 0
fi

T="$(mktemp -d /tmp/riph-f2b-regex.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
cat >"${T}/stream.log" <<'LOG'
2026-08-17T14:00:00+00:00 src=203.0.113.10 route=reject sni=- upstream=127.0.0.1:9 status=502 session=0.001
2026-08-17T14:00:01+00:00 src=203.0.113.11 route=fake_1 sni=private-a.example.net upstream=127.0.0.1:9543 status=200 session=1.000
2026-08-17T14:00:02+00:00 src=203.0.113.12 route=fake_2 sni=private-b.example.net upstream=127.0.0.1:9544 status=200 session=1.100
2026-08-17T14:00:03+00:00 src=192.0.2.25 route=xray_1 sni=private-a.example.net upstream=127.0.0.1:8443 status=200 session=20.000
2026-08-17T14:00:04+00:00 src=198.51.100.7 route=www sni=public.example.net upstream=127.0.0.1:7443 status=200 session=0.300
2026-08-17T14:00:05+00:00 src=203.0.113.99 route=passthrough_1 sni=cloud.example.net upstream=127.0.0.1:10443 status=200 session=4.200
LOG

reject_out="$(fail2ban-regex "${T}/stream.log" "${ROOT}/src/etc/fail2ban/filter.d/riph-nginx-stream-sni-reject.conf" --usedns=no -o ip | sort -u)"
[[ "${reject_out}" == '203.0.113.10' ]] || { echo "FAIL: reject filter output: ${reject_out}" >&2; exit 1; }

private_out="$(fail2ban-regex "${T}/stream.log" "${ROOT}/src/etc/fail2ban/filter.d/riph-nginx-stream-private-sni-abuse.conf" --usedns=no -o ip | sort -u)"
expected=$'203.0.113.11\n203.0.113.12'
[[ "${private_out}" == "${expected}" ]] || { echo "FAIL: private filter output: ${private_out}" >&2; exit 1; }

echo 'PASS: fail2ban regex tests'
