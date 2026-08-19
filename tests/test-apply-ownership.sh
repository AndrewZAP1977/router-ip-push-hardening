#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY="${ROOT}/src/usr/local/sbin/riph-apply"
T="$(mktemp -d /tmp/riph-apply-owner.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p "${T}/etc/router-ip-push-hardening" "${T}/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"

cat >"${T}/bin/systemctl-stub" <<'EOF_SYSTEMCTL'
#!/usr/bin/env bash
set -Eeuo pipefail
cmd="${1:-}"
shift || true
if [[ "${1:-}" == --quiet ]]; then shift; fi
unit="${1:-}"
case "${cmd}:${unit}" in
    is-active:router-ip-push-nginx-hotfix.path) exit 0 ;;
    is-enabled:router-ip-push-nginx-hotfix.path) exit 0 ;;
    *) exit 1 ;;
esac
EOF_SYSTEMCTL
chmod +x "${T}/bin/systemctl-stub"

export RIPH_SYSTEMCTL_BIN="${T}/bin/systemctl-stub"
export RIPH_TEST_HOTFIX_OWNERSHIP_CHECK=1

OUT="${T}/out.txt"
if bash "${APPLY}" --root "${T}" --reason 'must refuse dual owner' >"${OUT}" 2>&1; then
    fail 'riph-apply unexpectedly ran while temporary hotfix owned the allowlist'
fi
grep -Fq 'temporary Router IP Push Nginx hotfix still owns the allowlist' "${OUT}" \
    || fail 'ownership refusal message missing'
[[ ! -e "${T}/var/lib/router-ip-push-hardening" ]] \
    || fail 'ownership guard ran too late; RIPH state directory was already created'

# The same ownership state must not block read-only candidate generation. Build a
# complete test-root input and verify --dry-run reaches the candidate diff path.
mkdir -p "${T}/var/lib/router-ip-push/ips"
cp "${ROOT}/config/trusted-static.list.example" "${T}/etc/router-ip-push-hardening/trusted-static.list"
cp "${ROOT}/config/previous-ip-grace.json.example" "${T}/etc/router-ip-push-hardening/previous-ip-grace.json"
printf '%s\n' '192.0.2.26' >"${T}/var/lib/router-ip-push/ips/AX3200.ipv4"

DRY_OUT="${T}/dry-run.txt"
bash "${APPLY}" --root "${T}" --dry-run --reason 'ownership-safe candidate' >"${DRY_OUT}" 2>&1
grep -Fq 'dry-run:' "${DRY_OUT}" || fail 'dry-run did not reach candidate reporting'
grep -Fq '192.0.2.26/32' "${DRY_OUT}" || fail 'dry-run candidate lost current Router IP'

# Dry-run may create private test-root runtime scratch/state directories, but it
# must not install the generated Nginx targets.
[[ ! -e "${T}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" ]] \
    || fail 'dry-run unexpectedly installed allowlist'
[[ ! -e "${T}/etc/nginx/stream-enabled/stream.conf" ]] \
    || fail 'dry-run unexpectedly installed stream config'

echo 'PASS: apply temporary-hotfix ownership gate and dry-run exception'
