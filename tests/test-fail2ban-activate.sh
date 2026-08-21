#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVATE="${ROOT}/src/usr/local/sbin/riph-fail2ban-activate"
SYNC="${ROOT}/src/usr/local/sbin/riph-provider-router-ip-push-sync"
BASE="$(mktemp -d /tmp/riph-f2b-activate.XXXXXX)"
trap 'rm -rf "${BASE}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

make_case() {
    local t="$1" legacy_ban="${2:-203.0.113.81}"
    mkdir -p \
        "${t}/etc/router-ip-push-hardening" \
        "${t}/etc/fail2ban/jail.d" \
        "${t}/etc/fail2ban/filter.d" \
        "${t}/var/lib/router-ip-push/ips" \
        "${t}/var/log/nginx" \
        "${t}/usr/local/bin"
    cp "${ROOT}/config/config.env.example" "${t}/etc/router-ip-push-hardening/config.env"
    cp "${ROOT}/config/trusted-static.list.example" "${t}/etc/router-ip-push-hardening/trusted-static.list"
    cp "${ROOT}/config/previous-ip-grace.json.example" "${t}/etc/router-ip-push-hardening/previous-ip-grace.json"
    : >"${t}/etc/router-ip-push-hardening/manual-deny-443.list"
    : >"${t}/etc/router-ip-push-hardening/manual-deny-all.list"
    printf '%s\n' '192.0.2.26' >"${t}/var/lib/router-ip-push/ips/ROUTER_A.ipv4"
    bash "${SYNC}" --root "${t}" --no-reconcile >/dev/null
    : >"${t}/var/log/nginx/riph-stream-sni.log"
    cp "${ROOT}/src/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" "${t}/etc/fail2ban/jail.d/"
    cp "${ROOT}/src/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" "${t}/etc/fail2ban/jail.d/"
    cp "${ROOT}/src/etc/fail2ban/filter.d/riph-nginx-stream-sni-reject.conf" "${t}/etc/fail2ban/filter.d/"
    cp "${ROOT}/src/etc/fail2ban/filter.d/riph-nginx-stream-private-sni-abuse.conf" "${t}/etc/fail2ban/filter.d/"

    cat >"${t}/usr/local/bin/f2b-stub" <<EOF_STUB
#!/usr/bin/env bash
set -Eeuo pipefail
case "\${1:-}" in
    status) exit 0 ;;
    get)
        if [[ "\${2:-}" == nginx-stream-sni-reject && "\${3:-}" == banip ]]; then
            printf '%s\n' '${legacy_ban}'
        fi
        ;;
    set) exit 0 ;;
    -t|reload) exit 0 ;;
esac
EOF_STUB
    chmod +x "${t}/usr/local/bin/f2b-stub"
}

CASE_OK="${BASE}/ok"
make_case "${CASE_OK}"
cat >"${CASE_OK}/usr/local/bin/guard-ok" <<'EOF_GUARD_OK'
#!/usr/bin/env bash
exit 0
EOF_GUARD_OK
chmod +x "${CASE_OK}/usr/local/bin/guard-ok"

export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_OK}/usr/local/bin/f2b-stub"
export RIPH_GUARD_BIN="${CASE_OK}/usr/local/bin/guard-ok"

"${ACTIVATE}" --root "${CASE_OK}" >"${CASE_OK}/out.txt" 2>&1
grep -Fq 'RIPH Fail2ban jails activated; legacy jail remains active under dynamic trusted ignore protection' "${CASE_OK}/out.txt" \
    || fail 'legacy-active success message is wrong'
grep -Fx 'enabled = true' "${CASE_OK}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" >/dev/null \
    || fail 'reject jail was not enabled'
grep -Fx 'enabled = true' "${CASE_OK}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" >/dev/null \
    || fail 'private-abuse jail was not enabled'
LEGACY_OVERRIDE="${CASE_OK}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local"
[[ -f "${LEGACY_OVERRIDE}" ]] || fail 'legacy dynamic trusted ignore override was not created'
grep -Fx 'ignorecommand = /usr/local/sbin/riph-fail2ban-ignore <ip>' "${LEGACY_OVERRIDE}" >/dev/null \
    || fail 'legacy dynamic trusted ignore override is wrong'
backup_count="$(find "${CASE_OK}/var/lib/router-ip-push-hardening/backups" -maxdepth 1 -type d -name 'fail2ban-activate-*' | wc -l)"
[[ "${backup_count}" -eq 1 ]] || fail 'activation backup missing'

