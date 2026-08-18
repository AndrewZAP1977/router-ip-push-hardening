# РИФ — практическая инструкция

> **РИФ = Router IP Push Hardening (RIPH).**  
> Это пользовательская инструкция. Внутренняя архитектура и история миграции лежат в других документах.

## РИФ за 30 секунд

РИФ стоит на VPS перед приватными Xray/SNI-маршрутами и решает две основные задачи:

```text
Router IP Push сообщает VPS текущий внешний IP роутера
                    ↓
РИФ автоматически считает IP зарегистрированного роутера доверенным
                    ↓
private SNI + trusted IP   → Xray
private SNI + чужой IP     → fake site
неизвестный/пустой SNI     → reject
                    ↓
Fail2ban может временно банить сканеры на TCP/443
```

Если провайдер поменял внешний IP роутера, Router IP Push обновляет его на VPS, а РИФ сам перестраивает allowlist. Предыдущий IP по умолчанию остаётся доверенным ещё 4 часа, чтобы смена адреса не оборвала рабочее соединение из-за гонки или задержки.

## Самое важное про несколько роутеров

**Дополнительного разрешения в РИФ после регистрации Router IP Push не требуется.**

Нормальная последовательность такая:

```text
1. Ставим Router IP Push на роутер.
2. Регистрируем/синхронизируем этот роутер с нужным VPS по инструкции Router IP Push.
3. Роутер делает первый update и VPS получает его текущий внешний IPv4.
4. РИФ видит валидную регистрацию Router IP Push и автоматически добавляет этот роутер в trusted allowlist.
5. Все дальнейшие смены IP обрабатываются автоматически.
```

Для второго, третьего, пятого роутера повторяются только пункты **1–3**. В конфиг РИФ вручную лезть не нужно.

РИФ не доверяет случайному файлу `*.ipv4`. Для автоматического добавления одновременно нужны:

- валидная регистрация `/etc/router-ip-push/routers.d/<router_id>.json`, созданная серверной регистрацией Router IP Push;
- первый успешный Router IP Push `update`, после которого появился текущий IPv4.

Поэтому регистрация Router IP Push на VPS является самим актом разрешения этому роутеру пользоваться приватными маршрутами РИФ.

---

## Что РИФ делает сам

В нормальной работе ничего нажимать не нужно. РИФ:

- отслеживает изменения `/var/lib/router-ip-push/ips/`;
- автоматически подхватывает зарегистрированные Router IP Push роутеры после первого update;
- запускает reconcile при изменении IP;
- дополнительно запускает страховочный reconcile примерно раз в минуту;
- создаёт trusted allowlist для Nginx;
- проверяет `nginx -t` до принятия новой конфигурации;
- хранит предыдущий IP в grace-периоде;
- не даёт RIPH Fail2ban/manual deny конфликтовать с trusted set;
- ведёт `/var/log/nginx/riph-stream-sni.log`;
- управляет только собственными UFW-правилами и проверяет их ownership;
- делает backup перед опасными изменениями, где это предусмотрено.

---

# Быстрое управление

Открыть интерактивное меню:

```bash
sudo riph-admin
```

Посмотреть общий статус без меню:

```bash
sudo riph-admin status
```

Посмотреть Fail2ban:

```bash
sudo riph-admin fail2ban-status
```

Посмотреть связанные UFW-правила:

```bash
sudo riph-admin ufw-status
```

### Уровни действий в этой инструкции

- **Просмотр** — ничего не меняет.
- **Обычная операция** — штатное изменение через проверки РИФ.
- **ОСТОРОЖНО** — действие может заметно повлиять на доступ или восстановить старое состояние.

---

# Все пункты интерактивного меню

<details>
<summary><strong>1. Status — общий статус РИФ</strong> · Просмотр</summary>

Показывает одним экраном:

- текущие IP всех роутеров, которые сейчас учитывает РИФ;
- effective trusted set;
- статические trusted CIDR;
- previous-IP grace;
- последние применённые данные;
- сгенерированные Nginx-файлы;
- manual deny списки;
- `nginx -t`;
- RIPH Fail2ban jails;
- path/timer.

**Это первая команда при любой непонятной ситуации.**

```bash
sudo riph-admin status
```

Пример применения: после установки нового Router IP Push роутера открыть Status и убедиться, что появился его `router_id` и текущий IP.

</details>

<details>
<summary><strong>2. Apply / regenerate trusted + routing</strong> · Обычная операция</summary>

Принудительно пересобирает trusted allowlist и Nginx routing из текущего состояния.

