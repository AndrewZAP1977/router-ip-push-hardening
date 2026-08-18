# РИФ — практическая инструкция

> **РИФ = Router IP Push Hardening (RIPH).**  
> Эта страница — не описание внутренностей проекта, а инструкция для обычного использования.

## РИФ за 30 секунд

РИФ стоит на VPS между внешним интернетом и приватными Xray/SNI-маршрутами.

Главная идея:

```text
Router IP Push сообщает текущий внешний IP роутера
                    ↓
РИФ считает этот IP доверенным
                    ↓
приватный SNI с доверенного IP → Xray
приватный SNI с чужого IP       → fake/reject
                    ↓
Fail2ban может временно заблокировать сканеры только на TCP/443
```

Если внешний IP настроенного роутера изменился, Router IP Push обновляет его на VPS, а РИФ автоматически перестраивает allowlist. Предыдущий IP по умолчанию остаётся доверенным ещё 4 часа — это страховка от гонок и задержек.

**Важно:** Router IP Push и РИФ — два отдельных проекта. Сам факт регистрации нового роутера в Router IP Push ещё не делает его доверенным в РИФ. Его `router_id` должен быть один раз добавлен в `ROUTER_IDS` в `/etc/router-ip-push-hardening/config.env`. После этого его IP уже меняется полностью автоматически.

---

## Что РИФ делает сам

В нормальной работе ничего нажимать не нужно:

- следит за изменениями `/var/lib/router-ip-push/ips/`;
- запускает reconcile при изменении Router IP Push;
- раз в минуту делает страховочный reconcile;
- обновляет Nginx allowlist;
- проверяет `nginx -t` перед принятием конфигурации;
- хранит предыдущий IP в grace-периоде;
- следит, чтобы доверенный IP не оказался под RIPH Fail2ban/manual deny;
- ведёт отдельный журнал `/var/log/nginx/riph-stream-sni.log`;
- применяет только свои UFW-правила и проверяет их ownership.

---

## Быстрый старт управления

На VPS:

```bash
sudo riph-admin
```

Откроется текстовое меню. Ничего запоминать не надо.

Для одной команды без меню:

```bash
sudo riph-admin status
sudo riph-admin fail2ban-status
sudo riph-admin ufw-status
```

### Условные уровни опасности

- **Просмотр** — ничего не меняет.
- **Обычная операция** — меняет только данные РИФ и имеет проверки/rollback.
- **Осторожно** — может повлиять на доступ к VPS или вернуть старую конфигурацию.

---

# Пункты интерактивного меню

<details>
<summary><strong>1. Status — общий статус РИФ</strong> · Просмотр</summary>

Показывает почти всё важное одним экраном:

- текущий IP каждого настроенного Router IP Push роутера;
- effective trusted set;
- статические доверенные сети;
- previous-IP grace;
- состояние сгенерированных Nginx-файлов;
- manual deny списки;
- `nginx -t`;
- два RIPH Fail2ban jail;
- systemd path/timer.

**Когда применять:** это первая команда, если «что-то не работает» или просто хочется убедиться, что всё живо.

```bash
sudo riph-admin status
```

</details>

<details>
<summary><strong>2. Apply / regenerate trusted + routing</strong> · Обычная операция</summary>

Принудительно пересобирает доверенный allowlist и Nginx routing из текущих конфигов.

РИФ делает backup, проверяет новую конфигурацию через `nginx -t` и откатывается при ошибке.

**Обычно не нужен:** автоматический reconcile делает это сам.

Пример: вручную изменили конфигурационный файл и хотим применить именно Nginx/trusted state.

```bash
sudo riph-admin apply
```

</details>

<details>
<summary><strong>3. Reconcile — привести всё к актуальному состоянию</strong> · Обычная операция</summary>

Предпочтительная ручная команда после изменений Router IP Push или trusted-конфигурации.

Reconcile:

