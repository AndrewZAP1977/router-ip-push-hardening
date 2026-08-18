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
    shellcheck "${shell_files[@]}"
else
    printf '%s\n' '==> ShellCheck: SKIP (not installed)'
fi

printf '%s\n' '==> Regression tests'
for test_script in tests/test-*.sh; do
    printf '==> %s\n' "${test_script}"
    bash "${test_script}"
done

printf '%s\n' 'PASS: local regression suite'