РИФ делает backup, строит новые файлы, проверяет их через `nginx -t` и не оставляет невалидную конфигурацию.

```bash
sudo riph-admin apply
```

**Обычно не нужен:** автоматика делает это сама.

Если сомневаешься между Apply и Reconcile, чаще нужен пункт **3 — Reconcile**.

</details>

<details>
<summary><strong>3. Reconcile — привести РИФ к актуальному состоянию</strong> · Обычная операция</summary>

Это предпочтительная ручная команда после изменений Router IP Push или trusted-настроек.

Reconcile:

1. перечитывает Router IP Push;
2. заново определяет зарегистрированные активные роутеры;
3. применяет trusted/routing;
4. проверяет, не поменялся ли IP прямо во время операции;
5. при необходимости повторяет попытку;
6. запускает trusted-unban guard.

```bash
sudo riph-admin reconcile
```

Пример: новый роутер уже зарегистрирован и сделал первый push, но хочется не ждать path/timer — запускаем Reconcile вручную.

</details>

<details>
<summary><strong>4. Run trusted-unban guard</strong> · Обычная операция</summary>

Проверяет, что trusted-адреса не оказались заблокированы правилами РИФ.

Guard может:

- снять RIPH Fail2ban ban с trusted IP;
- обнаружить пересечение manual deny с trusted set;
- проверить ownership manual UFW rules.

```bash
sudo riph-admin guard
```

В обычной работе guard запускается внутри каждого reconcile.

</details>

<details>
<summary><strong>5. Guard log</strong> · Просмотр</summary>

Показывает последние записи trusted-unban guard.

```bash
sudo riph-admin guard-log
```

Полезно, если Status/журнал сообщил, что trusted IP пришлось разбанить или найден manual conflict.

</details>

<details>
<summary><strong>6. Timers / Router-IP watch</strong> · Просмотр</summary>

Показывает два автомата:

- `riph-router-ip.path` — реагирует на запись нового Router IP Push IP;
- `riph-reconcile.timer` — страховочный reconcile примерно раз в минуту.

В норме оба:

```text
enabled=enabled
active=active
```

Команда:

```bash
sudo riph-admin timers
```

</details>

<details>
<summary><strong>7. Apply manual deny lists</strong> · Обычная операция</summary>

Синхронизирует manual deny списки РИФ с его реальными UFW-правилами.

```bash
sudo riph-admin manual-deny-apply
```

Обычно вручную не нужен: пункты 10–13 после изменения списка вызывают синхронизацию сами.

</details>

<details>
<summary><strong>8. Add static trusted CIDR</strong> · Обычная операция</summary>

Добавляет **реально постоянный** IP или CIDR в static trusted list.

Пример:

```text
CIDR/IP: 203.0.113.10
Comment: office static IP
```

