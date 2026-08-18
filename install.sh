#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=src/usr/local/libexec/riph-common.sh
source "${SCRIPT_DIR}/src/usr/local/libexec/riph-common.sh"

RIPH_ROOT="/"
MODE=""
DO_APPLY=0
ENABLE_TIMERS=0
REPLACE_CONFIG=0
TEMP_HOTFIX_ACTIVE=0
HANDOVER_OWNS_TIMERS=0

usage() {
    cat <<'USAGE'
Usage: ./install.sh [options]

Modes (choose one):
  --check             Read-only preflight.
  --install           Install project files and seed missing config files.

Install options:
  --apply             Apply transactional Nginx/trusted routing only. Does not activate Fail2ban.
  --enable-timers     Enable Router-IP watch and 1-minute reconcile after successful apply.
  --replace-config    Replace config/list files with repository examples (backed up).

Global options:
  --root DIR          Test root prefix. Production root is '/'.
  -h, --help          Show this help.

Temporary Hexabyte hotfix ownership:
  If router-ip-push-nginx-hotfix.path/timer are active, a production --apply
  is allowed only together with --enable-timers. The installer then uses
  riph-hotfix-handover so there is never more than one active allowlist owner.

Development safety gate:
  Real '/' installation is intentionally blocked until the controlled VPS test.
  Set RIPH_ALLOW_INCOMPLETE_PRODUCTION=1 only for an explicitly controlled test.
USAGE
}

while (($#)); do
    case "$1" in
        --root)
            (($# >= 2)) || riph_die "--root requires a value"
            RIPH_ROOT="$(riph_validate_root "$2")"
            shift 2
            ;;
        --check)
            [[ -z "${MODE}" ]] || riph_die "choose only one mode"
            MODE="check"
            shift
            ;;
        --install)
            [[ -z "${MODE}" ]] || riph_die "choose only one mode"
            MODE="install"
            shift
            ;;
        --apply)
            DO_APPLY=1
            shift
            ;;
        --enable-timers)
            ENABLE_TIMERS=1
            shift
            ;;
        --replace-config)
            REPLACE_CONFIG=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            riph_die "unknown argument: $1"
            ;;
    esac
done

[[ -n "${MODE}" ]] || riph_die "choose --check or --install"
(( ENABLE_TIMERS == 0 || DO_APPLY == 1 )) || riph_die "--enable-timers requires --apply"

for required in \
    config/config.env.example \
    config/trusted-static.list.example \
    config/previous-ip-grace.json.example \
    config/manual-deny-443.list.example \
    config/manual-deny-all.list.example \
    src/usr/local/libexec/riph-common.sh \
    src/usr/local/libexec/riph-trusted.sh \
    src/usr/local/libexec/riph-net.sh \
    src/usr/local/sbin/riph-apply \
    src/usr/local/sbin/riph-generate-allowlist \
    src/usr/local/sbin/riph-generate-routing \
    src/usr/local/sbin/riph-apply-manual-deny \
    src/usr/local/sbin/riph-fail2ban-ignore \
    src/usr/local/sbin/riph-fail2ban-ufw \
    src/usr/local/sbin/riph-fail2ban-activate \
    src/usr/local/sbin/riph-legacy-handover \
    src/usr/local/sbin/riph-hotfix-handover \
    src/usr/local/sbin/riph-trusted-unban-guard \
    src/usr/local/sbin/riph-reconcile \
    src/usr/local/sbin/riph-rollback \
    src/usr/local/sbin/riph-harvest \
    src/usr/local/sbin/riph-admin \
    src/etc/fail2ban/filter.d/riph-nginx-stream-sni-reject.conf \
    src/etc/fail2ban/filter.d/riph-nginx-stream-private-sni-abuse.conf \
    src/etc/fail2ban/action.d/riph-ufw-443.conf \
    src/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local \
    src/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local \
    src/etc/systemd/system/riph-reconcile.service \
    src/etc/systemd/system/riph-reconcile.timer \
    src/etc/systemd/system/riph-guard.service \
    src/etc/systemd/system/riph-router-ip.path; do
    [[ -f "${SCRIPT_DIR}/${required}" ]] || riph_die "repository is incomplete: ${required}"
done

CONFIG_SOURCE="${SCRIPT_DIR}/config/config.env.example"
riph_load_config "${CONFIG_SOURCE}"

