#!/usr/bin/env bash

# Effective trusted-set helpers for Router IP Push Hardening.
# Requires riph-common.sh to be sourced first.

riph_router_is_configured() {
    local wanted="$1"
    local router_id
    for router_id in "${RIPH_ROUTER_IDS[@]}"; do
        [[ "${router_id}" == "${wanted}" ]] && return 0
    done
    return 1
}

riph_emit_effective_trusted_entries() {
    local static_file="$1"
    local grace_file="$2"
    local now_epoch="$3"
    local line_no=0 raw line value comment router_id current_ip
    local grace_ip expires_epoch expires_iso

    [[ "${now_epoch}" =~ ^[0-9]+$ ]] || riph_die "invalid trusted-set epoch: ${now_epoch}"

    if [[ -f "${static_file}" ]]; then
        while IFS= read -r raw || [[ -n "${raw}" ]]; do
            ((line_no += 1))
            line="${raw#"${raw%%[![:space:]]*}"}"
            [[ -z "${line}" || "${line:0:1}" == "#" ]] && continue

            value="${line%%[[:space:]]*}"
            if [[ "${line}" == *"#"* ]]; then
                comment="${line#*#}"
                comment="${comment#"${comment%%[![:space:]]*}"}"
            else
                comment="static"
            fi
            riph_is_ipv4_cidr "${value}" \
                || riph_die "${static_file}:${line_no}: invalid IPv4/CIDR: ${value}"
            comment="${comment//$'\t'/ }"
            printf '%s\t%s\n' "$(riph_normalize_ipv4_cidr "${value}")" "${comment:-static}"
        done <"${static_file}"
    fi

    # RIPH_ROUTER_IDS is derived only from validated RIPH-owned canonical provider
    # state. A missing value here is therefore an internal consistency error, not a
    # provider-availability policy decision. Zero routers simply means zero loops.
    for router_id in "${RIPH_ROUTER_IDS[@]}"; do
        current_ip="$(riph_current_router_ip "${router_id}")" \
            || riph_die "canonical provider state lost current IPv4 for ${router_id}"
        printf '%s/32\t%s\n' "${current_ip}" "router-ip-push:${router_id} current"
    done

    if [[ -f "${grace_file}" ]]; then
        jq -e '.version == 1 and (.routers | type == "object")' "${grace_file}" >/dev/null \
            || riph_die "invalid grace state: ${grace_file}"

        while IFS=$'\t' read -r router_id grace_ip expires_epoch expires_iso; do
            [[ -n "${router_id}" ]] || continue
            riph_validate_router_id "${router_id}"
            riph_router_is_configured "${router_id}" || continue
            riph_is_ipv4 "${grace_ip}" || riph_die "invalid grace IPv4 for ${router_id}: ${grace_ip}"
            [[ "${expires_epoch}" =~ ^[0-9]+$ ]] \
                || riph_die "invalid grace expiry for ${router_id}: ${expires_epoch}"
            if (( expires_epoch > now_epoch )); then
                printf '%s/32\t%s\n' \
                    "${grace_ip}" \
                    "router-ip-push:${router_id} previous grace until ${expires_iso}"
            fi
        done < <(
            jq -r '
                .routers
                | to_entries[]
                | [
                    .key,
                    (.value.ip // ""),
                    ((.value.expires_at_epoch // 0) | tostring),
                    (.value.expires_at // "")
                  ]
                | @tsv
            ' "${grace_file}"
        )
    fi
}

riph_write_effective_trusted_entries() {
    local output_file="$1"
    local static_file="$2"
    local grace_file="$3"
    local now_epoch="$4"
    local tmp
    tmp="$(mktemp)"
    riph_emit_effective_trusted_entries "${static_file}" "${grace_file}" "${now_epoch}" >"${tmp}"
    awk -F '\t' '!seen[$1]++' "${tmp}" >"${output_file}"
    rm -f "${tmp}"
}
