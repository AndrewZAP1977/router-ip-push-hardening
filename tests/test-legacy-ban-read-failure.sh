#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOVER="${ROOT}/src/usr/local/sbin/riph-legacy-handover"
T="$(mktemp -d /tmp/riph-legacy-ban-read.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/etc/nginx/stream-enabled" \
    "${T}/etc/fail2ban/jail.d" \
    "${T}/var/lib/router-ip-push/ips" \
    "${T}/bin"

cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
grep -Fx 'LEGACY_STREAM_AUDIT_COMPAT=0' "${T}/etc/router-ip-push-hardening/config.env" >/dev/null \
    || fail 'production config example must default legacy audit compatibility off'
printf '%s\n' '192.0.2.26' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
printf '%s\n' 'STREAM_SENTINEL' >"${T}/etc/nginx/stream-enabled/stream.conf"
printf '%s\n' 'LEGACY_WATCH' >"${T}/etc/nginx/stream-enabled/00-sni-watch.conf"
printf '%s\n' '[nginx-stream-sni-reject]' >"${T}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local"
cat >"${T}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" <<'EOF_OVERRIDE'
[nginx-stream-sni-reject]
ignorecommand = /usr/local/sbin/riph-fail2ban-ignore <ip>
EOF_OVERRIDE

cat >"${T}/bin/f2b-stub" <<'EOF_F2B'
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
            exit 17
        fi
        exit 1
        ;;
    *) exit 0 ;;
esac
EOF_F2B

cat >"${T}/bin/guard-stub" <<'EOF_GUARD'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RIPH_TEST_GUARD_LOG:?}"
exit 0
EOF_GUARD
chmod +x "${T}/bin/f2b-stub" "${T}/bin/guard-stub"

export RIPH_FAIL2BAN_CLIENT_BIN="${T}/bin/f2b-stub"
export RIPH_GUARD_BIN="${T}/bin/guard-stub"
export RIPH_TEST_GUARD_LOG="${T}/guard.log"

STATUS_OUT="${T}/status.out"
"${HANDOVER}" --root "${T}" status >"${STATUS_OUT}"
grep -Fq 'legacy banned IPs:           ERROR: unreadable' "${STATUS_OUT}" \
    || fail 'status did not surface unreadable legacy ban state'

if "${HANDOVER}" --root "${T}" retire >"${T}/retire.out" 2>&1; then
    fail 'retirement succeeded even though active legacy ban state was unreadable'
fi
grep -Fq 'cannot reliably read legacy nginx-stream-sni-reject ban list during retirement preflight' "${T}/retire.out" \
    || fail 'fail-closed retirement refusal message missing'
[[ -f "${T}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] \
    || fail 'unreadable-ban refusal moved legacy watch'
[[ -f "${T}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] \
    || fail 'unreadable-ban refusal moved legacy jail'
[[ -f "${T}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] \
    || fail 'unreadable-ban refusal moved legacy ignore override'
[[ ! -s "${T}/guard.log" ]] \
    || fail 'unreadable-ban refusal reached UFW shield mutation'

echo 'PASS: unreadable legacy ban state fails closed'
