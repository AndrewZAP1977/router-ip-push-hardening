#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADMIN="${ROOT}/src/usr/local/sbin/riph-admin"
T="$(mktemp -d /tmp/riph-admin-test.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/nginx/stream-enabled" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/var/lib/router-ip-push/state" \
    "${T}/var/log/nginx" \
    "${T}/usr/local/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '127.0.0.1/32 # localhost' >"${T}/etc/router-ip-push-hardening/trusted-static.list"
printf '%s\n' '{"version":1,"routers":{}}' >"${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '78.111.155.187' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
printf '%s\n' '{"version":1,"router_id":"AX3200","source_ip":"78.111.155.187","last_seen":"2026-08-17T14:00:00Z"}' >"${T}/var/lib/router-ip-push/state/AX3200.json"
: >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
: >"${T}/etc/router-ip-push-hardening/manual-deny-all.list"

CALL_LOG="${T}/calls.log"
cat >"${T}/usr/local/bin/nginx-stub" <<EOF_STUB
#!/usr/bin/env bash
echo "nginx \$*" >>"${CALL_LOG}"
exit 0
EOF_STUB
cat >"${T}/usr/local/bin/systemctl-stub" <<EOF_STUB
#!/usr/bin/env bash
echo "systemctl \$*" >>"${CALL_LOG}"
exit 0
EOF_STUB
cat >"${T}/usr/local/bin/ufw-stub" <<EOF_STUB
#!/usr/bin/env bash
echo "ufw \$*" >>"${CALL_LOG}"
exit 0
EOF_STUB
chmod +x "${T}/usr/local/bin/"*-stub
export RIPH_NGINX_BIN="${T}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T}/usr/local/bin/systemctl-stub"
export RIPH_UFW_BIN="${T}/usr/local/bin/ufw-stub"

"${ADMIN}" --root "${T}" apply >/dev/null
STATUS_OUT="${T}/status.txt"
"${ADMIN}" --root "${T}" status >"${STATUS_OUT}"
grep -F 'current=78.111.155.187' "${STATUS_OUT}" >/dev/null || fail 'status missing current router IP'
grep -F 'last_seen=2026-08-17T14:00:00Z' "${STATUS_OUT}" >/dev/null || fail 'status missing last_seen'

echo 'TEST A1: transactional trusted add/remove'
"${ADMIN}" --root "${T}" trusted-add 203.0.113.10 'temporary admin test' >/dev/null
grep -F '203.0.113.10/32 # temporary admin test' "${T}/etc/router-ip-push-hardening/trusted-static.list" >/dev/null || fail 'trusted add missing'
grep -F '203.0.113.10/32' "${T}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" >/dev/null || fail 'trusted add not applied'
"${ADMIN}" --root "${T}" trusted-remove 203.0.113.10 >/dev/null
! grep -F '203.0.113.10' "${T}/etc/router-ip-push-hardening/trusted-static.list" >/dev/null || fail 'trusted remove failed'

echo 'TEST A2: manual deny add/remove through managed sync'
"${ADMIN}" --root "${T}" deny443-add 198.51.100.0/24 scanner >/dev/null
grep -F '198.51.100.0/24 # scanner' "${T}/etc/router-ip-push-hardening/manual-deny-443.list" >/dev/null || fail 'deny443 add missing'
grep -F 'ufw prepend deny proto tcp from 198.51.100.0/24 to any port 443 comment riph-manual-443' "${CALL_LOG}" >/dev/null || fail 'deny443 add not applied'
"${ADMIN}" --root "${T}" deny443-remove 198.51.100.0/24 >/dev/null
grep -F 'ufw --force delete deny proto tcp from 198.51.100.0/24 to any port 443 comment riph-manual-443' "${CALL_LOG}" >/dev/null || fail 'deny443 remove not applied'

echo 'TEST A3: trusted overlap is rejected and list restored'
cp "${T}/etc/router-ip-push-hardening/manual-deny-443.list" "${T}/deny.before"
if "${ADMIN}" --root "${T}" deny443-add 78.111.0.0/16 overlap; then
    fail 'trusted-overlapping deny unexpectedly succeeded'
fi
cmp -s "${T}/deny.before" "${T}/etc/router-ip-push-hardening/manual-deny-443.list" || fail 'failed deny edit was not rolled back'

echo 'TEST A4: harvest through admin'
cat >"${T}/var/log/nginx/stream-sni.log" <<'EOF_LOG'
2026-08-17T14:00:00+00:00 src=203.0.113.10 route=reject sni=- upstream=127.0.0.1:9 status=502 session=0.001
2026-08-17T14:00:01+00:00 src=78.111.155.187 route=xray_1 sni=treda.layerupzap.ru upstream=127.0.0.1:8443 status=200 session=1.000
EOF_LOG
"${ADMIN}" --root "${T}" harvest --all >"${T}/harvest.txt"
grep -F 'total: 2' "${T}/harvest.txt" >/dev/null || fail 'harvest total mismatch'
grep -F 'reject: 1' "${T}/harvest.txt" >/dev/null || fail 'harvest reject mismatch'

echo 'PASS: admin tests'
