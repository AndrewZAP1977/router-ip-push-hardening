# Hexabyte controlled validation plan

This plan is deliberately gate-based. Do not advance to the next phase until the
previous phase has been reviewed and explicitly accepted.

The first server interaction is **read-only**. Production mutation remains gated
until candidate validation is complete.

## Real incident incorporated into the test plan

On 2026-08-17 the AX3200 public IPv4 changed from `78.111.155.187` to
`78.111.154.96`. Router IP Push correctly updated:

- `/var/lib/router-ip-push/ips/AX3200.ipv4`;
- `/var/lib/router-ip-push/state/AX3200.json`.

The old staging Nginx allowlist did not have a consumer watching that update, so
the new source was treated as untrusted and `treda.layerupzap.ru` was routed to
bridge `9543` / fake site instead of Xray `8443` until the allowlist was corrected
and Nginx reloaded.

This exact A -> B transition is now a mandatory regression case. A temporary
production safeguard currently owns the staging allowlist on Hexabyte:

- `router-ip-push-nginx-hotfix.path`;
- `router-ip-push-nginx-hotfix.timer` (1-minute fallback);
- `router-ip-push-nginx-hotfix.service`;
- `/usr/local/sbin/router-ip-push-nginx-hotfix`.

The temporary hotfix must remain active until RIPH takes ownership atomically. It
must not run in parallel with RIPH as a second long-lived allowlist writer.

## Phase 0 — local/repository readiness

Required before changing Hexabyte production state:

- GitHub Actions remains manual-only (`workflow_dispatch`);
- local/test-root regression suite passes;
- no production `/` install has been performed from this repository;
- branch remains draft and unmerged;
- exact Router-IP incident regression passes:
  - A=`78.111.155.187` is initially current/trusted;
  - Router IP Push atomically replaces the current file with B=`78.111.154.96`;
  - first reconcile makes B trusted immediately;
  - A remains trusted only as 4-hour previous-IP grace;
  - after grace expiry A is removed while B remains trusted;
- systemd unit regression confirms:
  - `PathChanged=/var/lib/router-ip-push/ips`;
  - path triggers `riph-reconcile.service`;
  - fallback reconcile timer is 1 minute;
- hotfix handover regression confirms:
  - successful takeover disables temporary hotfix path/timer;
  - RIPH path/timer become active;
  - takeover performs a second reconcile after RIPH path activation;
  - an IP change occurring between the two reconciles is still consumed;
  - failed takeover restores the temporary hotfix;
- current Hexabyte-specific seed values are reviewed:
  - public SNI `nukla.layerupzap.ru` -> `127.0.0.1:7443`;
  - private SNI `treda.layerupzap.ru` -> Xray `8443`, fake `9443`, bridge `9543`;
  - private SNI `trongo.layerupzap.ru` -> Xray `8444`, fake `9444`, bridge `9544`;
  - reject upstream `127.0.0.1:9`;
  - static trusted `127.0.0.1`, VPS_GR `5.61.39.137`, Spectra `45.87.41.121`, Hexabyte `194.104.94.182`;
  - AX3200 remains dynamic through Router IP Push.

## Phase 1 — read-only Hexabyte preflight

Run `tools/preflight-report.sh` as root.

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

1. Debian version and command availability;
2. current `nginx -t` result;
3. current Nginx stream include layout;
4. exact current contents of:
   - `00-sni-watch.conf`;
   - `05-router-ip-push-source-allow.conf`;
   - `06-router-ip-push-fake-site-bridges.conf`;
   - `stream.conf`;
5. current listeners on 443/7443/8443/8444/9443/9444/9543/9544;
6. Router IP Push current IP and `last_seen`;
7. temporary hotfix script, backup directory and unit states;
8. current Fail2ban installation/service/jails;
9. current UFW rules and whether UFW is active;
10. any existing RIPH files/units;
11. legacy and RIPH stream audit log state/tails.

**STOP GATE 1:** do not install anything until the report is compared with the
known working Hexabyte state.

## Phase 2 — candidate generation without production mutation

Build temporary candidates and generate:

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

During migration the external `:443` server may explicitly write both:

- legacy `/var/log/nginx/stream-sni.log` using `sni_watch` so the existing legacy
  reject jail remains fed;
- new `/var/log/nginx/riph-stream-sni.log` using `riph_stream_sni`.

Internal bridge listeners must not enter the new RIPH audit log.

Validate Fail2ban regex against synthetic controlled log lines before live RIPH
jails are enabled. Validate `riph-fail2ban-ufw` with synthetic UFW status containing
both a manual deny and a project Fail2ban deny for the same IP; unban must select
only the exact `riph-f2b-<jail>` marked rule.

**STOP GATE 2:** candidate diff must contain no unexpected listener, upstream,
trusted source, package/service, SSH or unrelated configuration change.

## Phase 3 — pre-install safety snapshot

Immediately before the first controlled install:

- confirm SSH access still works from the current session;
- keep the current SSH session open;
- confirm the temporary Router-IP/Nginx hotfix path and timer are active;
- record current `nginx -t` as successful;
- save the exact Nginx stream files;
- save current Fail2ban related files/status;
- save `ufw status numbered`;
- save Router IP Push state;
- record enabled/active state of temporary hotfix and RIPH units.

The installer creates its own pre-install snapshot as an additional layer, including
all three Nginx runtime files that may later be changed by `riph-apply`.

No SSH policy is changed.

**STOP GATE 3:** rollback material must be readable before any apply.

## Phase 4 — controlled file install while hotfix remains owner

Use the explicit controlled-test production gate only after Phases 1–3 pass.

