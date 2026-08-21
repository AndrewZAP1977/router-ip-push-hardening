# RIPH architecture

Этот документ описывает архитектуру Router IP Push Hardening без привязки к конкретному VPS, провайдеру или доменам.

## 1. Назначение и граница ответственности

RIPH располагается поверх существующей схемы Nginx Stream/Xray и отвечает за:

1. effective trusted source IPv4/CIDR;
2. SNI routing по признаку trusted/untrusted source;
3. собственные Fail2ban/UFW/manual-deny policy;
4. transactional apply/reconcile/rollback.

Router IP Push — **отдельный optional provider**. Он отвечает только за безопасную доставку текущего внешнего IPv4 роутера. Core RIPH не знает о его registrations, SSH keys, пользователе, receiver/revoker или heartbeat runtime.

```text
Router IP Push provider ─┐
trusted-static.list ──────┼─> RIPH own canonical/input state
no provider ──────────────┘                │
                                           ▼
                                  policy / reconcile
                                           │
                           ┌───────────────┼───────────────┐
                           ▼               ▼               ▼
                         Nginx          Fail2ban           UFW
```

Zero-provider и zero-router — штатные состояния.

## 2. Optional Router IP Push adapter

Provider contract:

```text
/var/lib/router-ip-push/ips/<Router-ID>.ipv4
```

Adapter:

```text
/usr/local/sbin/riph-provider-router-ip-push-sync
```

читает только `ips/*.ipv4`, валидирует Router ID/IPv4 и атомарно записывает RIPH-owned snapshot:

```text
/var/lib/router-ip-push-hardening/providers/router-ip-push.json
```

Пример:

```json
{
  "version": 1,
  "provider": "router-ip-push",
  "status": "available",
  "routers": {
    "ROUTER_A": {"current_ip": "192.0.2.10"},
    "ROUTER_B": {"current_ip": "192.0.2.20"}
  },
  "invalid_entries": 0
}
```

### Provider status

- `available` — source directory существует и все найденные `.ipv4` валидны;
- `degraded` — часть provider entries невалидна; плохие entries не trusted, хорошие сохраняются;
- `absent` — source directory отсутствует; `routers={}`.

Пустой существующий source directory — `available` + `routers={}`.

Canonical snapshot является единственным dynamic-provider input для core RIPH. Core не читает напрямую:

```text
/etc/router-ip-push/routers.d
/var/lib/router-ip-push/state
authorized_keys
routerip user/group
receiver/revoker
```

## 3. Provider lifecycle semantics

### Обычная смена IPv4

```text
ROUTER_A: A -> B
```

B становится current, A может попасть в `previous-ip-grace.json` на `PREVIOUS_IP_GRACE_HOURS`.

### Revoke/withdraw Router ID

Если provider перестал отдавать `ROUTER_A`, Router ID исчезает из canonical state. Его current trust и его grace удаляются. Это **не** обычная смена IP и новый grace не создаётся.

Если остаётся `ROUTER_B`, он не затрагивается.

### Revoke последнего Router ID

```text
routers={}
```

валиден. Apply/reconcile продолжают работать со static/no-dynamic trusted set.

### Provider disappearance

Если `/var/lib/router-ip-push/ips` отсутствует, adapter materializes `status=absent`, `routers={}`. RIPH core продолжает работать.

### Temporary provider service outage

RIPH не проверяет состояние Router IP Push service и не использует heartbeat TTL. Пока authoritative `.ipv4` остаются, они сохраняются в provider snapshot. Это сознательная policy текущей версии.

## 4. Effective trusted set

Effective trusted set строится из:

- `/etc/router-ip-push-hardening/trusted-static.list`;
- current dynamic routers из RIPH canonical provider state;
- ещё не истёкшего previous-IP grace для обычных IP transitions.

`ROUTER_IDS` — только optional compatibility filter canonical provider entries. Пустое значение принимает все валидные Router ID.

`REQUIRE_ROUTER_IP` сохранён как compatibility config key, но zero dynamic routers больше не является fatal state.

## 5. Previous-IP grace

Grace существует только для перехода current IP одного и того же присутствующего Router ID:

```text
A -> B
```

Он нужен для гонок между сменой WAN IP, открытыми соединениями и обновлением клиентов.

При provider withdraw/revoke grace соответствующего Router ID удаляется немедленно при apply.

## 6. Nginx routing

RIPH генерирует:

- source allowlist (`geo`);
- основной stream routing;
- PROXY-protocol bridges для untrusted private SNI.

```text
TLS :443
   |
   +-- public SNI --------------------------> public upstream
   |
   +-- private SNI + trusted --------------> Xray
   |
   +-- private SNI + untrusted ------------> PROXY bridge -> fake HTTPS
   |
   +-- unknown / empty / IP-SNI -----------> reject
```

Bridge нужен потому, что внешний stream listener передаёт PROXY protocol, а fake HTTPS upstream ожидает обычный TLS.

Исторические generated filenames сохраняются для совместимости:

```text
/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf
/etc/nginx/stream-enabled/stream.conf
/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf
```

Имя allowlist файла не означает ownership Router IP Push: файл управляется RIPH.

## 7. Source of truth

RIPH source/input state:

```text
/etc/router-ip-push-hardening/config.env
/etc/router-ip-push-hardening/trusted-static.list
/etc/router-ip-push-hardening/previous-ip-grace.json
/etc/router-ip-push-hardening/manual-deny-*.list
/var/lib/router-ip-push-hardening/providers/router-ip-push.json
```