Командой:

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "office static IP"
```

**Не добавляй сюда динамический домашний/провайдерский IP.** Для роутеров с меняющимся адресом используется Router IP Push, и зарегистрированные роутеры РИФ подхватывает автоматически.

</details>

<details>
<summary><strong>9. Remove static trusted CIDR</strong> · Обычная операция</summary>

Удаляет адрес из static trusted list и запускает reconcile.

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

Используется, например, если постоянный офисный/VPS IP больше не должен иметь trusted-доступ.

</details>

<details>
<summary><strong>10. Add manual deny 443 CIDR</strong> · Обычная операция</summary>

Постоянно блокирует источник **только на TCP/443**.

SSH и остальные порты этим правилом не блокируются.

Пример через меню:

```text
CIDR/IP: 203.0.113.55
Comment: repeated scanner
```

Командой:

```bash
sudo riph-admin deny443-add 203.0.113.55/32 "repeated scanner"
```

РИФ не даст добавить CIDR, пересекающийся с effective trusted set.

</details>

<details>
<summary><strong>11. Remove manual deny 443 CIDR</strong> · Обычная операция</summary>

Удаляет постоянную project-owned блокировку TCP/443.

```bash
sudo riph-admin deny443-remove 203.0.113.55/32
```

Это не обязательно снимает отдельный Fail2ban ban того же IP — manual deny и Fail2ban являются разными механизмами.

</details>

<details>
<summary><strong>12. Add manual deny ALL CIDR</strong> · ОСТОРОЖНО</summary>

Блокирует источник **на всех портах**.

```bash
sudo riph-admin denyall-add 203.0.113.55/32 "exceptional full block"
```

Это может затронуть SSH и служебный трафик. Если нужен обычный постоянный бан сканера HTTPS, используй пункт **10**, а не ALL.

</details>

<details>
<summary><strong>13. Remove manual deny ALL CIDR</strong> · ОСТОРОЖНО</summary>

Удаляет project-owned all-port deny.

```bash
sudo riph-admin denyall-remove 203.0.113.55/32
```

</details>

<details>
<summary><strong>14. RIPH Fail2ban status</strong> · Просмотр</summary>

Показывает только два jail РИФ:

- `riph-nginx-stream-sni-reject`;
- `riph-nginx-stream-private-sni-abuse`.

Можно увидеть количество failed/banned и текущие заблокированные IP.

```bash
sudo riph-admin fail2ban-status
```

</details>

<details>
<summary><strong>15. RIPH Fail2ban unban IP</strong> · Обычная операция</summary>

Снимает указанный IPv4 с обоих RIPH Fail2ban jail.

```bash
sudo riph-admin fail2ban-unban 203.0.113.55
```

Снимается только Fail2ban ban. Если IP находится в manual deny, постоянная manual-блокировка останется.

</details>

<details>
<summary><strong>16. Fail2ban validate + reload</strong> · Обычная операция</summary>

Сначала проверяет конфигурацию Fail2ban, затем делает `reload`, после чего запускает trusted guard.

```bash
sudo riph-admin fail2ban-reload
```

Это **reload, не restart**.

Обычно команда нужна только после осознанного изменения Fail2ban-конфигурации.

</details>

<details>
<summary><strong>17. UFW relevant status</strong> · Просмотр</summary>

Показывает связанные с TCP/443/РИФ UFW-правила и applied-state manual deny.

```bash
sudo riph-admin ufw-status
```

Полезно для ответа на вопрос: «этот IP заблокирован Fail2ban, manual deny или причина вообще не в firewall?»

</details>

<details>
<summary><strong>18. Harvest since checkpoint</strong> · Просмотр</summary>

Строит короткую статистику из stream audit log:

- всего сессий;
- `reject`;
- `fake`;
- `xray`;
- `www`;
- top routes;
- top source IP;
- top SNI.

```bash
sudo riph-admin harvest
```

По всему текущему логу, игнорируя checkpoint:

```bash
sudo riph-admin harvest --all
```

</details>

<details>
<summary><strong>19. Set harvest checkpoint</strong> · Обычная безопасная операция</summary>

Запоминает текущую позицию в audit log. После этого пункт 18 показывает только новые события после checkpoint.

```bash
sudo riph-admin harvest-checkpoint
```

Пример: ставим checkpoint сегодня, через неделю получаем статистику только за прошедшую неделю.

</details>

<details>
<summary><strong>20. Recent RIPH stream log</strong> · Просмотр</summary>

Показывает последние строки `/var/log/nginx/riph-stream-sni.log`.

```bash
sudo riph-admin recent-log 100
```

Основные `route`:

- `xray_1` / `xray_2` — trusted private SNI ушёл в Xray;
- `fake_1` / `fake_2` — private SNI пришёл с untrusted IP;
- `reject` — неизвестный/пустой/IP-SNI;
- `www` — публичный SNI.

</details>

<details>
<summary><strong>21. List backups</strong> · Просмотр</summary>

Показывает доступные apply-backup для rollback.

```bash
sudo riph-admin backups
```

Ничего не восстанавливает — только выводит список.

</details>

<details>
<summary><strong>22. Rollback</strong> · ОСТОРОЖНО</summary>

Восстанавливает старый RIPH apply-backup.

Меню сначала показывает backup ID, затем просит выбрать ID или `latest`, а потом требует вручную написать:

```text
ROLLBACK
```

Только после этого начинается откат.

Командный пример:

```bash
sudo riph-admin rollback latest
```

**Без необходимости не применять.** Если рабочая система ведёт себя странно, сначала лучше сохранить вывод `riph-admin status` и разобраться в причине.

</details>

---

# Как добавить ещё один роутер

На новом роутере:

1. установить Router IP Push;
2. создать/получить его registration code;
3. зарегистрировать этот код на том же VPS серверной частью Router IP Push;
4. вставить выданный VPS endpoint в Router IP Push на роутере;
5. дождаться первого успешного `update`.

После первого update РИФ сам обнаружит регистрацию и текущий IP. Обычно `riph-router-ip.path` применит изменение сразу; страховочный timer всё равно проверит состояние примерно в течение минуты.

Проверить:

```bash
sudo riph-admin status
```

В выводе должен появиться новый `router_id` и его текущий IPv4.

**Никакого отдельного `trusted-add` и никакого редактирования `ROUTER_IDS` для такого роутера не требуется.**

---

# Первая установка РИФ

## Что должно быть заранее

РИФ является дополнением, а не заменой всей VPS-конфигурации. До установки должны быть готовы:

- базовая Nginx/Xray-схема;
- Router IP Push server;
- хотя бы один работающий Router IP Push роутер с текущим IPv4;
- UFW/Fail2ban/Nginx в ожидаемом для этой VPS состоянии.

## 1. Read-only проверка

Из каталога репозитория:

```bash
sudo ./install.sh --check
```

Это preflight без установки файлов.

## 2. Установка + trusted/Nginx + автоматика

```bash
sudo RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

