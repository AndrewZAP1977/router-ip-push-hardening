#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d /tmp/riph-reconcile-guard.XXXXXX)"
trap 'rm -rf "${T}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

cp "${ROOT}/src/usr/local/sbin/riph-reconcile" "${T}/riph-reconcile"
chmod +x "${T}/riph-reconcile"

cat >"${T}/riph-apply" <<'EOF_APPLY'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RIPH_TEST_APPLY_LOG:?}"
exit "${RIPH_TEST_APPLY_EXIT:-0}"
EOF_APPLY
cat >"${T}/riph-trusted-unban-guard" <<'EOF_GUARD'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${RIPH_TEST_GUARD_LOG:?}"
exit "${RIPH_TEST_GUARD_EXIT:-0}"
EOF_GUARD
chmod +x "${T}/riph-apply" "${T}/riph-trusted-unban-guard"

export RIPH_TEST_APPLY_LOG="${T}/apply.log"
export RIPH_TEST_GUARD_LOG="${T}/guard.log"

# A guard failure is secondary. The trusted/Nginx state was already successfully
# applied, so reconcile must return success and let the next path/timer invocation
# retry the cleanup instead of rolling back the new Router IP.
export RIPH_TEST_APPLY_EXIT=0
export RIPH_TEST_GUARD_EXIT=42
if ! bash "${T}/riph-reconcile" --root /tmp/riph-test-root --reason 'guard retry contract' >"${T}/out.txt" 2>&1; then
    fail 'reconcile failed even though trusted/Nginx apply succeeded'
fi
grep -Fq 'trusted state applied, but guard cleanup failed; will retry on next reconcile' "${T}/out.txt" \
    || fail 'guard-failure warning missing'
[[ "$(wc -l <"${T}/apply.log")" == 1 ]] || fail 'apply was not called exactly once'
[[ "$(wc -l <"${T}/guard.log")" == 1 ]] || fail 'guard was not called exactly once'

# Primary apply failure is hard. Guard must not run against a state that was not
# successfully accepted.
: >"${T}/apply.log"
: >"${T}/guard.log"
export RIPH_TEST_APPLY_EXIT=23
export RIPH_TEST_GUARD_EXIT=0
if bash "${T}/riph-reconcile" --root /tmp/riph-test-root --reason 'apply must fail' >"${T}/out2.txt" 2>&1; then
    fail 'reconcile unexpectedly succeeded when primary apply failed'
fi
[[ "$(wc -l <"${T}/apply.log")" == 1 ]] || fail 'failed apply was not called exactly once'
[[ ! -s "${T}/guard.log" ]] || fail 'guard ran after failed primary apply'

echo 'PASS: reconcile primary/secondary failure semantics'
