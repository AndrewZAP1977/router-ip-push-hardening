#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANUAL="${ROOT}/src/usr/local/sbin/riph-apply-manual-deny"
T="$(mktemp -d /tmp/riph-manual.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

mkdir -p "${T}/etc/router-ip-push-hardening" "${T}/var/lib/router-ip-push/ips" "${T}/usr/local/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"
printf '%s\n' '127.0.0.1/32 # localhost' >"${T}/etc/router-ip-push-hardening/trusted-static.list"
printf '%s\n' '{"version":1,"routers":{}}' >"${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '78.111.155.187' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"
printf '%s\n' '45.148.10.0/24 # scanner' >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
printf '%s\n' '167.71.72.165 # exceptional' >"${T}/etc/router-ip-push-hardening/manual-deny-all.list"

LOG="${T}/ufw.log"
cat >"${T}/usr/local/bin/ufw-stub" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RIPH_TEST_UFW_LOG:?}"
EOF
chmod +x "${T}/usr/local/bin/ufw-stub"
export RIPH_UFW_BIN="${T}/usr/local/bin/ufw-stub"
export RIPH_TEST_UFW_LOG="${LOG}"

"${MANUAL}" --root "${T}" --now-epoch 1000
grep -F 'prepend deny proto tcp from 45.148.10.0/24 to any port 443 comment riph-manual-443' "${LOG}" >/dev/null
grep -F 'prepend deny from 167.71.72.165/32 comment riph-manual-all' "${LOG}" >/dev/null
STATE="${T}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv"
[[ "$(wc -l <"${STATE}" | tr -d ' ')" == 2 ]]

before="$(wc -l <"${LOG}" | tr -d ' ')"
"${MANUAL}" --root "${T}" --now-epoch 1000
after="$(wc -l <"${LOG}" | tr -d ' ')"
[[ "${before}" == "${after}" ]]

printf '%s\n' '78.111.0.0/16 # trusted overlap' >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
before="$(wc -l <"${LOG}" | tr -d ' ')"
if "${MANUAL}" --root "${T}" --now-epoch 1000; then
    echo 'FAIL: manual deny accepted trusted overlap' >&2
    exit 1
fi
after="$(wc -l <"${LOG}" | tr -d ' ')"
[[ "${before}" == "${after}" ]]

echo 'PASS: manual deny tests'
