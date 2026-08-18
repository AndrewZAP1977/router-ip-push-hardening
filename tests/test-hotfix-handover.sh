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
        if [[ "${1:-}" == --now ]]; then shift; fi
        for unit in "$@"; do
            printf '%s\n' disabled >"${state}/${unit}.enabled"
            printf '%s\n' inactive >"${state}/${unit}.active"
        done
        ;;
    enable)
        if [[ "${1:-}" == --now ]]; then shift; fi
        for unit in "$@"; do
            printf '%s\n' enabled >"${state}/${unit}.enabled"
            printf '%s\n' active >"${state}/${unit}.active"
        done
        ;;
    stop)
        unit="${1:?}"
        printf '%s\n' inactive >"${state}/${unit}.active"
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
mkdir -p "${root}/etc/nginx/stream-enabled"
cat >"${root}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<'EOF_ALLOW'
geo $router_ip_push_source_allowed {
        default 0;
        78.111.154.96/32 1; # router-ip-push:AX3200 current
}
EOF_ALLOW
printf '%s\n' called >>"${RIPH_TEST_RECONCILE_LOG:?}"
EOF_RECONCILE_OK
chmod +x "${CASE_OK}/bin/reconcile-stub"

export RIPH_SYSTEMCTL_BIN="${CASE_OK}/bin/systemctl-stub"
export RIPH_RECONCILE_BIN="${CASE_OK}/bin/reconcile-stub"
export RIPH_TEST_SYSTEMD_STATE="${CASE_OK}/state"
export RIPH_TEST_RECONCILE_LOG="${CASE_OK}/reconcile.log"
export RIPH_HOTFIX_LOCK="${CASE_OK}/hotfix.lock"

bash "${HANDOVER}" --root "${CASE_OK}" takeover >/dev/null
[[ "$(cat "${CASE_OK}/state/router-ip-push-nginx-hotfix.path.enabled")" == disabled ]] \
    || fail 'hotfix path stayed enabled after successful takeover'
[[ "$(cat "${CASE_OK}/state/router-ip-push-nginx-hotfix.timer.enabled")" == disabled ]] \
    || fail 'hotfix timer stayed enabled after successful takeover'
[[ "$(cat "${CASE_OK}/state/riph-router-ip.path.active")" == active ]] \
    || fail 'RIPH path is not active after successful takeover'
[[ "$(cat "${CASE_OK}/state/riph-reconcile.timer.active")" == active ]] \
    || fail 'RIPH timer is not active after successful takeover'
[[ "$(wc -l <"${CASE_OK}/reconcile.log")" == 1 ]] || fail 'reconcile was not called exactly once'

CASE_FAIL="${T}/fail"
make_case "${CASE_FAIL}"
cat >"${CASE_FAIL}/bin/reconcile-stub" <<'EOF_RECONCILE_FAIL'
#!/usr/bin/env bash
exit 23
EOF_RECONCILE_FAIL
chmod +x "${CASE_FAIL}/bin/reconcile-stub"

export RIPH_SYSTEMCTL_BIN="${CASE_FAIL}/bin/systemctl-stub"
export RIPH_RECONCILE_BIN="${CASE_FAIL}/bin/reconcile-stub"
export RIPH_TEST_SYSTEMD_STATE="${CASE_FAIL}/state"
export RIPH_TEST_RECONCILE_LOG="${CASE_FAIL}/reconcile.log"
export RIPH_HOTFIX_LOCK="${CASE_FAIL}/hotfix.lock"

if bash "${HANDOVER}" --root "${CASE_FAIL}" takeover >/dev/null 2>&1; then
    fail 'handover unexpectedly succeeded when reconcile failed'
fi
[[ "$(cat "${CASE_FAIL}/state/router-ip-push-nginx-hotfix.path.enabled")" == enabled ]] \
    || fail 'failed takeover did not restore hotfix path'
[[ "$(cat "${CASE_FAIL}/state/router-ip-push-nginx-hotfix.timer.enabled")" == enabled ]] \
    || fail 'failed takeover did not restore hotfix timer'
[[ "$(cat "${CASE_FAIL}/state/router-ip-push-nginx-hotfix.path.active")" == active ]] \
    || fail 'failed takeover did not reactivate hotfix path'
[[ "$(cat "${CASE_FAIL}/state/router-ip-push-nginx-hotfix.timer.active")" == active ]] \
    || fail 'failed takeover did not reactivate hotfix timer'

echo 'PASS: temporary hotfix ownership handover tests'
