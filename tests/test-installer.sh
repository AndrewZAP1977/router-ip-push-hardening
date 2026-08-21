#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="${ROOT}/install.sh"
fail(){ echo "FAIL: $*" >&2; exit 1; }

make_root(){
    local t="$1"
    mkdir -p "${t}/var/lib/router-ip-push/ips" "${t}/usr/local/bin" "${t}/etc/nginx/stream-enabled" "${t}/etc/nginx/sites-available"
    printf '%s\n' '198.51.100.25' >"${t}/var/lib/router-ip-push/ips/TEST_ROUTER.ipv4"
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
upstream www { server 127.0.0.1:7443; }
upstream xray { server 127.0.0.1:8443; }
upstream reject { server 127.0.0.1:9; }
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
if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then printf '%s\n' 'Status: active'; fi
exit 0
EOF_STUB
    chmod +x "${t}/usr/local/bin/"*-stub
}

T1="$(mktemp -d /tmp/riph-installer-ok.XXXXXX)"
T2="$(mktemp -d /tmp/riph-installer-fail.XXXXXX)"
T3="$(mktemp -d /tmp/riph-installer-reinstall.XXXXXX)"
T4="$(mktemp -d /tmp/riph-installer-bad-jail.XXXXXX)"
T5="$(mktemp -d /tmp/riph-installer-zero-provider.XXXXXX)"
trap 'rm -rf "${T1}" "${T2}" "${T3}" "${T4}" "${T5}"' EXIT
for t in "${T1}" "${T2}" "${T3}" "${T4}" "${T5}"; do make_root "${t}"; done
rm -rf "${T5}/var/lib/router-ip-push"

# Structural transaction checks.
grep -Fq 'trap restore_install_on_exit EXIT' "${INSTALLER}" || fail 'installer is not protected by EXIT rollback'
grep -Fq 'resync_temporary_hotfix_after_error' "${INSTALLER}" || fail 'installer lost temporary-hotfix recovery hook'
grep -Fq '"${RIPH_ROUTER_IP_PUSH_STATE}"' "${INSTALLER}" || fail 'canonical provider state is not part of install snapshot'
grep -Fq 'disable --now "${RIPH_PATH_UNIT}" "${RIPH_PROVIDER_TIMER_UNIT}" "${RIPH_TIMER_UNIT}"' "${INSTALLER}" || fail 'rollback does not disable provider/core triggers first'
grep -Fq 'RIPH_ALLOW_PRODUCTION' "${INSTALLER}" || fail 'installer lost production confirmation gate'
grep -Fq 'bootstrap-config-from-stream.sh' "${INSTALLER}" || fail 'installer lost stream bootstrap'

echo 'TEST I1: fresh install adopts routing and materializes optional provider before apply'
export RIPH_NGINX_BIN="${T1}/usr/local/bin/nginx-stub" RIPH_SYSTEMCTL_BIN="${T1}/usr/local/bin/systemctl-stub" RIPH_UFW_BIN="${T1}/usr/local/bin/ufw-stub"
"${INSTALLER}" --root "${T1}" --check >/dev/null
"${INSTALLER}" --root "${T1}" --install --apply >/dev/null
for f in riph-admin riph-harvest riph-fail2ban-ignore riph-fail2ban-ufw riph-hotfix-handover riph-provider-router-ip-push-sync; do
    [[ -x "${T1}/usr/local/sbin/${f}" ]] || fail "${f} not installed"
done
for f in riph-router-ip.path riph-provider-router-ip-push.service riph-provider-router-ip-push.timer riph-reconcile.timer; do
    [[ -f "${T1}/etc/systemd/system/${f}" ]] || fail "${f} not installed"
done
grep -Fqx 'Unit=riph-provider-router-ip-push.service' "${T1}/etc/systemd/system/riph-router-ip.path" || fail 'provider path does not target adapter service'
grep -Fqx 'Unit=riph-provider-router-ip-push.service' "${T1}/etc/systemd/system/riph-provider-router-ip-push.timer" || fail 'provider timer does not target adapter service'

