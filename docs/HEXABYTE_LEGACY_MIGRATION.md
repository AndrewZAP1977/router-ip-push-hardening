# Hexabyte legacy migration

This document records the pre-existing Hexabyte mechanisms discovered by the
read-only preflight on 2026-08-17 and defines a no-gap migration into RIPH v1.

## Legacy state that must be preserved initially

### Nginx stream audit

`/etc/nginx/stream-enabled/00-sni-watch.conf` defines:

```nginx
log_format sni_watch 'time="$time_local" ip="$remote_addr" port="$remote_port" sni="$ssl_preread_server_name" upstream="$upstream_addr" status=$status sent=$bytes_sent recv=$bytes_received time_sec=$session_time';
access_log /var/log/nginx/stream-sni.log sni_watch buffer=32k flush=5s;
```

Because the logger is configured at stream level, it currently records both the
external `:443` server and local PROXY-protocol bridge servers.

### Legacy Fail2ban reject jail

Existing jail name:

```text
nginx-stream-sni-reject
```

Observed configuration:

```text
enabled  = true
findtime = 10m
maxretry = 5
bantime  = 6h
action   = ufw-443-insert[name=nginx-stream-sni-reject]
logpath  = /var/log/nginx/stream-sni.log
```

Observed filter:

```text
failregex = ^.*ip="<HOST>" port="[0-9]+" sni="[^"]*" upstream="127\.0\.0\.1:9" status=.*$
```

So the legacy jail bans sessions that reached the dead reject upstream.

Observed action:

```text
actionban   = ufw insert 1 deny from <ip> to any port 443 proto tcp
actionunban = ufw delete deny from <ip> to any port 443 proto tcp
```

These legacy automatic UFW rules have no RIPH ownership marker. Because the
legacy `actionunban` is a generic rule deletion, RIPH must not try to adopt those
rules in place or accelerate their removal during handover.

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

1. legacy `sni_watch`, so the already-running legacy reject jail continues to
   observe external sessions;
2. dedicated RIPH route-aware log, used for RIPH validation and future RIPH jails.

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

## Phase C — activate RIPH jails while legacy jail remains active

The activation is explicit and guarded:

1. validate `fail2ban-client -t`;
2. validate both RIPH regex filters;
3. validate current/static trusted ignore behavior;
4. enable `riph-nginx-stream-sni-reject` and
   `riph-nginx-stream-private-sni-abuse`;
5. reload Fail2ban;
6. confirm both RIPH jails are active;
7. run trusted-unban guard;
8. verify any new RIPH UFW bans use exact `riph-f2b-*` ownership markers.

At this point both the legacy reject jail and the RIPH security pipeline may be
active briefly. Do not migrate existing legacy ban rules into RIPH manually.

## Phase D — quiesce legacy input, then wait for old bans to expire

Once the RIPH jails are proven healthy:

1. set `LEGACY_STREAM_AUDIT_COMPAT=0` through the controlled legacy handover;
2. remove the stream-level `00-sni-watch.conf` from active logging only through a
   backed-up `nginx -t`-gated operation;
3. stop feeding **new** reject events to the legacy jail;
4. leave the legacy jail running while its existing ban list ages naturally under
   the original 6-hour `bantime`;
5. do not issue generic legacy `unbanip`/UFW cleanup merely to speed retirement.

This avoids having the broad legacy `actionunban` remove a rule whose ownership is
ambiguous.

## Phase E — retire legacy jail only when ban list is empty

Retirement is permitted only when:

```text
fail2ban-client get nginx-stream-sni-reject banip
```

returns no addresses.

Then:

1. back up the legacy jail configuration;
2. disable/remove the active legacy jail override from Fail2ban configuration;
3. validate `fail2ban-client -t`;
4. reload/restart Fail2ban as required by the tested helper;
5. confirm the legacy jail is no longer active;
6. confirm both RIPH jails remain active;
7. confirm existing manual UFW denies remain unchanged.

The old filter/action/log files may be retained as historical evidence. They do
not need to be deleted.

## Phase F — manual UFW adoption

The five legacy manual denies remain active and untouched until a separate
migration step is tested. Adoption must avoid both protection gaps and permanent
duplicate rules:

1. validate the CIDR does not overlap effective trusted state;
2. create the equivalent RIPH-owned marked rule;
3. confirm the RIPH-owned rule is active;
4. remove only the exact corresponding legacy rule;
5. record the CIDR in the RIPH source list/applied state.

Do not infer ownership merely because a CIDR already exists in UFW.

## SSH and unrelated services

No phase in this migration changes SSH policy, ZeroTier, Nextcloud, OnlyOffice,
ztncui, 3x-ui client data or Xray client definitions.
