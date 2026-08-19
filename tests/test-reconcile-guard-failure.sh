#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/riph-reconcile-contract.XXXXXX)"
R="${T}/runtime"
FS="${T}/rootfs"
trap 'rm -rf "${T}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir -p "${R}/sbin" "${R}/libexec" "${FS}/etc/router-ip-push-hardening" "${FS}/etc/nginx/stream-enabled" "${FS}/var/lib/router-ip-push/ips"
cp "${ROOT}/src/usr/local/sbin/riph-reconcile" "${R}/sbin/riph-reconcile"
cp "${ROOT}/src/usr/local/libexec/riph-common.sh" "${R}/libexec/riph-common.sh"
chmod +x "${R}/sbin/riph-reconcile"
cp "${ROOT}/config/config.env.example" "${FS}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '192.0.2.26' >"${FS}/var/lib/router-ip-push/ips/ROUTER_A.ipv4"

cat >"${R}/sbin/riph-apply" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
root=''
while (($#)); do case "$1" in --root) root="$2"; shift 2;; *) shift;; esac; done
printf '%s\n' called >>"${RIPH_TEST_APPLY_LOG:?}"
if [[ "${RIPH_TEST_APPLY_EXIT:-0}" != 0 ]]; then exit "${RIPH_TEST_APPLY_EXIT}"; fi
ip_file="${root}/var/lib/router-ip-push/ips/ROUTER_A.ipv4"
ip="$(tr -d '[:space:]' <"${ip_file}")"
mkdir -p "${root}/etc/router-ip-push-hardening" "${root}/etc/nginx/stream-enabled"
printf '%s\n' "{\"version\":1,\"routers\":{\"ROUTER_A\":{\"current_ip\":\"${ip}\"}}}" >"${root}/etc/router-ip-push-hardening/last-apply-state.json"
cat >"${root}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<EOF_ALLOW
geo \$router_ip_push_source_allowed {
    default 0;
    ${ip}/32 1; # router-ip-push:ROUTER_A current
}
EOF_ALLOW
count="$(wc -l <"${RIPH_TEST_APPLY_LOG}")"
if [[ -n "${RIPH_TEST_CHANGE_IP_AFTER_FIRST:-}" && "${count}" == 1 ]]; then
    tmp="${ip_file}.receiver.$$"
    printf '%s\n' "${RIPH_TEST_CHANGE_IP_AFTER_FIRST}" >"${tmp}"
    mv -f "${tmp}" "${ip_file}"
fi
EOF_APPLY

cat >"${R}/sbin/riph-trusted-unban-guard" <<'EOF_GUARD'
#!/usr/bin/env bash
printf '%s\n' called >>"${RIPH_TEST_GUARD_LOG:?}"
exit "${RIPH_TEST_GUARD_EXIT:-0}"
EOF_GUARD
chmod +x "${R}/sbin/riph-apply" "${R}/sbin/riph-trusted-unban-guard"
export RIPH_TEST_APPLY_LOG="${T}/apply.log"
export RIPH_TEST_GUARD_LOG="${T}/guard.log"

reset_case() {
    : >"${RIPH_TEST_APPLY_LOG}"; : >"${RIPH_TEST_GUARD_LOG}"
    rm -f "${FS}/etc/router-ip-push-hardening/last-apply-state.json" "${FS}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
    printf '%s\n' '192.0.2.26' >"${FS}/var/lib/router-ip-push/ips/ROUTER_A.ipv4"
    unset RIPH_TEST_CHANGE_IP_AFTER_FIRST || true
}

reset_case
export RIPH_TEST_APPLY_EXIT=0 RIPH_TEST_GUARD_EXIT=42
if ! bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason 'guard retry contract' >"${T}/out.txt" 2>&1; then fail 'reconcile failed even though trusted/Nginx apply succeeded'; fi
grep -Fq 'trusted state applied, but guard cleanup failed; will retry on next reconcile' "${T}/out.txt" || fail 'guard-failure warning missing'
[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 1 ]] || fail 'apply was not called exactly once'
[[ "$(wc -l <"${RIPH_TEST_GUARD_LOG}")" == 1 ]] || fail 'guard was not called exactly once'

reset_case
export RIPH_TEST_APPLY_EXIT=23 RIPH_TEST_GUARD_EXIT=0
if bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason 'apply must fail' >"${T}/out2.txt" 2>&1; then fail 'reconcile unexpectedly succeeded when primary apply failed'; fi
[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 1 ]] || fail 'failed apply was not called exactly once'
[[ ! -s "${RIPH_TEST_GUARD_LOG}" ]] || fail 'guard ran after failed primary apply'

reset_case
export RIPH_TEST_APPLY_EXIT=0 RIPH_TEST_GUARD_EXIT=0 RIPH_TEST_CHANGE_IP_AFTER_FIRST='192.0.2.27'
if ! bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason 'mid-transaction Router IP change' >"${T}/out3.txt" 2>&1; then fail 'reconcile failed to converge after one mid-transaction Router IP change'; fi
[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 2 ]] || fail 'mid-transaction Router IP change did not cause exactly one immediate retry'
[[ "$(wc -l <"${RIPH_TEST_GUARD_LOG}")" == 1 ]] || fail 'guard should run once only after Router IP convergence'
grep -Fq 'Router IP changed or active allowlist moved during reconcile attempt 1; retrying' "${T}/out3.txt" || fail 'mid-transaction convergence retry message missing'
[[ "$(jq -r '.routers.ROUTER_A.current_ip' "${FS}/etc/router-ip-push-hardening/last-apply-state.json")" == '192.0.2.27' ]] || fail 'last state did not converge to the new Router IP'
grep -Fq '192.0.2.27/32 1;' "${FS}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" || fail 'active allowlist did not converge to the new Router IP'
unset RIPH_TEST_CHANGE_IP_AFTER_FIRST

echo 'PASS: reconcile convergence and primary/secondary failure semantics'