CONFIG="${T1}/etc/router-ip-push-hardening/config.env"
grep -Fx 'ROUTER_IDS=""' "${CONFIG}" >/dev/null || fail 'fresh imported config did not keep optional Router ID filter empty'
! grep -Fq 'ROUTER_AUTO_DISCOVER_REGISTERED=' "${CONFIG}" || fail 'fresh config retained registration-based discovery'
! grep -Fq 'ROUTER_REGISTRY_DIR=' "${CONFIG}" || fail 'fresh config retained Pusher registry dependency'
grep -Fx 'PUBLIC_SNI="public.example.net"' "${CONFIG}" >/dev/null || fail 'public SNI not imported'
grep -Fx 'PRIVATE_ROUTE_COUNT=2' "${CONFIG}" >/dev/null || fail 'both private routes not imported'
grep -Fx 'PRIVATE_SNI_1="reality.example.net"' "${CONFIG}" >/dev/null || fail 'Reality SNI not imported'
grep -Fx 'PRIVATE_SNI_2="xhttp.example.net"' "${CONFIG}" >/dev/null || fail 'XHTTP SNI not imported'
grep -Fx 'LEGACY_STREAM_AUDIT_COMPAT=0' "${CONFIG}" >/dev/null || fail 'legacy audit compatibility default changed'

PROVIDER="${T1}/var/lib/router-ip-push-hardening/providers/router-ip-push.json"
[[ -f "${PROVIDER}" ]] || fail 'canonical provider state was not created'
[[ "$(jq -r '.status' "${PROVIDER}")" == available ]] || fail 'provider status is not available'
[[ "$(jq -r '.routers.TEST_ROUTER.current_ip' "${PROVIDER}")" == 198.51.100.25 ]] || fail 'provider current IP was not materialized'
ALLOW="${T1}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
grep -Fq '198.51.100.25/32' "${ALLOW}" || fail 'first apply happened before provider materialization'
STREAM="${T1}/etc/nginx/stream-enabled/stream.conf"
grep -Fq 'public.example.net|0' "${STREAM}" || fail 'public routing missing after adoption'
grep -Fq 'reality.example.net|1' "${STREAM}" || fail 'trusted Reality routing missing'
grep -Fq 'xhttp.example.net|0' "${STREAM}" || fail 'untrusted XHTTP fake routing missing'
backup_stream="$(find "${T1}/var/lib/router-ip-push-hardening/install-backups" -path '*/files/etc/nginx/stream-enabled/stream.conf' -type f | head -n1)"
[[ -n "${backup_stream}" ]] && grep -Fq PREINSTALL_STREAM_SENTINEL "${backup_stream}" || fail 'pre-install stream snapshot missing'

REJECT_JAIL="${T1}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local"
PRIVATE_JAIL="${T1}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local"
grep -Fx 'enabled = false' "${REJECT_JAIL}" >/dev/null || fail 'fresh reject jail must install disabled'
grep -Fx 'enabled = false' "${PRIVATE_JAIL}" >/dev/null || fail 'fresh private-abuse jail must install disabled'

