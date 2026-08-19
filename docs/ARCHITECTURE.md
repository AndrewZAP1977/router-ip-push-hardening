# RIPH architecture

Этот документ описывает действующую архитектуру Router IP Push Hardening без привязки к конкретному серверу, провайдеру или набору доменов.

## 1. Назначение

RIPH располагается поверх уже существующей схемы Nginx Stream/Xray и решает две задачи:

1. поддерживает актуальный набор доверенных source IPv4;
2. маршрутизирует TLS по SNI и признаку trusted/untrusted source.

Router IP Push остаётся отдельным компонентом и отвечает только за безопасную доставку текущего внешнего IP роутера. RIPH читает его состояние и применяет policy.

## 2. Источники trusted state

Effective trusted set строится из:

- `trusted-static.list` — постоянные IPv4/CIDR;
- явно заданных `ROUTER_IDS`, если они используются;
- автоматически обнаруженных валидно зарегистрированных Router IP Push роутеров;
- предыдущих динамических IP, пока для них действует grace.

### 2.1. Auto-discovery

По умолчанию:

```text
ROUTER_AUTO_DISCOVER_REGISTERED=1
ROUTER_REGISTRY_DIR=/etc/router-ip-push/routers.d
```

Регистрация считается валидной только если JSON имеет ожидаемую версию, `router_id` совпадает с именем файла, а `public_key` имеет ожидаемый SSH Ed25519 формат.

Регистрация сама по себе ещё не делает адрес trusted. Роутер становится effective только после появления валидного текущего Router IP Push IPv4/state.

Файл `.ipv4` без регистрации не является достаточным основанием для доверия.

## 3. Previous-IP grace

После успешной смены динамического IP предыдущий адрес временно сохраняется в trusted set.

Цель — пережить гонки между сменой WAN IP, уже открытыми соединениями и обновлением внешних клиентов.

Продолжительность задаётся:

```text
PREVIOUS_IP_GRACE_HOURS
```

По истечении grace старый адрес удаляется очередным reconcile.

## 4. Nginx routing

RIPH генерирует три логических части:

- source allowlist (`geo`);
- основной stream routing;
- PROXY-protocol bridge для untrusted private-SNI маршрутов.

Общая схема:

```text
                     +----------------------+
TLS :443 ----------> | Nginx Stream         |
                     +----------+-----------+
                                |
                 SNI + source trusted?
                                |
          +---------------------+---------------------+
          |                     |                     |
      public SNI          private SNI           unknown/empty/IP-SNI
          |                     |                     |
          v              +------+-------+             v
 public upstream         | trusted?     |       reject upstream
                         +------+-------+
                                |
                     +----------+----------+
                     |                     |
                    yes                   no
                     |                     |
                     v                     v
               Xray upstream        PROXY bridge
                                          |
                                          v
                                   fake HTTPS upstream
```

### Почему нужен bridge

Внешний stream listener передаёт PROXY protocol, чтобы downstream мог видеть реальный source IP. Обычный fake HTTPS upstream при этом может ожидать чистый TLS. Bridge принимает соединение с PROXY protocol и создаёт обычное TLS-соединение к fake upstream.

## 5. Generated files и source of truth

Типовые generated files:

```text
/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf
/etc/nginx/stream-enabled/stream.conf
/etc/nginx/stream-enabled/06-router-ip-push-fake-site-bridges.conf
```

Их нельзя использовать как ручной источник конфигурации. Они генерируются из:

```text
/etc/router-ip-push-hardening/config.env
/etc/router-ip-push-hardening/trusted-static.list
/etc/router-ip-push-hardening/previous-ip-grace.json
/var/lib/router-ip-push/...
```

## 6. Transactional apply

`riph-apply` выполняет изменение как транзакцию:

```text
lock
 -> read/validate inputs
 -> generate candidate files
 -> backup current state
 -> atomic install
 -> nginx -t
 -> rollback on validation failure
 -> reload only if state actually changed
 -> write last-apply-state
```

Одновременные writers блокируются через `flock`.

