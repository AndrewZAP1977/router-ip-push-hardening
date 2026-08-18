# Router IP Push Hardening

Private hardening supplement for an existing `3x-ui-installer` Nginx/Xray deployment.

The repository is intentionally separate from the public installer. It contains
private source-IP/SNI policy and must remain private.

## Status

Controlled Hexabyte production validation completed on 2026-08-18.

The branch remains draft/unmerged pending an explicit final review decision.
GitHub Actions remains manual-only (`workflow_dispatch`) and was not run during the
production validation.

Production ownership is now RIPH:

- `riph-router-ip.path` is enabled/active;
- `riph-reconcile.timer` is enabled/active with 1-minute fallback;
- the temporary Router-IP/Nginx hotfix path/timer are disabled/inactive;
- the temporary hotfix files/script remain on disk only for rollback/forensics;
- the legacy stream logger/jail have been retired from active configuration;
- five pre-existing manual TCP/443 UFW denies are now exact RIPH-owned
  `# riph-manual-443` rules;
- `riph-adopt-bridge` temporary adoption rules are absent;
- the fail-closed manual-deny helper verifies physical UFW ownership on every
  applied-state row.

## v1 scope

Implemented on `agent/core-apply-v1`:

- Router IP Push current IPv4 as a trusted source;
- static trusted IPv4/CIDR entries;
- configurable previous-IP grace (4 hours by default);
- generated Nginx `geo $router_ip_push_source_allowed`;
- private SNI routing:
  - public SNI -> public site;
  - private SNI + trusted IP -> Xray;
  - private SNI + untrusted IP -> PROXY-protocol bridge -> fake site;
  - unknown / empty / IP-SNI -> reject upstream;
- dedicated route-aware audit log `/var/log/nginx/riph-stream-sni.log` on external `:443` only;
- transactional `riph-apply` with `flock`, backup, `nginx -t`, reload gating and rollback;
- Router IP change detection via `systemd.path` watching `/var/lib/router-ip-push/ips`;
- 1-minute fallback reconcile for a missed path event, grace expiry and trusted-unban protection;
- isolated RIPH Fail2ban jails:
  - `riph-nginx-stream-sni-reject`: 3 attempts / 5 minutes / 8 hour ban;
  - `riph-nginx-stream-private-sni-abuse`: 3 attempts / 2 minutes / 12 hour ban;
- automatic Fail2ban bans scoped to TCP/443 only;
- dynamic Fail2ban `ignorecommand` with emergency Router-IP/last-known-good fast paths;
- Fail2ban UFW helper that owns rules by exact `riph-f2b-<jail>` marker;
- trusted-unban guard for project Fail2ban bans and project-owned manual UFW rules;
- manual deny 443 and explicit manual deny all-ports lists;
- one shared UFW mutation lock across Fail2ban and manual-deny writers;
- CIDR overlap protection against banning a trusted source;
- fail-closed physical ownership verification for manual UFW state;
- stream-log harvest/checkpoint statistics;
- interactive and command-mode `riph-admin`;
- runtime rollback with a pre-rollback safety snapshot;
- installer with preflight, project-file backup, Nginx runtime snapshot and automatic restore on installation failure;
- deterministic `/tmp` test-root support;
- one-time transactional legacy manual-deny adoption helper with rollback coverage.

## Safety boundary

v1 does not modify:

- 3x-ui clients or database;
- Xray client definitions;
- ZeroTier;
- Nextcloud;
- OnlyOffice;
- ztncui;
- SSH policy.

Automatic bans never block all ports. The automatic Fail2ban action affects only
TCP/443 so Router IP Push over SSH can still report a changed home address.
Manual all-port deny remains an explicit exceptional admin operation only.

## 2026-08-17 Router-IP incident

A real ISP address change exposed the missing consumer in the old staging setup:

