#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOVER="${ROOT}/src/usr/local/sbin/riph-hotfix-handover"
T="$(mktemp -d /tmp/riph-hotfix-handover.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_case() {
    local c="$1"
    mkdir -p \
        "${c}/etc/router-ip-push-hardening" \
        "${c}/etc/nginx/stream-enabled" \
        "${c}/var/lib/router-ip-push/ips" \
        "${c}/var/lib/router-ip-push/state" \
        "${c}/bin" \
        "${c}/state"
    cp "${ROOT}/config/config.env.example" "${c}/etc/router-ip-push-hardening/config.env"
    printf '%s\n' '78.111.154.96' >"${c}/var/lib/router-ip-push/ips/AX3200.ipv4"

    printf '%s\n' enabled >"${c}/state/router-ip-push-nginx-hotfix.path.enabled"
    printf '%s\n' active >"${c}/state/router-ip-push-nginx-hotfix.path.active"
    printf '%s\n' enabled >"${c}/state/router-ip-push-nginx-hotfix.timer.enabled"
    printf '%s\n' active >"${c}/state/router-ip-push-nginx-hotfix.timer.active"
    printf '%s\n' disabled >"${c}/state/riph-router-ip.path.enabled"
    printf '%s\n' inactive >"${c}/state/riph-router-ip.path.active"
    printf '%s\n' disabled >"${c}/state/riph-reconcile.timer.enabled"
    printf '%s\n' inactive >"${c}/state/riph-reconcile.timer.active"
    printf '%s\n' disabled >"${c}/state/router-ip-push-nginx-hotfix.service.enabled"
    printf '%s\n' inactive >"${c}/state/router-ip-push-nginx-hotfix.service.active"

    cat >"${c}/bin/systemctl-stub" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
state="${RIPH_TEST_SYSTEMD_STATE:?}"
cmd="${1:-}"
shift || true
case "${cmd}" in
    is-enabled)
        cat "${state}/${1}.enabled" 2>/dev/null || printf '%s\n' disabled
        ;;
    is-active)
        cat "${state}/${1}.active" 2>/dev/null || printf '%s\n' inactive
        ;;
    disable)
        now=0
        if [[ "${1:-}" == --now ]]; then now=1; shift; fi
        for unit in "$@"; do
            printf '%s\n' disabled >"${state}/${unit}.enabled"
            if (( now == 1 )); then
                printf '%s\n' inactive >"${state}/${unit}.active"
            fi
        done
        ;;
    enable)
        now=0
        if [[ "${1:-}" == --now ]]; then now=1; shift; fi
        for unit in "$@"; do
            printf '%s\n' enabled >"${state}/${unit}.enabled"
            if (( now == 1 )); then
                printf '%s\n' active >"${state}/${unit}.active"
                if [[ "${unit}" == riph-router-ip.path && -n "${RIPH_TEST_IP_AFTER_FIRST:-}" ]]; then
                    tmp="${RIPH_TEST_IP_FILE}.receiver.$$"
                    printf '%s\n' "${RIPH_TEST_IP_AFTER_FIRST}" >"${tmp}"
                    mv -f "${tmp}" "${RIPH_TEST_IP_FILE}"
                fi
            fi
        done
        ;;
    start)
        for unit in "$@"; do
            printf '%s\n' active >"${state}/${unit}.active"
        done
        ;;
    stop)
        for unit in "$@"; do
            printf '%s\n' inactive >"${state}/${unit}.active"
        done
        ;;
    daemon-reload)
        :
        ;;
    *)
        echo "unexpected systemctl command: ${cmd} $*" >&2
        exit 2
        ;;
esac
EOF_SYSTEMCTL
    chmod +x "${c}/bin/systemctl-stub"
}

