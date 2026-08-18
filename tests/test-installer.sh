#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

make_root() {
    local t="$1"
    mkdir -p "${t}/var/lib/router-ip-push/ips" "${t}/usr/local/bin" "${t}/etc/nginx/stream-enabled"
    printf '%s\n' '78.111.155.187' >"${t}/var/lib/router-ip-push/ips/AX3200.ipv4"
    cat >"${t}/usr/local/bin/nginx-stub" <<'EOF_STUB'
#!/usr/bin/env bash
exit "${RIPH_TEST_NGINX_EXIT:-0}"
EOF_STUB
    cat >"${t}/usr/local/bin/systemctl-stub" <<'EOF_STUB'
#!/usr/bin/env bash
exit "${RIPH_TEST_SYSTEMCTL_EXIT:-0}"
EOF_STUB
    chmod +x "${t}/usr/local/bin/"*-stub
}

T1="$(mktemp -d /tmp/riph-installer-ok.XXXXXX)"
T2="$(mktemp -d /tmp/riph-installer-fail.XXXXXX)"
trap 'rm -rf "${T1}" "${T2}"' EXIT
make_root "${T1}"
make_root "${T2}"
printf '%s\n' 'PREINSTALL_STREAM_SENTINEL' >"${T1}/etc/nginx/stream-enabled/stream.conf"

# Structural safety assertions: the installer transaction must use EXIT rollback
# (explicit riph_die/exit paths included) and must resynchronize the live temporary
# Router-IP owner after a failed production install restores an older Nginx snapshot.
grep -Fq 'trap restore_install_on_exit EXIT' "${INSTALLER}" \
    || fail 'installer is not protected by EXIT rollback'
grep -Fq 'resync_temporary_hotfix_after_error' "${INSTALLER}" \
    || fail 'installer has no post-rollback temporary-hotfix resync hook'
grep -Fq 'disable --now "${RIPH_PATH_UNIT}" "${RIPH_TIMER_UNIT}"' "${INSTALLER}" \
    || fail 'installer rollback does not remove partial RIPH automatic ownership first'

echo 'TEST I1: test-root install + apply'
export RIPH_NGINX_BIN="${T1}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T1}/usr/local/bin/systemctl-stub"
"${INSTALLER}" --root "${T1}" --check >/dev/null
"${INSTALLER}" --root "${T1}" --install --apply >/dev/null
[[ -x "${T1}/usr/local/sbin/riph-admin" ]] || fail 'admin not installed'
[[ -x "${T1}/usr/local/sbin/riph-harvest" ]] || fail 'harvest not installed'
[[ -x "${T1}/usr/local/sbin/riph-fail2ban-ignore" ]] || fail 'fail2ban ignore helper not installed'
[[ -x "${T1}/usr/local/sbin/riph-fail2ban-ufw" ]] || fail 'fail2ban UFW helper not installed'
[[ -x "${T1}/usr/local/sbin/riph-hotfix-handover" ]] || fail 'temporary hotfix handover helper not installed'
[[ -f "${T1}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" ]] || fail 'RIPH reject jail not installed'
[[ ! -e "${T1}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] || fail 'legacy reject jail path must not be installed'
[[ -f "${T1}/etc/fail2ban/action.d/riph-ufw-443.conf" ]] || fail 'fail2ban action not installed'
[[ -f "${T1}/etc/systemd/system/riph-router-ip.path" ]] || fail 'router IP path unit not installed'
[[ -f "${T1}/etc/systemd/system/riph-reconcile.timer" ]] || fail 'reconcile timer not installed'
grep -Fqx 'OnActiveSec=1min' "${T1}/etc/systemd/system/riph-reconcile.timer" || fail 'installed reconcile fallback does not start one minute after activation'
grep -Fqx 'OnUnitActiveSec=1min' "${T1}/etc/systemd/system/riph-reconcile.timer" || fail 'installed reconcile fallback recurrence is not one minute'
! grep -Fq 'OnBootSec=' "${T1}/etc/systemd/system/riph-reconcile.timer" || fail 'installed reconcile timer still uses boot-relative first trigger'
[[ ! -e "${T1}/etc/systemd/system/riph-guard.timer" ]] || fail 'redundant guard timer was installed'
[[ -f "${T1}/etc/nginx/stream-enabled/stream.conf" ]] || fail 'stream config not applied'
grep -F 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${T1}/etc/nginx/stream-enabled/stream.conf" >/dev/null || fail 'dedicated audit log missing'
grep -F 'treda.layerupzap.ru|1' "${T1}/etc/nginx/stream-enabled/stream.conf" >/dev/null || fail 'private routing missing'
backup_stream="$(find "${T1}/var/lib/router-ip-push-hardening/install-backups" -path '*/files/etc/nginx/stream-enabled/stream.conf' -type f | head -n 1)"
[[ -n "${backup_stream}" ]] || fail 'install backup did not capture pre-install stream.conf'
grep -Fx 'PREINSTALL_STREAM_SENTINEL' "${backup_stream}" >/dev/null || fail 'pre-install stream snapshot mismatch'

echo 'TEST I2: failed apply restores pre-install files via EXIT transaction'
mkdir -p "${T2}/usr/local/sbin"
printf '%s\n' 'PREEXISTING_ADMIN_SENTINEL' >"${T2}/usr/local/sbin/riph-admin"
chmod 0700 "${T2}/usr/local/sbin/riph-admin"
export RIPH_NGINX_BIN="${T2}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T2}/usr/local/bin/systemctl-stub"
export RIPH_TEST_NGINX_EXIT=1
if "${INSTALLER}" --root "${T2}" --install --apply; then
    fail 'installer unexpectedly succeeded with failing nginx'
fi
unset RIPH_TEST_NGINX_EXIT
grep -Fx 'PREEXISTING_ADMIN_SENTINEL' "${T2}/usr/local/sbin/riph-admin" >/dev/null || fail 'preexisting admin was not restored'
[[ ! -e "${T2}/etc/router-ip-push-hardening/config.env" ]] || fail 'new config was not removed by install rollback'
[[ ! -e "${T2}/etc/systemd/system/riph-reconcile.timer" ]] || fail 'new systemd unit was not removed by install rollback'
[[ ! -e "${T2}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" ]] || fail 'new RIPH Fail2ban jail was not removed by install rollback'
[[ ! -e "${T2}/usr/local/sbin/riph-hotfix-handover" ]] || fail 'new handover helper was not removed by install rollback'

echo 'PASS: installer tests'
