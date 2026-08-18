#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/riph-reconcile-bounded.XXXXXX)"
R="${T}/runtime"
FS="${T}/rootfs"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p \
    "${R}/sbin" \
    "${R}/libexec" \
    "${FS}/etc/router-ip-push-hardening" \
    "${FS}/etc/nginx/stream-enabled" \
    "${FS}/var/lib/router-ip-push/ips"

cp "${ROOT}/src/usr/local/sbin/riph-reconcile" "${R}/sbin/riph-reconcile"
cp "${ROOT}/src/usr/local/libexec/riph-common.sh" "${R}/libexec/riph-common.sh"
chmod +x "${R}/sbin/riph-reconcile"
cp "${ROOT}/config/config.env.example" "${FS}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '78.111.154.96' >"${FS}/var/lib/router-ip-push/ips/AX3200.ipv4"

cat >"${R}/sbin/riph-apply" <<'EOF_APPLY'
#!/usr/bin/env bash
set -Eeuo pipefail
root=''
while (($#)); do
    case "$1" in
        --root) root="$2"; shift 2 ;;
        *) shift ;;
    esac
done

log="${RIPH_TEST_APPLY_LOG:?}"
printf '%s\n' called >>"${log}"
count="$(wc -l <"${log}")"
ip_file="${root}/var/lib/router-ip-push/ips/AX3200.ipv4"
ip="$(tr -d '[:space:]' <"${ip_file}")"

mkdir -p "${root}/etc/router-ip-push-hardening" "${root}/etc/nginx/stream-enabled"
printf '%s\n' "{\"version\":1,\"routers\":{\"AX3200\":{\"current_ip\":\"${ip}\"}}}" \
    >"${root}/etc/router-ip-push-hardening/last-apply-state.json"
cat >"${root}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" <<EOF_ALLOW
geo \$router_ip_push_source_allowed {
    default 0;
    ${ip}/32 1; # router-ip-push:AX3200 current
}
EOF_ALLOW

# Simulate a continuously moving ISP source: every successful apply is followed
# by Router IP Push atomically publishing another address before verification.
case "${count}" in
    1) next='78.111.154.97' ;;
    2) next='78.111.154.98' ;;
    3) next='78.111.154.99' ;;
    *) next='' ;;
esac
if [[ -n "${next}" ]]; then
    tmp="${ip_file}.receiver.$$"
    printf '%s\n' "${next}" >"${tmp}"
    mv -f "${tmp}" "${ip_file}"
fi
EOF_APPLY

cat >"${R}/sbin/riph-trusted-unban-guard" <<'EOF_GUARD'
#!/usr/bin/env bash
printf '%s\n' called >>"${RIPH_TEST_GUARD_LOG:?}"
exit 0
EOF_GUARD
chmod +x "${R}/sbin/riph-apply" "${R}/sbin/riph-trusted-unban-guard"

export RIPH_TEST_APPLY_LOG="${T}/apply.log"
export RIPH_TEST_GUARD_LOG="${T}/guard.log"
: >"${RIPH_TEST_APPLY_LOG}"
: >"${RIPH_TEST_GUARD_LOG}"

if bash "${R}/sbin/riph-reconcile" --root "${FS}" --reason 'continuous Router IP movement' >"${T}/out.txt" 2>&1; then
    fail 'reconcile unexpectedly succeeded while current Router IP changed after every bounded attempt'
fi

[[ "$(wc -l <"${RIPH_TEST_APPLY_LOG}")" == 3 ]] \
    || fail 'reconcile did not stop at exactly three convergence attempts'
[[ ! -s "${RIPH_TEST_GUARD_LOG}" ]] \
    || fail 'guard ran even though Router IP never converged'
grep -Fq 'Router IP did not converge into active allowlist after 3 attempts' "${T}/out.txt" \
    || fail 'bounded-convergence failure message missing'

# The third successful apply remains a valid Nginx/trusted transaction for .98;
# live Router IP has already advanced to .99. Do not roll that successful apply
# backward merely because convergence failed; the path/timer retry is the next
# convergence attempt.
[[ "$(jq -r '.routers.AX3200.current_ip' "${FS}/etc/router-ip-push-hardening/last-apply-state.json")" == '78.111.154.98' ]] \
    || fail 'last successful apply state was unexpectedly rolled back'
[[ "$(tr -d '[:space:]' <"${FS}/var/lib/router-ip-push/ips/AX3200.ipv4")" == '78.111.154.99' ]] \
    || fail 'live Router IP movement simulation is wrong'

echo 'PASS: bounded Router IP convergence under continuous change'
