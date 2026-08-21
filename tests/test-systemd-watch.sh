#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATH_UNIT="${ROOT}/src/etc/systemd/system/riph-router-ip.path"
PROVIDER_TIMER_UNIT="${ROOT}/src/etc/systemd/system/riph-provider-router-ip-push.timer"
PROVIDER_SERVICE_UNIT="${ROOT}/src/etc/systemd/system/riph-provider-router-ip-push.service"
TIMER_UNIT="${ROOT}/src/etc/systemd/system/riph-reconcile.timer"
SERVICE_UNIT="${ROOT}/src/etc/systemd/system/riph-reconcile.service"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

grep -Fqx 'PathChanged=/var/lib/router-ip-push/ips' "${PATH_UNIT}" \
    || fail 'provider path unit is not watching the Router IP Push ips directory'
grep -Fqx 'Unit=riph-provider-router-ip-push.service' "${PATH_UNIT}" \
    || fail 'provider path unit bypasses the adapter'

grep -Fq 'ExecStart=/usr/local/sbin/riph-provider-router-ip-push-sync' "${PROVIDER_SERVICE_UNIT}" \
    || fail 'provider service does not execute the adapter'
grep -Fqx 'OnActiveSec=1min' "${PROVIDER_TIMER_UNIT}" \
    || fail 'provider fallback timer does not start one minute after activation'
grep -Fqx 'OnUnitActiveSec=1min' "${PROVIDER_TIMER_UNIT}" \
    || fail 'provider fallback timer recurrence is not one minute'
grep -Fqx 'Unit=riph-provider-router-ip-push.service' "${PROVIDER_TIMER_UNIT}" \
    || fail 'provider fallback timer does not trigger provider sync'

grep -Fqx 'OnActiveSec=1min' "${TIMER_UNIT}" \
    || fail 'reconcile fallback timer does not start one minute after timer activation'
grep -Fqx 'OnUnitActiveSec=1min' "${TIMER_UNIT}" \
    || fail 'reconcile fallback timer recurrence is not one minute'
grep -Fqx 'AccuracySec=5s' "${TIMER_UNIT}" \
    || fail 'reconcile fallback timer accuracy is not five seconds'
! grep -Fq 'OnBootSec=' "${TIMER_UNIT}" \
    || fail 'reconcile fallback timer must not use an already-expired boot-relative trigger during takeover'
! grep -Fq 'Persistent=' "${TIMER_UNIT}" \
    || fail 'monotonic one-minute fallback must not claim calendar persistence'
grep -Fqx 'Unit=riph-reconcile.service' "${TIMER_UNIT}" \
    || fail 'reconcile timer does not trigger riph-reconcile.service'

grep -Fq 'ExecStart=/usr/local/sbin/riph-reconcile' "${SERVICE_UNIT}" \
    || fail 'reconcile service does not execute riph-reconcile'

echo 'PASS: optional provider watch + independent RIPH reconcile units'
