# RIPH: практическая инструкция

## РИФ за 30 секунд

RIPH (Router IP Push Hardening) держит список доверенных source IP и по нему решает, куда отправлять TLS-трафик по SNI.

```text
Router IP Push
    -> сообщает актуальный внешний IP роутера

RIPH
    -> считает этот IP trusted
    -> генерирует Nginx allowlist/routing
    -> защищает trusted IP от своих Fail2ban/manual-deny правил
```

Для роутера с динамическим IP нормальная схема такая:

```text
установить Router IP Push
 -> зарегистрировать роутер на VPS
 -> дождаться первого успешного push
 -> RIPH автоматически увидит регистрацию и текущий IP
```

Отдельно добавлять router ID в RIPH обычно не требуется.

Для VPS/узла с постоянным IPv4 используется **Static trusted**.

---

## 1. Перед первой установкой

Нужны:

- уже установленный и работающий 3x-ui/Xray/Nginx;
- уже работающий Router IP Push;
- минимум одна валидная Router IP Push регистрация с первым успешным push;
- Nginx со `stream` и include для `/etc/nginx/stream-enabled/*.conf`;
- UFW в активном состоянии;
- Fail2ban;
- `jq`, `flock`, `sha256sum`, стандартные shell tools.

### Что RIPH делает с существующим `stream.conf`

При **первой** установке, когда файла

```text
/etc/router-ip-push-hardening/config.env
```

ещё нет, installer не использует placeholder SNI из примера. Он читает уже работающий:

```text
/etc/nginx/stream-enabled/stream.conf
```

и автоматически перенимает штатную конфигурацию 3x-ui-installer:

```text
public SNI      -> www
Reality SNI     -> xray
XHTTP SNI       -> xray2    # если используется отдельный XHTTP SNI
```

Также проверяются соответствующие loopback upstream и fake HTTPS site:

```text
/etc/nginx/sites-available/reality.conf
/etc/nginx/sites-available/xhttp.conf    # если есть отдельный XHTTP SNI
```

После этого RIPH создаёт свой `config.env`, делает backup исходного `stream.conf` и уже из обнаруженных реальных значений генерирует защищённый routing.

Поддерживаются оба штатных варианта 3x-ui-installer:

```text
public + Reality
public + Reality + отдельный XHTTP SNI
```

Если исходный stream layout неизвестен, неполон или неоднозначен, bootstrap завершается ошибкой **до изменения production-файлов**.

Для обычной штатной первой установки вручную переносить SNI/порты в `config.env` не нужно. `config/config.env.example` остаётся reference/default-файлом для нестандартной ручной конфигурации.

---

## 2. Проверка перед установкой

Read-only preflight:

```bash
sudo ./install.sh --check
```

На первой установке эта команда также read-only проверяет, что существующий `stream.conf` можно безопасно перенять и что Router IP Push уже имеет валидную регистрацию/current IP.

Если preflight не проходит — production ничего не меняется.

---

## 3. Первая установка

Правильный порядок на новой VPS:

```text
3x-ui-installer
 -> Router IP Push registration + first push
 -> RIPH
```

Установка RIPH:

```bash
sudo env RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

Во время первой установки ожидается следующая последовательность:

```text
existing stream.conf
 -> parse/validate
 -> bootstrap production config.env
 -> install backup
 -> generate allowlist + RIPH stream.conf + bridge config
 -> nginx -t
 -> reload only after successful validation
```

После установки:

```bash
sudo riph-admin status
```

Нужно проверить:

- правильные router ID/current IP;
- правильный Effective trusted set;
- реальные public/private SNI сохранились;
- `nginx -t` = OK;
- оба RIPH timer/watch = enabled/active;
- корректный Fail2ban status.

Важно: повторный запуск базового 3x-ui-installer может заново создать его обычный `stream.conf`. Поэтому штатный порядок — сначала базовый installer, затем RIPH. После намеренного изменения базовой Nginx/Xray-схемы RIPH нужно повторно согласовать/применить.

---

## 4. Обновление существующей установки

Обычное обновление:

```bash
sudo env RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

**Не добавляй `--replace-config` при обычном обновлении.**

Installer обновит project files, но сохранит существующие рабочие config/list файлы. Авто-bootstrap из базового `stream.conf` выполняется только когда production `config.env` ещё отсутствует.

После обновления:

```bash
sudo riph-admin status
```

---

## 5. Динамические роутеры

По умолчанию RIPH автоматически обнаруживает зарегистрированные Router IP Push роутеры:

```text
ROUTER_AUTO_DISCOVER_REGISTERED=1
ROUTER_REGISTRY_DIR=/etc/router-ip-push/routers.d
```

Роутер становится effective только если одновременно есть:

1. валидная Router IP Push регистрация;
2. первый валидный текущий IPv4/state.

