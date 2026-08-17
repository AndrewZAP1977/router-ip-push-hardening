#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GEN="${ROOT}/src/usr/local/sbin/riph-generate-routing"
T="$(mktemp -d /tmp/riph-routing-test.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p "${T}/etc/router-ip-push-hardening"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
"${GEN}" --root "${T}"

STREAM="${T}/etc/nginx/stream-enabled/stream.conf"
BRIDGE="${T}/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf"
grep -F 'log_format riph_stream_sni' "${STREAM}" >/dev/null
grep -F 'src=$remote_addr route=$sni_name' "${STREAM}" >/dev/null
grep -F 'access_log /var/log/nginx/stream-sni.log riph_stream_sni;' "${STREAM}" >/dev/null
grep -F 'nukla.layerupzap.ru|0' "${STREAM}" >/dev/null
grep -F 'nukla.layerupzap.ru|1' "${STREAM}" >/dev/null
grep -F 'treda.layerupzap.ru|1' "${STREAM}" >/dev/null
grep -F 'treda.layerupzap.ru|0' "${STREAM}" >/dev/null
grep -F 'trongo.layerupzap.ru|1' "${STREAM}" >/dev/null
grep -F 'trongo.layerupzap.ru|0' "${STREAM}" >/dev/null
grep -F 'default                                  reject;' "${STREAM}" >/dev/null
grep -F 'server 127.0.0.1:8443;' "${STREAM}" >/dev/null
grep -F 'server 127.0.0.1:8444;' "${STREAM}" >/dev/null
grep -F 'listen 127.0.0.1:9543 proxy_protocol;' "${BRIDGE}" >/dev/null
grep -F 'proxy_pass 127.0.0.1:9443;' "${BRIDGE}" >/dev/null
grep -F 'listen 127.0.0.1:9544 proxy_protocol;' "${BRIDGE}" >/dev/null
grep -F 'proxy_pass 127.0.0.1:9444;' "${BRIDGE}" >/dev/null

echo 'PASS: routing tests'