Если generated state не изменился, Nginx не перезагружается без необходимости.

## 7. Reconcile

`riph-reconcile` сводит фактическое состояние к желаемому.

Он:

- читает текущие Router IP Push адреса;
- вызывает apply;
- проверяет, что после apply текущие адреса действительно присутствуют в active allowlist/state;
- повторяет попытку ограниченное число раз, если IP успел измениться во время операции;
- запускает trusted-unban guard после сходимости.

Это защищает от гонки вида «IP изменился между чтением и применением».

## 8. systemd watch + fallback

Основной быстрый путь:

```text
/var/lib/router-ip-push/ips changes
 -> riph-router-ip.path
 -> riph-reconcile.service
```

Резервный путь:

```text
riph-reconcile.timer
 -> reconcile примерно раз в минуту
```

Timer нужен как страховка от пропущенного path event и для истечения previous-IP grace.

## 9. Fail2ban

RIPH использует два собственных jail:

```text
riph-nginx-stream-sni-reject
riph-nginx-stream-private-sni-abuse
```

Первый реагирует на reject route, второй — на повторные обращения untrusted source к private SNI.

Автоматические action ограничены TCP/443.

### Dynamic ignore

`riph-fail2ban-ignore` проверяет, является ли IP trusted. Для отказоустойчивости он имеет fast paths для текущих Router IP Push адресов и last-known-good allowlist, поэтому кратковременная проблема основного config не должна превращать актуальный trusted IP в бан.

## 10. Trusted-unban guard

Guard выполняется после reconcile и может запускаться вручную.

Он защищает effective trusted set от:

- RIPH Fail2ban bans;
- конфликтующих project-owned manual deny rules.

Если IP становится trusted после того, как ранее был заблокирован RIPH, guard снимает соответствующий RIPH ban.

## 11. Manual deny

Есть два управляемых списка:

```text
manual-deny-443.list
manual-deny-all.list
```

TCP/443 deny — нормальный вариант для постоянной блокировки scanner source.

All-ports deny — исключительный режим, потому что способен затронуть management traffic.

Перед применением выполняется CIDR overlap check с effective trusted set. RIPH также проверяет, что applied-state соответствует реально существующим UFW rules с проектными marker.

## 12. Audit log и harvest

Внешний `:443` пишет route-aware журнал:

```text
/var/log/nginx/riph-stream-sni.log
```

Запись содержит source, SNI, выбранный route/upstream и результат сессии. Этот журнал используется Fail2ban и `riph-harvest`.

Harvest умеет работать от checkpoint, чтобы анализировать только новые записи.

## 13. Rollback

`riph-rollback` умеет:

- показать backups;
- восстановить выбранный backup или `latest`;
- сделать pre-rollback safety snapshot;
- проверить восстановленную Nginx-конфигурацию;
- вернуть исходное состояние, если восстановленный backup не проходит validation.

Rollback не должен превращать ошибочный старый snapshot в новое рабочее состояние без проверки.

## 14. Installer

`install.sh` разделяет:

- project files — обновляются;
- config/list files — seed only и сохраняются при обычном reinstall;
- runtime generated files — входят в install transaction snapshot.

Production mutation требует явного:

```bash
RIPH_ALLOW_PRODUCTION=1
```

`--replace-config` предназначен только для осознанной замены пользовательских config/list файлов и не используется при обычном обновлении.

## 15. Safety boundary

RIPH не должен управлять:

- базой/клиентами Xray или 3x-ui;
- SSH policy;
- VPN/overlay-сетями;
- приложениями за reverse proxy.

Эта граница намеренная: RIPH владеет только source trust, stream routing, собственными Fail2ban/UFW правилами и своим runtime state.

## 16. Тестирование

`tests/run-local.sh` выполняет:

1. `bash -n`;
2. ShellCheck, если он установлен;
3. все regression tests `tests/test-*.sh` в изолированных `/tmp` test roots.

Тесты покрывают apply/rollback, смену Router IP, bounded convergence, auto-discovery, Fail2ban, UFW ownership, guard, installer и systemd watch/timer.
