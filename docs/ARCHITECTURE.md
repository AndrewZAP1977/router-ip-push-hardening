# Router IP Push Hardening v1 architecture

## Design boundary

This repository is a private supplement installed after the public `3x-ui-installer`.
It owns private trusted-source policy, private SNI camouflage routing and the related
operational safeguards. It does not own 3x-ui/Xray client configuration, SSH,
ZeroTier, Nextcloud, OnlyOffice or ztncui.

Controlled production validation on Hexabyte completed on 2026-08-18. The sections
below describe the resulting steady-state architecture; migration-only mechanisms
are identified explicitly as historical/rollback paths.

## Source of truth

The generated Nginx allowlist is not edited manually after RIPH takes ownership.
The effective trusted set is:

```text
static trusted
+ current Router IP Push IPv4
+ previous Router IPv4 while grace is valid
```

Inputs:

- `/etc/router-ip-push-hardening/trusted-static.list`
- `/var/lib/router-ip-push/ips/<ROUTER_ID>.ipv4`
- `/etc/router-ip-push-hardening/previous-ip-grace.json`

Generated output:

- `/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf`

The validated Hexabyte static trusted set contains localhost, VPS_GR, Spectra,
Hexabyte itself and SmartBox-mother. AX3200 remains dynamic through Router IP Push.

## 2026-08-17 Router-IP invariant

The old staging setup had Router IP Push and a generated Nginx allowlist but no
permanent consumer connecting the two. When AX3200 changed from
`78.111.155.187` to `78.111.154.96`, Router IP Push correctly updated its `.ipv4`
and state JSON while Nginx retained the old trusted address. The new home address
was therefore routed as untrusted to the fake-site bridge.

RIPH treats the following as a hard invariant:

```text
Router IP Push current file changes
        -> reconcile is triggered
        -> new current IP is present in the active allowlist
        -> Nginx validation succeeds
        -> Nginx reload succeeds when configuration changed
```

The exact real A -> B transition is a regression test.

## Routing policy

For the Hexabyte v1 topology:

```text
nukla.layerupzap.ru + any source
  -> 127.0.0.1:7443

treda.layerupzap.ru + trusted source
  -> 127.0.0.1:8443

treda.layerupzap.ru + untrusted source
  -> 127.0.0.1:9543 (accept PROXY) -> 127.0.0.1:9443 (plain TLS)

trongo.layerupzap.ru + trusted source
  -> 127.0.0.1:8444

trongo.layerupzap.ru + untrusted source
  -> 127.0.0.1:9544 (accept PROXY) -> 127.0.0.1:9444 (plain TLS)

unknown / empty / IP-SNI
  -> 127.0.0.1:9 (reject)
```

`riph-generate-routing` validates hostnames and restricts configured upstreams to
`127.0.0.1:<port>` in v1.

The local 9543/9544 bridge layer is required because the external stream listener
forwards PROXY protocol while the fake HTTPS sites expect ordinary TLS.

## Stream audit log

RIPH owns a dedicated machine-readable log on the **external `:443` server only**:

```text
/var/log/nginx/riph-stream-sni.log
```

Fields include:

```text
$time_iso8601 src=<remote> route=<final route> sni=<SNI> upstream=<addr> status=<status> session=<seconds>
```

The security field is the final route:

- `route=reject` -> unknown/empty/IP-SNI path;
- `route=fake_N` -> private SNI from an untrusted source;
- `route=xray_N` -> private SNI from a trusted source;
- `route=www` -> public site.

Internal bridge sessions on 9543/9544 never enter the RIPH route-aware log.

The old `/var/log/nginx/stream-sni.log` compatibility feed was used only during the
controlled migration. `LEGACY_STREAM_AUDIT_COMPAT` now defaults to `0`; setting it
to `1` is a deliberate coexistence/rollback operation and requires the legacy
`sni_watch` Nginx log format to exist.

## Apply transaction

`riph-apply` is the normal mutation engine for trusted/routing state:

