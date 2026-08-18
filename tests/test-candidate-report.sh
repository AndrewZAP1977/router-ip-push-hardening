#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${ROOT}/tools/hexabyte-candidate-report.sh"
STATIC="${ROOT}/config/trusted-static.list.example"
SMARTBOX_MOTHER='176.110.189.199/32'

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

[[ -f "${REPORT}" ]] || fail 'candidate report is missing'
[[ -f "${STATIC}" ]] || fail 'trusted static example is missing'

grep -Fq 'nginx -t -q -e stderr -c "${TMP}/nginx.conf"' "${REPORT}" \
    || fail 'candidate report does not validate the temporary config with the production Nginx prefix'

if grep -Eq 'nginx[[:space:]].*-p[[:space:]]+/etc/nginx' "${REPORT}"; then
    fail 'candidate report must not override Nginx prefix to /etc/nginx'
fi

grep -Fq 'Current production safety gate' "${REPORT}" \
    || fail 'candidate report lost the production safety gate'
grep -Fq 'temporary safeguard owns a synchronized staging allowlist' "${REPORT}" \
    || fail 'candidate report lost Router IP/hotfix synchronization check'

! grep -Fq "${SMARTBOX_MOTHER}" "${STATIC}" \
    || fail 'dynamic SmartBox-mother address is still seeded as permanent static trust'
! grep -Fq 'SMARTBOX_MOTHER_IP=' "${REPORT}" \
    || fail 'historical candidate report still hardcodes SmartBox-mother dynamic IPv4'

grep -Fq '# router-ip-push:AX3200 current' "${REPORT}" \
    || fail 'candidate report lost Router IP Push dynamic trust line'

echo 'PASS: candidate report preserves Nginx safety gate and keeps dynamic router IPs out of static trust'
