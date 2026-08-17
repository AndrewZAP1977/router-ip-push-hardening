# Hexabyte controlled validation plan

This plan is deliberately gate-based. Do not advance to the next phase until the
previous phase has been reviewed and explicitly accepted.

The first server interaction is **read-only**. The production installer gate stays
enabled until Phase 2 is complete.

## Phase 0 — local/repository readiness

Required before touching Hexabyte:

- GitHub Actions remains manual-only (`workflow_dispatch`);
- local/test-root regression suite passes;
- no production `/` install has been performed from this repository;
- branch remains draft and unmerged;
- current Hexabyte-specific seed values are reviewed:
  - public SNI `nukla.layerupzap.ru` -> `127.0.0.1:7443`;
  - private SNI `treda.layerupzap.ru` -> Xray `8443`, fake `9443`, bridge `9543`;
  - private SNI `trongo.layerupzap.ru` -> Xray `8444`, fake `9444`, bridge `9544`;
  - reject upstream `127.0.0.1:9`;
  - static trusted `127.0.0.1`, VPS_GR `5.61.39.137`, Spectra `45.87.41.121`, Hexabyte `194.104.94.182`;
  - AX3200 remains dynamic through Router IP Push.

## Phase 1 — read-only Hexabyte preflight

Run `tools/preflight-report.sh` as root from a checked-out copy of this branch.

The script must not:

- install packages;
- write Nginx configuration;
- reload/restart services;
- change UFW;
- change Fail2ban;
- modify Router IP Push;
- modify SSH;
- inspect or modify 3x-ui/Xray client data.

Review the report for:

1. Ubuntu/Debian version and command availability;
2. current `nginx -t` result;
3. current Nginx stream include layout;
4. exact current contents of:
   - `05-router-ip-push-source-allow.conf`;
   - `06-router-ip-push-fake-site-bridges.conf` if present;
   - `stream.conf`;
5. current listeners on 443/7443/8443/8444/9443/9444/9543/9544;
6. Router IP Push current IP and `last_seen`;
7. current Fail2ban installation/service/jails;
8. current UFW rules and whether UFW is active;
9. any existing RIPH files/units from manual experiments;
10. existing stream audit log format/tail.

**STOP GATE 1:** do not install anything until the report is compared with the
known manually tested Hexabyte state.

## Phase 2 — candidate generation without production mutation

Build a temporary test root from the approved Hexabyte values and generate:

- effective trusted allowlist;
- private `stream.conf`;
- fake-site bridge config;
- Fail2ban filters/jails/action.

Compare generated Nginx behavior with the known working manual policy:

```text
nukla + any                 -> 7443
treda + trusted             -> 8443
treda + untrusted           -> 9543 -> 9443
trongo + trusted            -> 8444
trongo + untrusted          -> 9544 -> 9444
unknown / empty / IP-SNI    -> reject 127.0.0.1:9
```

Confirm the generated audit log exists only on the external `:443` server, not on
internal bridge listeners.

Validate Fail2ban regex against synthetic controlled log lines before live jails are
enabled. Validate `riph-fail2ban-ufw` with synthetic UFW status containing both a
manual deny and a Fail2ban deny for the same IP; unban must select only the exact
`riph-f2b-<jail>` marked rule.

**STOP GATE 2:** candidate diff must contain no unexpected listener, upstream,
trusted source, package/service, SSH or unrelated configuration change.

## Phase 3 — pre-install safety snapshot

Immediately before the first controlled install:

- confirm SSH access still works from the current session;
- keep the current SSH session open;
- record current `nginx -t` as successful;
- save the exact Nginx stream files;
- save current Fail2ban project-related files/status;
- save `ufw status numbered`;
- save Router IP Push state;
- record enabled/active state of relevant systemd units.

The installer creates its own pre-install snapshot as an additional layer, including
all three Nginx runtime files that may later be changed by `riph-apply`.

No SSH policy is changed.

**STOP GATE 3:** rollback material must be readable before any apply.

## Phase 4 — controlled file install, no timers yet

Use the explicit controlled-test production gate only after Phases 1–3 pass.

First install files without enabling timers. Review:

- `/etc/router-ip-push-hardening/config.env`;
- static trusted list;
- current Router IP Push address;
- generated candidates via dry-run/admin status.

Do not use `--replace-config` unless replacement of existing RIPH config was
explicitly intended and reviewed.

## Phase 5 — transactional Nginx apply

