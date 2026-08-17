#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOVER="${ROOT}/src/usr/local/sbin/riph-legacy-handover"
T="$(mktemp -d /tmp/riph-legacy-handover.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/nginx/stream-enabled" \
    "${T}/etc/fail2ban/jail.d" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/usr/local/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '78.111.155.187' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
printf '%s\n' 'STREAM_SENTINEL' >"${T}/etc/nginx/stream-enabled/stream.conf"
printf '%s\n' 'LEGACY_WATCH' >"${T}/etc/nginx/stream-enabled/00-sni-watch.conf"
printf '%s\n' '[nginx-stream-sni-reject]' >"${T}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local"

BANS="${T}/bans.txt"
printf '%s\n' '66.132.224.81' >"${BANS}"
cat >"${T}/usr/local/bin/f2b-stub" <<'EOF_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    status)
        case "${2:-}" in
            nginx-stream-sni-reject|riph-nginx-stream-sni-reject|riph-nginx-stream-private-sni-abuse) exit 0 ;;
            *) exit 1 ;;
        esac
        ;;
    get)
        if [[ "${2:-}" == nginx-stream-sni-reject && "${3:-}" == banip ]]; then
            cat "${RIPH_TEST_BANS:?}"
        fi
        ;;
    -t|reload) exit 0 ;;
esac
EOF_STUB
cat >"${T}/usr/local/bin/apply-stub" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${RIPH_TEST_APPLY_LOG:?}"
EOF_APPLY
chmod +x "${T}/usr/local/bin/f2b-stub" "${T}/usr/local/bin/apply-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${T}/usr/local/bin/f2b-stub"
export RIPH_APPLY_BIN="${T}/usr/local/bin/apply-stub"
export RIPH_TEST_BANS="${BANS}"
export RIPH_TEST_APPLY_LOG="${T}/apply.log"

"${HANDOVER}" --root "${T}" status >/dev/null
"${HANDOVER}" --root "${T}" quiesce
grep -Fx 'LEGACY_STREAM_AUDIT_COMPAT=0' "${T}/etc/router-ip-push-hardening/config.env" >/dev/null
[[ -f "${T}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] || { echo 'FAIL: quiesce retired watch too early' >&2; exit 1; }
[[ -f "${T}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] || { echo 'FAIL: quiesce retired jail too early' >&2; exit 1; }

if "${HANDOVER}" --root "${T}" retire; then
    echo 'FAIL: retirement succeeded with legacy bans present' >&2
    exit 1
fi
[[ -f "${T}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] || { echo 'FAIL: refused retirement changed watch file' >&2; exit 1; }

: >"${BANS}"
"${HANDOVER}" --root "${T}" retire
[[ ! -e "${T}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] || { echo 'FAIL: watch file not retired' >&2; exit 1; }
[[ ! -e "${T}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] || { echo 'FAIL: legacy jail file not retired' >&2; exit 1; }
find "${T}/var/lib/router-ip-push-hardening/runtime/legacy-retired" -type f -name '00-sni-watch.conf' | grep -q .
find "${T}/var/lib/router-ip-push-hardening/runtime/legacy-retired" -type f -name 'nginx-stream-sni-reject.local' | grep -q .

echo 'PASS: legacy handover tests'
