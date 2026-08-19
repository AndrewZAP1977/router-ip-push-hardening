#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROLLBACK="${ROOT}/src/usr/local/sbin/riph-rollback"
T="$(mktemp -d /tmp/riph-rollback-owner.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

mkdir -p \
    "${T}/etc/router-ip-push-hardening" \
    "${T}/var/lib/router-ip-push-hardening/backups/20260817-120000-123" \
    "${T}/bin"
cp "${ROOT}/config/config.env.example" "${T}/etc/router-ip-push-hardening/config.env"

B="${T}/var/lib/router-ip-push-hardening/backups/20260817-120000-123"
printf '%s\n' '{"version":1,"created_at":"2026-08-17T12:00:00Z","reason":"test"}' >"${B}/manifest.json"
for name in allowlist.conf stream.conf bridges.conf previous-ip-grace.json last-apply-state.json; do
    printf '%s\n' "${name}-sentinel" >"${B}/${name}"
done

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

# Read-only operations stay available while the temporary writer owns production.
"${ROLLBACK}" --root "${T}" --list | grep -Fq '20260817-120000-123' \
    || fail 'rollback list was unexpectedly blocked by temporary ownership'
"${ROLLBACK}" --root "${T}" --backup 20260817-120000-123 --dry-run >"${T}/dry.txt"
grep -Fq 'backup=20260817-120000-123' "${T}/dry.txt" \
    || fail 'rollback dry-run was unexpectedly blocked by temporary ownership'

OUT="${T}/out.txt"
if "${ROLLBACK}" --root "${T}" --backup 20260817-120000-123 >"${OUT}" 2>&1; then
    fail 'runtime rollback unexpectedly ran while temporary hotfix owned the allowlist'
fi
grep -Fq 'runtime RIPH rollback is refused before ownership handover' "${OUT}" \
    || fail 'rollback ownership refusal message missing'

[[ ! -e "${T}/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf" ]] \
    || fail 'rollback ownership guard ran after Nginx mutation'

# Refusal must not create a rollback safety snapshot.
if find "${T}/var/lib/router-ip-push-hardening/backups" -maxdepth 1 -type d -name 'rollback-safety-*' | grep -q .; then
    fail 'rollback ownership guard ran after safety/mutation phase began'
fi

echo 'PASS: rollback temporary-hotfix ownership gate'
