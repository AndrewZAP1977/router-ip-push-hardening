#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/riph-reconcile-contract.XXXXXX)"; R="${T}/runtime"; FS="${T}/rootfs"
trap 'rm -rf "${T}"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
mkdir -p "${R}/sbin" "${R}/libexec" "${FS}/etc/router-ip-push-hardening" "${FS}/etc/nginx/stream-enabled" "${FS}/var/lib/router-ip-push-hardening/providers"
cp "${ROOT}/src/usr/local/sbin/riph-reconcile" "${R}/sbin/riph-reconcile"
cp "${ROOT}/src/usr/local/libexec/riph-common.sh" "${R}/libexec/riph-common.sh"
chmod +x "${R}/sbin/riph-reconcile"
cp "${ROOT}/config/config.env.example" "${FS}/etc/router-ip-push-hardening/config.env"
PROVIDER="${FS}/var/lib/router-ip-push-hardening/providers/router-ip-push.json"
write_provider(){ printf '{"version":1,"provider":"router-ip-push","status":"available","routers":{"ROUTER_A":{"current_ip":"%s"}},"invalid_entries":0}\n' "$1" >"${PROVIDER}"; }
write_provider 192.0.2.26

cat >"${R}/sbin/riph-apply" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
root=''; while (($#)); do case "$1" in --root) root="$2"; shift 2;; *) shift;; esac; done
echo called >>"${RIPH_TEST_APPLY_LOG:?}"
[[ "${RIPH_TEST_APPLY_EXIT:-0}" == 0 ]] || exit "${RIPH_TEST_APPLY_EXIT}"
p="${root}/var/lib/router-ip-push-hardening/providers/router-ip-push.json"
ip="$(jq -r '.routers.ROUTER_A.current_ip' "${p}")"
printf '{"version":1,"routers":{"ROUTER_A":{"current_ip":"%s"}}}\n' "${ip}" >"${root}/etc/router-ip-push-hardening/last-apply-state.json"
printf 'geo $router_ip_push_source_allowed {\n default 0;\n %s/32 1;\n}\n' "${ip}" >"${root}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"
if [[ -n "${RIPH_TEST_CHANGE_IP_AFTER_FIRST:-}" && "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 1 ]]; then
  tmp="${p}.tmp"; jq --arg ip "${RIPH_TEST_CHANGE_IP_AFTER_FIRST}" '.routers.ROUTER_A.current_ip=$ip' "${p}" >"${tmp}"; mv -f "${tmp}" "${p}"
fi
EOF_APPLY
cat >"${R}/sbin/riph-trusted-unban-guard" <<'EOF_GUARD'
#!/usr/bin/env bash
echo called >>"${RIPH_TEST_GUARD_LOG:?}"; exit "${RIPH_TEST_GUARD_EXIT:-0}"
EOF_GUARD
chmod +x "${R}/sbin/riph-apply" "${R}/sbin/riph-trusted-unban-guard"
export RIPH_TEST_APPLY_LOG="${T}/apply.log" RIPH_TEST_GUARD_LOG="${T}/guard.log"
reset_case(){ : >"${RIPH_TEST_APPLY_LOG}"; : >"${RIPH_TEST_GUARD_LOG}"; rm -f "${FS}/etc/router-ip-push-hardening/last-apply-state.json" "${FS}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf"; write_provider 192.0.2.26; unset RIPH_TEST_CHANGE_IP_AFTER_FIRST || true; }

reset_case; export RIPH_TEST_APPLY_EXIT=0 RIPH_TEST_GUARD_EXIT=42
bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason guard >"${T}/out1" 2>&1 || fail 'guard failure incorrectly failed reconcile'
grep -Fq 'guard cleanup failed' "${T}/out1" || fail 'guard warning missing'
[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 1 && "$(wc -l <"${RIPH_TEST_GUARD_LOG}")" == 1 ]] || fail 'guard-failure call counts wrong'

reset_case; export RIPH_TEST_APPLY_EXIT=23 RIPH_TEST_GUARD_EXIT=0
if bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason apply-fail >"${T}/out2" 2>&1; then fail 'primary apply failure was ignored'; fi
[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 1 && ! -s "${RIPH_TEST_GUARD_LOG}" ]] || fail 'apply-failure call counts wrong'

reset_case; export RIPH_TEST_APPLY_EXIT=0 RIPH_TEST_GUARD_EXIT=0 RIPH_TEST_CHANGE_IP_AFTER_FIRST=192.0.2.27
bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason provider-race >"${T}/out3" 2>&1 || fail 'canonical provider race did not converge'
[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 2 && "$(wc -l <"${RIPH_TEST_GUARD_LOG}")" == 1 ]] || fail 'provider-race call counts wrong'
grep -Fq 'provider state or active allowlist moved during reconcile attempt 1; retrying' "${T}/out3" || fail 'provider retry message missing'
[[ "$(jq -r '.routers.ROUTER_A.current_ip' "${FS}/etc/router-ip-push-hardening/last-apply-state.json")" == 192.0.2.27 ]] || fail 'last state did not converge'
grep -Fq '192.0.2.27/32 1;' "${FS}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" || fail 'allowlist did not converge'
echo 'PASS: reconcile primary/secondary failure and canonical-provider race semantics'
