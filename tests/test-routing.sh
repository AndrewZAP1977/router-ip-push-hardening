#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="${ROOT}/src/usr/local/sbin/riph-generate-routing"
T="$(mktemp -d /tmp/riph-routing-test.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p "${T}/etc/router-ip-push-hardening"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"

# Normal default is legacy compatibility OFF. Enable it explicitly for the
# compatibility half of this regression.
sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=0$/LEGACY_STREAM_AUDIT_COMPAT=1/' \
    "${T}/etc/router-ip-push-hardening/config.env"
"${GEN}" --root "${T}"

STREAM="${T}/etc/nginx/stream-enabled/stream.conf"
BRIDGE="${T}/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf"
grep -F 'log_format riph_stream_sni' "${STREAM}" >/dev/null
grep -F 'src=$remote_addr route=$sni_name' "${STREAM}" >/dev/null
grep -F 'access_log /var/log/nginx/stream-sni.log sni_watch buffer=32k flush=5s;' "${STREAM}" >/dev/null
grep -F 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${STREAM}" >/dev/null
[[ "$(grep -Fc 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${STREAM}")" == 1 ]] || { echo 'FAIL: unexpected RIPH audit access_log count' >&2; exit 1; }
[[ "$(grep -Fc 'access_log /var/log/nginx/stream-sni.log sni_watch buffer=32k flush=5s;' "${STREAM}")" == 1 ]] || { echo 'FAIL: legacy external audit compatibility missing' >&2; exit 1; }
! grep -F 'access_log /var/log/nginx/riph-stream-sni.log' "${BRIDGE}" >/dev/null || { echo 'FAIL: bridge traffic must not enter RIPH audit log' >&2; exit 1; }
grep -F 'public.example.invalid|0' "${STREAM}" >/dev/null
grep -F 'public.example.invalid|1' "${STREAM}" >/dev/null
grep -F 'private-a.example.invalid|1' "${STREAM}" >/dev/null
grep -F 'private-a.example.invalid|0' "${STREAM}" >/dev/null
grep -F 'private-b.example.invalid|1' "${STREAM}" >/dev/null
grep -F 'private-b.example.invalid|0' "${STREAM}" >/dev/null
grep -F 'default                                  reject;' "${STREAM}" >/dev/null
grep -F 'server 127.0.0.1:8443;' "${STREAM}" >/dev/null
grep -F 'server 127.0.0.1:8444;' "${STREAM}" >/dev/null
grep -F 'listen 127.0.0.1:9543 proxy_protocol;' "${BRIDGE}" >/dev/null
grep -F 'proxy_pass 127.0.0.1:9443;' "${BRIDGE}" >/dev/null
grep -F 'listen 127.0.0.1:9544 proxy_protocol;' "${BRIDGE}" >/dev/null
grep -F 'proxy_pass 127.0.0.1:9444;' "${BRIDGE}" >/dev/null

# Quiesce mode must stop only the legacy external audit feed. The dedicated RIPH
# route-aware log remains exactly once on the external :443 server, and bridge
# sessions must still not enter it.
sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=1$/LEGACY_STREAM_AUDIT_COMPAT=0/' \
    "${T}/etc/router-ip-push-hardening/config.env"
"${GEN}" \
    --root "${T}" \
    --stream-output /etc/nginx/stream-enabled/stream-quiesced.conf \
    --bridge-output /etc/nginx/stream-enabled/bridges-quiesced.conf

QUIESCED_STREAM="${T}/etc/nginx/stream-enabled/stream-quiesced.conf"
QUIESCED_BRIDGE="${T}/etc/nginx/stream-enabled/bridges-quiesced.conf"
[[ "$(grep -Fc 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${QUIESCED_STREAM}")" == 1 ]] \
    || { echo 'FAIL: quiesced routing lost or duplicated RIPH audit log' >&2; exit 1; }
! grep -F 'access_log /var/log/nginx/stream-sni.log sni_watch' "${QUIESCED_STREAM}" >/dev/null \
    || { echo 'FAIL: quiesced routing still feeds legacy external audit log' >&2; exit 1; }
! grep -F 'access_log /var/log/nginx/riph-stream-sni.log' "${QUIESCED_BRIDGE}" >/dev/null \
    || { echo 'FAIL: quiesced bridge traffic entered RIPH audit log' >&2; exit 1; }

echo 'PASS: routing tests'
