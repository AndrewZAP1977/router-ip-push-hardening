# Core v1 architecture

This branch implements only the first safe layer of Router IP Push Hardening.

## Implemented in this stage

- static trusted IPv4/CIDR input;
- current Router IP Push IPv4 input;
- one previous IPv4 grace entry per router;
- generated Nginx `geo $router_ip_push_source_allowed`;
- transactional allowlist apply;
- `nginx -t` before reload;
- rollback on failed Nginx validation or reload;
- lock against concurrent apply/reconcile runs;
- no reload when the effective allowlist did not change;
- explicit test-root support.

## Not implemented yet

- installation on the VPS;
- Nginx SNI/fake-site bridge rendering;
- Fail2ban jails/actions;
- UFW manual deny lists;
- trusted-unban guard;
- systemd timers;
- interactive `riph-admin`;
- full project rollback UI.

## Source of truth

The generated Nginx allowlist is not edited manually. It is derived from:

1. `/etc/router-ip-push-hardening/trusted-static.list`;
2. `/var/lib/router-ip-push/ips/<ROUTER_ID>.ipv4`;
3. `/etc/router-ip-push-hardening/previous-ip-grace.json`.

`last-apply-state.json` records the last successfully applied current router addresses
and allowlist hash. It is used to detect an address transition and create the grace entry.

## Apply transaction

`riph-apply`:

1. takes an exclusive `flock`;
2. reads and validates current router addresses;
3. derives the next grace state;
4. generates candidate allowlist/state files in the runtime directory;
5. exits without backup/reload if nothing meaningful changed;
6. creates a snapshot;
7. atomically installs the candidate files;
8. runs `nginx -t`;
9. rolls back immediately if validation fails;
10. reloads Nginx only when the allowlist changed;
11. rolls back and restores/reloads the known-good files if reload fails.

The candidate Nginx include cannot be validated by the real Nginx configuration
without making it visible at its include path. Therefore the candidate is installed
atomically on disk first, but it is not made active until the subsequent successful
Nginx reload. A failed `nginx -t` restores the previous file before exiting.
