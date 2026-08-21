# RIPH: практическая инструкция

## RIPH за 30 секунд

RIPH держит effective trusted source set и по нему маршрутизирует TLS по SNI.

```text
Router IP Push (optional)
    -> current Router-ID / IPv4
    -> RIPH adapter
    -> RIPH canonical provider state

Static trusted
    -> trusted-static.list

RIPH policy
    -> Nginx allowlist/routing
    -> Fail2ban trusted protection
    -> manual deny/UFW
```

Router IP Push **не обязателен**. RIPH штатно работает при полном отсутствии provider, zero routers, revoke одного или последнего Router ID и повторном появлении provider.

## 1. Перед установкой

Обязательны работающий Nginx Stream/Xray layout, include `/etc/nginx/stream-enabled/*.conf`, UFW, Fail2ban, `jq`, `flock`, `sha256sum` и стандартные shell tools.

Router IP Push — optional. Если он установлен и уже имеет:

```text
/var/lib/router-ip-push/ips/<Router-ID>.ipv4
```

installer перед первым apply materialize эти IP в собственный state RIPH. Если Router IP Push отсутствует, install/apply всё равно должны работать.

## 2. Первый bootstrap routing

Если ещё нет `/etc/router-ip-push-hardening/config.env`, installer читает существующий `/etc/nginx/stream-enabled/stream.conf` и перенимает standard 3x-ui-installer routing:

```text
public SNI      -> www
Reality SNI     -> xray
XHTTP SNI       -> xray2   # если используется
```

Также сверяются fake HTTPS configs `reality.conf` и `xhttp.conf`. Неизвестный/неполный/неоднозначный layout останавливает bootstrap до production mutation.

## 3. Read-only preflight

```bash
sudo ./install.sh --check
```

Preflight **не требует Router IP Push** и не изменяет production state.

## 4. Production install/update

```bash
sudo env RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

Порядок внутри installer:

```text
backup install targets/generated state
 -> install project files
 -> provider sync into RIPH canonical state
 -> riph-apply
 -> guard
 -> enable provider/core timers if requested