1. перечитывает текущий Router IP Push;
2. применяет allowlist/routing;
3. проверяет, не изменился ли IP прямо во время операции;
4. при необходимости повторяет convergence;
5. запускает trusted-unban guard.

```bash
sudo riph-admin reconcile
```

Если сомневаешься между **Apply** и **Reconcile**, обычно выбирай **Reconcile**.

</details>

<details>
<summary><strong>4. Run trusted-unban guard</strong> · Обычная операция</summary>

Проверяет, что доверенные адреса не заблокированы правилами, которыми владеет РИФ.

Guard может:

- снять RIPH Fail2ban ban с доверенного IP;
- обнаружить конфликт manual deny с trusted set;
- синхронизировать project-owned защиту.

```bash
sudo riph-admin guard
```

Обычно guard запускается автоматически внутри reconcile.

</details>

<details>
<summary><strong>5. Guard log</strong> · Просмотр</summary>

Показывает последние записи журнала trusted-unban guard.

Полезно, если guard что-то разбанивал или сообщал о конфликте.

```bash
sudo riph-admin guard-log
```

</details>

<details>
<summary><strong>6. Timers / Router-IP watch</strong> · Просмотр</summary>

Показывает два главных автомата:

- `riph-router-ip.path` — реагирует на изменение Router IP Push;
- `riph-reconcile.timer` — страховочный запуск примерно раз в минуту.

В норме оба должны быть `enabled` и `active`.

```bash
sudo riph-admin timers
```

</details>

<details>
<summary><strong>7. Apply manual deny lists</strong> · Обычная операция</summary>

Синхронизирует файлы manual deny с реальными UFW-правилами РИФ.

Обычно не требуется: пункты **10–13** сами вызывают синхронизацию после изменения списка.

Используется скорее после ручного восстановления/редактирования конфигурации.

```bash
sudo riph-admin manual-deny-apply
```

</details>

<details>
<summary><strong>8. Add static trusted CIDR</strong> · Обычная операция</summary>

Добавляет **действительно постоянный** IP/CIDR в статический trusted list и запускает reconcile.

Пример:

```text
CIDR/IP: 203.0.113.10
Comment: office static IP
```

