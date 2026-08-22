# Router IP Push Hardening (RIPH)

RIPH — защита приватных SNI для Nginx Stream/Xray.

Он пропускает Reality/XHTTP к Xray только от доверенных IP, а недоверенный трафик отправляет на fake-site или reject. Динамические IP роутеров может получать через Router IP Push, но Router IP Push **не обязателен**.

## Быстрый старт

Обычный сценарий: на VPS уже установлен стек от `3x-ui-installer` — Nginx Stream/Xray, UFW и Fail2ban.

> Команды ниже рассчитаны на то, что репозиторий во время установки **Public**.

### Самый простой вариант — скопировать один блок

Для Debian/Ubuntu:

```bash
sudo apt-get update && \
sudo apt-get install -y git && \
git clone https://github.com/AndrewZAP1977/router-ip-push-hardening.git && \
cd router-ip-push-hardening && \
sudo env RIPH_ALLOW_PRODUCTION=1 bash ./install.sh --install --apply --enable-timers && \
sudo riph-fail2ban-activate && \
sudo riph-admin status
```

Если блок завершился без ошибок и `riph-admin status` показывает валидный Nginx, trusted set и активные timers — RIPH установлен и запущен.

### То же самое по шагам

```bash
sudo apt-get update
sudo apt-get install -y git

git clone https://github.com/AndrewZAP1977/router-ip-push-hardening.git
cd router-ip-push-hardening

sudo env RIPH_ALLOW_PRODUCTION=1 bash ./install.sh --install --apply --enable-timers
sudo riph-fail2ban-activate
sudo riph-admin status
```

При **первой** установке RIPH Fail2ban jails специально ставятся выключенными, поэтому после успешного install/apply выполняется `riph-fail2ban-activate`.

Installer сам:

- проверит текущий Nginx/UFW/Fail2ban;
- если это первая установка, перенесёт routing из уже работающего `stream.conf` от `3x-ui-installer`;
- сделает backup перед изменениями;
- установит RIPH;
- если есть Router IP Push — импортирует его текущие `ips/*.ipv4` в собственный state RIPH;
- если Router IP Push нет — продолжит установку без dynamic routers;
- применит Nginx routing/allowlist;
- включит provider watcher и reconcile timers.

## Хочешь сначала только проверить VPS

После `git clone` и `cd router-ip-push-hardening`:

```bash
sudo bash ./install.sh --check
```

Это read-only preflight: он ничего не устанавливает и не меняет production state.

## Обновление существующего RIPH

Если репозиторий уже скачан:

```bash
cd router-ip-push-hardening
git pull --ff-only
sudo env RIPH_ALLOW_PRODUCTION=1 bash ./install.sh --install --apply --enable-timers
sudo riph-admin status
```

При обновлении уже активные RIPH Fail2ban jails сохраняют своё состояние, повторно запускать `riph-fail2ban-activate` обычно не нужно.

При обычном обновлении **не используй `--replace-config`** — существующие рабочие config/list файлы должны сохраняться.

## Router IP Push — опционально

Если Router IP Push установлен, его текущие адреса:

```text
/var/lib/router-ip-push/ips/<Router-ID>.ipv4
```

адаптер RIPH переводит в собственный canonical state:

```text
/var/lib/router-ip-push-hardening/providers/router-ip-push.json
```

Core RIPH работает только со своим state и не зависит от регистраций, ключей, heartbeat или сервиса Router IP Push.

Если Router IP Push отсутствует, RIPH продолжает работать со static trusted IP и остальной своей защитой.

## Что происходит с TLS :443

```text
public SNI
    -> public upstream

private SNI + trusted source
    -> Xray

private SNI + untrusted source
    -> fake HTTPS site

unknown / empty / IP-SNI
    -> reject
```

## Добавить постоянный доверенный IP

```bash
sudo riph-admin trusted-add 203.0.113.10/32 "admin VPS"
```

Удалить:

```bash
sudo riph-admin trusted-remove 203.0.113.10/32
```

Для домашнего/офисного динамического IP лучше использовать Router IP Push, а не добавлять адрес вручную в static trusted.

## Основные команды

```bash
sudo riph-admin                 # интерактивное меню
sudo riph-admin status          # общее состояние
sudo riph-admin reconcile       # пересобрать effective state
sudo riph-admin timers          # systemd watcher/timers
sudo riph-admin fail2ban-status # RIPH Fail2ban jails
sudo riph-admin ufw-status      # UFW rules
sudo riph-admin backups         # доступные backup
```

## Что RIPH не трогает

RIPH намеренно не управляет:

- Xray client definitions и базой 3x-ui;
- SSH policy;
- ZeroTier/VPN;
- Router IP Push registrations/keys/users/receiver/revoker;
- приложениями за reverse proxy.

Автоматические Fail2ban-баны RIPH ограничены TCP/443. All-ports deny выполняется только отдельным явным действием администратора.

## Подробная документация

README специально оставлен коротким. Всё подробное вынесено сюда:

- [Практическая инструкция](docs/USER_GUIDE_RU.md) — provider lifecycle, manual deny, Fail2ban, rollback и команды администратора.
- [Архитектура](docs/ARCHITECTURE.md) — trusted model, routing, canonical provider state и transaction model.

## Проверка исходников

```bash
bash tests/run-local.sh
```

Regression suite выполняет Bash syntax checks, ShellCheck (если установлен) и `tests/test-*.sh`.

GitHub Actions запускается только вручную (`workflow_dispatch`).