Install project files **without applying RIPH and without changing ownership yet**.
The temporary hotfix continues protecting Router IP changes during this phase.

Review:

- `/etc/router-ip-push-hardening/config.env`;
- static trusted list;
- current Router IP Push address;
- both RIPH Fail2ban jails remain disabled;
- `riph-hotfix-handover status` reports temporary ownership;
- generated candidates via dry-run/status.

Do not use `--replace-config` unless replacement was explicitly intended and
reviewed.

## Phase 5 — atomic allowlist ownership handover + transactional Nginx apply

Because the temporary hotfix and RIPH both write the same allowlist, **do not run a
raw production `riph-apply` while the hotfix path/timer are active**.

The controlled production transition uses `riph-hotfix-handover takeover` (the
installer invokes it when production `--apply --enable-timers` sees the temporary
hotfix).

Required handover sequence:

1. acquire `/run/lock/router-ip-push-nginx-hotfix.lock`;
2. record temporary hotfix unit state;
3. disable/stop the temporary hotfix path/timer/service triggers;
4. run strict transactional `riph-reconcile`;
5. `nginx -t` and Nginx reload must succeed through `riph-apply`;
6. enable `riph-router-ip.path` and `riph-reconcile.timer`;
7. verify both RIPH units are active;
8. run a **second** reconcile after RIPH path/timer activation;
9. read Router IP Push again and verify every configured current Router IP is
   present in the generated allowlist;
10. leave temporary hotfix files on disk but disabled.

The second reconcile is mandatory because Router IP Push does not use the hotfix
lock: the ISP address can change in the middle of the ownership transition.

If any handover step fails, the temporary hotfix path/timer must be re-enabled.

**STOP GATE 4:** RIPH owns the allowlist, current AX3200 IP is trusted, Nginx is
healthy, RIPH path/timer are active, and temporary hotfix path/timer are disabled.

## Phase 6 — routing functional checks

Verify the non-destructive cases first:

- `nukla` reaches the public site;
- AX3200/current trusted source reaches `treda` Xray (`8443`);
- AX3200/current trusted source reaches `trongo` Xray (`8444`);
- normal user traffic remains functional.

For an untrusted-source camouflage test, use a source deliberately outside the
effective trusted set. Do not remove the current home/Router IP from trusted state
merely to force a test.

Expected untrusted results:

- `treda` -> fake treda site through bridge 9543;
- `trongo` -> fake trongo site through bridge 9544;
- unknown SNI -> reject.

Confirm `/var/log/nginx/riph-stream-sni.log` records only external `:443` sessions
and shows final routes `www`, `xray_N`, `fake_N`, or `reject`.

## Phase 7 — Fail2ban validation, activation and legacy handover

The packaged RIPH jails remain disabled until this phase.

Before activation:

- `fail2ban-client -t` succeeds;
- `fail2ban-regex` succeeds against controlled sample log;
- both RIPH actions are TCP/443 only;
- `riph-fail2ban-ignore` returns success for:
  - current AX3200 IP;
  - VPS_GR;
  - Spectra;
  - Hexabyte;
- it returns nonzero for a known untrusted test IP;
- `riph-fail2ban-ufw` only selects/removes exact project-marked rules.

Then:

1. activate the two `riph-*` jails;
2. confirm both are active and no trusted IP is banned;
3. run the trusted guard;
4. quiesce legacy SNI logging only after the new jails are proven healthy;
5. allow existing legacy bans to expire naturally under the old 6-hour policy;
6. retire the legacy jail only when its ban list is empty.

Do not manually migrate/remove legacy unmarked UFW bans merely to make the handover
faster. Do not deliberately trigger a live ban from the current home IP.

## Phase 8 — manual deny validation / later legacy manual-deny adoption

Use a harmless documentation/test IP outside all trusted ranges to validate:

- add 443-only deny;
- repeated apply is idempotent;
- remove 443-only deny;
- trusted-overlap addition is rejected before UFW mutation.

Existing legacy manual UFW deny rules are preserved until an explicit adoption
step. Do not duplicate or delete them implicitly during first installation.

All-port deny remains a manual exceptional path.

## Phase 9 — Router IP watch / grace / guard end-to-end observation

RIPH path/timer are already active after Phase 5. Verify:

- `riph-router-ip.path` is active/waiting;
- `riph-reconcile.timer` is active with 1-minute fallback;
- there is no separate periodic guard timer;
- trusted guard runs inside reconcile.

A natural future ISP IP change is the end-to-end validation:

1. Router IP Push atomically replaces the current `.ipv4` address;
2. directory `PathChanged` triggers reconcile;
3. new IP becomes current trusted immediately;
4. old IP enters 4-hour grace;
5. trusted guard removes any project 443 ban affecting the new IP;
6. if the path event is missed, the 1-minute timer is the fallback;
7. after grace expires, reconcile removes the old IP.

Do not force an ISP reconnect solely for the test unless explicitly agreed.

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
Use a controlled non-connectivity-breaking routing/config change or isolated
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
- the exact 2026-08-17 Router-IP incident regression passes;
- hotfix -> RIPH ownership handover and its mid-handover IP-race regression pass;
- controlled Hexabyte routing matches the manually proven scheme;
- Fail2ban jails match only controlled final routes;
- trusted IPs cannot remain project-banned;
- automatic bans remain TCP/443-only;
- Fail2ban unban cannot remove project manual-deny ownership;
- Router IP Push remains reachable over SSH;
- path plus 1-minute fallback timer behave as designed;
- temporary hotfix path/timer are disabled after RIPH takes ownership;
- harvest shows clean routing categories;
- rollback has been validated;
- one final GitHub Actions run may be performed only with explicit approval.