Командный вариант:

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "office static IP"
```

**Не использовать для динамического домашнего IP.** Для него нужен Router IP Push.

</details>

<details>
<summary><strong>9. Remove static trusted CIDR</strong> · Обычная операция</summary>

Удаляет адрес из статического trusted list и запускает reconcile.

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

Перед удалением убедись, что это не единственный способ доступа к приватному SNI с нужной сети.

</details>

<details>
<summary><strong>10. Add manual deny 443 CIDR</strong> · Обычная операция</summary>

Постоянно блокирует источник **только на TCP/443**.

SSH и остальные порты этим правилом не блокируются.

Пример:

```text
CIDR/IP: 203.0.113.55
Comment: repeated scanner
```

Или:

```bash
sudo riph-admin deny443-add 203.0.113.55/32 "repeated scanner"
```

РИФ откажется добавлять сеть, которая пересекается с effective trusted set.

</details>

<details>
<summary><strong>11. Remove manual deny 443 CIDR</strong> · Обычная операция</summary>

Удаляет project-owned постоянную блокировку TCP/443.

```bash
sudo riph-admin deny443-remove 203.0.113.55/32
```

Это не обязательно снимает отдельный активный Fail2ban ban того же IP — это другой механизм.

</details>

<details>
<summary><strong>12. Add manual deny ALL CIDR</strong> · ОСТОРОЖНО</summary>

Блокирует источник **на всех портах**.

Это исключительная операция. В отличие от deny443, она может отрезать SSH и служебный трафик.

```bash
sudo riph-admin denyall-add 203.0.113.55/32 "exceptional full block"
```

Если не уверен — используй **10. deny 443**, а не ALL.

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

Показывает состояние только двух jail, которыми занимается РИФ:

- `riph-nginx-stream-sni-reject`;
- `riph-nginx-stream-private-sni-abuse`.

Видны количество failed/banned и текущие заблокированные IP.

```bash
sudo riph-admin fail2ban-status
```

</details>

<details>
<summary><strong>15. RIPH Fail2ban unban IP</strong> · Обычная операция</summary>

Просит Fail2ban снять указанный IP с обоих RIPH jail.

```bash
sudo riph-admin fail2ban-unban 203.0.113.55
```

Это снимает **только Fail2ban ban**. Если IP одновременно есть в manual deny, постоянная manual-блокировка останется.

</details>

<details>
<summary><strong>16. Fail2ban validate + reload</strong> · Обычная операция</summary>

Сначала выполняет проверку конфигурации Fail2ban, затем `reload`, после чего запускает trusted guard.

```bash
sudo riph-admin fail2ban-reload
```

Это **reload, не restart**.

Обычно применять после осознанного изменения Fail2ban-конфигурации РИФ.

</details>

<details>
<summary><strong>17. UFW relevant status</strong> · Просмотр</summary>

Показывает связанные с 443/РИФ UFW-правила и project-owned manual-deny state.

```bash
sudo riph-admin ufw-status
```

Полезно, когда нужно понять: «это Fail2ban, manual deny или вообще не firewall?»

</details>

<details>
<summary><strong>18. Harvest since checkpoint</strong> · Просмотр</summary>

Делает короткую статистику по RIPH stream audit log после последнего checkpoint:

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

Для всего текущего лога, игнорируя checkpoint:

```bash
sudo riph-admin harvest --all
```

</details>

<details>
<summary><strong>19. Set harvest checkpoint</strong> · Обычная операция, безопасная</summary>

Запоминает текущую позицию в audit log. После этого пункт **18** покажет статистику только по новым событиям.

```bash
sudo riph-admin harvest-checkpoint
```

Пример применения: поставил checkpoint сегодня, через неделю смотришь статистику только за эту неделю.

</details>

<details>
<summary><strong>20. Recent RIPH stream log</strong> · Просмотр</summary>

Показывает последние строки `/var/log/nginx/riph-stream-sni.log`.

По умолчанию 50 строк; в меню можно указать другое число.

```bash
sudo riph-admin recent-log 100
```

Примеры `route`:

- `xray_1` / `xray_2` — доверенный private SNI попал в Xray;
- `fake_1` / `fake_2` — private SNI пришёл с недоверенного источника;
- `reject` — неизвестный/пустой/IP-SNI;
- `www` — публичный SNI.

</details>

<details>
<summary><strong>21. List backups</strong> · Просмотр</summary>

Показывает доступные RIPH apply-backup для rollback.

```bash
sudo riph-admin backups
```

Ничего не восстанавливает — только список.

</details>

<details>
<summary><strong>22. Rollback</strong> · ОСТОРОЖНО</summary>

Возвращает Nginx/trusted routing к выбранному backup.

В интерактивном меню сначала показывается список backup, затем нужно выбрать ID и отдельно напечатать:

```text
ROLLBACK
```

Без этого операция отменяется.

Командный вариант последнего backup:

```bash
sudo riph-admin rollback latest
```

РИФ делает **ещё один safety snapshot перед rollback**, проверяет восстановленную конфигурацию и пытается вернуть исходное состояние, если откат оказался невалидным.

Не использовать «просто попробовать».

</details>

---

# Динамический IP и Router IP Push

## Уже настроенный роутер

Для роутера, чей ID уже находится в `ROUTER_IDS`, всё автоматическое.

Например:

```text
ROUTER_IDS="AX3200"
```

Router IP Push обновил:

```text
/var/lib/router-ip-push/ips/AX3200.ipv4
```

После этого РИФ сам запускает reconcile и переносит новый IP в allowlist.

## Добавление второго роутера

Порядок безопаснее делать именно такой:

1. установить и зарегистрировать Router IP Push на новом роутере;
2. убедиться, что на VPS появился его файл `/var/lib/router-ip-push/ips/<router_id>.ipv4`;
3. один раз добавить `<router_id>` в `ROUTER_IDS`;
4. выполнить `sudo riph-admin reconcile`;
5. проверить `sudo riph-admin status`.

Например, если будущий router ID будет `MOTHER`:

```text
ROUTER_IDS="AX3200 MOTHER"
```

**Никакой внешний IP маминого роутера в `trusted-static.list` записывать не нужно.** После этой одноразовой привязки Router IP Push будет менять его автоматически.

---

# Статический trusted и динамический trusted — не одно и то же

`trusted-static.list` предназначен только для адресов, которые действительно должны оставаться постоянными.

Примеры подходящих статических записей:

```text
127.0.0.1/32         # localhost
5.61.39.137/32       # VPS_GR
45.87.41.121/32      # Spectra
194.104.94.182/32    # Hexabyte
```

Домашние/провайдерские динамические IP туда добавлять не следует — для них существует Router IP Push.

---

# Установка и обновление

## Перед установкой

РИФ не является универсальным «поставил на пустой VPS и готово». Он является дополнением к существующей схеме Nginx/Xray и Router IP Push.

Перед production install должны быть подготовлены:

- Nginx stream-конфигурация/порты, соответствующие `config.env`;
- Router IP Push server;
- текущий `.ipv4` хотя бы для обязательного ID из `ROUTER_IDS`;
- UFW и Fail2ban;
- проверенные значения `PUBLIC_SNI`, private SNI и upstream-портов.

## Проверка перед установкой

Из каталога репозитория:

```bash
sudo ./install.sh --check
```

Это preflight, он ничего не устанавливает.

## Production install

После проверки конфигурации:

```bash
sudo RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

