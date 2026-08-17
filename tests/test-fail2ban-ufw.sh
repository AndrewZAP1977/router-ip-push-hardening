#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/src/usr/local/sbin/riph-fail2ban-ufw"
T="$(mktemp -d /tmp/riph-f2b-ufw.XXXXXX)"
trap 'rm -rf "${T}"' EXIT
STATE="${T}/status.txt"
CALLS="${T}/calls.txt"

cat >"${T}/ufw-stub" <<'EOF_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    cat "${RIPH_TEST_UFW_STATE:?}"
    exit 0
fi
printf '%s\n' "$*" >>"${RIPH_TEST_UFW_CALLS:?}"
exit 0
EOF_STUB
chmod +x "${T}/ufw-stub"
export RIPH_UFW_BIN="${T}/ufw-stub"
export RIPH_F2B_UFW_LOCK="${T}/ufw.lock"
export RIPH_TEST_UFW_STATE="${STATE}"
export RIPH_TEST_UFW_CALLS="${CALLS}"

cat >"${STATE}" <<'EOF_STATE'
[ 1] 443/tcp DENY IN 203.0.113.44 # riph-manual-443
[ 2] 443/tcp DENY IN 203.0.113.44 # riph-f2b-nginx-stream-sni-reject
[ 3] 443/tcp DENY IN 198.51.100.8 # riph-f2b-nginx-stream-sni-reject
EOF_STATE

"${HELPER}" unban nginx-stream-sni-reject 203.0.113.44

grep -Fx -- '--force delete 2' "${CALLS}" >/dev/null || { echo 'FAIL: owned Fail2ban rule not deleted' >&2; exit 1; }
! grep -Fx -- '--force delete 1' "${CALLS}" >/dev/null || { echo 'FAIL: manual rule was deleted' >&2; exit 1; }
! grep -Fx -- '--force delete 3' "${CALLS}" >/dev/null || { echo 'FAIL: another IP rule was deleted' >&2; exit 1; }

: >"${CALLS}"
"${HELPER}" ban nginx-stream-sni-reject 203.0.113.44
! grep -q . "${CALLS}" || { echo 'FAIL: duplicate owned ban was added' >&2; exit 1; }

cat >"${STATE}" <<'EOF_STATE2'
[ 1] 443/tcp DENY IN 203.0.113.44 # riph-manual-443
EOF_STATE2
"${HELPER}" ban nginx-stream-sni-reject 203.0.113.44
expected='prepend deny proto tcp from 203.0.113.44 to any port 443 comment riph-f2b-nginx-stream-sni-reject'
grep -Fx -- "${expected}" "${CALLS}" >/dev/null || { echo 'FAIL: owned ban was not created' >&2; exit 1; }

echo 'PASS: Fail2ban UFW ownership tests'