1. take exclusive RIPH apply `flock`;
2. validate current Router IP Push addresses;
3. expire old grace entries;
4. detect current-IP transitions and create previous-IP grace;
5. generate candidate allowlist, stream config and bridge config;
6. compare hashes/state with the current successful state;
7. exit without backup/reload when nothing meaningful changed;
8. create an apply backup;
9. atomically install candidates;
10. run `nginx -t`;
11. restore the backup immediately if validation fails;
12. reload Nginx only when an Nginx file changed;
13. restore/reload the known-good backup if reload fails;
14. record successful state only after the transaction succeeds.

`riph-reconcile` treats trusted/Nginx state as primary. A later Fail2ban/UFW guard
failure is logged and retried; it does not roll back a newly accepted Router IP.

## Router-IP event path and fallback

The existing Router IP Push receiver atomically replaces `.ipv4` only when the
source address changes. RIPH does not modify that receiver.

```text
Router IP changes
  -> /var/lib/router-ip-push/ips directory changes
  -> riph-router-ip.path
  -> riph-reconcile.service
  -> riph-apply
  -> riph-trusted-unban-guard
```

The path unit watches the **directory**, not only the file, because the receiver
uses atomic replacement.

A separate `riph-reconcile.timer` runs every **1 minute** with 5-second accuracy as
a fallback if the path event is missed. It also handles grace expiry and retryable
guard cleanup. There is deliberately no second periodic guard timer.

Production state after handover is:

- `riph-router-ip.path`: enabled/active;
- `riph-reconcile.timer`: enabled/active;
- temporary hotfix path/timer: disabled/inactive.

## Historical temporary hotfix and ownership handover

During incident recovery, Hexabyte temporarily used:

```text
router-ip-push-nginx-hotfix.path
router-ip-push-nginx-hotfix.timer
router-ip-push-nginx-hotfix.service
/usr/local/sbin/router-ip-push-nginx-hotfix
```

`riph-hotfix-handover takeover` transferred ownership without allowing two
long-lived allowlist writers:

1. acquire the same hotfix lock as the temporary writer;
2. record temporary hotfix state;
3. disable/stop its automatic triggers;
4. run strict RIPH reconcile;
5. enable the RIPH path/timer;
6. run a second reconcile to close an IP-change race;
7. verify current Router IP in the active generated allowlist;
8. keep temporary files on disk only for rollback/forensics.

The production handover completed successfully. The helper remains available for
forensic/rollback scenarios but is not the normal steady-state path.

## Fail2ban policy

Two isolated project jails consume the RIPH route-aware log:

### `riph-nginx-stream-sni-reject`

- match: final `route=reject`;
- `maxretry = 3`;
- `findtime = 5m`;
- `bantime = 8h`;
- action scope: TCP/443 only.

### `riph-nginx-stream-private-sni-abuse`

- match: final `route=fake_N`;
- `maxretry = 3`;
- `findtime = 2m`;
- `bantime = 12h`;
- action scope: TCP/443 only.

Repository jail templates use `enabled = false` so a first install cannot activate
blocking policy before routing is validated. Production activation is an explicit
`riph-fail2ban-activate` operation. Once a jail has been activated, a later
`install.sh --install` preserves the existing installed `enabled=true/false` flag
while refreshing the rest of the jail content; it never silently deactivates an
already-active project jail on disk.

Both jails use `riph-fail2ban-ignore <ip>` before banning. The helper protects trusted
sources in three stages:

1. current Router IP Push `.ipv4` files, before hardening config is parsed;
2. last-known-good generated Nginx allowlist;
3. normal computed effective trusted set (static + current + valid grace).

This means a newly changed Router IP is protected from RIPH Fail2ban even before the
Nginx reconcile transaction has completed.

### Fail2ban UFW ownership

Fail2ban uses `riph-fail2ban-ufw` rather than a generic unowned UFW delete command.
The helper:

- validates jail/address syntax;
- creates only TCP/443 rules;
- labels them `riph-f2b-<jail>`;
- identifies an existing rule by exact source token + exact marker;
- deletes only its own numbered rule(s), in descending order;
- treats repeated bans idempotently;
- shares one UFW mutation lock with manual-deny.

Therefore a RIPH Fail2ban unban does not intentionally remove a separate
`riph-manual-443` rule for the same source. Automatic whole-IP/all-port bans are
outside v1.

## Completed legacy Fail2ban handover

