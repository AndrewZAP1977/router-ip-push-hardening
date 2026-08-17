# Hexabyte legacy migration

This document records the pre-existing Hexabyte mechanisms discovered by the
read-only preflight on 2026-08-17 and defines a no-gap migration into RIPH v1.

## Legacy state that must be preserved initially

### Nginx stream audit

`/etc/nginx/stream-enabled/00-sni-watch.conf` defines stream-level format
`sni_watch` and writes:

```text
/var/log/nginx/stream-sni.log
```

Because it is configured at stream level, it currently logs both the external
`:443` server and the local PROXY-protocol bridge servers.

### Legacy Fail2ban reject jail

Existing jail name:

```text
nginx-stream-sni-reject
```

Observed policy before migration:

```text
enabled  = true
findtime = 10m
maxretry = 5
bantime  = 6h
action   = ufw-443-insert[name=nginx-stream-sni-reject]
```

It consumes `/var/log/nginx/stream-sni.log`.

The exact legacy filter and action definitions must be captured read-only before
retirement is implemented.

### Existing manual UFW 443 denies

These are intentionally left untouched during initial RIPH installation:

```text
176.65.132.38
199.45.154.0/23
167.71.72.165
82.39.206.156
45.148.10.0/24
```

They are not treated as RIPH-owned until a later explicit adoption step.

## Collision avoidance in RIPH v1

RIPH does not overwrite the legacy jail/filter/log names.

Dedicated RIPH objects:

```text
log:     /var/log/nginx/riph-stream-sni.log
jails:   riph-nginx-stream-sni-reject
         riph-nginx-stream-private-sni-abuse
filters: riph-nginx-stream-sni-reject
         riph-nginx-stream-private-sni-abuse
```

Both RIPH jails are installed disabled.

## Phase A — parallel audit, legacy protection remains active

During controlled migration:

```text
LEGACY_STREAM_AUDIT_COMPAT=1
```

The external `:443` server explicitly writes two logs:

1. the legacy `sni_watch` log, so the already-running legacy jail continues to
   observe external sessions;
2. the dedicated RIPH route-aware log, used for RIPH validation.

The legacy stream-level logger remains present, so bridge sessions continue to be
recorded exactly as before in the legacy log. Bridge sessions are never written to
the RIPH route-aware log.

No legacy Fail2ban file is overwritten and no legacy jail is restarted merely by
RIPH Nginx apply.

## Phase B — validate RIPH routing and RIPH log

Before any Fail2ban migration:

- validate Nginx routing behavior;
- confirm the legacy log still receives external `:443` traffic;
- confirm `/var/log/nginx/riph-stream-sni.log` receives external `:443` only;
- validate RIPH Fail2ban regex against the new route-aware log;
- confirm RIPH jails remain disabled.

## Phase C — Fail2ban handover (planned, not automatic yet)

The handover must be an explicit guarded operation after the exact legacy filter
and action files have been captured.

Desired no-gap sequence:

1. enable RIPH jails while legacy jail is still active;
2. validate both RIPH jails and trusted-ignore protection;
3. optionally carry currently banned legacy source IPs into the new RIPH reject
   jail so active protection is not lost;
4. disable the legacy `nginx-stream-sni-reject` jail with a reversible override;
5. reload/validate Fail2ban;
6. verify RIPH-owned UFW rules use `riph-f2b-*` markers and legacy shutdown did
   not remove them;
7. run trusted-unban guard;
8. only then retire legacy audit compatibility.

No SSH policy is changed at any point.

## Phase D — retire legacy stream audit

After the new RIPH jails are proven:

1. set `LEGACY_STREAM_AUDIT_COMPAT=0`;
2. transactionally apply and validate Nginx;
3. move `00-sni-watch.conf` out of the active `stream-enabled` include only with a
   backup and `nginx -t` gate;
4. reload Nginx;
5. verify only the RIPH audit log is active for the security pipeline.

The old log file may be retained as historical evidence; it does not need to be
deleted.

## Phase E — manual UFW adoption

The five legacy manual denies remain active and untouched until a separate
migration step is tested. Adoption must avoid both protection gaps and permanent
duplicate rules:

1. validate the CIDR does not overlap effective trusted state;
2. create the equivalent RIPH-owned marked rule;
3. confirm the RIPH-owned rule is active;
4. remove only the exact corresponding legacy rule;
5. record the CIDR in the RIPH source list/applied state.

Do not infer ownership merely because a CIDR already exists in UFW.
