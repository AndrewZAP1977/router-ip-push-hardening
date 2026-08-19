#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="${ROOT}/src/usr/local/sbin/riph-trusted-unban-guard"
T="$(mktemp -d /tmp/riph-guard.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p "${T}/etc/router-ip-push-hardening" "${T}/var/lib/router-ip-push/ips" "${T}/usr/local/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '127.0.0.1/32 # localhost' >"${T}/etc/router-ip-push-hardening/trusted-static.list"
printf '%s\n' '{"version":1,"routers":{}}' >"${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '192.0.2.25' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
: >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
: >"${T}/etc/router-ip-push-hardening/manual-deny-all.list"

LOG="${T}/f2b.log"
cat >"${T}/usr/local/bin/f2b-stub" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == status ]]; then
    printf '%s\n' 'Banned IP list: 192.0.2.25 203.0.113.9'
else
    printf '%s\n' "$*" >>"${RIPH_TEST_F2B_LOG:?}"
fi
EOF

# riph-apply-manual-deny is invoked by the guard even when the desired manual
# deny state is empty. The helper intentionally requires an inspectable UFW
# executable before trusting ownership state, so test-root guard coverage must
# provide one rather than depending on the host having UFW installed.
cat >"${T}/usr/local/bin/ufw-stub" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    exit 0
fi
exit 0
EOF

chmod +x "${T}/usr/local/bin/f2b-stub" "${T}/usr/local/bin/ufw-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${T}/usr/local/bin/f2b-stub"
export RIPH_UFW_BIN="${T}/usr/local/bin/ufw-stub"
export RIPH_TEST_F2B_LOG="${LOG}"

"${GUARD}" --root "${T}" --now-epoch 1000
grep -F 'set riph-nginx-stream-sni-reject unbanip 192.0.2.25' "${LOG}" >/dev/null
grep -F 'set riph-nginx-stream-private-sni-abuse unbanip 192.0.2.25' "${LOG}" >/dev/null
! grep -F '203.0.113.9' "${LOG}" >/dev/null

# A later trusted-set change may overlap an older manual rule. Guard recovery
# suppresses project-owned conflicting UFW state instead of failing the timer.
printf '%s\n' '192.0.2.0/24 # trusted overlap' >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
"${GUARD}" --root "${T}" --dry-run --now-epoch 1000

echo 'PASS: guard tests'