Просто положить `.ipv4` файл вручную недостаточно.

### Второй, третий и следующие роутеры

Нормальный порядок:

```text
Router IP Push install
 -> server registration
 -> first push
 -> RIPH auto-discovery
 -> IP появляется в Effective trusted set
```

После первого push проверь:

```bash
sudo riph-admin status
```

---

## 6. Static trusted

Для VPS или другого узла с постоянным IP:

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "admin VPS"
```

Проверка:

```bash
sudo riph-admin status
```

Удаление:

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

Не используй static trusted для обычного динамического домашнего WAN IP — этим должен заниматься Router IP Push.

---

## 7. Previous-IP grace

После смены динамического IP старый адрес некоторое время остаётся trusted.

По умолчанию:

```text
PREVIOUS_IP_GRACE_HOURS=4
```

Это уменьшает вероятность разрыва при смене WAN IP.

После истечения grace старый IP удалит reconcile.

---

## 8. `riph-admin`

Запуск интерактивного меню:

```bash
sudo riph-admin
```

Текущее меню:

```text
 1. Status
 2. Apply / regenerate trusted + routing
 3. Reconcile
 4. Run trusted-unban guard
 5. Guard log
 6. Timers / Router-IP watch
 7. Apply manual deny lists
 8. Add static trusted CIDR
 9. Remove static trusted CIDR
10. Add manual deny 443 CIDR
11. Remove manual deny 443 CIDR
12. Add manual deny ALL CIDR
13. Remove manual deny ALL CIDR
14. RIPH Fail2ban status
15. RIPH Fail2ban unban IP
16. Fail2ban validate + reload
17. UFW relevant status
18. Harvest since checkpoint
19. Set harvest checkpoint
20. Recent RIPH stream log
21. List backups
22. Rollback
 0. Exit
```

<details>
<summary><b>1. Status</b></summary>

Главный экран состояния.

Показывает:

- Router IP Push current/last_seen;
- effective trusted set;
- static trusted;
- previous-IP grace;
- last apply state;
- generated Nginx files и SHA256;
- manual deny lists;
- `nginx -t`;
- RIPH Fail2ban jail;
- timers/watch.

Команда:

```bash
sudo riph-admin status
```
</details>

<details>
<summary><b>2. Apply / regenerate trusted + routing</b></summary>

Принудительно пересобирает trusted/routing из текущих источников.

Обычно вручную не нужен: этим занимается reconcile.

```bash
sudo riph-admin apply
```
</details>

<details>
<summary><b>3. Reconcile</b></summary>

Полный штатный цикл синхронизации.

Проверяет Router IP Push, применяет изменения, убеждается в сходимости и запускает trusted guard.

```bash
sudo riph-admin reconcile
```
</details>

<details>
<summary><b>4. Run trusted-unban guard</b></summary>

Проверяет, что trusted source не остаётся заблокирован собственными RIPH Fail2ban/manual-deny правилами.

```bash
sudo riph-admin guard
```
</details>

<details>
<summary><b>5. Guard log</b></summary>

Показывает журнал последних запусков trusted-unban guard.
</details>

<details>
<summary><b>6. Timers / Router-IP watch</b></summary>

Показывает состояние:

- `riph-router-ip.path`;
- `riph-reconcile.timer`.

```bash
sudo riph-admin timers
```
</details>

<details>
<summary><b>7. Apply manual deny lists</b></summary>

Синхронизирует управляемые manual deny списки с UFW.

```bash
sudo riph-admin manual-deny-apply
```
</details>

<details>
<summary><b>8. Add static trusted CIDR</b></summary>

Добавляет постоянный trusted IPv4/CIDR и сразу выполняет безопасный reconcile.

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "admin VPS"
```
</details>

<details>
<summary><b>9. Remove static trusted CIDR</b></summary>

