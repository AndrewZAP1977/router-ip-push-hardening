#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT}/src/usr/local/sbin/riph-apply"
ROLLBACK="${ROOT}/src/usr/local/sbin/riph-rollback"
T="$(mktemp -d /tmp/riph-rollback-test.XXXXXX)"
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
printf '%s\n' '192.0.2.25' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"

CALL_LOG="${T}/calls.log"
cat >"${T}/usr/local/bin/nginx-stub" <<EOF_STUB
#!/usr/bin/env bash
echo "nginx \$*" >>"${CALL_LOG}"
exit "\${RIPH_TEST_NGINX_EXIT:-0}"
EOF_STUB
cat >"${T}/usr/local/bin/systemctl-stub" <<EOF_STUB
#!/usr/bin/env bash
echo "systemctl \$*" >>"${CALL_LOG}"
exit "\${RIPH_TEST_SYSTEMCTL_EXIT:-0}"
EOF_STUB
chmod +x "${T}/usr/local/bin/nginx-stub" "${T}/usr/local/bin/systemctl-stub"
export RIPH_NGINX_BIN="${T}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T}/usr/local/bin/systemctl-stub"

"${APPLY}" --root "${T}" --reason initial --now-epoch 1000 >/dev/null
STREAM="${T}/etc/nginx/stream-enabled/stream.conf"
grep -F 'server 127.0.0.1:7443;' "${STREAM}" >/dev/null

sed -i 's/PUBLIC_UPSTREAM="127.0.0.1:7443"/PUBLIC_UPSTREAM="127.0.0.1:7555"/' \
    "${T}/etc/router-ip-push-hardening/config.env"
"${APPLY}" --root "${T}" --reason route-7555 --now-epoch 2000 >/dev/null
grep -F 'server 127.0.0.1:7555;' "${STREAM}" >/dev/null

sed -i 's/PUBLIC_UPSTREAM="127.0.0.1:7555"/PUBLIC_UPSTREAM="127.0.0.1:7666"/' \
    "${T}/etc/router-ip-push-hardening/config.env"
"${APPLY}" --root "${T}" --reason route-7666 --now-epoch 3000 >/dev/null
grep -F 'server 127.0.0.1:7666;' "${STREAM}" >/dev/null

BACKUP_ID="$("${ROLLBACK}" --root "${T}" --list | awk 'NR == 1 {print $1}')"
[[ -n "${BACKUP_ID}" ]] || fail 'rollback list returned no backup'
"${ROLLBACK}" --root "${T}" --backup "${BACKUP_ID}" >/dev/null
grep -F 'server 127.0.0.1:7555;' "${STREAM}" >/dev/null || fail 'successful rollback did not restore previous routing'

sed -i 's/PUBLIC_UPSTREAM="127.0.0.1:7666"/PUBLIC_UPSTREAM="127.0.0.1:7777"/' \
    "${T}/etc/router-ip-push-hardening/config.env"
"${APPLY}" --root "${T}" --reason route-7777 --now-epoch 4000 >/dev/null
grep -F 'server 127.0.0.1:7777;' "${STREAM}" >/dev/null
cp "${STREAM}" "${T}/stream.before-failed-rollback"

export RIPH_TEST_NGINX_EXIT=1
if "${ROLLBACK}" --root "${T}" --backup "${BACKUP_ID}"; then
    fail 'rollback unexpectedly succeeded while nginx validation failed'
fi
unset RIPH_TEST_NGINX_EXIT
cmp -s "${STREAM}" "${T}/stream.before-failed-rollback" || fail 'failed rollback did not restore safety snapshot'

echo 'PASS: rollback tests'