Hexabyte originally had a legacy `nginx-stream-sni-reject` jail using a generic
unmarked UFW action. RIPH used distinct names and a no-gap migration:

1. prove RIPH routing and audit log;
2. activate both `riph-*` jails while legacy reject remained active;
3. validate trusted-ignore and marked UFW ownership;
4. quiesce new external events to the legacy log;
5. let existing legacy bans expire naturally;
6. retire legacy jail configuration only when its ban list was reliably readable
   and empty;
7. preserve legacy artifacts for forensic rollback where appropriate.

That sequence completed successfully on 2026-08-18. The active Fail2ban set after
retirement contains `3x-ipl` plus the two RIPH jails.

## Manual deny ownership

Source lists:

- `/etc/router-ip-push-hardening/manual-deny-443.list`
- `/etc/router-ip-push-hardening/manual-deny-all.list`

`riph-apply-manual-deny` treats its applied-state file as an ownership claim, not
merely a desired-state cache. Every recorded row must correspond to a physically
visible RIPH-marked UFW rule. A UFW success/duplicate no-op cannot create a false
ownership record.

Normal edits are strict: a deny CIDR that overlaps the effective trusted set is
rejected before UFW is changed. Manual-deny and RIPH Fail2ban UFW mutations are
serialized by the shared project lock.

If the trusted set changes later and moves inside an already configured manual deny,
`riph-trusted-unban-guard` invokes the manual-deny engine in protection mode. The
conflicting project-owned rule is removed/suppressed from applied state while the
source-list entry remains visible for administrator review.

Five pre-existing unmarked Hexabyte TCP/443 manual denies were adopted into exact
`# riph-manual-443` ownership on 2026-08-18. The one-time source helper
`riph-manual-deny-adopt-legacy` used temporary destination-specific bridge denies so
there was no TCP/443 protection gap. It is intentionally **not installed** by
`install.sh`; it remains source/test material for this completed migration and
forensic recovery.

Post-adoption production state is exactly five RIPH manual 443 rules, zero
`riph-adopt-bridge` rules, and a matching applied-state file.

## Installer/update semantics

`install.sh` creates a pre-install snapshot of every project-managed target and the
three generated Nginx runtime files. On failure it restores those files and, when
needed, restores the previous writer/unit state.

Important steady-state update rules:

- existing config/list files are seeded, not overwritten, unless
  `--replace-config` is explicitly requested;
- project program/unit/filter/action files are replaced from the repository;
- existing RIPH jail `enabled=true/false` values are preserved across reinstall;
- malformed existing jail enabled state fails closed before replacement;
- production installs run `systemctl daemon-reload` after unit replacement;
- newly installed Fail2ban files are checked with `fail2ban-client -t`;
- the installer does **not** reload Fail2ban merely because project files were
  refreshed;
- Nginx apply and Router-IP timer activation remain explicit options.

## Rollback

Normal apply backups contain generated allowlist/routing files, previous-IP grace,
last successful apply state and a manifest. `riph-rollback` creates a safety
snapshot immediately before rollback, validates restored Nginx with `nginx -t`, and
restores its own safety snapshot if rollback validation/reload fails.

The production install transaction has a separate install-backup tree. SSH policy
and unrelated services are outside all RIPH rollback/install mutations.

## Admin / operational surface

`riph-admin` is a frontend; it does not implement a second copy of apply logic.
Core operational tools also include:

- `riph-hotfix-handover status|takeover`;
- `riph-fail2ban-activate`;
- `riph-legacy-handover status|quiesce|retire`.

Normal administration exposes trusted/grace state, apply/reconcile, manual deny,
RIPH Fail2ban status/unban, UFW status, guard, Router-IP watch/timer, harvest and
rollback.

## Production confirmation gate

Production validation is complete, but a real `/` install remains an explicit
operator action. `install.sh` requires:

```text
RIPH_ALLOW_PRODUCTION=1
```

for production mutation. The historical
`RIPH_ALLOW_INCOMPLETE_PRODUCTION=1` variable is accepted as a compatibility alias
so old controlled procedures do not fail unexpectedly. This is a confirmation
interlock, not an indication that v1 is still pre-production.
