#!/usr/bin/env bash
set -Eeuo pipefail

section() { printf '\n===== %s =====\n' "$1"; }
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ "${EUID}" -eq 0 ]] || fail 'run as root so Nginx can read the same production files during validation'
for cmd in nginx diff awk sed grep fail2ban-regex; do
    command -v "${cmd}" >/dev/null 2>&1 || fail "required command missing: ${cmd}"
done

ROUTER_IP_FILE=/var/lib/router-ip-push/ips/AX3200.ipv4
[[ -f "${ROUTER_IP_FILE}" ]] || fail "missing ${ROUTER_IP_FILE}"
ROUTER_IP="$(tr -d '[:space:]' <"${ROUTER_IP_FILE}")"
[[ "${ROUTER_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || fail "invalid AX3200 IPv4: ${ROUTER_IP}"
IFS=. read -r a b c d <<<"${ROUTER_IP}"
for octet in "$a" "$b" "$c" "$d"; do ((10#${octet} <= 255)) || fail "invalid AX3200 IPv4: ${ROUTER_IP}"; done

TMP="$(mktemp -d /tmp/riph-candidate.XXXXXX)"
trap 'rm -rf "${TMP}"' EXIT
mkdir -p "${TMP}/stream-enabled" "${TMP}/f2b"

ALLOW="${TMP}/stream-enabled/05-router-ip-push-source-allow.conf"
BRIDGE="${TMP}/stream-enabled/06-router-ip-push-fake-site-bridges.conf"
STREAM="${TMP}/stream-enabled/stream.conf"

cat >"${ALLOW}" <<EOF_ALLOW
# Managed by router-ip-push-hardening. DO NOT EDIT.
# Effective trusted source set.

geo \$router_ip_push_source_allowed {
        default 0;
        127.0.0.1/32 1; # localhost
        5.61.39.137/32 1; # VPS_GR
        45.87.41.121/32 1; # Spectra
        194.104.94.182/32 1; # Hexabyte
        ${ROUTER_IP}/32 1; # router-ip-push:AX3200
}
EOF_ALLOW

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
printf 'temp root: %s\nAX3200 current IPv4: %s\n' "${TMP}" "${ROUTER_IP}"

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
printf 'PASS: expected Hexabyte routing is present\n'

section 'Diff: trusted allowlist'
diff -u /etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf "${ALLOW}" || true

section 'Diff: fake-site bridges'
diff -u /etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf "${BRIDGE}" || true

section 'Diff: stream routing'
diff -u /etc/nginx/stream-enabled/stream.conf "${STREAM}" || true

section 'Temporary Nginx syntax validation'
[[ -f /etc/nginx/stream-enabled/00-sni-watch.conf ]] || fail 'legacy 00-sni-watch.conf missing; overlap candidate intentionally requires it'
cp /etc/nginx/stream-enabled/00-sni-watch.conf "${TMP}/stream-enabled/00-sni-watch.conf"
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
nginx -t -q -e stderr -p /etc/nginx -c "${TMP}/nginx.conf"
printf 'PASS: temporary candidate passes nginx -t\n'

section 'Fail2ban regex compatibility on Debian host'
cat >"${TMP}/f2b/sample.log" <<'EOF_LOG'
2026-08-17T14:00:00+00:00 src=203.0.113.10 route=reject sni=- upstream=127.0.0.1:9 status=502 session=0.001
2026-08-17T14:00:01+00:00 src=203.0.113.11 route=fake_1 sni=treda.layerupzap.ru upstream=127.0.0.1:9543 status=200 session=1.000
2026-08-17T14:00:02+00:00 src=203.0.113.12 route=fake_2 sni=trongo.layerupzap.ru upstream=127.0.0.1:9544 status=200 session=1.100
2026-08-17T14:00:03+00:00 src=78.111.155.187 route=xray_1 sni=treda.layerupzap.ru upstream=127.0.0.1:8443 status=200 session=20.000
2026-08-17T14:00:04+00:00 src=198.51.100.7 route=www sni=nukla.layerupzap.ru upstream=127.0.0.1:7443 status=200 session=0.300
EOF_LOG
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
printf 'PASS: Fail2ban regexes behave as intended on this server\n'

section 'Candidate report complete'
printf 'No file under /etc, /var/lib, /var/log, UFW, Fail2ban runtime or systemd was changed by this script.\n'