assert_hotfix_owner() {
    local c="$1"
    [[ "$(cat "${c}/state/router-ip-push-nginx-hotfix.path.enabled")" == enabled ]] \
        || fail 'hotfix path not enabled after rollback'
    [[ "$(cat "${c}/state/router-ip-push-nginx-hotfix.path.active")" == active ]] \
        || fail 'hotfix path not active after rollback'
    [[ "$(cat "${c}/state/router-ip-push-nginx-hotfix.timer.enabled")" == enabled ]] \
        || fail 'hotfix timer not enabled after rollback'
    [[ "$(cat "${c}/state/router-ip-push-nginx-hotfix.timer.active")" == active ]] \
        || fail 'hotfix timer not active after rollback'
    [[ "$(cat "${c}/state/riph-router-ip.path.enabled")" == disabled ]] \
        || fail 'RIPH path remained enabled after rollback'
    [[ "$(cat "${c}/state/riph-router-ip.path.active")" == inactive ]] \
        || fail 'RIPH path remained active after rollback'
    [[ "$(cat "${c}/state/riph-reconcile.timer.enabled")" == disabled ]] \
        || fail 'RIPH timer remained enabled after rollback'
    [[ "$(cat "${c}/state/riph-reconcile.timer.active")" == inactive ]] \
        || fail 'RIPH timer remained active after rollback'
}

CASE_OK="${T}/ok"
make_case "${CASE_OK}"
cat >"${CASE_OK}/bin/reconcile-stub" <<'EOF_RECONCILE_OK'
#!/usr/bin/env bash
set -Eeuo pipefail
root=''
while (($#)); do
    case "$1" in
        --root) root="$2"; shift 2 ;;
        *) shift ;;
    esac
done
ip="$(tr -d '[:space:]' <"${root}/var/lib/router-ip-push/ips/AX3200.ipv4")"
mkdir -p "${root}/etc/nginx/stream-enabled"
cat >"${root}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<EOF_ALLOW
geo \$router_ip_push_source_allowed {
        default 0;
        ${ip}/32 1; # router-ip-push:AX3200 current
}
EOF_ALLOW
printf '%s\n' "${ip}" >>"${RIPH_TEST_RECONCILE_LOG:?}"
EOF_RECONCILE_OK
chmod +x "${CASE_OK}/bin/reconcile-stub"

export RIPH_SYSTEMCTL_BIN="${CASE_OK}/bin/systemctl-stub"
export RIPH_RECONCILE_BIN="${CASE_OK}/bin/reconcile-stub"
export RIPH_TEST_SYSTEMD_STATE="${CASE_OK}/state"
export RIPH_TEST_RECONCILE_LOG="${CASE_OK}/reconcile.log"
export RIPH_HOTFIX_LOCK="${CASE_OK}/hotfix.lock"
export RIPH_TEST_IP_FILE="${CASE_OK}/var/lib/router-ip-push/ips/AX3200.ipv4"
export RIPH_TEST_IP_AFTER_FIRST='78.111.154.97'

bash "${HANDOVER}" --root "${CASE_OK}" takeover >/dev/null
[[ "$(cat "${CASE_OK}/state/router-ip-push-nginx-hotfix.path.enabled")" == disabled ]] \
    || fail 'hotfix path stayed enabled after successful takeover'
[[ "$(cat "${CASE_OK}/state/router-ip-push-nginx-hotfix.path.active")" == inactive ]] \
    || fail 'hotfix path stayed active after successful takeover'
[[ "$(cat "${CASE_OK}/state/router-ip-push-nginx-hotfix.timer.enabled")" == disabled ]] \
    || fail 'hotfix timer stayed enabled after successful takeover'
[[ "$(cat "${CASE_OK}/state/router-ip-push-nginx-hotfix.timer.active")" == inactive ]] \
    || fail 'hotfix timer stayed active after successful takeover'
[[ "$(cat "${CASE_OK}/state/riph-router-ip.path.active")" == active ]] \
    || fail 'RIPH path is not active after successful takeover'
[[ "$(cat "${CASE_OK}/state/riph-reconcile.timer.active")" == active ]] \
    || fail 'RIPH timer is not active after successful takeover'
[[ "$(wc -l <"${CASE_OK}/reconcile.log")" == 2 ]] || fail 'stable handover should need exactly two explicit reconciles'
[[ "$(sed -n '1p' "${CASE_OK}/reconcile.log")" == '78.111.154.96' ]] \
    || fail 'first reconcile did not consume the starting IP'
[[ "$(sed -n '2p' "${CASE_OK}/reconcile.log")" == '78.111.154.97' ]] \
    || fail 'post-path reconcile did not consume the IP changed during handover'
