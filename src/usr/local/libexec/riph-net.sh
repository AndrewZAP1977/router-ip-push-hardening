#!/usr/bin/env bash

# IPv4/CIDR arithmetic helpers. Requires riph-common.sh first.

riph_ipv4_to_u32() {
    local ip="$1"
    local a b c d
    riph_is_ipv4 "${ip}" || return 1
    IFS=. read -r a b c d <<<"${ip}"
    printf '%u\n' "$(( (10#${a} << 24) | (10#${b} << 16) | (10#${c} << 8) | 10#${d} ))"
}

riph_cidr_bounds() {
    local cidr="$1"
    local ip prefix ip_u32 mask network broadcast
    riph_is_ipv4_cidr "${cidr}" || return 1
    if [[ "${cidr}" == */* ]]; then
        ip="${cidr%/*}"
        prefix="${cidr##*/}"
    else
        ip="${cidr}"
        prefix=32
    fi
    ip_u32="$(riph_ipv4_to_u32 "${ip}")" || return 1
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - 10#${prefix})) & 0xFFFFFFFF ))
    fi
    network=$(( ip_u32 & mask ))
    broadcast=$(( network | ((~mask) & 0xFFFFFFFF) ))
    printf '%u\t%u\n' "${network}" "${broadcast}"
}

riph_ipv4_in_cidr() {
    local ip="$1"
    local cidr="$2"
    local ip_u32 bounds start end
    ip_u32="$(riph_ipv4_to_u32 "${ip}")" || return 1
    bounds="$(riph_cidr_bounds "${cidr}")" || return 1
    IFS=$'\t' read -r start end <<<"${bounds}"
    (( ip_u32 >= start && ip_u32 <= end ))
}

riph_ipv4_cidr_overlap() {
    local left="$1"
    local right="$2"
    local l_bounds r_bounds l_start l_end r_start r_end
    l_bounds="$(riph_cidr_bounds "${left}")" || return 1
    r_bounds="$(riph_cidr_bounds "${right}")" || return 1
    IFS=$'\t' read -r l_start l_end <<<"${l_bounds}"
    IFS=$'\t' read -r r_start r_end <<<"${r_bounds}"
    (( l_start <= r_end && r_start <= l_end ))
}
