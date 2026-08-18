#!/usr/bin/env bash
set -uo pipefail

section() {
    printf '\n===== %s =====\n' "$1"
}

run() {
    printf '+ %s\n' "$*"
    "$@" 2>&1 || printf '[exit=%s]\n' "$?"
}

show_file() {
    local file="$1"
    printf '\n--- %s ---\n' "${file}"
    if [[ -f "${file}" ]]; then
        sed -n '1,260p' "${file}" 2>&1 || true
    else
        printf '(missing)\n'
    fi
}

if [[ "${EUID}" -ne 0 ]]; then
    printf 'ERROR: run as root (sudo -i) so read-only status commands are complete.\n' >&2
    exit 1
fi

section 'Identity / OS'
run date -u '+UTC %Y-%m-%dT%H:%M:%SZ'
run hostname
show_file /etc/os-release

section 'Required commands / versions'
for cmd in nginx jq flock ufw fail2ban-client fail2ban-regex systemctl ss; do
    if command -v "${cmd}" >/dev/null 2>&1; then
        printf '%-18s %s\n' "${cmd}" "$(command -v "${cmd}")"
    else
        printf '%-18s MISSING\n' "${cmd}"
    fi
done
command -v nginx >/dev/null 2>&1 && nginx -v 2>&1 || true
command -v fail2ban-client >/dev/null 2>&1 && fail2ban-client --version 2>&1 || true
command -v ufw >/dev/null 2>&1 && ufw --version 2>&1 | head -n 2 || true

section 'Nginx validation / include layout'
if command -v nginx >/dev/null 2>&1; then
    run nginx -t
fi
if [[ -f /etc/nginx/nginx.conf ]]; then
    grep -nE '^[[:space:]]*(stream|include[[:space:]]+/etc/nginx/stream-enabled/)' /etc/nginx/nginx.conf 2>&1 || true
fi
run ls -la /etc/nginx/stream-enabled

for file in \
    /etc/nginx/stream-enabled/00-sni-watch.conf \
    /etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf \
    /etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf \
    /etc/nginx/stream-enabled/stream.conf; do
    show_file "${file}"
done

section 'Expected local TCP listeners'
if command -v ss >/dev/null 2>&1; then
    ss -H -ltnp 2>&1 \
        | awk '$4 ~ /:(443|7443|8443|8444|9443|9444|9543|9544)$/ {print}' \
        | sort -k4,4 || true
fi

section 'Router IP Push state'
run ls -la /var/lib/router-ip-push/ips
run ls -la /var/lib/router-ip-push/state
for file in /var/lib/router-ip-push/ips/*.ipv4 /var/lib/router-ip-push/state/*.json; do
    [[ -e "${file}" ]] || continue
    show_file "${file}"
done
if [[ -e /usr/local/libexec/router-ip-push-receiver ]]; then
    run stat -c '%A %U:%G %s %n' /usr/local/libexec/router-ip-push-receiver
fi

section 'Temporary Router IP Push Nginx hotfix'
if [[ -e /usr/local/sbin/router-ip-push-nginx-hotfix ]]; then
    run stat -c '%A %U:%G %s %y %n' /usr/local/sbin/router-ip-push-nginx-hotfix
else
    printf '/usr/local/sbin/router-ip-push-nginx-hotfix does not exist\n'
fi
for unit in \
    router-ip-push-nginx-hotfix.path \
    router-ip-push-nginx-hotfix.service \
    router-ip-push-nginx-hotfix.timer; do
    printf '%-42s enabled=%-12s active=%s\n' \
        "${unit}" \
        "$(systemctl is-enabled "${unit}" 2>/dev/null || true)" \
        "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done
if [[ -d /var/backups/router-ip-push-nginx-hotfix ]]; then
    run ls -lt /var/backups/router-ip-push-nginx-hotfix
fi

section 'Existing hardening state'
if [[ -d /etc/router-ip-push-hardening ]]; then
    run find /etc/router-ip-push-hardening -maxdepth 1 -type f -printf '%M %u:%g %s %p\n'
    for file in \
        /etc/router-ip-push-hardening/config.env \
        /etc/router-ip-push-hardening/trusted-static.list \
        /etc/router-ip-push-hardening/previous-ip-grace.json \
        /etc/router-ip-push-hardening/manual-deny-443.list \
        /etc/router-ip-push-hardening/manual-deny-all.list \
        /etc/router-ip-push-hardening/last-apply-state.json; do
        show_file "${file}"
    done
else
    printf '/etc/router-ip-push-hardening does not exist\n'
fi

section 'Fail2ban'
if command -v fail2ban-client >/dev/null 2>&1; then
    run systemctl is-active fail2ban
    run fail2ban-client status
    for jail in \
        nginx-stream-sni-reject \
        nginx-stream-private-sni-abuse \
        riph-nginx-stream-sni-reject \
        riph-nginx-stream-private-sni-abuse; do
        if fail2ban-client status "${jail}" >/dev/null 2>&1; then
            run fail2ban-client status "${jail}"
        else
            printf '%s: not active\n' "${jail}"
        fi
    done
else
    printf 'fail2ban-client missing\n'
fi

section 'UFW'
if command -v ufw >/dev/null 2>&1; then
    run ufw status numbered
else
    printf 'ufw missing\n'
fi

section 'RIPH systemd units if present'
for unit in riph-router-ip.path riph-reconcile.service riph-reconcile.timer riph-guard.service; do
    printf '%-26s enabled=%-12s active=%s\n' \
        "${unit}" \
        "$(systemctl is-enabled "${unit}" 2>/dev/null || true)" \
        "$(systemctl is-active "${unit}" 2>/dev/null || true)"
done

section 'Stream audit logs'
for log in /var/log/nginx/stream-sni.log /var/log/nginx/riph-stream-sni.log; do
    if [[ -f "${log}" ]]; then
        run stat -c 'inode=%i size=%s mtime=%y %n' "${log}"
        tail -n 30 "${log}" 2>&1 || true
    else
        printf '%s does not exist\n' "${log}"
    fi
done

section 'Preflight complete'
printf 'No configuration, firewall, service or package changes were requested by this script.\n'
