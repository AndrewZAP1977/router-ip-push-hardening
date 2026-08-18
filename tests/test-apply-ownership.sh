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

echo 'PASS: apply temporary-hotfix ownership gate'
