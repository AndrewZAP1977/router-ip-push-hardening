#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HANDOVER="${ROOT}/src/usr/local/sbin/riph-legacy-handover"
BASE="$(mktemp -d /tmp/riph-legacy-handover.XXXXXX)"
trap 'rm -rf "${BASE}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_case() {
    local t="$1"
    mkdir -p \
        "${t}/etc/router-ip-push-hardening" \
        "${t}/etc/nginx/stream-enabled" \
        "${t}/etc/fail2ban/jail.d" \
        "${t}/var/lib/router-ip-push/ips" \
        "${t}/usr/local/bin"
    cp "${ROOT}/config/config.env.example" "${t}/etc/router-ip-push-hardening/config.env"
    # The production default is now compatibility OFF. This test intentionally
    # recreates the old coexistence phase so quiesce/retire behavior stays covered.
    sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=0$/LEGACY_STREAM_AUDIT_COMPAT=1/' \
        "${t}/etc/router-ip-push-hardening/config.env"
    printf '%s\n' '78.111.154.96' >"${t}/var/lib/router-ip-push/ips/AX3200.ipv4"
    printf '%s\n' 'STREAM_SENTINEL' >"${t}/etc/nginx/stream-enabled/stream.conf"
    printf '%s\n' 'LEGACY_WATCH' >"${t}/etc/nginx/stream-enabled/00-sni-watch.conf"
    printf '%s\n' '[nginx-stream-sni-reject]' >"${t}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local"
    cat >"${t}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" <<'EOF_OVERRIDE'
# Managed by router-ip-push-hardening during legacy coexistence.
[nginx-stream-sni-reject]
ignorecommand = /usr/local/sbin/riph-fail2ban-ignore <ip>
EOF_OVERRIDE

    cat >"${t}/usr/local/bin/apply-stub" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${RIPH_TEST_APPLY_LOG:?}"
EOF_APPLY

    cat >"${t}/usr/local/bin/guard-stub" <<'EOF_GUARD'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${RIPH_TEST_GUARD_LOG:?}"
if [[ " $* " == *' --legacy-shield-remove-all '* && -n "${RIPH_TEST_GUARD_REMOVE_EXIT:-}" ]]; then
    exit "${RIPH_TEST_GUARD_REMOVE_EXIT}"
fi
exit 0
EOF_GUARD
    chmod +x "${t}/usr/local/bin/apply-stub" "${t}/usr/local/bin/guard-stub"
}

CASE_NORMAL="${BASE}/normal"
make_case "${CASE_NORMAL}"
BANS="${CASE_NORMAL}/bans.txt"
printf '%s\n' '66.132.224.81' >"${BANS}"
cat >"${CASE_NORMAL}/usr/local/bin/f2b-stub" <<'EOF_STUB'
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
chmod +x "${CASE_NORMAL}/usr/local/bin/f2b-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_NORMAL}/usr/local/bin/f2b-stub"
export RIPH_APPLY_BIN="${CASE_NORMAL}/usr/local/bin/apply-stub"
export RIPH_GUARD_BIN="${CASE_NORMAL}/usr/local/bin/guard-stub"
export RIPH_TEST_BANS="${BANS}"
export RIPH_TEST_APPLY_LOG="${CASE_NORMAL}/apply.log"
export RIPH_TEST_GUARD_LOG="${CASE_NORMAL}/guard.log"

"${HANDOVER}" --root "${CASE_NORMAL}" status >/dev/null
"${HANDOVER}" --root "${CASE_NORMAL}" quiesce
grep -Fx 'LEGACY_STREAM_AUDIT_COMPAT=0' "${CASE_NORMAL}/etc/router-ip-push-hardening/config.env" >/dev/null \
    || fail 'quiesce did not disable external legacy compatibility'