grep -Fq '78.111.154.97/32 1;' "${CASE_OK}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" \
    || fail 'final allowlist does not contain the IP changed during handover'

unset RIPH_TEST_IP_AFTER_FIRST

# Failure before RIPH activation must restore the temporary owner.
CASE_FAIL_EARLY="${T}/fail-early"
make_case "${CASE_FAIL_EARLY}"
cat >"${CASE_FAIL_EARLY}/bin/reconcile-stub" <<'EOF_RECONCILE_FAIL_EARLY'
#!/usr/bin/env bash
exit 23
EOF_RECONCILE_FAIL_EARLY
chmod +x "${CASE_FAIL_EARLY}/bin/reconcile-stub"

export RIPH_SYSTEMCTL_BIN="${CASE_FAIL_EARLY}/bin/systemctl-stub"
export RIPH_RECONCILE_BIN="${CASE_FAIL_EARLY}/bin/reconcile-stub"
export RIPH_TEST_SYSTEMD_STATE="${CASE_FAIL_EARLY}/state"
export RIPH_TEST_RECONCILE_LOG="${CASE_FAIL_EARLY}/reconcile.log"
export RIPH_HOTFIX_LOCK="${CASE_FAIL_EARLY}/hotfix.lock"
export RIPH_TEST_IP_FILE="${CASE_FAIL_EARLY}/var/lib/router-ip-push/ips/AX3200.ipv4"

if bash "${HANDOVER}" --root "${CASE_FAIL_EARLY}" takeover >/dev/null 2>&1; then
    fail 'handover unexpectedly succeeded when initial reconcile failed'
fi
assert_hotfix_owner "${CASE_FAIL_EARLY}"

# More important: failure after RIPH path has already been enabled must first
# remove that writer and then restore the temporary writer. This prevents the
# rollback itself from creating two simultaneous allowlist owners.
CASE_FAIL_LATE="${T}/fail-late"
make_case "${CASE_FAIL_LATE}"
cat >"${CASE_FAIL_LATE}/bin/reconcile-stub" <<'EOF_RECONCILE_FAIL_LATE'
#!/usr/bin/env bash
set -Eeuo pipefail
count_file="${RIPH_TEST_RECONCILE_COUNT:?}"
count=0
[[ -f "${count_file}" ]] && count="$(cat "${count_file}")"
count=$((count + 1))
printf '%s\n' "${count}" >"${count_file}"
if (( count == 1 )); then
    root=''
    while (($#)); do
        case "$1" in
            --root) root="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    mkdir -p "${root}/etc/nginx/stream-enabled"
    cat >"${root}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<'EOF_ALLOW'
geo $router_ip_push_source_allowed {
        default 0;
        78.111.154.96/32 1; # router-ip-push:AX3200 current
}
EOF_ALLOW
    exit 0
fi
exit 24
EOF_RECONCILE_FAIL_LATE
chmod +x "${CASE_FAIL_LATE}/bin/reconcile-stub"

export RIPH_SYSTEMCTL_BIN="${CASE_FAIL_LATE}/bin/systemctl-stub"
export RIPH_RECONCILE_BIN="${CASE_FAIL_LATE}/bin/reconcile-stub"
export RIPH_TEST_SYSTEMD_STATE="${CASE_FAIL_LATE}/state"
export RIPH_TEST_RECONCILE_LOG="${CASE_FAIL_LATE}/reconcile.log"
export RIPH_TEST_RECONCILE_COUNT="${CASE_FAIL_LATE}/reconcile.count"
export RIPH_HOTFIX_LOCK="${CASE_FAIL_LATE}/hotfix.lock"
export RIPH_TEST_IP_FILE="${CASE_FAIL_LATE}/var/lib/router-ip-push/ips/AX3200.ipv4"

if bash "${HANDOVER}" --root "${CASE_FAIL_LATE}" takeover >/dev/null 2>&1; then
    fail 'handover unexpectedly succeeded when post-path reconciliation never converged'
fi
assert_hotfix_owner "${CASE_FAIL_LATE}"
[[ "$(cat "${CASE_FAIL_LATE}/reconcile.count")" == 4 ]] \
    || fail 'late failure should perform initial reconcile plus three bounded convergence attempts'

echo 'PASS: temporary hotfix ownership handover tests'
