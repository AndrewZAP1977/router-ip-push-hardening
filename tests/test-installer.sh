#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/install.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

make_root() {
    local t="$1"
    mkdir -p \
        "${t}/var/lib/router-ip-push/ips" \
        "${t}/var/lib/router-ip-push/state" \
        "${t}/etc/router-ip-push/routers.d" \
        "${t}/usr/local/bin" \
        "${t}/etc/nginx/stream-enabled" \
        "${t}/etc/nginx/sites-available"

    printf '%s\n' '198.51.100.25' >"${t}/var/lib/router-ip-push/ips/TEST_ROUTER.ipv4"
    printf '%s\n' '{"version":1,"router_id":"TEST_ROUTER","source_ip":"198.51.100.25","last_seen":"2026-08-19T10:00:00Z"}' \
        >"${t}/var/lib/router-ip-push/state/TEST_ROUTER.json"
    printf '%s\n' '{"version":1,"router_id":"TEST_ROUTER","public_key":"ssh-ed25519 AAAA"}' \
        >"${t}/etc/router-ip-push/routers.d/TEST_ROUTER.json"

    cat >"${t}/etc/nginx/stream-enabled/stream.conf" <<'EOF_STREAM'
# PREINSTALL_STREAM_SENTINEL
map $ssl_preread_server_name $sni_name
{
    hostnames;
    public.example.net      www;
    reality.example.net     xray;
    xhttp.example.net       xray2;
    default                 reject;
}

upstream www
{
    server 127.0.0.1:7443;
}

upstream xray
{
    server 127.0.0.1:8443;
}

upstream reject
{
    server 127.0.0.1:9;
}

upstream xray2 { server 127.0.0.1:8444; }

server
{
    proxy_protocol on;
    proxy_connect_timeout 5s;
    proxy_timeout 1h;
    tcp_nodelay on;
    set_real_ip_from unix:;
    listen 443;
    listen [::]:443;
    proxy_pass $sni_name;
    ssl_preread on;
}
EOF_STREAM

    cat >"${t}/etc/nginx/sites-available/reality.conf" <<'EOF_REALITY'
server
{
    server_name reality.example.net;
    listen 127.0.0.1:9443 ssl;
}
EOF_REALITY

    cat >"${t}/etc/nginx/sites-available/xhttp.conf" <<'EOF_XHTTP'
server
{
    server_name xhttp.example.net;
    listen 127.0.0.1:9444 ssl;
}
EOF_XHTTP

    cat >"${t}/usr/local/bin/nginx-stub" <<'EOF_STUB'
#!/usr/bin/env bash
exit "${RIPH_TEST_NGINX_EXIT:-0}"
EOF_STUB
    cat >"${t}/usr/local/bin/systemctl-stub" <<'EOF_STUB'
#!/usr/bin/env bash
exit "${RIPH_TEST_SYSTEMCTL_EXIT:-0}"
EOF_STUB
    cat >"${t}/usr/local/bin/ufw-stub" <<'EOF_STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    printf '%s\n' 'Status: active'
fi
exit 0
EOF_STUB
    chmod +x "${t}/usr/local/bin/"*-stub
}

T1="$(mktemp -d /tmp/riph-installer-ok.XXXXXX)"
T2="$(mktemp -d /tmp/riph-installer-fail.XXXXXX)"
T3="$(mktemp -d /tmp/riph-installer-reinstall.XXXXXX)"
T4="$(mktemp -d /tmp/riph-installer-bad-jail.XXXXXX)"
trap 'rm -rf "${T1}" "${T2}" "${T3}" "${T4}"' EXIT
make_root "${T1}"
make_root "${T2}"
make_root "${T3}"
make_root "${T4}"

# Structural safety assertions: installer rollback must cover explicit failures,
# and a first install must bootstrap routing from the existing stream.conf rather
# than seed placeholder SNI values.
grep -Fq 'trap restore_install_on_exit EXIT' "${INSTALLER}" \
    || fail 'installer is not protected by EXIT rollback'
grep -Fq 'resync_temporary_hotfix_after_error' "${INSTALLER}" \
    || fail 'installer has no post-rollback temporary-hotfix resync hook'
grep -Fq 'disable --now "${RIPH_PATH_UNIT}" "${RIPH_TIMER_UNIT}"' "${INSTALLER}" \
    || fail 'installer rollback does not remove partial RIPH automatic ownership first'
grep -Fq 'RIPH_ALLOW_PRODUCTION' "${INSTALLER}" \
    || fail 'installer lost explicit production confirmation gate'
grep -Fq 'bootstrap-config-from-stream.sh' "${INSTALLER}" \
    || fail 'installer lost first-install stream bootstrap'