- Router IP Push correctly changed AX3200 from `78.111.155.187` to `78.111.154.96`;
- the old staging Nginx allowlist remained on the previous address;
- the new home address was therefore classified untrusted and `treda` was sent to
  bridge `9543` / fake site instead of Xray `8443`;
- synchronizing the allowlist and reloading Nginx restored service.

The exact A -> B transition is a dedicated regression test. RIPH makes B trusted
on reconcile, retains A only as 4-hour previous-IP grace, and removes A after grace
expiry.

The temporary production safeguard was then handed over atomically to RIPH using
`riph-hotfix-handover`. Its path/timer are now disabled; RIPH path/timer are the
active allowlist owners.

## Hexabyte production validation

Completed on 2026-08-18:

1. local/test-root regression gate passed with `RUN_LOCAL_RC=0`;
2. read-only candidate validation passed;
3. production install and temporary-hotfix ownership handover passed;
4. live routing validated for AX3200 and SmartBox-mother trusted sources;
5. RIPH Fail2ban jails activated with `fail2ban-client -t` + reload;
6. synthetic IPv4 reject, IPv4 private-abuse and IPv6 reject UFW actions validated;
7. legacy external logging quiesced;
8. legacy stream logger/jail/trusted-ignore/current-IP shield retired transactionally;
9. final post-retire live smoke passed;
10. five old unmarked manual TCP/443 denies were adopted into exact
    `riph-manual-443` ownership with no bridge rule left behind;
11. the fail-closed ownership helper was installed in production;
12. repeated automatic `riph-reconcile.service` runs accepted the physical
    ownership state with `manual_conflicts=0`.

Permanent static trusted sources validated in production include localhost,
VPS_GR `5.61.39.137/32`, Spectra `45.87.41.121/32`, Hexabyte
`194.104.94.182/32`, and SmartBox-mother `176.110.189.199/32`.

See `docs/HEXABYTE_LEGACY_MIGRATION.md` for the migration record.

## Local validation

GitHub Actions is manual-only (`workflow_dispatch`) so development commits do not
consume Actions minutes automatically.

Preferred local runner:

```bash
bash tests/run-local.sh
```

It performs:

1. `bash -n` over installer/source/tests/tools;
2. ShellCheck when installed;
3. all `tests/test-*.sh` regression tests.

The tests use temporary `/tmp/riph-*` roots and stub Nginx/systemctl/UFW commands.

Important regressions include:

- `tests/test-ip-change-incident.sh` — exact 2026-08-17 address transition;
- `tests/test-systemd-watch.sh` — directory path watch + 1-minute fallback;
- `tests/test-hotfix-handover.sh` — ownership transfer, rollback, and IP change in
  the middle of handover;
- `tests/test-manual-deny.sh` — physical ownership, duplicate no-op and stale-state
  fail-closed behavior;
- `tests/test-manual-deny-adopt-legacy.sh` — transactional legacy manual-deny
  adoption and rollback.

## Main commands after deployment

```bash
riph-admin status
riph-admin reconcile
riph-admin guard
riph-admin fail2ban-status
riph-admin ufw-status
riph-admin harvest
riph-admin harvest-checkpoint
riph-admin backups
riph-hotfix-handover status
```

Interactive administration:

```bash
riph-admin
```

## Source of truth

The Nginx allowlist is generated and must not be edited manually. Effective trusted
sources are derived from:

1. `/etc/router-ip-push-hardening/trusted-static.list`;
2. `/var/lib/router-ip-push/ips/<ROUTER_ID>.ipv4`;
3. non-expired entries in `/etc/router-ip-push-hardening/previous-ip-grace.json`.

Manual-deny ownership is derived from the configured source lists plus the
project-owned applied-state file, but state is trusted only when the corresponding
RIPH-marked UFW rule is physically visible.

See `docs/ARCHITECTURE.md`, `docs/HEXABYTE_TEST_PLAN.md` and
`docs/HEXABYTE_LEGACY_MIGRATION.md`.
