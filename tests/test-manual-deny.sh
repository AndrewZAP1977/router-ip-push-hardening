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
UFW_STATE="${T}/ufw-state.tsv"
: >"${LOG}"
: >"${UFW_STATE}"

cat >"${T}/usr/local/bin/ufw-stub" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOG="${RIPH_TEST_UFW_LOG:?}"
STATE="${RIPH_TEST_UFW_STATE:?}"

if [[ "${1:-}" == status && "${2:-}" == numbered ]]; then
    n=0
    while IFS=$'\t' read -r scope cidr marker; do
        [[ -n "${scope:-}" ]] || continue
        ((n += 1))
        source="${cidr}"
        [[ "${source}" == */32 ]] && source="${source%/32}"
        if [[ "${scope}" == 443 ]]; then
            printf '[%2d] 443/tcp                    DENY IN     %-28s # %s\n' "${n}" "${source}" "${marker}"
        else
            printf '[%2d] Anywhere                   DENY IN     %-28s # %s\n' "${n}" "${source}" "${marker}"
        fi
    done <"${STATE}"
    exit 0
fi

parse_rule() {
    local -a args=("$@")
    local i
    SCOPE=all
    CIDR=''
    MARKER=''
    for ((i=0; i<${#args[@]}; i++)); do
        case "${args[$i]}" in
            from)
                CIDR="${args[$((i+1))]}"
                ;;
            port)
                [[ "${args[$((i+1))]}" == 443 ]] && SCOPE=443
                ;;
            comment)
                MARKER="${args[$((i+1))]}"
                ;;
        esac
    done
    [[ -n "${CIDR}" && -n "${MARKER}" ]]
}

if [[ "${1:-}" == prepend ]]; then
    parse_rule "$@"
    printf '%s\n' "$*" >>"${LOG}"
    if awk -F '\t' -v s="${SCOPE}" -v c="${CIDR}" '$1==s && $2==c {found=1} END{exit !found}' "${STATE}"; then
        echo 'Skipping adding existing rule'
        exit 0
    fi
    printf '%s\t%s\t%s\n' "${SCOPE}" "${CIDR}" "${MARKER}" >>"${STATE}"
    echo 'Rule inserted'
    exit 0
fi

if [[ "${1:-}" == --force && "${2:-}" == delete ]]; then
    shift 2
    parse_rule "$@"
    printf '%s\n' "--force delete $*" >>"${LOG}"
    tmp="${STATE}.tmp.$$"
    awk -F '\t' -v s="${SCOPE}" -v c="${CIDR}" -v m="${MARKER}" \
        '!( $1==s && $2==c && $3==m )' "${STATE}" >"${tmp}"
    mv -f "${tmp}" "${STATE}"
    echo 'Rule deleted'
    exit 0
fi

printf '%s\n' "$*" >>"${LOG}"
EOF
chmod +x "${T}/usr/local/bin/ufw-stub"
export RIPH_UFW_BIN="${T}/usr/local/bin/ufw-stub"
export RIPH_TEST_UFW_LOG="${LOG}"
export RIPH_TEST_UFW_STATE="${UFW_STATE}"

"${MANUAL}" --root "${T}" --now-epoch 1000
grep -F 'prepend deny proto tcp from 45.148.10.0/24 to any port 443 comment riph-manual-443' "${LOG}" >/dev/null
grep -F 'prepend deny from 167.71.72.165/32 comment riph-manual-all' "${LOG}" >/dev/null
STATE="${T}/var/lib/router-ip-push-hardening/runtime/manual-deny-applied.tsv"
[[ "$(wc -l <"${STATE}" | tr -d ' ')" == 2 ]]
grep -F $'443\t45.148.10.0/24\triph-manual-443' "${UFW_STATE}" >/dev/null
grep -F $'all\t167.71.72.165/32\triph-manual-all' "${UFW_STATE}" >/dev/null

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

# Regression: UFW returns success for an equivalent pre-existing unmarked rule.
# RIPH must not record false ownership when the requested marker was not created.
printf '%s\n' '203.0.113.44/32 # legacy duplicate' >"${T}/etc/router-ip-push-hardening/manual-deny-443.list"
: >"${T}/etc/router-ip-push-hardening/manual-deny-all.list"
: >"${STATE}"
printf '%s\t%s\t%s\n' 443 203.0.113.44/32 legacy-manual >"${UFW_STATE}"
before="$(wc -l <"${LOG}" | tr -d ' ')"
if "${MANUAL}" --root "${T}" --now-epoch 1000; then
    echo 'FAIL: manual deny accepted UFW duplicate no-op as owned rule' >&2
    exit 1
fi
[[ ! -s "${STATE}" ]]
after="$(wc -l <"${LOG}" | tr -d ' ')"
(( after == before + 1 ))
grep -F $'443\t203.0.113.44/32\tlegacy-manual' "${UFW_STATE}" >/dev/null

# Regression for the exact live incident: state claims ownership, but UFW only
# contains the older unmarked equivalent rule. Fail closed before any mutation.
printf '%s\t%s\n' 443 203.0.113.44/32 >"${STATE}"
before="$(wc -l <"${LOG}" | tr -d ' ')"
if "${MANUAL}" --root "${T}" --now-epoch 1000; then
    echo 'FAIL: manual deny trusted stale ownership state without a marked UFW rule' >&2
    exit 1
fi
after="$(wc -l <"${LOG}" | tr -d ' ')"
[[ "${before}" == "${after}" ]]

echo 'PASS: manual deny tests'
