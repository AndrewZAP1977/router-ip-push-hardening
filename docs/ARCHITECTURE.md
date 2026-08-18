# Router IP Push Hardening v1 architecture

## Design boundary

This repository is a private supplement installed after the public `3x-ui-installer`.
It owns private trusted-source policy, private SNI camouflage routing and the related
operational safeguards. It does not own 3x-ui/Xray client configuration, SSH,
ZeroTier, Nextcloud, OnlyOffice or ztncui.

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

## 2026-08-17 staging failure that defines the Router-IP invariant

The old staging setup had Router IP Push and a generated Nginx allowlist but no
permanent consumer connecting the two. When AX3200 changed from
`78.111.155.187` to `78.111.154.96`, Router IP Push correctly updated its `.ipv4`
and state JSON, while Nginx retained the old trusted address. The new home address
was therefore routed as untrusted to the fake-site bridge.

RIPH treats the following as a hard invariant:

```text
Router IP Push current file changes
        -> reconcile is triggered
        -> new current IP is present in the active allowlist
        -> Nginx validation succeeds
        -> Nginx reload succeeds
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

## Stream audit logs and legacy overlap

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

During controlled migration, `LEGACY_STREAM_AUDIT_COMPAT=1` also writes the
external `:443` session to the existing legacy:

```text
/var/log/nginx/stream-sni.log
```

using `sni_watch`, while `/etc/nginx/stream-enabled/00-sni-watch.conf` remains
available for the old security pipeline. This overlap is explicitly retired only
through the legacy handover.

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

## Temporary staging hotfix and atomic ownership handover

Until production RIPH ownership is validated, Hexabyte is protected by the
temporary:

```text
router-ip-push-nginx-hotfix.path
router-ip-push-nginx-hotfix.timer
router-ip-push-nginx-hotfix.service
/usr/local/sbin/router-ip-push-nginx-hotfix
```

The temporary hotfix and RIPH must not remain simultaneous long-lived writers of
the same allowlist.

`riph-hotfix-handover takeover` transfers ownership:

1. acquire `/run/lock/router-ip-push-nginx-hotfix.lock`, the same lock used by the
   temporary writer;
2. record temporary hotfix state;
3. disable/stop its automatic triggers;
4. run a strict RIPH reconcile while no automatic writer owns the allowlist;
5. enable `riph-router-ip.path` and `riph-reconcile.timer`;
6. confirm both are active;
7. run a **second reconcile**;
8. re-read Router IP Push and verify each configured current IP exists in the
   active generated allowlist;
9. keep temporary hotfix files on disk but disabled for rollback/forensics.

The second reconcile closes a subtle race: Router IP Push itself does not use the
hotfix lock, so an ISP address may change during the ownership transition. If any
handover step fails, the temporary path/timer are re-enabled.

The production installer detects an active temporary hotfix. While it owns the
allowlist, production apply is accepted only as the atomic
`--apply --enable-timers` ownership handover.

## Fail2ban policy

Two isolated project jails consume the RIPH route-aware log. They are installed
**disabled** and activated only after Nginx routing has been proven.

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
`riph-manual-443` rule for the same source.

Automatic whole-IP/all-port bans are outside v1.

## Legacy Fail2ban handover

Hexabyte already has an active legacy `nginx-stream-sni-reject` jail using a generic
unmarked UFW action. RIPH therefore uses different jail/filter names and does not
overwrite the legacy files.

The no-gap retirement sequence is:

1. prove RIPH routing and audit log;
2. activate both `riph-*` jails while legacy reject remains active;
3. validate trusted-ignore and marked UFW ownership;
4. quiesce new external events to the legacy log;
5. let any existing legacy 6-hour bans expire naturally;
6. retire legacy jail configuration only when its ban list is empty;
7. preserve legacy filter/action/log files for forensic rollback.

Existing legacy automatic bans are not adopted in place because their
`actionunban` is a generic unmarked UFW deletion.

## Manual deny

Source lists:

- `/etc/router-ip-push-hardening/manual-deny-443.list`
- `/etc/router-ip-push-hardening/manual-deny-all.list`

`riph-apply-manual-deny` owns only UFW rules recorded in its own applied-state file.
It does not run `ufw reset` and does not delete unrelated rules by number.
Manual-deny and RIPH Fail2ban UFW mutations are serialized by the shared project
UFW lock.

Normal edits are strict: a deny CIDR that overlaps the effective trusted set is
rejected before UFW is changed.

If the trusted set changes later and moves inside an already configured manual deny,
`riph-trusted-unban-guard` invokes the manual-deny engine in protection mode. The
conflicting project-owned rule is removed/suppressed from applied state while the
source-list entry remains visible for administrator review.

Existing legacy manual UFW denies are outside RIPH ownership until a later explicit
adoption operation.

## Rollback

Normal apply backups contain:

- generated allowlist;
- generated stream config;
- generated bridge config;
- previous-IP grace state;
- last successful apply state;
- manifest with reason/timestamp.

`riph-rollback` creates a safety snapshot immediately before rollback. A selected
backup is restored, `nginx -t` is executed, and Nginx is reloaded. If the restored
backup fails validation or reload, rollback restores its own safety snapshot.

The installer separately creates a pre-install snapshot of every installed project
file plus the three Nginx runtime files. It validates Fail2ban while the RIPH jails
are still disabled and does not activate them as part of the Nginx ownership
handover.

## Admin / operational surface

`riph-admin` is a frontend; it does not implement a second copy of apply logic.
Core operational tools also include:

- `riph-hotfix-handover status|takeover`;
- `riph-fail2ban-activate`;
- `riph-legacy-handover status|quiesce|retire`.

Normal administration exposes trusted/grace state, apply/reconcile, manual deny,
RIPH Fail2ban status/unban, UFW status, guard, Router-IP watch/timer, harvest and
rollback.

## Production gate

The branch remains pre-production. Real `/` installation is blocked by `install.sh`
unless the explicit controlled-test environment variable is supplied. The gate must
remain in place until the controlled sequence in `docs/HEXABYTE_TEST_PLAN.md` is
ready to execute.
