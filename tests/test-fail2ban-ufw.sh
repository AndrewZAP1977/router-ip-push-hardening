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
export RIPH_UFW_LOCK="${T}/ufw.lock"
export RIPH_TEST_UFW_STATE="${STATE}"
export RIPH_TEST_UFW_CALLS="${CALLS}"

cat >"${STATE}" <<'EOF_STATE'
[ 1] 443/tcp DENY IN 203.0.113.44 # riph-manual-443
[ 2] 443/tcp DENY IN 203.0.113.44 # riph-f2b-nginx-stream-sni-reject
[ 3] 443/tcp DENY IN 198.51.100.8 # riph-f2b-nginx-stream-sni-reject
[ 4] 443/tcp DENY IN 1203.0.113.440 # riph-f2b-nginx-stream-sni-reject
[ 5] 80/tcp  DENY IN 203.0.113.44 # riph-f2b-nginx-stream-sni-reject
[ 6] 443/tcp ALLOW IN 203.0.113.44 # riph-f2b-nginx-stream-sni-reject
EOF_STATE

"${HELPER}" unban nginx-stream-sni-reject 203.0.113.44

grep -Fx -- '--force delete 2' "${CALLS}" >/dev/null || { echo 'FAIL: owned Fail2ban rule not deleted' >&2; exit 1; }
! grep -Fx -- '--force delete 1' "${CALLS}" >/dev/null || { echo 'FAIL: manual rule was deleted' >&2; exit 1; }
! grep -Fx -- '--force delete 3' "${CALLS}" >/dev/null || { echo 'FAIL: another IP rule was deleted' >&2; exit 1; }
! grep -Fx -- '--force delete 4' "${CALLS}" >/dev/null || { echo 'FAIL: source substring was treated as exact IP' >&2; exit 1; }
! grep -Fx -- '--force delete 5' "${CALLS}" >/dev/null || { echo 'FAIL: same-marker wrong-port rule was deleted' >&2; exit 1; }
! grep -Fx -- '--force delete 6' "${CALLS}" >/dev/null || { echo 'FAIL: same-marker ALLOW rule was deleted' >&2; exit 1; }

: >"${CALLS}"
"${HELPER}" ban nginx-stream-sni-reject 203.0.113.44
! grep -q . "${CALLS}" || { echo 'FAIL: duplicate owned TCP/443 ban was added' >&2; exit 1; }

cat >"${STATE}" <<'EOF_STATE2'
[ 1] 443/tcp DENY IN 203.0.113.44 # riph-manual-443
[ 2] 80/tcp  DENY IN 203.0.113.44 # riph-f2b-nginx-stream-sni-reject
[ 3] 443/tcp ALLOW IN 203.0.113.44 # riph-f2b-nginx-stream-sni-reject
EOF_STATE2
: >"${CALLS}"
"${HELPER}" ban nginx-stream-sni-reject 203.0.113.44
expected='prepend deny proto tcp from 203.0.113.44 to any port 443 comment riph-f2b-nginx-stream-sni-reject'
grep -Fx -- "${expected}" "${CALLS}" >/dev/null || { echo 'FAIL: correct owned TCP/443 deny was not created when only wrong-shape same-marker rules existed' >&2; exit 1; }

echo 'PASS: Fail2ban UFW ownership tests'
