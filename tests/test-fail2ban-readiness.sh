#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTIVATE="${ROOT}/src/usr/local/sbin/riph-fail2ban-activate"
SYNC="${ROOT}/src/usr/local/sbin/riph-provider-router-ip-push-sync"
BASE="$(mktemp -d /tmp/riph-f2b-readiness.XXXXXX)"
trap 'rm -rf "${BASE}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

make_case() {
    local t="$1" with_router="${2:-1}"
    mkdir -p "${t}/etc/router-ip-push-hardening" "${t}/etc/fail2ban/jail.d" "${t}/etc/fail2ban/filter.d" "${t}/etc/nginx/stream-enabled" "${t}/var/log/nginx" "${t}/bin"
    cp "${ROOT}/config/config.env.example" "${t}/etc/router-ip-push-hardening/config.env"
    cp "${ROOT}/config/trusted-static.list.example" "${t}/etc/router-ip-push-hardening/trusted-static.list"
    cp "${ROOT}/config/previous-ip-grace.json.example" "${t}/etc/router-ip-push-hardening/previous-ip-grace.json"
    cp "${ROOT}/src/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" "${t}/etc/fail2ban/jail.d/"
    cp "${ROOT}/src/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local" "${t}/etc/fail2ban/jail.d/"
    cp "${ROOT}/src/etc/fail2ban/filter.d/riph-nginx-stream-sni-reject.conf" "${t}/etc/fail2ban/filter.d/"
    cp "${ROOT}/src/etc/fail2ban/filter.d/riph-nginx-stream-private-sni-abuse.conf" "${t}/etc/fail2ban/filter.d/"
    if [[ "${with_router}" == 1 ]]; then
        mkdir -p "${t}/var/lib/router-ip-push/ips"
        printf '%s\n' '192.0.2.26' >"${t}/var/lib/router-ip-push/ips/ROUTER_A.ipv4"
    fi
    bash "${SYNC}" --root "${t}" --no-reconcile >/dev/null
    : >"${t}/var/log/nginx/riph-stream-sni.log"
    cat >"${t}/etc/nginx/stream-enabled/stream.conf" <<'EOF_STREAM'
server {
    access_log /var/log/nginx/riph-stream-sni.log riph_stream_sni;
}
EOF_STREAM
    if [[ "${with_router}" == 1 ]]; then
        cat >"${t}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<'EOF_ALLOW'
geo $router_ip_push_source_allowed {
    default 0;
    192.0.2.26/32 1; # router-ip-push:ROUTER_A current
}
EOF_ALLOW
    else
        cat >"${t}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<'EOF_ALLOW_ZERO'
geo $router_ip_push_source_allowed {
    default 0;
    127.0.0.1/32 1; # localhost
}
EOF_ALLOW_ZERO
    fi
    cat >"${t}/bin/f2b-stub" <<'EOF_F2B'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
    -t) exit 0;;
    status) [[ "${2:-}" == nginx-stream-sni-reject ]] && exit 0; exit 1;;
    get) [[ "${2:-}" == nginx-stream-sni-reject && "${3:-}" == banip ]] && exit 0; exit 1;;
    *) exit 0;;
esac
EOF_F2B
    cat >"${t}/bin/f2b-regex-stub" <<'EOF_REGEX'
#!/usr/bin/env bash
case "${2:-}" in
    *riph-nginx-stream-sni-reject.conf) printf '%s\n' '203.0.113.10';;
    *riph-nginx-stream-private-sni-abuse.conf) printf '%s\n' '203.0.113.11' '203.0.113.12';;
    *) exit 2;;
esac
EOF_REGEX
    cat >"${t}/bin/nginx-stub" <<'EOF_NGINX'
#!/usr/bin/env bash
[[ "${1:-}" == -t ]] && exit 0
exit 2
EOF_NGINX
    cat >"${t}/bin/ignore-ok" <<'EOF_IGNORE'
#!/usr/bin/env bash
exit 0
EOF_IGNORE
    chmod +x "${t}/bin/"*
}

