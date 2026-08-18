# Hexabyte legacy migration

This document records the pre-existing Hexabyte security mechanisms discovered by
read-only preflight on 2026-08-17 and the completed no-gap migration into RIPH v1.

## Completion status

Migration completed on 2026-08-18.

Final production state:

- dedicated RIPH audit log active on external `:443`;
- RIPH reject/private-SNI Fail2ban jails active;
- legacy stream logger retired from active Nginx configuration;
- legacy reject jail retired from active Fail2ban configuration;
- temporary legacy trusted-ignore override retired;
- temporary current-Router-IP UFW shield retired;
- exactly five RIPH-owned manual TCP/443 denies remain;
- no temporary manual-deny adoption bridge remains;
- `riph-router-ip.path` and `riph-reconcile.timer` are enabled/active;
- automatic reconcile accepts the fail-closed physical ownership state.

Retired legacy files were archived by the migration helpers for forensic rollback.
Legacy filter/action files were retained where appropriate.

## Legacy state discovered before migration

### Nginx stream audit

`/etc/nginx/stream-enabled/00-sni-watch.conf` defined the old `sni_watch` log format
and wrote `/var/log/nginx/stream-sni.log` at stream level. Because it was configured
at stream level, it included both external `:443` and local bridge activity.

### Legacy Fail2ban reject jail

Observed legacy jail:

```text
nginx-stream-sni-reject
findtime = 10m
maxretry = 5
bantime  = 6h
logpath  = /var/log/nginx/stream-sni.log
```

Its filter matched sessions that reached reject upstream `127.0.0.1:9`.
Its UFW action created unmarked TCP/443 denies and used a broad unmarked delete on
unban. Because those automatic rules had no RIPH ownership marker, RIPH never
adopted them in place or accelerated their removal.

### Existing manual UFW TCP/443 denies

Five pre-existing manual rules were present:

```text
176.65.132.38/32
199.45.154.0/23
167.71.72.165/32
82.39.206.156/32
45.148.10.0/24
```

They were intentionally left untouched during the first RIPH install and only
adopted after the rest of the security migration was stable.

## Collision avoidance used during migration

RIPH used separate names throughout coexistence:

```text
log:     /var/log/nginx/riph-stream-sni.log
jails:   riph-nginx-stream-sni-reject
         riph-nginx-stream-private-sni-abuse
filters: riph-nginx-stream-sni-reject
         riph-nginx-stream-private-sni-abuse
```

The first install did not overwrite the old jail/filter/log names.

## Phase A — parallel audit

The controlled migration initially used:

```text
LEGACY_STREAM_AUDIT_COMPAT=1
```

The external `:443` server wrote both the legacy log and the new RIPH route-aware
log while the old jail remained active. Live validation confirmed equivalent
external sessions appeared in both logs before quiesce.

## Phase B — validate RIPH routing/logging

Before Fail2ban activation, production validation confirmed:

- trusted AX3200 `treda` -> Xray `8443`;
- trusted AX3200 `trongo` -> Xray `8444`;
- trusted SmartBox-mother `treda` -> Xray `8443`;
- untrusted/reject sessions were recorded with final RIPH routes;
- internal bridge listeners did not become separate external RIPH log entries.

## Phase C — activate RIPH jails

Activation completed transactionally with `fail2ban-client -t` and reload rather
than restart.

Both RIPH jails became active while the legacy jail was still present. Synthetic
UFW action tests validated:

- IPv4 reject ban/unban;
- IPv4 private-SNI-abuse ban/unban;
- IPv6 reject ban/unban;
- exact RIPH ownership markers;
- cleanup after explicit unban.

During coexistence, dynamic trusted ignore plus a project-owned top-of-UFW current
Router-IP shield protected a newly assigned trusted ISP source without deleting any
ambiguous old legacy deny.

## Phase D — quiesce legacy input

After RIPH Fail2ban validation, legacy external logging was quiesced by setting:

```text
LEGACY_STREAM_AUDIT_COMPAT=0
```

The old jail remained available while its existing ban list aged naturally under
the original 6-hour policy. A post-quiesce live AX3200 request appeared only in the
RIPH log, proving new external events no longer fed the legacy pipeline.

## Phase E — retire legacy jail/logger

Retirement was allowed only after the legacy ban list was read successfully and was
empty.

The controlled retirement then removed the active:

- `00-sni-watch.conf`;
- legacy reject jail config;
- legacy trusted-ignore override;
- temporary RIPH current-IP UFW shield.

Nginx and Fail2ban validation/reload succeeded. Retired active files were archived
under the RIPH runtime backup area.

Post-retirement production state had exactly these active jails:

```text
3x-ipl
riph-nginx-stream-sni-reject
riph-nginx-stream-private-sni-abuse
```

Final live smoke confirmed the legacy log remained unchanged while the RIPH log
continued to grow.

## Phase F — manual UFW adoption

### Ownership bug discovered before adoption

The first attempt to add the five manual sources to RIPH exposed real UFW behavior:
a semantically duplicate rule can be skipped while the command still returns
success. The old manual unmarked DENY therefore remained, while the old helper
incorrectly wrote `manual-deny-applied.tsv` as if a RIPH-marked rule had been
created.

`riph-apply-manual-deny` was hardened before migration continued:

- applied state is treated as an ownership claim;
- every state row must correspond to a physically visible exact RIPH-marked UFW
  rule;
- `Skipping adding existing rule` is treated as failure;
- successful add/delete is followed by physical rule verification;
- false ownership state fails closed before mutation.

Regression coverage includes the exact duplicate/no-op and false-state cases.

### Transactional adoption

A one-time helper adopted the five old manual rules with this safety sequence:

1. require `manual-deny-443.list` and stale applied state to match exactly;
2. require exactly one old unmarked TCP/443 deny for each source;
3. verify no source overlaps effective trusted state;
4. verify there is no conflicting active RIPH Fail2ban rule;
5. add and verify temporary destination-specific `riph-adopt-bridge` denies to
   Hexabyte public `194.104.94.182:443`;
6. remove only the exact old unmarked manual rules;
7. add and verify exact `# riph-manual-443` rules;
8. atomically repair `manual-deny-applied.tsv`;
9. remove temporary bridge rules only after permanent ownership and state are
   verified;
10. rollback restores old legacy rules/state and keeps bridge protection if
    restoration cannot be proven complete.

The production dry-run passed for all five sources with no UFW/list/state change.
The real adoption completed successfully and created an adoption backup under:

```text
/var/lib/router-ip-push-hardening/backups/manual-deny-adopt-20260818-162655-1320851
```

A later accidental second invocation correctly failed its preflight because the
old unmarked rules no longer existed; it made no changes.

Final manual-deny state:

```text
5 × # riph-manual-443
0 × riph-adopt-bridge
0 × old unmarked copies of those five rules
```

The production `riph-apply-manual-deny` was then replaced with the tested
fail-closed version. Installed ownership dry-run returned success, guard returned
success with `trusted_unbanned=0 manual_conflicts=0`, and subsequent automatic
`riph-reconcile.service` runs repeatedly logged:

```text
manual deny state already matches desired lists and owned UFW rules
```

## SSH and unrelated services

No phase in this migration changed SSH policy, ZeroTier, Nextcloud, OnlyOffice,
ztncui, 3x-ui client data or Xray client definitions.
