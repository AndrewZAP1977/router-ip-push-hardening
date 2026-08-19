# Router IP Push Hardening (RIPH)

RIPH — приватный слой защиты и маршрутизации для Nginx Stream/Xray, который использует Router IP Push как источник актуальных внешних IP роутеров.

Главная задача проекта: **разрешать приватные SNI только доверенным источникам**, не ломая доступ при смене динамического IP и не смешивая эту логику с публичным установщиком Xray/3x-ui.

## Документация

- [Практическая инструкция на русском](docs/USER_GUIDE_RU.md) — установка, обновление, работа с `riph-admin`, добавление доверенных IP и роутеров.
- [Архитектура](docs/ARCHITECTURE.md) — устройство trusted set, маршрутизация, Fail2ban, reconcile и rollback.

## Что умеет RIPH

- автоматически получает текущие IPv4 зарегистрированных Router IP Push роутеров;
- автоматически обнаруживает новые зарегистрированные роутеры после их первого валидного push;
- при первой установке автоматически перенимает штатную Nginx Stream-маршрутизацию 3x-ui-installer;
- поддерживает статические доверенные IPv4/CIDR для VPS и других узлов с постоянным адресом;
- хранит предыдущий динамический IP в grace-периоде после смены адреса;
- генерирует Nginx allowlist и SNI-маршрутизацию;
- отправляет trusted private SNI в Xray, а untrusted private SNI — на fake-site через PROXY-protocol bridge;
- отклоняет неизвестный, пустой и IP-SNI трафик;
- ведёт отдельный route-aware stream log;
- использует два изолированных Fail2ban jail для reject/private-SNI abuse;
- автоматически защищает trusted IP от собственных Fail2ban/manual-deny правил;
- поддерживает управляемые manual deny списки для TCP/443 и, отдельно, all-ports;
- применяет изменения транзакционно: backup → validation → atomic install → reload;
- умеет rollback с safety snapshot;
- следит за Router IP Push через `systemd.path` и резервный reconcile timer;
- имеет единый CLI/интерактивный интерфейс `riph-admin`.

## Модель доверия

RIPH собирает effective trusted set из четырёх источников:

1. `/etc/router-ip-push-hardening/trusted-static.list` — постоянные IPv4/CIDR;
2. явно указанные Router IP Push router ID, если они нужны для совместимости;
3. валидные регистрации `/etc/router-ip-push/routers.d/<router_id>.json`, у которых уже есть текущий Router IP Push IPv4;
4. ещё не истёкшие previous-IP grace записи.

Просто создать файл `/var/lib/router-ip-push/ips/<name>.ipv4` недостаточно: автоматически обнаруживаемый роутер должен иметь валидную регистрацию Router IP Push.

## Маршрутизация

Логика для входящего TLS на внешнем `:443`:

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

Bridge нужен потому, что внешний stream listener передаёт PROXY protocol, а обычный fake HTTPS upstream ожидает чистый TLS.

## Первая установка поверх 3x-ui-installer

Нормальный порядок для новой VPS:

```text
3x-ui-installer
    -> создаёт рабочий Nginx stream.conf и fake HTTPS upstream

Router IP Push
    -> регистрация роутера на VPS
    -> первый успешный push

RIPH
    -> читает существующий stream.conf
    -> проверяет его штатную структуру
    -> автоматически переносит public / Reality / XHTTP SNI и upstream в свой config.env
    -> делает backup исходного stream.conf
    -> генерирует защищённый RIPH-managed stream.conf + allowlist + bridge config
```

Для штатного `stream.conf` от 3x-ui-installer **не нужно вручную переписывать SNI в `config.env` перед первой установкой**.

Поддерживаются оба штатных варианта:

- public SNI + Reality (`xray`);
- public SNI + Reality (`xray`) + отдельный XHTTP SNI (`xray2`).

Importer также сверяет private SNI с соответствующим fake HTTPS site и перенимает его loopback listen-порт. Если исходный stream layout неизвестен, неполон или неоднозначен, установка останавливается до изменения production-файлов.

Read-only preflight:

```bash
sudo ./install.sh --check
```

Первая production-установка:

```bash
sudo env RIPH_ALLOW_PRODUCTION=1 \
  ./install.sh --install --apply --enable-timers
```

Проверка:

```bash
sudo riph-admin status
```

`config/config.env.example` и `config/trusted-static.list.example` нужны как reference/defaults и для нестандартной ручной конфигурации. Для штатной первой установки routing-поля `config.env` автоматически берутся из уже работающего Nginx.

> `--replace-config` не используется при обычном обновлении существующей установки: рабочие config/list файлы должны сохраняться.

## Обновление

После обновления исходников:

```bash
sudo env RIPH_ALLOW_PRODUCTION=1 ./install.sh --install --apply --enable-timers
sudo riph-admin status
```

Installer сохраняет существующие пользовательские config/list файлы, делает install-backup и сохраняет текущее enabled-состояние RIPH Fail2ban jail.

## Добавление доверенного VPS

Для узла с постоянным IPv4:

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "admin VPS"
```

Удаление:

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

Для динамического домашнего/офисного IP вместо static trusted используется Router IP Push: регистрация роутера + первый валидный push автоматически вводят его в effective trusted set.

## Основные команды

```bash
sudo riph-admin                 # интерактивное меню
sudo riph-admin status
sudo riph-admin reconcile
sudo riph-admin guard
sudo riph-admin fail2ban-status
sudo riph-admin ufw-status
sudo riph-admin harvest
sudo riph-admin backups
```

## Структура репозитория

```text
config/       примеры конфигурации и управляемых списков
docs/         пользовательская и архитектурная документация
src/          устанавливаемые файлы RIPH
tests/        локальная regression suite
tools/        bootstrap/preflight инструменты
install.sh    production/test-root installer
```

## Безопасность

RIPH намеренно не управляет:

- Xray client definitions и базой 3x-ui;
- SSH policy;
- ZeroTier;
- приложениями, которые находятся за прокси.

Автоматические Fail2ban-баны RIPH ограничены TCP/443. All-ports deny существует только как отдельное явное действие администратора.

Сгенерированные Nginx-файлы нельзя редактировать вручную: источником истины являются RIPH config/list/state файлы.

## Проверка исходников

Локальная regression suite:

```bash
bash tests/run-local.sh
```

Она выполняет Bash syntax check, ShellCheck (если установлен) и все `tests/test-*.sh`.

GitHub Actions оставлен **только ручным** (`workflow_dispatch`).