CASE_NO_LEGACY="${BASE}/no-legacy"
make_case "${CASE_NO_LEGACY}"
cat >"${CASE_NO_LEGACY}/usr/local/bin/f2b-stub" <<'EOF_NO_LEGACY_F2B'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    status)
        if [[ "${2:-}" == nginx-stream-sni-reject ]]; then exit 1; fi
        exit 0
        ;;
    get|set|-t|reload) exit 0 ;;
esac
EOF_NO_LEGACY_F2B
chmod +x "${CASE_NO_LEGACY}/usr/local/bin/f2b-stub"
cat >"${CASE_NO_LEGACY}/usr/local/bin/guard-ok" <<'EOF_NO_LEGACY_GUARD'
#!/usr/bin/env bash
exit 0
EOF_NO_LEGACY_GUARD
chmod +x "${CASE_NO_LEGACY}/usr/local/bin/guard-ok"
export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_NO_LEGACY}/usr/local/bin/f2b-stub"
export RIPH_GUARD_BIN="${CASE_NO_LEGACY}/usr/local/bin/guard-ok"
"${ACTIVATE}" --root "${CASE_NO_LEGACY}" >"${CASE_NO_LEGACY}/out.txt" 2>&1
grep -Fq 'RIPH Fail2ban jails activated; no legacy jail was active' "${CASE_NO_LEGACY}/out.txt" || fail 'no-legacy success message is wrong'
[[ ! -e "${CASE_NO_LEGACY}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] || fail 'legacy ignore override was created without an active legacy jail'

CASE_FAIL="${BASE}/fail"
make_case "${CASE_FAIL}"
cp "${CASE_FAIL}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" "${CASE_FAIL}/reject.before"
cp "${CASE_FAIL}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" "${CASE_FAIL}/private.before"
cat >"${CASE_FAIL}/usr/local/bin/guard-fail" <<'EOF_GUARD_FAIL'
#!/usr/bin/env bash
exit 42
EOF_GUARD_FAIL
chmod +x "${CASE_FAIL}/usr/local/bin/guard-fail"
export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_FAIL}/usr/local/bin/f2b-stub"
export RIPH_GUARD_BIN="${CASE_FAIL}/usr/local/bin/guard-fail"
if "${ACTIVATE}" --root "${CASE_FAIL}" >/dev/null 2>&1; then fail 'activation unexpectedly succeeded when late guard failed'; fi
cmp -s "${CASE_FAIL}/reject.before" "${CASE_FAIL}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" || fail 'reject jail was not restored after activation failure'
cmp -s "${CASE_FAIL}/private.before" "${CASE_FAIL}/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" || fail 'private-abuse jail was not restored after activation failure'
[[ ! -e "${CASE_FAIL}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] || fail 'legacy ignore override was not removed after activation rollback'

CASE_BANNED="${BASE}/current-banned"
make_case "${CASE_BANNED}" '192.0.2.26'
cat >"${CASE_BANNED}/usr/local/bin/guard-ok" <<'EOF_GUARD_OK2'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RIPH_TEST_GUARD_COLLISION_LOG:?}"
exit 0
EOF_GUARD_OK2
chmod +x "${CASE_BANNED}/usr/local/bin/guard-ok"
export RIPH_FAIL2BAN_CLIENT_BIN="${CASE_BANNED}/usr/local/bin/f2b-stub"
export RIPH_GUARD_BIN="${CASE_BANNED}/usr/local/bin/guard-ok"
export RIPH_TEST_GUARD_COLLISION_LOG="${CASE_BANNED}/guard.log"
"${ACTIVATE}" --root "${CASE_BANNED}" >"${CASE_BANNED}/out.txt" 2>&1
grep -Fq 'legacy ban will remain untouched and RIPH trusted shield will protect TCP/443' "${CASE_BANNED}/out.txt" || fail 'legacy current-IP collision warning missing'
grep -Fx 'enabled = true' "${CASE_BANNED}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" >/dev/null || fail 'legacy collision prevented RIPH jail activation'
[[ -f "${CASE_BANNED}/etc/fail2ban/jail.d/zz-riph-legacy-trusted-ignore.local" ]] || fail 'legacy collision did not install dynamic ignore override'
[[ -s "${CASE_BANNED}/guard.log" ]] || fail 'legacy collision activation did not reach trusted guard'

echo 'PASS: Fail2ban activation tests with canonical provider state'