[[ -f "${CASE_NORMAL}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] \
    || fail 'quiesce retired watch too early'
[[ -f "${CASE_NORMAL}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] \
    || fail 'quiesce retired jail too early'
[[ -f "${CASE_NORMAL}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] \
    || fail 'quiesce retired trusted-ignore protection too early'

if "${HANDOVER}" --root "${CASE_NORMAL}" retire >/dev/null 2>&1; then
    fail 'retirement succeeded with legacy bans present'
fi
[[ -f "${CASE_NORMAL}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] \
    || fail 'refused retirement changed watch file'

: >"${BANS}"
: >"${CASE_NORMAL}/guard.log"
"${HANDOVER}" --root "${CASE_NORMAL}" retire
[[ ! -e "${CASE_NORMAL}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] \
    || fail 'watch file not retired'
[[ ! -e "${CASE_NORMAL}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] \
    || fail 'legacy jail file not retired'
[[ ! -e "${CASE_NORMAL}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] \
    || fail 'legacy trusted-ignore override not retired'
grep -Fq -- '--legacy-shield-remove-all' "${CASE_NORMAL}/guard.log" \
    || fail 'successful retirement did not remove project legacy trusted shield'
find "${CASE_NORMAL}/var/lib/router-ip-push-hardening/runtime/legacy-retired" -type f -name '00-sni-watch.conf' | grep -q . \
    || fail 'retired watch archive missing'
find "${CASE_NORMAL}/var/lib/router-ip-push-hardening/runtime/legacy-retired" -type f -name 'nginx-stream-sni-reject.local' | grep -q . \
    || fail 'retired jail archive missing'
find "${CASE_NORMAL}/var/lib/router-ip-push-hardening/runtime/legacy-retired" -type f -name 'zz-riph-legacy-trusted-ignore.local' | grep -q . \
    || fail 'retired legacy trusted-ignore override archive missing'

# Simulate a buffered pre-quiesce reject being processed after the initial empty
# ban check but before the legacy jail file is retired. The second ban check must
# abort and the EXIT transaction must restore every legacy coexistence file.
CASE_LATE="${BASE}/late-ban"
make_case "${CASE_LATE}"
sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=1$/LEGACY_STREAM_AUDIT_COMPAT=0/' \
    "${CASE_LATE}/etc/router-ip-push-hardening/config.env"
COUNT_FILE="${CASE_LATE}/ban-get.count"
cat >"${CASE_LATE}/usr/local/bin/f2b-stub" <<'EOF_LATE_STUB'
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
            count=0
            [[ -f "${RIPH_TEST_BAN_COUNT:?}" ]] && count="$(cat "${RIPH_TEST_BAN_COUNT}")"
            count=$((count + 1))
            printf '%s\n' "${count}" >"${RIPH_TEST_BAN_COUNT}"
            if (( count >= 2 )); then
                printf '%s\n' '66.132.172.105'
            fi
        fi
        ;;
    -t|reload) exit 0 ;;
esac
EOF_LATE_STUB
chmod +x "${CASE_LATE}/usr/local/bin/f2b-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_LATE}/usr/local/bin/f2b-stub"
export RIPH_APPLY_BIN="${CASE_LATE}/usr/local/bin/apply-stub"
export RIPH_GUARD_BIN="${CASE_LATE}/usr/local/bin/guard-stub"
export RIPH_TEST_APPLY_LOG="${CASE_LATE}/apply.log"
export RIPH_TEST_GUARD_LOG="${CASE_LATE}/guard.log"
export RIPH_TEST_BAN_COUNT="${COUNT_FILE}"

if "${HANDOVER}" --root "${CASE_LATE}" retire >/dev/null 2>&1; then
    fail 'retirement unexpectedly succeeded when a late legacy ban appeared'
fi
[[ -f "${CASE_LATE}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] \
    || fail 'late-ban rollback did not restore legacy watch'
[[ -f "${CASE_LATE}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] \
    || fail 'late-ban rollback changed legacy jail file'
[[ -f "${CASE_LATE}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] \
    || fail 'late-ban rollback lost legacy trusted-ignore protection'
grep -Fx 'STREAM_SENTINEL' "${CASE_LATE}/etc/nginx/stream-enabled/stream.conf" >/dev/null \
    || fail 'late-ban rollback did not restore stream config'
[[ ! -s "${CASE_LATE}/guard.log" ]] \
    || fail 'late-ban abort reached shield cleanup too early'

# A failure while removing the project shield occurs after legacy files have been
# moved. EXIT rollback must restore those files and call normal guard sync once so
# current-IP protection is recreated without touching the ambiguous legacy DENY.
CASE_SHIELD_FAIL="${BASE}/shield-fail"
make_case "${CASE_SHIELD_FAIL}"
sed -i 's/^LEGACY_STREAM_AUDIT_COMPAT=1$/LEGACY_STREAM_AUDIT_COMPAT=0/' \
    "${CASE_SHIELD_FAIL}/etc/router-ip-push-hardening/config.env"
cat >"${CASE_SHIELD_FAIL}/usr/local/bin/f2b-stub" <<'EOF_SHIELD_F2B'
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
        [[ "${2:-}" == nginx-stream-sni-reject && "${3:-}" == banip ]] && exit 0
        exit 1
        ;;
    -t|reload) exit 0 ;;
esac
EOF_SHIELD_F2B
chmod +x "${CASE_SHIELD_FAIL}/usr/local/bin/f2b-stub"
export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_SHIELD_FAIL}/usr/local/bin/f2b-stub"
export RIPH_APPLY_BIN="${CASE_SHIELD_FAIL}/usr/local/bin/apply-stub"
export RIPH_GUARD_BIN="${CASE_SHIELD_FAIL}/usr/local/bin/guard-stub"
export RIPH_TEST_APPLY_LOG="${CASE_SHIELD_FAIL}/apply.log"
export RIPH_TEST_GUARD_LOG="${CASE_SHIELD_FAIL}/guard.log"
export RIPH_TEST_GUARD_REMOVE_EXIT=42

if "${HANDOVER}" --root "${CASE_SHIELD_FAIL}" retire >/dev/null 2>&1; then
    fail 'retirement unexpectedly succeeded when shield cleanup failed'
fi
unset RIPH_TEST_GUARD_REMOVE_EXIT
[[ -f "${CASE_SHIELD_FAIL}/etc/nginx/stream-enabled/00-sni-watch.conf" ]] \
    || fail 'shield-failure rollback did not restore legacy watch'
[[ -f "${CASE_SHIELD_FAIL}/etc/fail2ban/jail.d/nginx-stream-sni-reject.local" ]] \
    || fail 'shield-failure rollback did not restore legacy jail file'
[[ -f "${CASE_SHIELD_FAIL}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] \
    || fail 'shield-failure rollback did not restore legacy trusted-ignore override'
[[ "$(wc -l <"${CASE_SHIELD_FAIL}/guard.log")" == 2 ]] \
    || fail 'shield-failure rollback should call remove-all then normal guard resync'
grep -Fq -- '--legacy-shield-remove-all' "${CASE_SHIELD_FAIL}/guard.log" \
    || fail 'shield failure test never attempted shield removal'
tail -n 1 "${CASE_SHIELD_FAIL}/guard.log" | grep -Fvq -- '--legacy-shield-remove-all' \
    || fail 'shield-failure rollback did not run normal guard resync'

echo 'PASS: legacy handover tests'