preflight() {
    local router_id ip_file ip
    riph_require_cmd jq
    riph_require_cmd flock
    riph_require_cmd install
    riph_require_cmd sha256sum
    riph_require_cmd date

    if [[ "${RIPH_ROOT}" == "/" ]]; then
        [[ "${EUID}" -eq 0 ]] || riph_die "production check/install must run as root"
        riph_require_cmd nginx
        riph_require_cmd systemctl
        riph_require_cmd ufw
        riph_require_cmd fail2ban-client
        riph_require_cmd fail2ban-regex
        [[ -f /etc/nginx/nginx.conf ]] || riph_die "/etc/nginx/nginx.conf is missing"
        grep -F 'include /etc/nginx/stream-enabled/*.conf;' /etc/nginx/nginx.conf >/dev/null \
            || riph_die "nginx.conf does not include /etc/nginx/stream-enabled/*.conf"
        nginx -t
        fail2ban-client -t
        LC_ALL=C ufw status | grep -Fqx 'Status: active' \
            || riph_die "UFW must already be active; installer will not enable/reset it"

        if systemctl is-active --quiet router-ip-push-nginx-hotfix.path \
            || systemctl is-active --quiet router-ip-push-nginx-hotfix.timer \
            || systemctl is-enabled --quiet router-ip-push-nginx-hotfix.path \
            || systemctl is-enabled --quiet router-ip-push-nginx-hotfix.timer; then
            TEMP_HOTFIX_ACTIVE=1
            riph_log "temporary Router IP Push Nginx hotfix detected; allowlist ownership handover is required"
        fi
    fi

    for router_id in "${RIPH_ROUTER_IDS[@]}"; do
        ip_file="$(riph_root_path "${ROUTER_IP_PUSH_DIR}/ips/${router_id}.ipv4")"
        if [[ ! -f "${ip_file}" ]]; then
            [[ "${REQUIRE_ROUTER_IP:-1}" == "0" ]] || riph_die "Router IP Push file missing: ${ip_file}"
            continue
        fi
        ip="$(tr -d '[:space:]' <"${ip_file}")"
        riph_is_ipv4 "${ip}" || riph_die "invalid Router IP Push IPv4 in ${ip_file}: ${ip}"
    done
}

preflight
if [[ "${MODE}" == "check" ]]; then
    riph_log "preflight OK for root ${RIPH_ROOT}"
    exit 0
fi

if [[ "${RIPH_ROOT}" == "/" && "${RIPH_ALLOW_INCOMPLETE_PRODUCTION:-0}" != "1" ]]; then
    riph_die "production install is blocked until the controlled VPS test; use test-root for development"
fi

if [[ "${RIPH_ROOT}" == "/" ]] && (( TEMP_HOTFIX_ACTIVE == 1 && DO_APPLY == 1 && ENABLE_TIMERS == 0 )); then
    riph_die "temporary hotfix currently owns the allowlist; use --apply --enable-timers for atomic RIPH ownership handover"
fi

STATE_DIR="$(riph_root_path "${RIPH_STATE_DIR}")"
INSTALL_BACKUP_ROOT="${STATE_DIR}/install-backups"
mkdir -p "${INSTALL_BACKUP_ROOT}"
BACKUP_ID="$(date -u '+%Y%m%d-%H%M%S')-$$"
BACKUP_DIR="${INSTALL_BACKUP_ROOT}/${BACKUP_ID}"
mkdir -p "${BACKUP_DIR}"

# Nginx files are generated by riph-apply rather than copied by the installer,
# but they still belong to the install transaction.
RUNTIME_SNAPSHOT_LOGICAL=(
    "${ALLOWLIST_OUTPUT}"
    "${STREAM_OUTPUT:-/etc/nginx/stream-enabled/stream.conf}"
    "${BRIDGE_OUTPUT:-/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf}"
)