Run the normal transactional apply.

Required checks:

1. backup created;
2. `nginx -t` succeeds;
3. only expected allowlist/stream/bridge files change;
4. Nginx reload succeeds;
5. current SSH session remains healthy;
6. `riph-admin status` shows expected current/effective trusted sources.

If validation or reload fails, stop and inspect automatic rollback. Do not continue
to Fail2ban.

## Phase 6 — routing functional checks

Verify the non-destructive cases first:

- `nukla` reaches the public site;
- AX3200/current trusted source reaches `treda` Xray;
- AX3200/current trusted source reaches `trongo` Xray;
- normal user traffic remains functional.

For an untrusted-source camouflage test, use a source that is deliberately and
safely outside the effective trusted set. Do not temporarily remove the current
home/Router IP from trusted state merely to force a test.

Expected untrusted results:

- `treda` -> fake treda site through bridge 9543;
- `trongo` -> fake trongo site through bridge 9544;
- unknown SNI -> reject.

Confirm `/var/log/nginx/stream-sni.log` records external `:443` sessions only and
shows final routes `www`, `xray_N`, `fake_N`, or `reject`.

**STOP GATE 4:** private trusted routing and camouflage must match the previously
manual-tested behavior before Fail2ban is activated.

## Phase 7 — Fail2ban validation and activation

Before restart/reload:

- ensure `fail2ban-client -t` succeeds;
- run `fail2ban-regex` against controlled sample log;
- verify both actions are TCP/443 only;
- verify `riph-fail2ban-ignore` returns success for:
  - current AX3200 IP;
  - VPS_GR;
  - Spectra;
  - Hexabyte;
- verify it returns nonzero for a known untrusted test IP;
- verify `riph-fail2ban-ufw` only selects/removes exact project-marked rules.

After activation:

- both project jails are active;
- no trusted IP is banned;
- `riph-admin guard` reports a clean trusted state.

Do not deliberately trigger a live ban from the current home IP.

## Phase 8 — manual deny validation

Use a harmless documentation/test IP outside all trusted ranges to validate:

- add 443-only deny;
- repeated apply is idempotent;
- remove 443-only deny;
- trusted-overlap addition is rejected before UFW mutation.

All-port deny remains a manual exceptional path; it is not part of the normal live
validation sequence.

## Phase 9 — Router IP watch / grace / guard

Only after routing and Fail2ban are healthy:

- enable `riph-router-ip.path`;
- enable `riph-reconcile.timer`;
- confirm both are active;
- confirm there is no separate periodic guard timer;
- confirm the trusted guard runs inside reconcile.

A real ISP IP change is the final end-to-end validation when it naturally occurs:

1. Router IP Push writes the new `.ipv4` address;
2. path unit triggers reconcile;
3. new IP becomes current trusted;
4. old IP enters 4-hour grace;
5. trusted guard removes any project 443 ban affecting the new IP;
6. after grace expires, periodic reconcile removes the old IP.

Do not force an ISP reconnect solely for this test unless explicitly agreed.

## Phase 10 — harvest checkpoint / observation

Set a harvest checkpoint only after the system is known healthy:

```text
riph-admin harvest-checkpoint
```

Observe normal traffic, then inspect:

```text
riph-admin harvest
```

Expected categories:

- trusted private SNI -> `xray_N`;
- untrusted private SNI -> `fake_N`;
- unknown/empty/IP-SNI -> `reject`;
- public site -> `www`.

## Phase 11 — rollback drill

A rollback drill is performed only after a known-good post-install state is saved.
Use a controlled non-connectivity-breaking routing/config change or an isolated
validation where possible.

Verify:

- apply backup list is readable;
- rollback creates a safety snapshot;
- selected backup restores successfully;
- `nginx -t` succeeds before reload;
- system returns to the known-good configuration.

Do not use SSH/UFW access-policy changes as rollback-drill material.

## Completion criteria

Private v1 is ready to merge only after:

- all read-only/pre-production gates pass;
- controlled Hexabyte routing matches the manually proven scheme;
- Fail2ban jails match only controlled final routes;
- trusted IPs cannot remain project-banned;
- automatic bans remain TCP/443-only;
- Fail2ban unban cannot remove project manual-deny ownership;
- Router IP Push remains reachable over SSH;
- timers/watch behave as designed;
- harvest shows clean routing categories;
- rollback has been validated;
- one final GitHub Actions run may be performed only with explicit approval.
