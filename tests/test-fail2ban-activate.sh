#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVATE="${ROOT}/src/usr/local/sbin/riph-fail2ban-activate"
T="$(mktemp -d /tmp/riph-f2b-activate.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/fail2ban/jail.d" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/var/log/nginx" \
    "${T}/usr/local/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
cp "${ROOT}/config/trusted-static.list.example" "${T}/etc/router-ip-push-hardening/trusted-static.list"
cp "${ROOT}/config/previous-ip-grace.json.example" "${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
: >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
: >"${T}/etc/router-ip-push-hardening/manual-deny-all.list"
printf '%s\n' '78.111.155.187' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
: >"${T}/var/log/nginx/riph-stream-sni.log"
cp "${ROOT}/src/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" "${T}/etc/fail2ban/jail.d/"
cp "${ROOT}/src/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" "${T}/etc/fail2ban/jail.d/"

cat >"${T}/usr/local/bin/f2b-stub" <<'EOF_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    status) exit 0 ;;
    get)
        if [[ "${2:-}" == nginx-stream-sni-reject && "${3:-}" == banip ]]; then
            printf '%s\n' '66.132.224.81'
        fi
        ;;
    set) exit 0 ;;
    -t|reload) exit 0 ;;
esac
EOF_STUB
chmod +x "${T}/usr/local/bin/f2b-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${T}/usr/local/bin/f2b-stub"

"${ACTIVATE}" --root "${T}"
grep -Fx 'enabled = true' "${T}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" >/dev/null
grep -Fx 'enabled = true' "${T}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" >/dev/null

backup_count="$(find "${T}/var/lib/router-ip-push-hardening/backups" -maxdepth 1 -type d -name 'fail2ban-activate-*' | wc -l)"
[[ "${backup_count}" -eq 1 ]] || { echo 'FAIL: activation backup missing' >&2; exit 1; }

echo 'PASS: Fail2ban activation tests'
