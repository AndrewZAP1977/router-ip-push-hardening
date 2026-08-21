#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

# GitHub Contents API and archives created on Windows may not preserve executable
# bits for newly added scripts. Production permissions are enforced by install.sh;
# normalize only this test checkout so regression results do not depend on transport.
chmod +x install.sh tests/*.sh tools/*.sh src/usr/local/sbin/*

printf '%s\n' '==> Bash syntax'
while IFS= read -r -d '' file; do
    bash -n "${file}"
done < <(find install.sh src tests tools -type f \( -name '*.sh' -o -path '*/sbin/*' \) -print0)

if command -v shellcheck >/dev/null 2>&1; then
    printf '%s\n' '==> ShellCheck'
    mapfile -d '' shell_files < <(find install.sh src tests tools -type f \( -name '*.sh' -o -path '*/sbin/*' \) -print0)
    # Keep warning/error findings visible without flooding normal runs with
    # informational source-following/style notes. Warnings remain advisory;
    # a real ShellCheck error is a hard gate before functional regression.
    if ! shellcheck --severity=warning "${shell_files[@]}"; then
        printf '%s\n' '==> ShellCheck: advisory warnings above; enforcing errors only'
        shellcheck --severity=error "${shell_files[@]}"
    fi
else
    printf '%s\n' '==> ShellCheck: SKIP (not installed)'
fi

printf '%s\n' '==> Regression tests'
for test_script in tests/test-*.sh; do
    printf '==> %s\n' "${test_script}"
    bash "${test_script}"
done

printf '%s\n' 'PASS: local regression suite'
