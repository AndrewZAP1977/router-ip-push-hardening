#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ADOPT="${ROOT}/src/usr/local/sbin/riph-manual-deny-adopt-legacy"
BASE="$(mktemp -d /tmp/riph-manual-adopt.XXXXXX)"
trap 'rm -rf "${BASE}"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

make_case() {
    local t="$1"
    mkdir -p \
        "${t}/etc/router-ip-push-hardening" \
        "${t}/var/lib/router-ip-push/ips" \
        "${t}/var/lib/router-ip-push-hardening/runtime" \
        "${t}/usr/local/bin"

    cp "${ROOT}/config/config.env.example" "${t}/etc/router-ip-push-hardening/config.env"
    printf '%s\n' '127.0.0.1/32 # localhost' >"${t}/etc/router-ip-push-hardening/trusted-static.list"
    printf '%s\n' '{"version":1,"routers":{}}' >"${t}/etc/router-ip-push-hardening/previous-ip-grace.json"
    printf '%s\n' '192.0.2.25' >"${t}/var/lib/router-ip-push/ips/ROUTER_A.ipv4"
    cat >"${t}/etc/router-ip-push-hardening/manual-deny-443.list" <<'EOF_LIST'
203.0.113.44/32 # old exact scanner
198.51.100.0/24 # old scanner range
EOF_LIST
    : >"${t}/etc/router-ip-push-hardening/manual-deny-all.list"
    cat >"${t}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv" <<'EOF_STATE'
443	198.51.100.0/24
443	203.0.113.44/32
EOF_STATE

    UFW_STATE="${t}/ufw-state.tsv"
    cat >"${UFW_STATE}" <<'EOF_UFW'
443	203.0.113.44/32	any	old exact scanner
443	198.51.100.0/24	any	old scanner range
EOF_UFW

    cat >"${t}/usr/local/bin/ufw-stub" <<'EOF_STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE="${RIPH_TEST_UFW_STATE:?}"

show_status() {
    local n=0 scope cidr dest comment source to
    echo 'Status: active'
    echo
    while IFS=$'\t' read -r scope cidr dest comment; do
        [[ -n "${scope:-}" ]] || continue
        ((n += 1))
        source="${cidr}"
        [[ "${source}" == */32 ]] && source="${source%/32}"
        if [[ "${dest}" == any ]]; then
            to='443/tcp'
        else
            to="${dest} 443/tcp"
        fi
        printf '[%2d] %-28s DENY IN     %-28s' "${n}" "${to}" "${source}"
        [[ -n "${comment:-}" ]] && printf ' # %s' "${comment}"
        printf '\n'
    done <"${STATE}"
}

normalize_source() {
    local source="$1"
    if [[ "${source}" == */* ]]; then
        printf '%s\n' "${source}"
    else
        printf '%s/32\n' "${source}"
    fi
}

if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    show_status
    exit 0
fi

if [[ "${1:-}" == prepend ]]; then
    shift
    scope=443
    cidr=''
    dest=any
    comment=''
    args=("$@")
    for ((i=0; i<${#args[@]}; i++)); do
        case "${args[$i]}" in
            from) cidr="$(normalize_source "${args[$((i+1))]}")" ;;
            to) dest="${args[$((i+1))]}" ;;
            comment) comment="${args[$((i+1))]}" ;;
        esac
    done
    [[ -n "${cidr}" ]] || exit 2

    if [[ "${comment}" == riph-manual-443 && "${cidr}" == "${RIPH_TEST_FAIL_PERMANENT_CIDR:-}" ]]; then
        echo 'Injected permanent add failure' >&2
        exit 42
    fi

    if awk -F '\t' -v c="${cidr}" -v d="${dest}" '$1==443 && $2==c && $3==d {found=1} END{exit !found}' "${STATE}"; then
        echo 'Skipping adding existing rule'
        exit 0
    fi

    tmp="${STATE}.tmp.$$"
    printf '443\t%s\t%s\t%s\n' "${cidr}" "${dest}" "${comment}" >"${tmp}"
    cat "${STATE}" >>"${tmp}"
    mv -f "${tmp}" "${STATE}"
    echo 'Rule inserted'
    exit 0
fi

if [[ "${1:-}" == --force && "${2:-}" == delete ]]; then
    number="${3:-}"
    [[ "${number}" =~ ^[0-9]+$ ]] || exit 2
    tmp="${STATE}.tmp.$$"
    awk -v n="${number}" 'NR != n' "${STATE}" >"${tmp}"
    mv -f "${tmp}" "${STATE}"
    echo 'Rule deleted'
    exit 0
fi

exit 2
EOF_STUB
    chmod +x "${t}/usr/local/bin/ufw-stub"
}

count_comment() {
    local state="$1" comment="$2"
    awk -F '\t' -v m="${comment}" '$4==m {n++} END{print n+0}' "${state}"
}

count_dest_comment() {
    local state="$1" dest="$2" comment="$3"
    awk -F '\t' -v d="${dest}" -v m="${comment}" '$3==d && $4==m {n++} END{print n+0}' "${state}"
}

assert_legacy_pair() {
    local state="$1"
    [[ "$(count_comment "${state}" 'old exact scanner')" == 1 ]] || fail 'legacy exact rule missing'
    [[ "$(count_comment "${state}" 'old scanner range')" == 1 ]] || fail 'legacy range rule missing'
}

PUBLIC_IP='192.0.2.10'

CASE_OK="${BASE}/ok"
make_case "${CASE_OK}"
export RIPH_UFW_BIN="${CASE_OK}/usr/local/bin/ufw-stub"
export RIPH_TEST_UFW_STATE="${CASE_OK}/ufw-state.tsv"

before_ufw="$(sha256sum "${RIPH_TEST_UFW_STATE}" | awk '{print $1}')"
before_state="$(sha256sum "${CASE_OK}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv" | awk '{print $1}')"
bash "${ADOPT}" --root "${CASE_OK}" --public-ip "${PUBLIC_IP}" --dry-run >/dev/null
[[ "$(sha256sum "${RIPH_TEST_UFW_STATE}" | awk '{print $1}')" == "${before_ufw}" ]] || fail 'dry-run changed UFW state'
[[ "$(sha256sum "${CASE_OK}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv" | awk '{print $1}')" == "${before_state}" ]] || fail 'dry-run changed applied state'

bash "${ADOPT}" --root "${CASE_OK}" --public-ip "${PUBLIC_IP}"
[[ "$(count_comment "${RIPH_TEST_UFW_STATE}" 'riph-manual-443')" == 2 ]] || fail 'permanent RIPH rules not adopted'
[[ "$(count_dest_comment "${RIPH_TEST_UFW_STATE}" "${PUBLIC_IP}" 'riph-adopt-bridge')" == 0 ]] || fail 'bridge rules remained after success'
[[ "$(count_comment "${RIPH_TEST_UFW_STATE}" 'old exact scanner')" == 0 ]] || fail 'old exact legacy rule remained after success'
[[ "$(count_comment "${RIPH_TEST_UFW_STATE}" 'old scanner range')" == 0 ]] || fail 'old range legacy rule remained after success'
printf '%s\n' $'443\t198.51.100.0/24' $'443\t203.0.113.44/32' >"${CASE_OK}/expected-state.tsv"
cmp -s "${CASE_OK}/expected-state.tsv" "${CASE_OK}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv" \
    || fail 'adopted applied-state mismatch'
find "${CASE_OK}/var/lib/router-ip-push-hardening/backups" -maxdepth 1 -type d -name 'manual-deny-adopt-*' | grep -q . \
    || fail 'adoption backup missing'

echo 'TEST MDA2: injected permanent-rule failure rolls legacy protection back'
CASE_FAIL="${BASE}/fail"
make_case "${CASE_FAIL}"
export RIPH_UFW_BIN="${CASE_FAIL}/usr/local/bin/ufw-stub"
export RIPH_TEST_UFW_STATE="${CASE_FAIL}/ufw-state.tsv"
export RIPH_TEST_FAIL_PERMANENT_CIDR='203.0.113.44/32'
if bash "${ADOPT}" --root "${CASE_FAIL}" --public-ip "${PUBLIC_IP}" >/dev/null 2>&1; then
    fail 'adoption unexpectedly succeeded with injected permanent add failure'
fi
unset RIPH_TEST_FAIL_PERMANENT_CIDR
assert_legacy_pair "${RIPH_TEST_UFW_STATE}"
[[ "$(count_comment "${RIPH_TEST_UFW_STATE}" 'riph-manual-443')" == 0 ]] || fail 'partial permanent rules remained after rollback'
[[ "$(count_dest_comment "${RIPH_TEST_UFW_STATE}" "${PUBLIC_IP}" 'riph-adopt-bridge')" == 0 ]] || fail 'bridge remained despite verified legacy rollback'
printf '%s\n' $'443\t198.51.100.0/24' $'443\t203.0.113.44/32' >"${CASE_FAIL}/expected-state.tsv"
cmp -s "${CASE_FAIL}/expected-state.tsv" "${CASE_FAIL}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv" \
    || fail 'stale ownership state was not restored after failed adoption'

echo 'TEST MDA3: state mismatch fails before UFW mutation'
CASE_MISMATCH="${BASE}/mismatch"
make_case "${CASE_MISMATCH}"
export RIPH_UFW_BIN="${CASE_MISMATCH}/usr/local/bin/ufw-stub"
export RIPH_TEST_UFW_STATE="${CASE_MISMATCH}/ufw-state.tsv"
printf '%s\n' $'443\t203.0.113.44/32' >"${CASE_MISMATCH}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv"
before_ufw="$(sha256sum "${RIPH_TEST_UFW_STATE}" | awk '{print $1}')"
if bash "${ADOPT}" --root "${CASE_MISMATCH}" --public-ip "${PUBLIC_IP}" >/dev/null 2>&1; then
    fail 'adoption unexpectedly accepted applied-state mismatch'
fi
[[ "$(sha256sum "${RIPH_TEST_UFW_STATE}" | awk '{print $1}')" == "${before_ufw}" ]] || fail 'state mismatch mutated UFW'

echo 'PASS: transactional legacy manual deny adoption tests'
