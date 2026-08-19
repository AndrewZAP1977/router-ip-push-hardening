#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/riph-guard-shield.XXXXXX)"
R="${T}/runtime"
FS="${T}/rootfs"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p \
    "${R}/sbin" "${R}/libexec" \
    "${FS}/etc/router-ip-push-hardening" \
    "${FS}/etc/fail2ban/jail.d" \
    "${FS}/var/lib/router-ip-push/ips" \
    "${FS}/bin"

cp "${ROOT}/src/usr/local/sbin/riph-trusted-unban-guard" "${R}/sbin/riph-trusted-unban-guard"
cp "${ROOT}/src/usr/local/libexec/riph-common.sh" "${R}/libexec/riph-common.sh"
cp "${ROOT}/src/usr/local/libexec/riph-trusted.sh" "${R}/libexec/riph-trusted.sh"
cp "${ROOT}/src/usr/local/libexec/riph-net.sh" "${R}/libexec/riph-net.sh"
chmod +x "${R}/sbin/riph-trusted-unban-guard"

cat >"${R}/sbin/riph-apply-manual-deny" <<'EOF_MANUAL'
#!/usr/bin/env bash
exit 0
EOF_MANUAL
chmod +x "${R}/sbin/riph-apply-manual-deny"

cp "${ROOT}/config/config.env.example" "${FS}/etc/router-ip-push-hardening/config.env"
cp "${ROOT}/config/trusted-static.list.example" "${FS}/etc/router-ip-push-hardening/trusted-static.list"
cp "${ROOT}/config/previous-ip-grace.json.example" "${FS}/etc/router-ip-push-hardening/previous-ip-grace.json"
: >"${FS}/etc/router-ip-push-hardening/manual-deny-443.list"
: >"${FS}/etc/router-ip-push-hardening/manual-deny-all.list"
printf '%s\n' '78.111.154.96' >"${FS}/var/lib/router-ip-push/ips/AX3200.ipv4"
cat >"${FS}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" <<'EOF_OVERRIDE'
[nginx-stream-sni-reject]
ignorecommand = /usr/local/sbin/riph-fail2ban-ignore <ip>
EOF_OVERRIDE

STATE="${T}/ufw-status.txt"
CALLS="${T}/ufw-calls.txt"
cat >"${FS}/bin/ufw-stub" <<'EOF_UFW'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    cat "${RIPH_TEST_UFW_STATE:?}"
    exit 0
fi
printf '%s\n' "$*" >>"${RIPH_TEST_UFW_CALLS:?}"
EOF_UFW
chmod +x "${FS}/bin/ufw-stub"

export RIPH_UFW_BIN="${FS}/bin/ufw-stub"
export RIPH_UFW_LOCK="${T}/ufw.lock"
export RIPH_TEST_UFW_STATE="${STATE}"
export RIPH_TEST_UFW_CALLS="${CALLS}"
export RIPH_FAIL2BAN_CLIENT_BIN="${T}/missing-fail2ban-client"

# Current Router IP is already under an ambiguous unmarked legacy DENY. Guard must
# prepend the project ALLOW shield and must not touch that old DENY.
cat >"${STATE}" <<'EOF_STATE1'
[ 1] 443/tcp DENY IN 78.111.154.96
[ 2] 80/tcp  ALLOW IN 78.111.154.96 # riph-legacy-trusted-shield
EOF_STATE1
: >"${CALLS}"
bash "${R}/sbin/riph-trusted-unban-guard" --root "${FS}" --now-epoch 1000 >/dev/null
expected='prepend allow proto tcp from 78.111.154.96 to any port 443 comment riph-legacy-trusted-shield'
grep -Fx -- "${expected}" "${CALLS}" >/dev/null \
    || fail 'guard did not prepend current Router IP shield'
! grep -Fq -- '--force delete 1' "${CALLS}" \
    || fail 'guard deleted ambiguous legacy DENY instead of shielding current IP'
! grep -Fq -- '--force delete 2' "${CALLS}" \
    || fail 'guard treated wrong-port same-marker rule as owned shield'

# After Router IP changes, stale project shield is removed, current exact project
# shield is retained, and legacy DENY remains untouched.
printf '%s\n' '78.111.154.97' >"${FS}/var/lib/router-ip-push/ips/AX3200.ipv4"
cat >"${STATE}" <<'EOF_STATE2'
[ 1] 443/tcp ALLOW IN 78.111.154.96 # riph-legacy-trusted-shield
[ 2] 443/tcp DENY IN 78.111.154.97
[ 3] 443/tcp ALLOW IN 78.111.154.97 # riph-legacy-trusted-shield
[ 4] 443/tcp DENY IN 203.0.113.44 # riph-legacy-trusted-shield
EOF_STATE2
: >"${CALLS}"
bash "${R}/sbin/riph-trusted-unban-guard" --root "${FS}" --now-epoch 1100 >/dev/null
grep -Fx -- '--force delete 1' "${CALLS}" >/dev/null \
    || fail 'stale project shield was not removed after Router IP change'
! grep -Fx -- '--force delete 2' "${CALLS}" >/dev/null \
    || fail 'legacy current-IP DENY was removed'
! grep -Fx -- '--force delete 3' "${CALLS}" >/dev/null \
    || fail 'current exact project shield was removed'
! grep -Fx -- '--force delete 4' "${CALLS}" >/dev/null \
    || fail 'same-marker DENY was mistaken for project ALLOW shield'
! grep -Fq 'prepend allow proto tcp from 78.111.154.97' "${CALLS}" \
    || fail 'duplicate current project shield was prepended'

# Retirement cleanup mode removes only exact project-owned 443/tcp ALLOW shields.
cat >"${STATE}" <<'EOF_STATE3'
[ 1] 443/tcp ALLOW IN 78.111.154.97 # riph-legacy-trusted-shield
[ 2] 443/tcp DENY IN 78.111.154.97
[ 3] 80/tcp  ALLOW IN 78.111.154.97 # riph-legacy-trusted-shield
EOF_STATE3
: >"${CALLS}"
bash "${R}/sbin/riph-trusted-unban-guard" --root "${FS}" --legacy-shield-remove-all >/dev/null
grep -Fx -- '--force delete 1' "${CALLS}" >/dev/null \
    || fail 'remove-all did not delete exact project shield'
! grep -Fx -- '--force delete 2' "${CALLS}" >/dev/null \
    || fail 'remove-all deleted legacy DENY'
! grep -Fx -- '--force delete 3' "${CALLS}" >/dev/null \
    || fail 'remove-all deleted wrong-port same-marker rule'

echo 'PASS: guard-managed legacy trusted UFW shield'
