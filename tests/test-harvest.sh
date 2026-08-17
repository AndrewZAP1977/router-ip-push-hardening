#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARVEST="${ROOT}/src/usr/local/sbin/riph-harvest"
T="$(mktemp -d /tmp/riph-harvest.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
mkdir -p "${T}/etc/router-ip-push-hardening" "${T}/var/log/nginx"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
LOG="${T}/var/log/nginx/stream-sni.log"
cat >"${LOG}" <<'LOG1'
2026-08-17T14:00:00+00:00 src=203.0.113.10 route=reject sni=- upstream=127.0.0.1:9 status=502 session=0.001
2026-08-17T14:00:01+00:00 src=203.0.113.11 route=fake_1 sni=treda.layerupzap.ru upstream=127.0.0.1:9543 status=200 session=1.000
LOG1

OUT="${T}/out.txt"
"${HARVEST}" --root "${T}" --all >"${OUT}"
grep -F 'total: 2' "${OUT}" >/dev/null
grep -F 'reject: 1' "${OUT}" >/dev/null
grep -F 'fake: 1' "${OUT}" >/dev/null

"${HARVEST}" --root "${T}" --checkpoint >/dev/null
cat >>"${LOG}" <<'LOG2'
2026-08-17T14:00:02+00:00 src=78.111.155.187 route=xray_1 sni=treda.layerupzap.ru upstream=127.0.0.1:8443 status=200 session=20.000
2026-08-17T14:00:03+00:00 src=198.51.100.7 route=www sni=nukla.layerupzap.ru upstream=127.0.0.1:7443 status=200 session=0.300
LOG2
"${HARVEST}" --root "${T}" >"${OUT}"
grep -F 'mode: since-checkpoint' "${OUT}" >/dev/null
grep -F 'total: 2' "${OUT}" >/dev/null
grep -F 'xray: 1' "${OUT}" >/dev/null
grep -F 'www: 1' "${OUT}" >/dev/null

echo 'PASS: harvest tests'
