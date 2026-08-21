# Router IP Push Hardening (RIPH)

RIPH — приватный слой защиты и маршрутизации для Nginx Stream/Xray. Он разрешает приватные SNI только доверенным источникам, управляет собственными Nginx/Fail2ban/UFW state и может опционально получать текущие внешние IPv4 роутеров через Router IP Push.

**Router IP Push не является обязательной инфраструктурной зависимостью RIPH.** Zero-provider / zero-router — штатные состояния.

## Документация

- [Практическая инструкция на русском](docs/USER_GUIDE_RU.md)
- [Архитектура](docs/ARCHITECTURE.md)

## Основная модель

```text
optional Router IP Push provider ─┐
trusted-static.list ───────────────┼─> RIPH own state / trusted policy
no provider ───────────────────────┘              │
                                                  ▼
                                        apply / reconcile
                                                  │
                                  ┌───────────────┼───────────────┐
                                  ▼               ▼               ▼
                                Nginx          Fail2ban           UFW
```

Router IP Push adapter читает только provider output:

```text
/var/lib/router-ip-push/ips/<Router-ID>.ipv4
```

и атомарно материализует его в собственное состояние RIPH:

```text
/var/lib/router-ip-push-hardening/providers/router-ip-push.json
```

Core RIPH читает **только canonical state RIPH** и не зависит от:

- `/etc/router-ip-push/routers.d/*.json`;
- пользователя `routerip`;
- `authorized_keys` Router IP Push;
- receiver/revoke scripts;
- `state/<Router-ID>.json` heartbeat;
- факта существования или активности Router IP Push как сервиса.

## Что умеет RIPH

- работает при полном отсутствии Router IP Push;
- поддерживает одновременно несколько dynamic Router ID;
- принимает появление/исчезновение конкретного Router ID как обычное изменение provider state;
- после revoke удаляет dynamic trust только для исчезнувшего Router ID;
- при revoke последнего router корректно переходит в zero-router state;
- при обычной смене IPv4 A→B сохраняет A на ограниченный previous-IP grace;
- **не создаёт grace при revoke/provider disappearance**;
- поддерживает static trusted IPv4/CIDR;
- генерирует Nginx allowlist и SNI routing;
- отправляет trusted private SNI в Xray, untrusted private SNI — на fake HTTPS через PROXY-protocol bridge;
- отклоняет unknown/empty/IP-SNI;
- ведёт route-aware stream log;
- использует отдельные Fail2ban jail для reject/private-SNI abuse;
- защищает effective trusted IP от собственных Fail2ban/manual-deny правил;
- поддерживает manual deny TCP/443 и отдельный explicit all-ports deny;
- применяет изменения транзакционно: backup → validation → atomic install → reload;
- поддерживает rollback с safety snapshot;
- имеет CLI `riph-admin`.

## Provider state

Canonical Router IP Push snapshot имеет состояния:

- `available` — source directory существует; все найденные записи валидны;
- `degraded` — часть `.ipv4` невалидна; плохие Router ID не trusted, валидные сохраняются;
- `absent` — source directory отсутствует; dynamic routers = 0.

Пустой существующий `ips/` означает `available` + `routers={}`.

RIPH не использует heartbeat TTL. Если Router IP Push service временно остановлен, но его authoritative `.ipv4` файлы остаются, текущий dynamic trust сохраняется. Если `.ipv4` конкретного Router ID удалён revoke-операцией, этот Router ID исчезает из dynamic trust после provider sync/reconcile.

## Effective trusted set

RIPH собирает effective trusted set из:

1. `/etc/router-ip-push-hardening/trusted-static.list`;
2. current Router ID/IP из RIPH canonical provider state;
3. ещё не истёкших previous-IP grace записей для обычной смены IP.

`ROUTER_IDS` в `config.env` оставлен только как необязательный compatibility filter. Пустое значение означает принимать все валидные Router ID из canonical provider state.

## Маршрутизация

```text
public SNI
    -> public upstream

private SNI + trusted source
    -> Xray upstream

private SNI + untrusted source
    -> PROXY-protocol bridge
    -> fake HTTPS upstream

unknown / empty / IP-SNI
    -> reject upstream
```

Bridge обязателен: внешний stream listener передаёт PROXY protocol, а обычный fake HTTPS upstream ожидает чистый TLS.

## Установка

RIPH можно установить как с Router IP Push, так и без него.

Типичный стек:

```text
3x-ui-installer
    -> рабочий Nginx stream.conf + fake HTTPS upstream

Router IP Push (optional)
    -> текущие ips/*.ipv4, если provider используется

RIPH
    -> bootstrap routing из существующего stream.conf
    -> materialize optional provider into RIPH state
    -> transactional apply
```

Read-only preflight:

```bash
sudo ./install.sh --check
```

Production install/update:

```bash
sudo env RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

Installer перед первым `riph-apply` синхронизирует optional Router IP Push provider в canonical state. Если provider отсутствует, создаётся нормальный `absent` snapshot и apply работает со static/no-dynamic trusted set.

`--replace-config` не используется при обычном обновлении существующей установки.

## Systemd

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

`riph-router-ip.path` исторически сохранил имя, но больше не запускает core reconcile напрямую от чужого filesystem: сначала работает provider adapter, затем при изменении canonical state запускается reconcile.

Старый `router-ip-push-nginx-hotfix.*` — transitional pre-RIPH writer. Он не является современным provider layer; controlled ownership transfer остаётся в `riph-hotfix-handover`.

## Static trusted

Добавить:

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "admin VPS"
```

Удалить:

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

## Основные команды

```bash
sudo riph-admin
sudo riph-admin status
sudo riph-admin reconcile
sudo riph-admin guard
sudo riph-admin fail2ban-status
sudo riph-admin ufw-status
sudo riph-admin harvest
sudo riph-admin backups
```

`riph-admin status` показывает provider status и Router ID/current-IP из **RIPH canonical state**, а не heartbeat/runtime Router IP Push.

## Безопасность

RIPH намеренно не управляет:

- Xray client definitions и базой 3x-ui;
- SSH policy;
- ZeroTier;
- Router IP Push registrations/keys/users/receiver/revoker;
- приложениями за прокси.

Автоматические Fail2ban-баны RIPH ограничены TCP/443. All-ports deny существует только как отдельное явное действие администратора.

Сгенерированные Nginx-файлы нельзя редактировать вручную: source of truth — RIPH config/list/canonical state.

## Проверка исходников

```bash
bash tests/run-local.sh
```

Suite выполняет Bash syntax check, ShellCheck (если установлен) и все `tests/test-*.sh`.

GitHub Actions остаётся **только ручным** (`workflow_dispatch`).