# destination|source|mode|policy
# policy=replace: always install; policy=seed: install only if missing unless --replace-config.
mapfile -t FILE_SPECS <<'EOF_SPECS'
/usr/local/libexec/riph-common.sh|src/usr/local/libexec/riph-common.sh|0644|replace
/usr/local/libexec/riph-trusted.sh|src/usr/local/libexec/riph-trusted.sh|0644|replace
/usr/local/libexec/riph-net.sh|src/usr/local/libexec/riph-net.sh|0644|replace
/usr/local/sbin/riph-apply|src/usr/local/sbin/riph-apply|0755|replace
/usr/local/sbin/riph-generate-allowlist|src/usr/local/sbin/riph-generate-allowlist|0755|replace
/usr/local/sbin/riph-generate-routing|src/usr/local/sbin/riph-generate-routing|0755|replace
/usr/local/sbin/riph-apply-manual-deny|src/usr/local/sbin/riph-apply-manual-deny|0755|replace
/usr/local/sbin/riph-fail2ban-ignore|src/usr/local/sbin/riph-fail2ban-ignore|0755|replace
/usr/local/sbin/riph-fail2ban-ufw|src/usr/local/sbin/riph-fail2ban-ufw|0755|replace
/usr/local/sbin/riph-fail2ban-activate|src/usr/local/sbin/riph-fail2ban-activate|0755|replace
/usr/local/sbin/riph-legacy-handover|src/usr/local/sbin/riph-legacy-handover|0755|replace
/usr/local/sbin/riph-hotfix-handover|src/usr/local/sbin/riph-hotfix-handover|0755|replace
/usr/local/sbin/riph-trusted-unban-guard|src/usr/local/sbin/riph-trusted-unban-guard|0755|replace
/usr/local/sbin/riph-reconcile|src/usr/local/sbin/riph-reconcile|0755|replace
/usr/local/sbin/riph-rollback|src/usr/local/sbin/riph-rollback|0755|replace
/usr/local/sbin/riph-harvest|src/usr/local/sbin/riph-harvest|0755|replace
/usr/local/sbin/riph-admin|src/usr/local/sbin/riph-admin|0755|replace
/etc/systemd/system/riph-reconcile.service|src/etc/systemd/system/riph-reconcile.service|0644|replace
/etc/systemd/system/riph-reconcile.timer|src/etc/systemd/system/riph-reconcile.timer|0644|replace
/etc/systemd/system/riph-guard.service|src/etc/systemd/system/riph-guard.service|0644|replace
/etc/systemd/system/riph-router-ip.path|src/etc/systemd/system/riph-router-ip.path|0644|replace
/etc/fail2ban/filter.d/riph-nginx-stream-sni-reject.conf|src/etc/fail2ban/filter.d/riph-nginx-stream-sni-reject.conf|0644|replace
/etc/fail2ban/filter.d/riph-nginx-stream-private-sni-abuse.conf|src/etc/fail2ban/filter.d/riph-nginx-stream-private-sni-abuse.conf|0644|replace
/etc/fail2ban/action.d/riph-ufw-443.conf|src/etc/fail2ban/action.d/riph-ufw-443.conf|0644|replace
/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local|src/etc/fail2ban/jail.d/riph-nginx-stream-sni-reject.local|0644|replace
/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local|src/etc/fail2ban/jail.d/riph-nginx-stream-private-sni-abuse.local|0644|replace
/etc/router-ip-push-hardening/config.env|config/config.env.example|0600|seed
/etc/router-ip-push-hardening/trusted-static.list|config/trusted-static.list.example|0600|seed
/etc/router-ip-push-hardening/previous-ip-grace.json|config/previous-ip-grace.json.example|0600|seed
/etc/router-ip-push-hardening/manual-deny-443.list|config/manual-deny-443.list.example|0600|seed
/etc/router-ip-push-hardening/manual-deny-all.list|config/manual-deny-all.list.example|0600|seed
EOF_SPECS

snapshot_target() {
    local logical="$1" target="$2" rel
    rel="${logical#/}"
    if [[ -e "${target}" ]]; then
        mkdir -p "${BACKUP_DIR}/files/$(dirname "${rel}")"
        cp -a "${target}" "${BACKUP_DIR}/files/${rel}"
    else
        mkdir -p "${BACKUP_DIR}/absent/$(dirname "${rel}")"
        : >"${BACKUP_DIR}/absent/${rel}"
    fi
}

restore_one_snapshot() {
    local logical="$1" target rel
    target="$(riph_root_path "${logical}")"
    rel="${logical#/}"
    if [[ -f "${BACKUP_DIR}/absent/${rel}" ]]; then
        rm -f "${target}"
    elif [[ -e "${BACKUP_DIR}/files/${rel}" ]]; then
        mkdir -p "$(dirname "${target}")"
        cp -a "${BACKUP_DIR}/files/${rel}" "${target}"
    fi
}

