# Router IP Push Hardening

Private hardening supplement for the existing `3x-ui-installer` deployment.

## Scope

This repository is intentionally separate from the public installer. It adds the
private runtime layer around an already-installed Nginx/Xray setup:

- Router IP Push trusted-source state;
- generated Nginx trusted-source allowlist;
- current + previous-IP grace handling;
- safe apply/reconcile flow;
- later: fake-site routing, Fail2ban, manual deny lists, trusted-unban guard,
  admin CLI, installer and rollback.

## Safety boundary

This project must not modify 3x-ui clients/database, ZeroTier, Nextcloud,
OnlyOffice or ztncui. SSH hardening and automatic all-port bans are outside v1.

## Current development stage

`agent/core-apply-v1` contains the first isolated core. It does **not** install
anything on a VPS yet.

Implemented:

- validated static trusted IPv4/CIDR list;
- Router IP Push current IPv4 lookup;
- 4-hour previous-IP grace by default;
- generated Nginx `geo $router_ip_push_source_allowed`;
- exclusive apply lock;
- no Nginx reload when the effective trusted set is unchanged;
- backup + atomic file replacement;
- `nginx -t` gate;
- rollback on validation/reload failure;
- deterministic test-root mode.

See `docs/ARCHITECTURE.md` for the transaction model and current boundaries.

## Local core test

Requirements: Bash, GNU coreutils, `jq`, `flock`.

```bash
bash tests/test-core.sh
```

The test runs only under a temporary `/tmp/riph-test.*` root and uses stub
Nginx/systemctl commands.

## Production warning

**Do not deploy this repository to Hexabyte or another production VPS yet.**
The installer, fake-site bridge rendering, Fail2ban, UFW deny management,
trusted-unban guard and admin CLI are intentionally not part of this first stage.