echo 'TEST I2: failed apply restores pre-RIPH files and removes generated canonical state'
mkdir -p "${T2}/usr/local/sbin"
printf '%s\n' PREEXISTING_ADMIN_SENTINEL >"${T2}/usr/local/sbin/riph-admin"; chmod 0700 "${T2}/usr/local/sbin/riph-admin"
cp "${T2}/etc/nginx/stream-enabled/stream.conf" "${T2}/stream.before"
export RIPH_NGINX_BIN="${T2}/usr/local/bin/nginx-stub" RIPH_SYSTEMCTL_BIN="${T2}/usr/local/bin/systemctl-stub" RIPH_UFW_BIN="${T2}/usr/local/bin/ufw-stub" RIPH_TEST_NGINX_EXIT=1
if "${INSTALLER}" --root "${T2}" --install --apply >/dev/null 2>&1; then fail 'installer unexpectedly succeeded with failing nginx'; fi
unset RIPH_TEST_NGINX_EXIT
grep -Fx PREEXISTING_ADMIN_SENTINEL "${T2}/usr/local/sbin/riph-admin" >/dev/null || fail 'preexisting admin was not restored'
[[ ! -e "${T2}/etc/router-ip-push-hardening/config.env" ]] || fail 'new config was not removed by rollback'
[[ ! -e "${T2}/var/lib/router-ip-push-hardening/providers/router-ip-push.json" ]] || fail 'generated canonical provider state was not removed by rollback'
[[ ! -e "${T2}/etc/systemd/system/riph-provider-router-ip-push.service" ]] || fail 'new provider service was not removed by rollback'
cmp -s "${T2}/stream.before" "${T2}/etc/nginx/stream-enabled/stream.conf" || fail 'original stream.conf was not restored'

echo 'TEST I3: reinstall preserves activated RIPH jail flags'
mkdir -p "${T3}/etc/fail2ban/jail.d"
printf '[riph-nginx-stream-sni-reject]\nenabled = true\nOLD_REJECT_SENTINEL = 1\n' >"${T3}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local"
printf '[riph-nginx-stream-private-sni-abuse]\nenabled = true\nOLD_PRIVATE_SENTINEL = 1\n' >"${T3}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local"
"${INSTALLER}" --root "${T3}" --install >/dev/null
T3R="${T3}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local"; T3P="${T3}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local"
grep -Fx 'enabled = true' "${T3R}" >/dev/null || fail 'reinstall disabled active reject jail'
grep -Fx 'enabled = true' "${T3P}" >/dev/null || fail 'reinstall disabled active private jail'
grep -Fx 'maxretry = 3' "${T3R}" >/dev/null || fail 'reinstall did not refresh reject jail'
! grep -Fq OLD_REJECT_SENTINEL "${T3R}" || fail 'stale reject jail content remained'

echo 'TEST I4: malformed existing jail state fails closed before replacement'
mkdir -p "${T4}/etc/fail2ban/jail.d"
printf '[riph-nginx-stream-sni-reject]\nenabled = maybe\nBAD_JAIL_SENTINEL = 1\n' >"${T4}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local"
if "${INSTALLER}" --root "${T4}" --install >"${T4}/out.txt" 2>&1; then fail 'installer accepted malformed existing jail state'; fi
grep -Fq 'could not preserve existing RIPH jail enabled state' "${T4}/out.txt" || fail 'malformed jail refusal missing'
grep -Fq BAD_JAIL_SENTINEL "${T4}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" || fail 'malformed jail was modified before refusal'
[[ ! -e "${T4}/usr/local/sbin/riph-admin" ]] || fail 'installer mutated project files after malformed jail refusal'

echo 'TEST I5: complete absence of Router IP Push is a supported fresh install'
export RIPH_NGINX_BIN="${T5}/usr/local/bin/nginx-stub" RIPH_SYSTEMCTL_BIN="${T5}/usr/local/bin/systemctl-stub" RIPH_UFW_BIN="${T5}/usr/local/bin/ufw-stub"
"${INSTALLER}" --root "${T5}" --check >/dev/null
"${INSTALLER}" --root "${T5}" --install --apply >/dev/null
P5="${T5}/var/lib/router-ip-push-hardening/providers/router-ip-push.json"
[[ "$(jq -r '.status' "${P5}")" == absent ]] || fail 'missing Pusher did not materialize absent provider state'
[[ "$(jq '.routers|length' "${P5}")" == 0 ]] || fail 'zero-provider install invented routers'
A5="${T5}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
grep -Fq '127.0.0.1/32' "${A5}" || fail 'zero-provider install lost static trust'
! grep -Fq 'router-ip-push:' "${A5}" || fail 'zero-provider install invented dynamic trust'

echo 'PASS: installer optional-provider and transaction tests'
