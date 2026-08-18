#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SHIELD="${ROOT}/src/usr/local/sbin/riph-legacy-trusted-shield"
T="$(mktemp -d /tmp/riph-legacy-shield.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '78.111.154.96' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"

STATE="${T}/status.txt"
CALLS="${T}/calls.txt"
cat >"${T}/bin/ufw-stub" <<'EOF_UFW'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    cat "${RIPH_TEST_UFW_STATE:?}"
    exit 0
fi
printf '%s\n' "$*" >>"${RIPH_TEST_UFW_CALLS:?}"
EOF_UFW
chmod +x "${T}/bin/ufw-stub"

export RIPH_UFW_BIN="${T}/bin/ufw-stub"
export RIPH_UFW_LOCK="${T}/ufw.lock"
export RIPH_TEST_UFW_STATE="${STATE}"
export RIPH_TEST_UFW_CALLS="${CALLS}"

cat >"${STATE}" <<'EOF_STATE'
[ 1] 443/tcp ALLOW IN 78.111.155.187 # riph-legacy-trusted-shield
[ 2] 443/tcp DENY IN 78.111.154.96 # old-legacy-unmarked-deny
[ 3] 443/tcp ALLOW IN 78.111.154.96 # riph-legacy-trusted-shield
[ 4] 80/tcp  ALLOW IN 78.111.155.187 # riph-legacy-trusted-shield
[ 5] 443/tcp DENY IN 203.0.113.44 # riph-legacy-trusted-shield
EOF_STATE
: >"${CALLS}"

"${SHIELD}" --root "${T}" sync

grep -Fx -- '--force delete 1' "${CALLS}" >/dev/null \
    || fail 'stale project shield was not removed'
! grep -Fx -- '--force delete 2' "${CALLS}" >/dev/null \
    || fail 'legacy unmarked DENY was removed'
! grep -Fx -- '--force delete 3' "${CALLS}" >/dev/null \
    || fail 'current project shield was removed'
! grep -Fx -- '--force delete 4' "${CALLS}" >/dev/null \
    || fail 'wrong-port same-marker rule was treated as shield ownership'
! grep -Fx -- '--force delete 5' "${CALLS}" >/dev/null \
    || fail 'DENY same-marker rule was treated as shield ownership'
! grep -Fq 'prepend allow proto tcp from 78.111.154.96' "${CALLS}" \
    || fail 'duplicate current shield was prepended'

# If current IP already has an old ambiguous DENY but no project shield, sync
# must prepend an ALLOW without deleting the old rule.
cat >"${STATE}" <<'EOF_STATE2'
[ 1] 443/tcp DENY IN 78.111.154.96
[ 2] 80/tcp  ALLOW IN 78.111.154.96 # riph-legacy-trusted-shield
EOF_STATE2
: >"${CALLS}"
"${SHIELD}" --root "${T}" sync
expected='prepend allow proto tcp from 78.111.154.96 to any port 443 comment riph-legacy-trusted-shield'
grep -Fx -- "${expected}" "${CALLS}" >/dev/null \
    || fail 'current Router IP shield was not prepended over an ambiguous legacy DENY'
! grep -Fq -- '--force delete 1' "${CALLS}" \
    || fail 'ambiguous legacy DENY was deleted instead of shielded'

# remove-all removes only exact project-owned 443/tcp ALLOW rules.
cat >"${STATE}" <<'EOF_STATE3'
[ 1] 443/tcp ALLOW IN 78.111.154.96 # riph-legacy-trusted-shield
[ 2] 443/tcp DENY IN 78.111.154.96
[ 3] 80/tcp  ALLOW IN 78.111.154.96 # riph-legacy-trusted-shield
EOF_STATE3
: >"${CALLS}"
"${SHIELD}" --root "${T}" remove-all
grep -Fx -- '--force delete 1' "${CALLS}" >/dev/null \
    || fail 'project shield was not removed by remove-all'
! grep -Fx -- '--force delete 2' "${CALLS}" >/dev/null \
    || fail 'remove-all deleted legacy DENY'
! grep -Fx -- '--force delete 3' "${CALLS}" >/dev/null \
    || fail 'remove-all deleted wrong-port same-marker rule'

echo 'PASS: legacy trusted UFW shield ownership tests'
