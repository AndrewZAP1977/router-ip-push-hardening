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
    "${T}/usr/local/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '127.0.0.1/32 # localhost' >"${T}/etc/router-ip-push-hardening/trusted-static.list"
printf '%s\n' '{"version":1,"routers":{}}' >"${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '78.111.155.187' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
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

echo 'PASS: admin tests'
