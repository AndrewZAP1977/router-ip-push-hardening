#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_UNIT="${ROOT}/src/etc/systemd/system/riph-router-ip.path"
TIMER_UNIT="${ROOT}/src/etc/systemd/system/riph-reconcile.timer"
SERVICE_UNIT="${ROOT}/src/etc/systemd/system/riph-reconcile.service"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fqx 'PathChanged=/var/lib/router-ip-push/ips' "${PATH_UNIT}" \
    || fail 'path unit is not watching the Router IP Push ips directory'
grep -Fqx 'Unit=riph-reconcile.service' "${PATH_UNIT}" \
    || fail 'path unit does not trigger riph-reconcile.service'

grep -Fqx 'OnBootSec=1min' "${TIMER_UNIT}" \
    || fail 'fallback timer does not start after one minute'
grep -Fqx 'OnUnitActiveSec=1min' "${TIMER_UNIT}" \
    || fail 'fallback timer is not one minute'
grep -Fqx 'AccuracySec=5s' "${TIMER_UNIT}" \
    || fail 'fallback timer accuracy is not five seconds'
grep -Fqx 'Persistent=true' "${TIMER_UNIT}" \
    || fail 'fallback timer is not persistent'
grep -Fqx 'Unit=riph-reconcile.service' "${TIMER_UNIT}" \
    || fail 'timer does not trigger riph-reconcile.service'

grep -Fq 'ExecStart=/usr/local/sbin/riph-reconcile' "${SERVICE_UNIT}" \
    || fail 'reconcile service does not execute riph-reconcile'

echo 'PASS: Router IP systemd watch/fallback units'
