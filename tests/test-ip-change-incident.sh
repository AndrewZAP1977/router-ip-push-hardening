#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RECONCILE="${ROOT}/src/usr/local/sbin/riph-reconcile"
T="$(mktemp -d /tmp/riph-ip-change-incident.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/nginx/stream-enabled" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/var/lib/router-ip-push/state" \
    "${T}/usr/local/bin"

cp "${ROOT}/config/config.env.example" \
   "${T}/etc/router-ip-push-hardening/config.env"
cp "${ROOT}/config/trusted-static.list.example" \
   "${T}/etc/router-ip-push-hardening/trusted-static.list"
cp "${ROOT}/config/previous-ip-grace.json.example" \
   "${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
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
cat >"${T}/usr/local/bin/ufw-stub" <<'EOF_STUB'
#!/usr/bin/env bash
# This regression has empty manual-deny lists. The production helper validates
# UFW availability fail-closed, so provide a harmless test-root UFW.
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    printf '%s\n' 'Status: active'
fi
exit 0
EOF_STUB
chmod +x "${T}/usr/local/bin/nginx-stub" \
         "${T}/usr/local/bin/systemctl-stub" \
         "${T}/usr/local/bin/ufw-stub"

export RIPH_NGINX_BIN="${T}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T}/usr/local/bin/systemctl-stub"
export RIPH_UFW_BIN="${T}/usr/local/bin/ufw-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${T}/usr/local/bin/fail2ban-not-installed"

OLD_IP='192.0.2.25'
NEW_IP='192.0.2.26'
ALLOW="${T}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
GRACE="${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
STATE="${T}/etc/router-ip-push-hardening/last-apply-state.json"
IP_FILE="${T}/var/lib/router-ip-push/ips/AX3200.ipv4"

printf '%s\n' "${OLD_IP}" >"${IP_FILE}"
printf '%s\n' "{\"version\":1,\"router_id\":\"AX3200\",\"source_ip\":\"${OLD_IP}\",\"last_seen\":\"2026-08-17T03:51:00Z\"}" \
    >"${T}/var/lib/router-ip-push/state/AX3200.json"

# Establish the previously working state.
bash "${RECONCILE}" --root "${T}" --reason 'IP-change baseline' --now-epoch 1000

grep -Fq "${OLD_IP}/32" "${ALLOW}" || fail 'baseline old IP is not trusted'
[[ "$(jq -r '.routers.AX3200.current_ip' "${STATE}")" == "${OLD_IP}" ]] \
    || fail 'baseline last-apply state is wrong'

# Model the receiver accurately: write a temporary file and atomically replace
# AX3200.ipv4, then update state. This is the transition that the path unit must
# cause riph-reconcile to consume.
tmp_ip="${IP_FILE}.receiver.$$"
printf '%s\n' "${NEW_IP}" >"${tmp_ip}"
mv -f "${tmp_ip}" "${IP_FILE}"
printf '%s\n' "{\"version\":1,\"router_id\":\"AX3200\",\"source_ip\":\"${NEW_IP}\",\"last_seen\":\"2026-08-17T17:38:12Z\"}" \
    >"${T}/var/lib/router-ip-push/state/AX3200.json"

bash "${RECONCILE}" --root "${T}" --reason 'Router IP Push changed AX3200' --now-epoch 2000

# The new address must become trusted on the first reconcile, while the old one
# remains trusted only as previous-IP grace. This prevents the new current IP
# from being routed to fake_1/fake_2.
grep -Fq "${NEW_IP}/32" "${ALLOW}" || fail 'new Router IP did not become trusted immediately'
grep -Fq "${OLD_IP}/32" "${ALLOW}" || fail 'old Router IP was not retained for grace'
grep -Fq 'router-ip-push:AX3200 current' "${ALLOW}" || fail 'new IP is not marked current'
grep -Fq 'previous grace until' "${ALLOW}" || fail 'old IP is not marked grace'

[[ "$(jq -r '.routers.AX3200.current_ip' "${STATE}")" == "${NEW_IP}" ]] \
    || fail 'last-apply state did not advance to new IP'
[[ "$(jq -r '.routers.AX3200.ip' "${GRACE}")" == "${OLD_IP}" ]] \
    || fail 'grace state did not record old IP'
[[ "$(jq -r '.routers.AX3200.expires_at_epoch' "${GRACE}")" == "$((2000 + 4 * 3600))" ]] \
    || fail 'grace expiry is not 4 hours'

[[ "$(grep -c '^systemctl reload nginx$' "${CALL_LOG}")" == 2 ]] \
    || fail 'IP transition did not cause exactly one additional Nginx reload'

# Once grace expires, only the new address remains trusted.
bash "${RECONCILE}" --root "${T}" --reason 'grace expiry check' --now-epoch "$((2000 + 4 * 3600 + 1))"
grep -Fq "${NEW_IP}/32" "${ALLOW}" || fail 'new IP disappeared after grace expiry'
if grep -Fq "${OLD_IP}/32" "${ALLOW}"; then
    fail 'old IP remained trusted after grace expiry'
fi

echo 'PASS: Router IP change regression'