echo 'TEST I1: fresh test-root install adopts existing stream routing + applies RIPH'
export RIPH_NGINX_BIN="${T1}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T1}/usr/local/bin/systemctl-stub"
export RIPH_UFW_BIN="${T1}/usr/local/bin/ufw-stub"
"${INSTALLER}" --root "${T1}" --check >/dev/null
"${INSTALLER}" --root "${T1}" --install --apply >/dev/null
[[ -x "${T1}/usr/local/sbin/riph-admin" ]] || fail 'admin not installed'
[[ -x "${T1}/usr/local/sbin/riph-harvest" ]] || fail 'harvest not installed'
[[ -x "${T1}/usr/local/sbin/riph-fail2ban-ignore" ]] || fail 'fail2ban ignore helper not installed'
[[ -x "${T1}/usr/local/sbin/riph-fail2ban-ufw" ]] || fail 'fail2ban UFW helper not installed'
[[ -x "${T1}/usr/local/sbin/riph-hotfix-handover" ]] || fail 'temporary hotfix handover helper not installed'
REJECT_JAIL="${T1}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local"
PRIVATE_JAIL="${T1}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local"
[[ -f "${REJECT_JAIL}" ]] || fail 'RIPH reject jail not installed'
[[ -f "${PRIVATE_JAIL}" ]] || fail 'RIPH private-abuse jail not installed'
grep -Fx 'enabled = false' "${REJECT_JAIL}" >/dev/null || fail 'fresh reject jail must install disabled'
grep -Fx 'enabled = false' "${PRIVATE_JAIL}" >/dev/null || fail 'fresh private-abuse jail must install disabled'
[[ ! -e "${T1}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] || fail 'legacy reject jail path must not be installed'
[[ -f "${T1}/etc/fail2ban/action.d/riph-ufw-443.conf" ]] || fail 'fail2ban action not installed'
[[ -f "${T1}/etc/systemd/system/riph-router-ip.path" ]] || fail 'router IP path unit not installed'
[[ -f "${T1}/etc/systemd/system/riph-reconcile.timer" ]] || fail 'reconcile timer not installed'
grep -Fqx 'OnActiveSec=1min' "${T1}/etc/systemd/system/riph-reconcile.timer" || fail 'installed reconcile fallback does not start one minute after activation'
grep -Fqx 'OnUnitActiveSec=1min' "${T1}/etc/systemd/system/riph-reconcile.timer" || fail 'installed reconcile fallback recurrence is not one minute'
! grep -Fq 'OnBootSec=' "${T1}/etc/systemd/system/riph-reconcile.timer" || fail 'installed reconcile timer still uses boot-relative first trigger'
[[ ! -e "${T1}/etc/systemd/system/riph-guard.timer" ]] || fail 'redundant guard timer was installed'
grep -Fx '127.0.0.1/32          # localhost' "${T1}/etc/router-ip-push-hardening/trusted-static.list" >/dev/null \
    || fail 'fresh install did not seed localhost static trust'

CONFIG="${T1}/etc/router-ip-push-hardening/config.env"
grep -Fx 'ROUTER_IDS=""' "${CONFIG}" >/dev/null || fail 'fresh imported config retained example explicit router ID'
grep -Fx 'ROUTER_AUTO_DISCOVER_REGISTERED=1' "${CONFIG}" >/dev/null || fail 'fresh install did not enable Router IP Push auto-discovery'
grep -Fx 'ROUTER_REGISTRY_DIR="/etc/router-ip-push/routers.d"' "${CONFIG}" >/dev/null || fail 'fresh install did not seed Router IP Push registry path'
grep -Fx 'PUBLIC_SNI="public.example.net"' "${CONFIG}" >/dev/null || fail 'fresh install did not import public SNI'
grep -Fx 'PRIVATE_ROUTE_COUNT=2' "${CONFIG}" >/dev/null || fail 'fresh install did not detect both private routes'
grep -Fx 'PRIVATE_SNI_1="reality.example.net"' "${CONFIG}" >/dev/null || fail 'fresh install did not import Reality SNI'
grep -Fx 'PRIVATE_SNI_2="xhttp.example.net"' "${CONFIG}" >/dev/null || fail 'fresh install did not import XHTTP SNI'
grep -Fx 'FAKE_SITE_UPSTREAM_1="127.0.0.1:9443"' "${CONFIG}" >/dev/null || fail 'fresh install did not import Reality fake-site upstream'
grep -Fx 'FAKE_SITE_UPSTREAM_2="127.0.0.1:9444"' "${CONFIG}" >/dev/null || fail 'fresh install did not import XHTTP fake-site upstream'
grep -Fx 'LEGACY_STREAM_AUDIT_COMPAT=0' "${CONFIG}" >/dev/null || fail 'fresh install did not use normal audit default'

STREAM="${T1}/etc/nginx/stream-enabled/stream.conf"
[[ -f "${STREAM}" ]] || fail 'stream config not applied'
grep -F 'access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;' "${STREAM}" >/dev/null || fail 'dedicated audit log missing'
grep -F 'public.example.net|0' "${STREAM}" >/dev/null || fail 'public routing missing after adoption'
grep -F 'reality.example.net|1' "${STREAM}" >/dev/null || fail 'trusted Reality routing missing after adoption'
grep -F 'xhttp.example.net|1' "${STREAM}" >/dev/null || fail 'trusted XHTTP routing missing after adoption'
grep -F 'reality.example.net|0' "${STREAM}" >/dev/null || fail 'untrusted Reality fake routing missing after adoption'
grep -F 'xhttp.example.net|0' "${STREAM}" >/dev/null || fail 'untrusted XHTTP fake routing missing after adoption'

backup_stream="$(find "${T1}/var/lib/router-ip-push-hardening/install-backups" -path '*/files/etc/nginx/stream-enabled/stream.conf' -type f | head -n 1)"
[[ -n "${backup_stream}" ]] || fail 'install backup did not capture pre-install stream.conf'
grep -Fq 'PREINSTALL_STREAM_SENTINEL' "${backup_stream}" || fail 'pre-install stream snapshot mismatch'

echo 'TEST I2: failed apply restores original pre-RIPH stream + files via EXIT transaction'
mkdir -p "${T2}/usr/local/sbin"
printf '%s\n' 'PREEXISTING_ADMIN_SENTINEL' >"${T2}/usr/local/sbin/riph-admin"
chmod 0700 "${T2}/usr/local/sbin/riph-admin"
cp "${T2}/etc/nginx/stream-enabled/stream.conf" "${T2}/stream.before"
export RIPH_NGINX_BIN="${T2}/usr/local/bin/nginx-stub"
export RIPH_SYSTEMCTL_BIN="${T2}/usr/local/bin/systemctl-stub"
export RIPH_UFW_BIN="${T2}/usr/local/bin/ufw-stub"
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
cmp -s "${T2}/stream.before" "${T2}/etc/nginx/stream-enabled/stream.conf" || fail 'original stream.conf was not restored'

echo 'TEST I3: reinstall preserves already-activated RIPH jail flags'
mkdir -p "${T3}/etc/fail2ban/jail.d"
cat >"${T3}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" <<'EOF_OLD_REJECT'
[riph-nginx-stream-sni-reject]
enabled = true
OLD_REJECT_SENTINEL = 1
EOF_OLD_REJECT
cat >"${T3}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" <<'EOF_OLD_PRIVATE'
[riph-nginx-stream-private-sni-abuse]
enabled = true
OLD_PRIVATE_SENTINEL = 1
EOF_OLD_PRIVATE
"${INSTALLER}" --root "${T3}" --install >/dev/null
T3_REJECT="${T3}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local"
T3_PRIVATE="${T3}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local"
grep -Fx 'enabled = true' "${T3_REJECT}" >/dev/null || fail 'reinstall disabled active reject jail on disk'
grep -Fx 'enabled = true' "${T3_PRIVATE}" >/dev/null || fail 'reinstall disabled active private-abuse jail on disk'
grep -Fx 'maxretry = 3' "${T3_REJECT}" >/dev/null || fail 'reinstall did not refresh reject jail content'
grep -Fx 'maxretry = 3' "${T3_PRIVATE}" >/dev/null || fail 'reinstall did not refresh private-abuse jail content'
! grep -Fq 'OLD_REJECT_SENTINEL' "${T3_REJECT}" || fail 'reinstall left stale reject jail content'
! grep -Fq 'OLD_PRIVATE_SENTINEL' "${T3_PRIVATE}" || fail 'reinstall left stale private-abuse jail content'

echo 'TEST I4: malformed existing jail state fails closed before replacement'
mkdir -p "${T4}/etc/fail2ban/jail.d"
cat >"${T4}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" <<'EOF_BAD_REJECT'
[riph-nginx-stream-sni-reject]
enabled = maybe
BAD_JAIL_SENTINEL = 1
EOF_BAD_REJECT
if "${INSTALLER}" --root "${T4}" --install >"${T4}/out.txt" 2>&1; then
    fail 'installer unexpectedly accepted malformed existing jail enabled state'
fi
grep -Fq 'could not preserve existing RIPH jail enabled state' "${T4}/out.txt" || fail 'malformed jail state refusal message missing'
grep -Fq 'BAD_JAIL_SENTINEL = 1' "${T4}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" || fail 'malformed existing jail was modified before refusal'
[[ ! -e "${T4}/usr/local/sbin/riph-admin" ]] || fail 'installer mutated project files after malformed jail refusal'

echo 'PASS: installer tests'