restore_install_backup() {
    local spec logical _source _mode _policy
    riph_log "restoring install backup ${BACKUP_ID}"
    for spec in "${FILE_SPECS[@]}"; do
        IFS='|' read -r logical _source _mode _policy <<<"${spec}"
        restore_one_snapshot "${logical}"
    done
    for logical in "${RUNTIME_SNAPSHOT_LOGICAL[@]}"; do
        restore_one_snapshot "${logical}"
    done
}

INSTALL_STARTED=0
restore_runtime_services_after_error() {
    [[ "${RIPH_ROOT}" == "/" ]] || return 0
    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx >/dev/null 2>&1 || riph_log "WARNING: failed to reload restored Nginx state"
    else
        riph_log "WARNING: restored Nginx state fails nginx -t"
    fi
}

on_install_error() {
    local rc=$?
    trap - ERR
    if (( INSTALL_STARTED == 1 )); then
        restore_install_backup || true
        restore_runtime_services_after_error || true
    fi
    exit "${rc}"
}
trap on_install_error ERR

for spec in "${FILE_SPECS[@]}"; do
    IFS='|' read -r logical source_rel mode policy <<<"${spec}"
    target="$(riph_root_path "${logical}")"
    source_file="${SCRIPT_DIR}/${source_rel}"
    [[ -f "${source_file}" ]] || riph_die "missing source file: ${source_rel}"
    snapshot_target "${logical}" "${target}"
done
for logical in "${RUNTIME_SNAPSHOT_LOGICAL[@]}"; do
    snapshot_target "${logical}" "$(riph_root_path "${logical}")"
done

jq -n \
    --arg created_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
    --arg root "${RIPH_ROOT}" \
    '{version:1, kind:"install-backup", created_at:$created_at, root:$root}' \
    >"${BACKUP_DIR}/manifest.json"

INSTALL_STARTED=1
for spec in "${FILE_SPECS[@]}"; do
    IFS='|' read -r logical source_rel mode policy <<<"${spec}"
    target="$(riph_root_path "${logical}")"
    source_file="${SCRIPT_DIR}/${source_rel}"
    if [[ "${policy}" == seed && -e "${target}" && "${REPLACE_CONFIG}" != "1" ]]; then
        continue
    fi
    mkdir -p "$(dirname "${target}")"
    temp="${target}.riph-install.$$"
    install -m "${mode}" "${source_file}" "${temp}"
    mv -f "${temp}" "${target}"
done

if (( DO_APPLY == 1 )); then
    installed_apply="$(riph_root_path /usr/local/sbin/riph-apply)"
    installed_guard="$(riph_root_path /usr/local/sbin/riph-trusted-unban-guard)"
    installed_handover="$(riph_root_path /usr/local/sbin/riph-hotfix-handover)"

    if [[ "${RIPH_ROOT}" == "/" ]]; then
        touch "${STREAM_AUDIT_LOG:-/var/log/nginx/riph-stream-sni.log}"
        # Validate project Fail2ban files while they remain disabled. Activation is
        # a separate controlled Phase 7 action after routing is proven healthy.
        fail2ban-client -t
    fi

    if [[ "${RIPH_ROOT}" == "/" ]] && (( TEMP_HOTFIX_ACTIVE == 1 )); then
        bash "${installed_handover}" --root "${RIPH_ROOT}" --config /etc/router-ip-push-hardening/config.env takeover
        HANDOVER_OWNS_TIMERS=1
    else
        bash "${installed_apply}" --root "${RIPH_ROOT}" --reason "initial hardening install"
        bash "${installed_guard}" --root "${RIPH_ROOT}"
    fi
fi

if (( ENABLE_TIMERS == 1 && HANDOVER_OWNS_TIMERS == 0 )); then
    [[ "${RIPH_ROOT}" == "/" ]] || riph_die "--enable-timers is only valid for real production root"
    systemctl daemon-reload
    systemctl enable --now riph-router-ip.path riph-reconcile.timer
fi

trap - ERR
riph_log "files installed successfully"
riph_log "install backup: ${BACKUP_DIR}"
if (( DO_APPLY == 0 )); then
    riph_log "Nginx/UFW state was not applied; review config and run riph-admin reconcile when approved"
fi