Installer делает backup существующих project-файлов, устанавливает РИФ, применяет routing и включает Router-IP watch/timer. Fail2ban jail при первой установке намеренно не активируются этим шагом автоматически.

После установки:

```bash
sudo riph-admin status
```

## Обновление уже установленного РИФ

Получить актуальный `main`, затем снова запустить installer. Повторная установка сохраняет уже активированное состояние двух RIPH Fail2ban jail.

Минимальная схема:

```bash
git pull --ff-only origin main
sudo ./install.sh --check
sudo RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
sudo riph-admin status
```

На production-сервере не следует использовать `--replace-config`, если нет конкретной причины заменить свои рабочие списки/настройки репозиторными примерами.

---

# Где лежат основные данные

```text
/etc/router-ip-push-hardening/config.env
/etc/router-ip-push-hardening/trusted-static.list
/etc/router-ip-push-hardening/manual-deny-443.list
/etc/router-ip-push-hardening/manual-deny-all.list
/etc/router-ip-push-hardening/previous-ip-grace.json

/var/lib/router-ip-push/ips/<router_id>.ipv4
/var/lib/router-ip-push/state/<router_id>.json

/var/log/nginx/riph-stream-sni.log
```

Сгенерированные Nginx-файлы вручную не редактируются — ими владеет РИФ.

---

# Если что-то сломалось

Начинать диагностику в таком порядке:

```bash
sudo riph-admin status
sudo riph-admin timers
sudo riph-admin fail2ban-status
sudo riph-admin ufw-status
sudo riph-admin recent-log 100
```

Не начинать с `ufw reset`, удаления правил по номеру, ручного редактирования generated Nginx-файлов или rollback «наугад».

Если проблема связана с изменением внешнего IP роутера, отдельно проверить:

```bash
cat /var/lib/router-ip-push/ips/<router_id>.ipv4
sudo riph-admin status
```

Текущий Router IP Push IP должен присутствовать в effective trusted set для этого настроенного `router_id`.