Установщик делает backup проектных файлов и не активирует RIPH Fail2ban jails автоматически.

## 3. Проверка

```bash
sudo riph-admin status
sudo riph-admin timers
sudo nginx -t
```

## 4. Первая активация RIPH Fail2ban

Это отдельный контролируемый шаг:

```bash
sudo /usr/local/sbin/riph-fail2ban-activate --dry-run
sudo /usr/local/sbin/riph-fail2ban-activate
```

После:

```bash
sudo riph-admin fail2ban-status
```

На уже настроенном Hexabyte этот этап давно выполнен; повторять его без причины не нужно.

---

# Как обновить уже установленный РИФ

Обновление кода не должно затирать существующие пользовательские config/list файлы при обычном `--install`.

После получения проверенной новой версии:

```bash
sudo RIPH_ALLOW_PRODUCTION=1 ./install.sh --install
```

Затем:

```bash
sudo riph-admin reconcile
sudo riph-admin status
```

`--replace-config` при обычном обновлении **не использовать**, если нет специальной причины: эта опция намеренно заменяет config/list файлами из репозитория.

---

# Что где лежит

Основное:

```text
/etc/router-ip-push-hardening/config.env
/etc/router-ip-push-hardening/trusted-static.list
/etc/router-ip-push-hardening/manual-deny-443.list
/etc/router-ip-push-hardening/manual-deny-all.list
/etc/router-ip-push-hardening/previous-ip-grace.json
```

Router IP Push:

```text
/etc/router-ip-push/routers.d/<router_id>.json
/var/lib/router-ip-push/ips/<router_id>.ipv4
/var/lib/router-ip-push/state/<router_id>.json
```

Логи/состояние РИФ:

```text
/var/log/nginx/riph-stream-sni.log
/var/lib/router-ip-push-hardening/
```

Сгенерированный Nginx allowlist:

```text
/etc/nginx/stream-enabled/05-router-ip-push-source-allow.conf
```

**Сгенерированный allowlist руками не редактировать.** Следующий reconcile всё равно пересоберёт его из источников состояния.

---

# Если что-то перестало работать

Проверять лучше в таком порядке.

### 1. Общий статус

```bash
sudo riph-admin status
```

### 2. Автоматика Router IP Push

```bash
sudo riph-admin timers
```

### 3. Последние маршруты

```bash
sudo riph-admin recent-log 50
```

### 4. Fail2ban

```bash
sudo riph-admin fail2ban-status
```

### 5. UFW

```bash
sudo riph-admin ufw-status
```

### 6. Строгая проверка trusted-защиты

```bash
sudo riph-admin guard
```

### 7. Принудительная синхронизация

```bash
sudo riph-admin reconcile
```

Если после этого проблема остаётся, лучше сохранить вывод этих команд до ручного изменения Nginx/UFW/Fail2ban: по нему гораздо проще восстановить причину.

---

# Короткая памятка

```text
Посмотреть всё                 sudo riph-admin status
Открыть меню                   sudo riph-admin
Проверить автоматику           sudo riph-admin timers
Синхронизировать               sudo riph-admin reconcile
Fail2ban                       sudo riph-admin fail2ban-status
UFW                            sudo riph-admin ufw-status
Последние маршруты             sudo riph-admin recent-log 50
Статистика                     sudo riph-admin harvest
Постоянно заблокировать 443    sudo riph-admin deny443-add IP/32 "comment"
Разблокировать manual 443      sudo riph-admin deny443-remove IP/32
Разбанить Fail2ban             sudo riph-admin fail2ban-unban IP
Список backup                  sudo riph-admin backups
```

Для обычного пользователя главные пункты меню — **1, 6, 14, 17, 18, 20**. Всё остальное чаще нужно только при изменении конфигурации или диагностике.
