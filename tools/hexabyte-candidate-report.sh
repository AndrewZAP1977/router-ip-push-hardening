#!/usr/bin/env bash
set -Eeuo pipefail

section() { printf '\n===== %s =====\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }

[[ "${EUID}" -eq 0 ]] || fail 'run as root so Nginx can read the same production files during validation'
for cmd in nginx diff awk sed grep fail2ban-regex systemctl tail sort; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command missing: ${cmd}"
done

ROUTER_IP_FILE=/var/lib/router-ip-push/ips/AX3200.ipv4
CURRENT_ALLOW=/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf
CURRENT_STREAM=/etc/nginx/stream-enabled/stream.conf
CURRENT_BRIDGE=/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf
LEGACY_WATCH=/etc/nginx/stream-enabled/00-sni-watch.conf
LEGACY_LOG=/var/log/nginx/stream-sni.log

[[ -f "${ROUTER_IP_FILE}" ]] || fail "missing ${ROUTER_IP_FILE}"
[[ -f "${CURRENT_ALLOW}" ]] || fail "missing ${CURRENT_ALLOW}"
[[ -f "${CURRENT_STREAM}" ]] || fail "missing ${CURRENT_STREAM}"
[[ -f "${CURRENT_BRIDGE}" ]] || fail "missing ${CURRENT_BRIDGE}"
[[ -f "${LEGACY_WATCH}" ]] || fail "legacy 00-sni-watch.conf missing; overlap candidate intentionally requires it"

ROUTER_IP="$(tr -d '[:space:]' <"${ROUTER_IP_FILE}")"
[[ "${ROUTER_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "invalid AX3200 IPv4: ${ROUTER_IP}"
IFS=. read -r a b c d <<<"${ROUTER_IP}"
for octet in "$a" "$b" "$c" "$d"; do
    [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || fail "invalid AX3200 IPv4: ${ROUTER_IP}"
    ((10#${octet} <= 255)) || fail "invalid AX3200 IPv4: ${ROUTER_IP}"
done

section 'Current production safety gate'
nginx -t

for unit in router-ip-push-nginx-hotfix.path router-ip-push-nginx-hotfix.timer; do
    enabled="$(systemctl is-enabled "${unit}" 2>/dev/null || true)"
    active="$(systemctl is-active "${unit}" 2>/dev/null || true)"
    printf '%-42s enabled=%-10s active=%s\n' "${unit}" "${enabled:-unknown}" "${active:-unknown}"
    [[ "${enabled}" == enabled && "${active}" == active ]] \
        || fail "temporary safeguard is not fully active: ${unit}"
done
service_active="$(systemctl is-active router-ip-push-nginx-hotfix.service 2>/dev/null || true)"
printf '%-42s active=%s (oneshot; inactive is normal between checks)\n' \
    'router-ip-push-nginx-hotfix.service' "${service_active:-unknown}"

printf 'AX3200 Router IP Push current IPv4: %s\n' "${ROUTER_IP}"
router_line_count="$(grep -Ec '# router-ip-push:AX3200([^[:alnum:]_-]|$)' "${CURRENT_ALLOW}" || true)"
[[ "${router_line_count}" == 1 ]] \
    || fail "current staging allowlist must contain exactly one AX3200 dynamic line; found ${router_line_count}"
grep -Eq "^[[:space:]]*${ROUTER_IP//./\\.}/32[[:space:]]+1;[[:space:]]+# router-ip-push:AX3200" "${CURRENT_ALLOW}" \
    || fail "temporary safeguard/current staging allowlist is not synchronized to Router IP Push ${ROUTER_IP}"
printf 'PASS: temporary safeguard owns a synchronized staging allowlist\n'

if [[ -f "${LEGACY_LOG}" ]]; then
    if tail -n 250 "${LEGACY_LOG}" \
        | grep -F "ip=\"${ROUTER_IP}\"" \
        | grep -F 'sni="treda.layerupzap.ru"' \
        | grep -F 'upstream="127.0.0.1:8443"' >/dev/null; then
        printf 'PASS: recent legacy log confirms current AX3200 -> treda -> Xray 8443\n'
    else
        warn 'no recent AX3200/treda/8443 line found; this is informational if no recent client session exists'
    fi
fi

TMP="$(mktemp -d /tmp/riph-candidate.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/stream-enabled" "${TMP}/f2b"

ALLOW="${TMP}/stream-enabled/05-router-ip-push-source-allow.conf"
BRIDGE="${TMP}/stream-enabled/06-router-ip-push-fake-site-bridges.conf"
STREAM="${TMP}/stream-enabled/stream.conf"

cat >"${ALLOW}" <<EOF_ALLOW
# Managed by router-ip-push-hardening. DO NOT EDIT.
# Regenerate with: riph-apply
geo \$router_ip_push_source_allowed {
        default 0;
        127.0.0.1/32     1; # localhost
        5.61.39.137/32   1; # VPS_GR
        45.87.41.121/32  1; # Spectra
        194.104.94.182/32 1; # Hexabyte
        ${ROUTER_IP}/32$(printf '%*s' $((19 - ${#ROUTER_IP} - 3)) '')1; # router-ip-push:AX3200 current
}
EOF_ALLOW

# Re-render allowlist with the exact %-18s formatting used by the generator.
{
    printf '# Managed by router-ip-push-hardening. DO NOT EDIT.\n'
    printf '# Regenerate with: riph-apply\n'
    printf 'geo $router_ip_push_source_allowed {\n'
    printf '        default 0;\n'
    printf '        %-18s 1; # localhost\n' '127.0.0.1/32'
    printf '        %-18s 1; # VPS_GR\n' '5.61.39.137/32'
    printf '        %-18s 1; # Spectra\n' '45.87.41.121/32'
    printf '        %-18s 1; # Hexabyte\n' '194.104.94.182/32'
    printf '        %-18s 1; # router-ip-push:AX3200 current\n' "${ROUTER_IP}/32"
    printf '}\n'
} >"${ALLOW}"

cat >"${BRIDGE}" <<'EOF_BRIDGE'
# Managed by router-ip-push-hardening. DO NOT EDIT.
# PROXY-protocol bridges for untrusted private SNI fake sites.

server
{
        listen 127.0.0.1:9543 proxy_protocol;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        tcp_nodelay on;
        proxy_pass 127.0.0.1:9443;
}

server
{
        listen 127.0.0.1:9544 proxy_protocol;
        proxy_connect_timeout 5s;
        proxy_timeout 1h;
        tcp_nodelay on;
        proxy_pass 127.0.0.1:9444;
}
EOF_BRIDGE

cat >"${STREAM}" <<'EOF_STREAM'
# Managed by router-ip-push-hardening. DO NOT EDIT.
# Private SNI routing: trusted -> Xray, untrusted -> fake site.

log_format riph_stream_sni '$time_iso8601 src=$remote_addr route=$sni_name sni=$ssl_preread_server_name upstream=$upstream_addr status=$status session=$session_time';

map "$ssl_preread_server_name|$router_ip_push_source_allowed" $sni_name
{
        nukla.layerupzap.ru|0                 www;
        nukla.layerupzap.ru|1                 www;
        treda.layerupzap.ru|1                 xray_1;
        treda.layerupzap.ru|0                 fake_1;
        trongo.layerupzap.ru|1                xray_2;
        trongo.layerupzap.ru|0                fake_2;
        default                               reject;
}

upstream www
{
        server 127.0.0.1:7443;
}

upstream xray_1
{
        server 127.0.0.1:8443;
}

upstream fake_1
{
        server 127.0.0.1:9543;
}

upstream xray_2
{
        server 127.0.0.1:8444;
}

upstream fake_2
{
        server 127.0.0.1:9544;
}

upstream reject
{
        server 127.0.0.1:9;
}

server
{
        # Migration overlap: keep the already-active legacy reject jail fed.
        access_log /var/log/nginx/stream-sni.log sni_watch buffer=32k flush=5s;
        # New machine-stable RIPH audit log used by the future riph-* jails.
        access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;
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

section 'Candidate files are temporary only'
printf 'temp root: %s\nAX3200 current IPv4 used by candidate: %s\n' "${TMP}" "${ROUTER_IP}"

section 'Semantic routing checks'
for check in \
    'nukla.layerupzap.ru|0                 www;' \
    'nukla.layerupzap.ru|1                 www;' \
    'treda.layerupzap.ru|1                 xray_1;' \
    'treda.layerupzap.ru|0                 fake_1;' \
    'trongo.layerupzap.ru|1                xray_2;' \
    'trongo.layerupzap.ru|0                fake_2;' \
    'server 127.0.0.1:8443;' \
    'server 127.0.0.1:8444;' \
    'server 127.0.0.1:9543;' \
    'server 127.0.0.1:9544;' \
    'server 127.0.0.1:9;'; do
    grep -Fq "${check}" "${STREAM}" || fail "candidate routing check failed: ${check}"
done
grep -Fq "${ROUTER_IP}/32" "${ALLOW}" || fail 'candidate allowlist lost current Router IP'
printf 'PASS: expected Hexabyte routing and current Router IP are present\n'

section 'Diff: trusted allowlist'
diff -u "${CURRENT_ALLOW}" "${ALLOW}" || true

section 'Diff: fake-site bridges'
diff -u "${CURRENT_BRIDGE}" "${BRIDGE}" || true

section 'Diff: stream routing'
diff -u "${CURRENT_STREAM}" "${STREAM}" || true

section 'Temporary Nginx syntax validation'
cp "${LEGACY_WATCH}" "${TMP}/stream-enabled/00-sni-watch.conf"
# Prevent nginx -t from opening production audit files while validating the temporary candidate.
sed -i -E 's#^[[:space:]]*access_log[[:space:]]+[^;]+;#access_log /dev/null sni_watch;#' "${TMP}/stream-enabled/00-sni-watch.conf"
cp "${STREAM}" "${TMP}/stream-enabled/stream.validate.conf"
sed -i -E 's#^[[:space:]]*access_log[[:space:]]+/var/log/nginx/stream-sni\.log[[:space:]]+sni_watch[^;]*;#        access_log /dev/null sni_watch;#' "${TMP}/stream-enabled/stream.validate.conf"
sed -i -E 's#^[[:space:]]*access_log[[:space:]]+/var/log/nginx/riph-stream-sni\.log[[:space:]]+riph_stream_sni;#        access_log /dev/null riph_stream_sni;#' "${TMP}/stream-enabled/stream.validate.conf"
rm -f "${TMP}/stream-enabled/stream.conf"

awk -v include_path="${TMP}/stream-enabled/*.conf" '
    $0 ~ /^[[:space:]]*include[[:space:]]+\/etc\/nginx\/stream-enabled\/\*\.conf;/ {
        sub(/\/etc\/nginx\/stream-enabled\/\*\.conf/, include_path)
    }
    {print}
' /etc/nginx/nginx.conf >"${TMP}/nginx.conf"
# Keep Nginx's compiled/default prefix exactly as production nginx -t does.
# Overriding -p here changes the base for relative load_module paths on Debian
# (for example modules/ngx_http_auth_pam_module.so) and can produce a false
# candidate failure even while the real production configuration validates.
nginx -t -q -e stderr -c "${TMP}/nginx.conf"
printf 'PASS: temporary candidate passes nginx -t\n'

section 'Fail2ban regex compatibility on this Debian host'
cat >"${TMP}/f2b/sample.log" <<'EOF_LOG'
2026-08-17T14:00:00+00:00 src=203.0.113.10 route=reject sni=- upstream=127.0.0.1:9 status=502 session=0.001
2026-08-17T14:00:01+00:00 src=203.0.113.11 route=fake_1 sni=treda.layerupzap.ru upstream=127.0.0.1:9543 status=200 session=1.000
2026-08-17T14:00:02+00:00 src=203.0.113.12 route=fake_2 sni=trongo.layerupzap.ru upstream=127.0.0.1:9544 status=200 session=1.100
2026-08-17T14:00:04+00:00 src=198.51.100.7 route=www sni=nukla.layerupzap.ru upstream=127.0.0.1:7443 status=200 session=0.300
EOF_LOG
printf '2026-08-17T14:00:03+00:00 src=%s route=xray_1 sni=treda.layerupzap.ru upstream=127.0.0.1:8443 status=200 session=20.000\n' \
    "${ROUTER_IP}" >>"${TMP}/f2b/sample.log"
cat >"${TMP}/f2b/reject.conf" <<'EOF_REJECT'
[Definition]
failregex = ^\s*src=<HOST>\s+route=reject(?:\s|$)
ignoreregex =
datepattern = {^LN-BEG}%%ExY(?P<_sep>[-/.])%%m(?P=_sep)%%d[T ]%%H:%%M:%%S(?:[.,]%%f)?(?:\s*%%z)?
              {^LN-BEG}
EOF_REJECT
cat >"${TMP}/f2b/private.conf" <<'EOF_PRIVATE'
[Definition]
failregex = ^\s*src=<HOST>\s+route=fake_[0-9]+(?:\s|$)
ignoreregex =
datepattern = {^LN-BEG}%%ExY(?P<_sep>[-/.])%%m(?P=_sep)%%d[T ]%%H:%%M:%%S(?:[.,]%%f)?(?:\s*%%z)?
              {^LN-BEG}
EOF_PRIVATE
reject_out="$(fail2ban-regex "${TMP}/f2b/sample.log" "${TMP}/f2b/reject.conf" --usedns=no -o ip | sort -u)"
private_out="$(fail2ban-regex "${TMP}/f2b/sample.log" "${TMP}/f2b/private.conf" --usedns=no -o ip | sort -u)"
printf 'reject matches:\n%s\nprivate-abuse matches:\n%s\n' "${reject_out}" "${private_out}"
[[ "${reject_out}" == '203.0.113.10' ]] || fail 'reject Fail2ban regex result mismatch'
[[ "${private_out}" == $'203.0.113.11\n203.0.113.12' ]] || fail 'private Fail2ban regex result mismatch'
if grep -Fxq "${ROUTER_IP}" <<<"${reject_out}${private_out}"; then
    fail "current trusted Router IP ${ROUTER_IP} unexpectedly matched a ban filter"
fi
printf 'PASS: Fail2ban regexes behave as intended and current Router IP is not a match\n'

section 'Candidate report complete'
printf 'PASS: current temporary safeguard remained active and synchronized.\n'
printf 'PASS: candidate routing was built and validated only under %s.\n' "${TMP}"
printf 'No file under /etc, /var/lib, /var/log, UFW, Fail2ban runtime or systemd was changed by this script.\n'
