# Router IP Push Hardening

Private hardening supplement for an existing `3x-ui-installer` Nginx/Xray deployment.

The repository is intentionally separate from the public installer. It contains
private source-IP/SNI policy and must remain private.

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
- stable Nginx stream audit log on the external `:443` server only;
- transactional `riph-apply` with `flock`, backup, `nginx -t`, reload gating and rollback;
- Router IP change detection via `systemd.path`;
- 5-minute reconcile for grace expiry and trusted-unban protection;
- two Fail2ban jails:
  - reject: 3 attempts / 5 minutes / 8 hour ban;
  - private-SNI abuse: 3 attempts / 2 minutes / 12 hour ban;
- automatic Fail2ban bans scoped to TCP/443 only;
- dynamic Fail2ban `ignorecommand` with emergency Router-IP/last-known-good fast paths;
- Fail2ban UFW helper that owns rules by exact `riph-f2b-<jail>` marker;
- trusted-unban guard for project Fail2ban bans and project-owned manual UFW rules;
- manual deny 443 and explicit manual deny all-ports lists;
- one shared UFW mutation lock across Fail2ban and manual-deny writers;
- CIDR overlap protection against banning a trusted source;
- stream-log harvest/checkpoint statistics;
- interactive and command-mode `riph-admin`;
- runtime rollback with a pre-rollback safety snapshot;
- installer with preflight, project-file backup, Nginx runtime snapshot and automatic restore on installation failure;
- deterministic `/tmp` test-root support;
- read-only Hexabyte preflight report and gated controlled validation plan.

## Safety boundary

v1 must not modify:

- 3x-ui clients or database;
- Xray client definitions;
- ZeroTier;
- Nextcloud;
- OnlyOffice;
- ztncui;
- SSH policy.

Automatic bans never block all ports. The automatic Fail2ban action affects only
TCP/443 so Router IP Push over SSH can still report a changed home address.

## Current state

The implementation is **pre-production**. It has not yet been installed by this
repository on Hexabyte. Real `/` installation remains blocked by a development
safety gate until the controlled VPS test is performed.

The next production step is **read-only preflight only**. See:

- `tools/preflight-report.sh`
- `docs/HEXABYTE_TEST_PLAN.md`

Do not bypass the production gate merely to make the installer run.

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
`test-fail2ban-regex.sh` skips locally when `fail2ban-regex` is unavailable.

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

See `docs/ARCHITECTURE.md` for the transaction model and safety invariants.