Generated Nginx files не редактируются вручную.

`last-apply-state.json` — результат последнего успешного apply, а не provider input.

## 8. Transactional apply

`riph-apply`:

```text
lock
 -> load RIPH config + canonical provider state
 -> build effective trusted/current state
 -> update/expire/remove grace
 -> generate candidates
 -> backup current state
 -> atomic install
 -> nginx -t
 -> rollback on failure
 -> reload only if generated state changed
 -> write last-apply-state
```

Withdrawn Router ID отсутствует в effective current set, поэтому его old grace удаляется до allowlist generation.

## 9. Reconcile

`riph-reconcile` работает только с canonical RIPH state.

После apply он **перечитывает canonical provider state** и проверяет соответствие:

```text
canonical current routers
        == last successful apply routers
        == current IPs in active allowlist
```

Если provider snapshot изменился во время транзакции, reconcile немедленно повторяет apply. Число попыток ограничено.

Zero routers сходится штатно.

Trusted-unban guard запускается после успешной сходимости.

## 10. systemd

Core:

```text
riph-reconcile.service
riph-reconcile.timer
riph-guard.service
```

Optional Router IP Push integration:

```text
/var/lib/router-ip-push/ips changes
    -> riph-router-ip.path
    -> riph-provider-router-ip-push.service
    -> adapter updates RIPH canonical state
    -> riph-reconcile
```

Fallback provider sync:

```text
riph-provider-router-ip-push.timer
```

Core fallback:

```text
riph-reconcile.timer
```

Provider timer нужен, в частности, для disappearance/reappearance и пропущенных filesystem events. Core timer нужен для convergence/maintenance, включая expiry grace.

`riph-router-ip.path` сохранил историческое имя, но больше не запускает core reconcile напрямую от Pusher filesystem.

## 11. Fail2ban

RIPH jails:

```text
riph-nginx-stream-sni-reject
riph-nginx-stream-private-sni-abuse
```

Автоматические bans ограничены TCP/443.

### Trusted ignore

`riph-fail2ban-ignore` не читает raw Router IP Push runtime.

Fast paths:

1. current IP из RIPH canonical provider snapshot;
2. active generated RIPH allowlist как last-known-good applied artifact.

Затем выполняется обычная effective-trusted evaluation.

Fail2ban activation не требует наличия dynamic provider. Production readiness требует валидный RIPH Nginx state, core reconcile timer и корректную защиту **всех dynamic routers, если они есть**.

## 12. Trusted-unban guard

Guard защищает effective trusted set от:

- RIPH Fail2ban bans;
- project-owned manual deny conflicts;
- transitional legacy-shield conflicts во время старой Fail2ban coexistence.

Он использует тот же canonical/effective trusted input, что и Nginx policy.

## 13. Manual deny

Управляемые списки:

```text
manual-deny-443.list
manual-deny-all.list
```

Перед применением выполняется overlap check с effective trusted set. RIPH удаляет/изменяет только rules с собственным marker/ownership state.

All-ports deny — исключительный режим из-за риска management traffic.

## 14. Installer

`install.sh` разделяет:

- project files — replace/update;
- config/list files — seed only при обычной установке;
- runtime/generated/canonical provider state — install transaction snapshot.

Перед **первым requested apply** installer запускает provider sync `--no-reconcile`. Поэтому upgrade не создаёт промежуточный static-only allowlist, если Router IP Push уже содержит current IP.

Если provider отсутствует, sync успешно создаёт `absent` snapshot и install/apply продолжается.

Rollback install transaction восстанавливает/удаляет canonical provider snapshot вместе с остальным RIPH state.

## 15. Transitional Router IP Push Nginx hotfix

`router-ip-push-nginx-hotfix.*` — старый pre-RIPH writer allowlist. Он не является provider adapter.

`riph-hotfix-handover`:

1. останавливает old writer под его lock;
2. materializes provider state;
3. делает reconcile;
4. включает provider path;
5. повторяет provider sync + reconcile для закрытия transition race;
6. включает provider/core fallback timers;
7. сохраняет старые hotfix files для rollback/forensics.

Это отдельный mechanism от `riph-legacy-handover`, который относится к старому stream-audit/Fail2ban stack.

## 16. Rollback

`riph-rollback` является core RIPH функцией и не требует Router IP Push.

Он:

- показывает backups;
- делает safety snapshot;
- восстанавливает выбранный backup;
- проверяет Nginx;
- возвращает pre-rollback state, если restored state невалиден.

## 17. Safety boundary

RIPH не управляет:

- Router IP Push registrations/authorized_keys/user/receiver/revoker;
- Xray client definitions / 3x-ui DB;
- SSH policy;
- VPN/overlay networks;
- приложениями за reverse proxy.

RIPH владеет только своим trust/policy state, Nginx routing, собственными Fail2ban/UFW rules и runtime.

## 18. Regression expectations

`tests/run-local.sh` выполняет Bash syntax check, ShellCheck (если установлен) и `tests/test-*.sh`.

Обязательные provider lifecycle scenarios:

- provider absent;
- provider present, zero routers;
- one/two routers;
- ordinary IP A→B + grace;
- revoke one of two;
- revoke last;
- provider disappearance/reappearance;
- malformed entry with surviving valid routers;
- Fail2ban ignore without raw-provider trust;
- installer/rollback with no provider;
- bounded canonical-state convergence.