Удаляет static trusted entry и пересобирает effective state.

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```
</details>

<details>
<summary><b>10. Add manual deny 443 CIDR</b></summary>

Постоянно блокирует source только на TCP/443.

Это предпочтительный manual deny для scanner/abuse source.

```bash
sudo riph-admin deny443-add 198.51.100.0/24 "scanner range"
```
</details>

<details>
<summary><b>11. Remove manual deny 443 CIDR</b></summary>

Удаляет запись из управляемого TCP/443 deny list.

```bash
sudo riph-admin deny443-remove 198.51.100.0/24
```
</details>

<details>
<summary><b>12. Add manual deny ALL CIDR</b></summary>

Блокирует source на всех портах.

Использовать только в исключительных случаях: такой deny способен затронуть management traffic.

```bash
sudo riph-admin denyall-add 198.51.100.25/32 "exceptional block"
```
</details>

<details>
<summary><b>13. Remove manual deny ALL CIDR</b></summary>

Удаляет all-ports deny.

```bash
sudo riph-admin denyall-remove 198.51.100.25/32
```
</details>

<details>
<summary><b>14. RIPH Fail2ban status</b></summary>

Показывает только собственные RIPH jail.

```bash
sudo riph-admin fail2ban-status
```
</details>

<details>
<summary><b>15. RIPH Fail2ban unban IP</b></summary>

Снимает IP только из RIPH jail.

```bash
sudo riph-admin fail2ban-unban 203.0.113.50
```
</details>

<details>
<summary><b>16. Fail2ban validate + reload</b></summary>

Сначала выполняет validation, затем reload Fail2ban и trusted guard.

```bash
sudo riph-admin fail2ban-reload
```
</details>

<details>
<summary><b>17. UFW relevant status</b></summary>

Показывает UFW rules, имеющие отношение к RIPH.

```bash
sudo riph-admin ufw-status
```
</details>

<details>
<summary><b>18. Harvest since checkpoint</b></summary>

Анализирует новые записи route-aware stream log после последнего checkpoint.

```bash
sudo riph-admin harvest
```
</details>

<details>
<summary><b>19. Set harvest checkpoint</b></summary>

Запоминает текущую позицию в stream log как начало следующего анализа.

```bash
sudo riph-admin harvest-checkpoint
```
</details>

<details>
<summary><b>20. Recent RIPH stream log</b></summary>

Показывает последние строки route-aware stream log.

```bash
sudo riph-admin recent-log 50
```
</details>

<details>
<summary><b>21. List backups</b></summary>

Показывает доступные runtime backups.

```bash
sudo riph-admin backups
```
</details>

<details>
<summary><b>22. Rollback</b></summary>

Восстанавливает выбранный runtime backup.

Перед rollback создаётся safety snapshot, а восстановленная Nginx-конфигурация проходит validation.

```bash
sudo riph-admin rollback latest
```

Интерактивный rollback дополнительно требует явного подтверждения.
</details>

---

## 9. Manual deny: что выбирать

Обычно:

```text
scanner/abuse на HTTPS
 -> manual deny 443
```

Только если действительно нужно перекрыть source целиком:

```text
исключительный случай
 -> manual deny ALL
```

RIPH проверяет пересечение manual deny с trusted set и не должен позволять штатно заблокировать собственный trusted source.

---

## 10. Fail2ban

RIPH использует два jail:

```text
riph-nginx-stream-sni-reject
riph-nginx-stream-private-sni-abuse
```

По умолчанию автоматические баны ограничены TCP/443.

Если ранее untrusted IP позже становится trusted (например после Router IP Push регистрации/смены адреса), reconcile/guard должен снять соответствующий RIPH ban.

---

## 11. Где смотреть логи

Route-aware stream log:

```text
/var/log/nginx/riph-stream-sni.log
```

Быстро посмотреть:

```bash
sudo riph-admin recent-log 100
```

Статистика новых записей:

```bash
sudo riph-admin harvest
```

---

## 12. Если что-то не работает

Начинай с:

```bash
sudo riph-admin status
sudo nginx -t
sudo fail2ban-client -t
sudo riph-admin timers
```

Если **первая** установка останавливается на bootstrap `stream.conf`, не запускай `--replace-config` наугад. Сначала проверь исходный базовый routing:

```bash
sudo cat /etc/nginx/stream-enabled/stream.conf
sudo cat /etc/nginx/sites-available/reality.conf
sudo test ! -e /etc/nginx/sites-available/xhttp.conf || sudo cat /etc/nginx/sites-available/xhttp.conf
```

Bootstrap специально fail-closed: неизвестную схему он не должен молча превращать в другую.

Если Router IP Push уже обновил IP, но RIPH его не видит:

```bash
sudo riph-admin reconcile
sudo riph-admin status
```

Проверь также наличие регистрации:

```text
/etc/router-ip-push/routers.d/<router_id>.json
```

и текущего Router IP Push state:

```text
/var/lib/router-ip-push/ips/<router_id>.ipv4
/var/lib/router-ip-push/state/<router_id>.json
```

---

## 13. Важные файлы

```text
/etc/router-ip-push-hardening/config.env
/etc/router-ip-push-hardening/trusted-static.list
/etc/router-ip-push-hardening/previous-ip-grace.json
/etc/router-ip-push-hardening/manual-deny-443.list
/etc/router-ip-push-hardening/manual-deny-all.list

/var/lib/router-ip-push-hardening/
/var/log/nginx/riph-stream-sni.log
```

Generated Nginx files вручную не редактируются.

---

## 14. Локальная проверка исходников

```bash
bash tests/run-local.sh
```

Она запускает Bash syntax check, ShellCheck (если установлен) и regression tests.

GitHub Actions в проекте оставлен только для ручного запуска через `workflow_dispatch`.