write_systemctl_stub() {
    local t="$1" hotfix_active="$2" reconcile_active="${3:-1}"
    cat >"${t}/bin/systemctl-stub" <<EOF_SYSTEMCTL
#!/usr/bin/env bash
cmd="\${1:-}"; shift || true
if [[ "\${1:-}" == --quiet ]]; then shift; fi
unit="\${1:-}"
case "\${cmd}:\${unit}" in
    is-enabled:riph-reconcile.timer|is-active:riph-reconcile.timer) [[ "${reconcile_active}" == 1 ]] && exit 0 || exit 1;;
    is-enabled:router-ip-push-nginx-hotfix.path|is-active:router-ip-push-nginx-hotfix.path|is-enabled:router-ip-push-nginx-hotfix.timer|is-active:router-ip-push-nginx-hotfix.timer) [[ "${hotfix_active}" == 1 ]] && exit 0 || exit 1;;
    is-active:router-ip-push-nginx-hotfix.service) exit 1;;
    *) exit 1;;
esac
EOF_SYSTEMCTL
    chmod +x "${t}/bin/systemctl-stub"
}

run_readiness() {
    local t="$1" out="$2"
    RIPH_TEST_PRODUCTION_READINESS=1 RIPH_FAIL2BAN_CLIENT_BIN="${t}/bin/f2b-stub" RIPH_FAIL2BAN_REGEX_BIN="${t}/bin/f2b-regex-stub" RIPH_SYSTEMCTL_BIN="${t}/bin/systemctl-stub" RIPH_NGINX_BIN="${t}/bin/nginx-stub" RIPH_IGNORE_BIN="${t}/bin/ignore-ok" bash "${ACTIVATE}" --root "${t}" --dry-run >"${out}" 2>&1
}

CASE_HOTFIX="${BASE}/hotfix"; make_case "${CASE_HOTFIX}"; write_systemctl_stub "${CASE_HOTFIX}" 1
if run_readiness "${CASE_HOTFIX}" "${CASE_HOTFIX}/out.txt"; then fail 'Fail2ban readiness unexpectedly accepted active temporary hotfix ownership'; fi
grep -Fq 'temporary Router IP Push Nginx hotfix still owns the allowlist' "${CASE_HOTFIX}/out.txt" || fail 'temporary ownership readiness refusal missing'

CASE_ALLOW="${BASE}/missing-current"; make_case "${CASE_ALLOW}"; write_systemctl_stub "${CASE_ALLOW}" 0
sed -i 's/192\.0\.2\.26\/32/192.0.2.25\/32/' "${CASE_ALLOW}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
if run_readiness "${CASE_ALLOW}" "${CASE_ALLOW}/out.txt"; then fail 'Fail2ban readiness accepted allowlist missing canonical current Router IP'; fi
grep -Fq 'current ROUTER_A IP 192.0.2.26 is absent from active allowlist' "${CASE_ALLOW}/out.txt" || fail 'missing-current readiness refusal missing'

CASE_TIMER="${BASE}/missing-timer"; make_case "${CASE_TIMER}"; write_systemctl_stub "${CASE_TIMER}" 0 0
if run_readiness "${CASE_TIMER}" "${CASE_TIMER}/out.txt"; then fail 'Fail2ban readiness accepted inactive core reconcile timer'; fi
grep -Fq 'riph-reconcile.timer must be enabled and active' "${CASE_TIMER}/out.txt" || fail 'core timer readiness refusal missing'

CASE_ZERO="${BASE}/zero-provider"; make_case "${CASE_ZERO}" 0; write_systemctl_stub "${CASE_ZERO}" 0
run_readiness "${CASE_ZERO}" "${CASE_ZERO}/out.txt"
grep -Fq 'dry-run: would enable riph-nginx-stream-sni-reject' "${CASE_ZERO}/out.txt" || fail 'zero-provider readiness did not reach activation preview'

CASE_OK="${BASE}/ok"; make_case "${CASE_OK}"; write_systemctl_stub "${CASE_OK}" 0
run_readiness "${CASE_OK}" "${CASE_OK}/out.txt"
grep -Fq 'dry-run: would enable riph-nginx-stream-sni-reject' "${CASE_OK}/out.txt" || fail 'ready production dry-run did not reach activation preview'
grep -Fxq 'enabled = false' "${CASE_OK}/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local" || fail 'production readiness dry-run mutated reject jail'

echo 'PASS: Fail2ban production readiness gate'
