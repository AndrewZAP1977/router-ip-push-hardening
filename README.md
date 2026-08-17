# Router IP Push Hardening

Private hardening supplement for the existing `3x-ui-installer` deployment.

## Scope

This repository is intentionally separate from the public installer. It adds the private runtime layer around an already-installed Nginx/Xray setup:

- Router IP Push trusted-source state;
- generated Nginx trusted-source allowlist;
- current + previous-IP grace handling;
- safe apply/reconcile flow;
- later: fake-site routing, Fail2ban, manual deny lists, trusted-unban guard, admin CLI, installer and rollback.

## Safety boundary

This project must not modify 3x-ui clients/database, ZeroTier, Nextcloud, OnlyOffice or ztncui. SSH hardening and automatic all-port bans are outside v1.

## Development status

Early development. **Do not deploy `main` to a production VPS yet.**
