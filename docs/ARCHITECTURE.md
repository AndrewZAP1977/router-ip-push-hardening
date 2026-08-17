# Router IP Push Hardening v1 architecture

## Design boundary

This repository is a private supplement installed after the public `3x-ui-installer`.
It owns private trusted-source policy, private SNI camouflage routing and the related
operational safeguards. It does not own 3x-ui/Xray client configuration, SSH,
ZeroTier, Nextcloud, OnlyOffice or ztncui.

## Source of truth

The generated Nginx allowlist is not edited manually. The effective trusted set is:

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

## Stable stream audit log

The generated stream config owns a stable machine-readable log:

```text
/var/log/nginx/stream-sni.log
```

Fields include:

```text
time src=<remote IPv4> route=<final route> sni=<SNI> upstream=<addr> status=<status> session=<seconds>
```

The important security field is the **final route**, not a regex guess about the
original SNI:

- `route=reject` -> unknown/empty/IP-SNI path;
- `route=fake_N` -> private SNI from an untrusted source;
- `route=xray_N` -> private SNI from a trusted source;
- `route=www` -> public site.

## Apply transaction

`riph-apply` is the only normal mutation path for trusted/routing state:

1. take exclusive `flock`;
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
14. record the successful state.

The candidate include files must be visible at the real Nginx include path for a
real `nginx -t`; therefore they are installed atomically before validation but do
not become active until a successful reload. Failure restores the previous files.

## Router-IP change and periodic reconcile

The existing Router IP Push receiver writes the `.ipv4` file only when the source
address actually changes. Hardening does not modify that receiver.

```text
Router IP changes
  -> /var/lib/router-ip-push/ips directory changes
  -> riph-router-ip.path
  -> riph-reconcile.service
  -> riph-apply
  -> riph-trusted-unban-guard
```

A separate `riph-reconcile.timer` runs every 5 minutes. It performs both periodic
grace expiry and the trusted-unban guard. There is deliberately no second periodic
guard timer because that would duplicate the same work.

## Fail2ban policy

Two project jails consume the controlled stream audit log:

### `nginx-stream-sni-reject`

- match: final `route=reject`;
- `maxretry = 3`;
- `findtime = 5m`;
- `bantime = 8h`;
- action scope: TCP/443 only.

### `nginx-stream-private-sni-abuse`

- match: final `route=fake_N`;
- `maxretry = 3`;
- `findtime = 2m`;
- `bantime = 12h`;
- action scope: TCP/443 only.

Both jails use `riph-fail2ban-ignore <ip>` before banning. The helper computes the
current effective trusted set dynamically, so current Router IP, grace IP and static
trusted ranges are protected even before the periodic guard runs.

Automatic whole-IP/all-port bans are outside v1.

## Manual deny

Source lists:

- `/etc/router-ip-push-hardening/manual-deny-443.list`
- `/etc/router-ip-push-hardening/manual-deny-all.list`

`riph-apply-manual-deny` owns only UFW rules recorded in its own applied-state file.
It does not run `ufw reset` and does not delete unrelated rules by number.

Normal edits are strict: a deny CIDR that overlaps the effective trusted set is
rejected before UFW is changed.

If the trusted set changes later and moves inside an already configured manual deny,
`riph-trusted-unban-guard` invokes the manual-deny engine in protection mode. The
conflicting project-owned rule is removed/suppressed from applied state while the
source-list entry remains visible for administrator review.

## Rollback

Normal apply backups contain:

- generated allowlist;
- generated stream config;
- generated bridge config;
- previous-IP grace state;
- last successful apply state;
- manifest with reason/timestamp.

`riph-rollback` creates a safety snapshot of the state immediately before rollback.
A selected backup is restored, `nginx -t` is executed, and Nginx is reloaded. If the
restored backup fails validation or reload, the rollback operation restores its own
safety snapshot.

The installer separately creates a pre-install snapshot of installed project files
and restores it automatically if installation fails. Manual restoration of a full
pre-install snapshot is intentionally deferred until the first read-only Hexabyte
preflight establishes the exact pre-existing server state.

## Admin surface

`riph-admin` is a frontend; it does not implement a second copy of apply logic.
It exposes:

- status and Router IP Push `last_seen`;
- effective/static/grace trusted state;
- apply/reconcile;
- manual deny 443/all add/remove/apply;
- Fail2ban status/unban/validate+reload;
- UFW project/relevant status;
- trusted-unban guard and guard log;
- Router-IP watch/reconcile timer status;
- stream-log harvest/checkpoint/recent log;
- apply backup listing and runtime rollback.

## Production gate

The branch remains pre-production. Real `/` installation is blocked by `install.sh`
unless the explicit controlled-test environment variable is supplied. The gate must
remain in place until the read-only Hexabyte preflight and planned test sequence are
completed.