```

Canonical provider state входит в install transaction и откатывается вместе с остальными RIPH files при ошибке.

При обычном update **не добавляй `--replace-config`**.

## 5. Canonical provider state

RIPH-owned Router IP Push snapshot:

```text
/var/lib/router-ip-push-hardening/providers/router-ip-push.json
```

Status:

```text
available   provider directory есть, entries валидны
degraded    часть .ipv4 невалидна; плохие entries не trusted
absent      provider directory отсутствует; routers={}
```

Пустая существующая `ips/` directory означает `available` + zero routers.

Core RIPH не читает и не требует:

```text
/etc/router-ip-push/routers.d/*.json
/var/lib/router-ip-push/state/*.json
authorized_keys
routerip user/group
receiver/revoker
Router IP Push service state
```

Проверка:

```bash
sudo riph-admin status
```

Status показывает RIPH canonical provider state, а не Router IP Push heartbeat/`last_seen`.

## 6. Dynamic Router ID lifecycle

### Новый Router ID

После появления валидного `/var/lib/router-ip-push/ips/ROUTER_A.ipv4` provider adapter обновляет canonical snapshot и запускает reconcile.

### Обычная смена WAN IPv4

```text
ROUTER_A: A -> B
```

B становится current. A остаётся trusted только на `PREVIOUS_IP_GRACE_HOURS`, если grace включён.

### Revoke Router ID

После удаления соответствующего `.ipv4`:

```text
ROUTER_A исчезает из canonical state
 -> current trust ROUTER_A исчезает
 -> previous grace ROUTER_A удаляется
```

Другие Router ID не затрагиваются.

### Revoke последнего Router ID

`routers={}` — нормальный RIPH state. Static trusted, routing, Fail2ban, manual deny, UFW и rollback продолжают работать.

### Provider полностью удалён

Если `/var/lib/router-ip-push/ips` отсутствует, adapter записывает `status=absent`, dynamic trusted = 0.

### Provider появился снова

Provider fallback timer повторно обнаружит provider; path watch ускоряет обычные изменения.

## 7. Static trusted

Добавить:

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "admin VPS"
```

Удалить:

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

Static trusted — явное административное решение.

## 8. Previous-IP grace

```text
PREVIOUS_IP_GRACE_HOURS=4
```

Grace создаётся только при обычной смене current IP одного и того же присутствующего Router ID:

```text
IP A -> B           => A может получить grace
Router ID revoked   => grace для него удаляется
provider absent     => dynamic routers отсутствуют
```

## 9. Systemd

Core:

```text
riph-reconcile.service
riph-reconcile.timer
riph-guard.service
```

Optional Router IP Push adapter:

```text
riph-router-ip.path
    -> riph-provider-router-ip-push.service

riph-provider-router-ip-push.timer
    -> fallback provider sync
```

Проверка:

```bash
sudo riph-admin timers
```

## 10. Основные команды

```bash
sudo riph-admin
sudo riph-admin status
sudo riph-admin apply
sudo riph-admin reconcile
sudo riph-admin guard
sudo riph-admin guard-log
sudo riph-admin timers
sudo riph-admin manual-deny-apply
sudo riph-admin fail2ban-status
sudo riph-admin fail2ban-unban 203.0.113.50
sudo riph-admin fail2ban-reload
sudo riph-admin ufw-status
sudo riph-admin harvest
sudo riph-admin harvest-checkpoint
sudo riph-admin recent-log 50
sudo riph-admin backups
```

## 11. Manual deny

TCP/443:

```bash
sudo riph-admin deny443-add 198.51.100.0/24 "scanner range"
sudo riph-admin deny443-remove 198.51.100.0/24
```

All ports:

```bash
sudo riph-admin denyall-add 198.51.100.25/32 "exceptional block"
sudo riph-admin denyall-remove 198.51.100.25/32
```

All-ports deny используй только в исключительных случаях. Перед apply RIPH проверяет overlap с effective trusted set.

## 12. Fail2ban

RIPH jails:

```text
riph-nginx-stream-sni-reject
riph-nginx-stream-private-sni-abuse
```

Автоматические bans ограничены TCP/443.

`riph-fail2ban-ignore` не читает raw Router IP Push runtime. Fast paths:

1. RIPH canonical provider state;
2. active generated RIPH allowlist.

Fail2ban activation допускает zero-provider/zero-router state. Если dynamic routers есть, каждый current IP обязан уже находиться в active allowlist и быть защищён ignore helper.

## 13. Routing

```text
public SNI
    -> public upstream

private SNI + trusted
    -> Xray

private SNI + untrusted
    -> PROXY bridge
    -> fake HTTPS

unknown / empty / IP-SNI
    -> reject
```

Generated files:

```text
/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf
/etc/nginx/stream-enabled/stream.conf
/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf
```

Историческое имя allowlist файла не меняет ownership: файл принадлежит RIPH и не должен удаляться вместе с Router IP Push.

## 14. Rollback

```bash
sudo riph-admin backups
```

Rollback создаёт safety snapshot, восстанавливает выбранный state и проверяет Nginx. Это core RIPH операция и она должна работать без Router IP Push.

## 15. Старый `router-ip-push-nginx-hotfix.*`

Это transitional pre-RIPH allowlist writer, а не современный provider adapter.

`riph-hotfix-handover` делает controlled ownership transfer и сохраняет старые files для rollback/forensics.

Не путай его с `riph-legacy-handover`, который относится к старому stream-audit/Fail2ban coexistence.

## 16. Что RIPH не трогает

RIPH не управляет:

- Router IP Push registrations/keys/user/receiver/revoker;
- Xray client definitions / 3x-ui DB;
- SSH policy;
- ZeroTier/VPN/overlay;
- приложениями за reverse proxy.

## 17. Regression tests

```bash
bash tests/run-local.sh
```

Suite выполняет `bash -n`, ShellCheck если установлен и все `tests/test-*.sh`.

Provider lifecycle regression включает absent/zero/multiple routers, A→B + grace, revoke одного/последнего, disappearance/reappearance, malformed entry, Fail2ban ignore без raw-provider trust, install/rollback без provider и bounded canonical-state convergence.

GitHub Actions остаётся только ручным (`workflow_dispatch`).
