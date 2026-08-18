# remnanode-bootstrap

Интерактивный скрипт разворачивания Remnawave-ноды на чистой VPS (Debian 12/13, Ubuntu 22.04/24.04).

Оборачивает установщики [DigneZzZ/remnawave-scripts](https://github.com/DigneZzZ/remnawave-scripts), добавляя к ним проверки, диагностику и обход двух известных граблей: конфликта SSH-дропинов от хостера и падения регистрации аккаунта acme.sh.

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/USER/remnanode-bootstrap/main/bootstrap.sh -o bootstrap.sh
less bootstrap.sh          # прочитайте перед запуском
sudo bash bootstrap.sh
```

Замените `USER` на своё имя пользователя GitHub.

Скрипт не запускается через пайп намеренно: вложенным установщикам нужен stdin для интерактивных вопросов.

## Что делает

| Шаг | Действие |
|---|---|
| 1 | Базовые пакеты, BBR + fq |
| 2 | Вход по SSH-ключу, отключение паролей |
| 3 | Tailscale (с `--ssh` как запасной канал) |
| 4 | Проверка A-записи домена |
| 5 | `remnanode.sh @ install` |
| 6 | `selfsteal.sh @ --nginx install` с предварительной подготовкой acme.sh |
| 7 | `wtm.sh @ install-script` + `wtm install-warp`, вариант B |

Каждый шаг можно пропустить. Пройденные шаги записываются в `/var/lib/remnanode-bootstrap/state`, поэтому скрипт безопасно перезапускать — он предложит пропустить сделанное.

## Что нужно приготовить заранее

- **SECRET_KEY** ноды из панели Remnawave (Nodes → Create node)
- **Публичный SSH-ключ** — в Termius: Keychain → New Key → Generate, тип ED25519
- **Домен** с A-записью на IP сервера; если домен за Cloudflare, проксирование должно быть выключено
- **Доступ к консоли VPS** через панель хостера — на случай, если SSH окажется недоступен
- *(опционально)* **Tailscale auth key** с https://login.tailscale.com/admin/settings/keys

## Решаемые проблемы

### SSH: дропины хостера перекрывают harden-конфиг

Провайдеры кладут в `/etc/ssh/sshd_config.d/` файлы вроде `00-hostup-auth.conf` и `50-cloud-init.conf` с `PasswordAuthentication yes`. Файлы читаются по алфавиту, и sshd применяет **первое встреченное** значение — поэтому дропин `99-hardening.conf` не работает.

Скрипт пишет директивы в основной `sshd_config` **перед строкой `Include`**, что перекрывает и дропины, и раскомментированные провайдером строки ниже по файлу. Дополнительно в `/etc/cloud/cloud.cfg` добавляется `ssh_pwauth: false`, чтобы cloud-init не восстановил свой файл после перезагрузки.

Блок обрамлён маркерами `# >>> remnanode-bootstrap` / `# <<<`, так что повторный запуск не дублирует его, а исходные строки провайдера остаются на месте — они просто перекрыты.

### SSH: socket-активация в Debian 13 и Ubuntu 24

Там порт 22 слушает `ssh.socket`, а не постоянно запущенный демон. Привычный `systemctl reload ssh` падает с `fatal: Cannot bind any address`. Скрипт определяет режим и делает `restart ssh.socket` либо `reload ssh` соответственно.

### acme.sh: не регистрируется аккаунт

`selfsteal.sh` при первой установке acme.sh генерирует случайный e-mail вида `user12345@$(hostname -f)`. Если у хоста короткое имя без домена (`stellar-gecko`), адрес получается невалидным и Let's Encrypt отклоняет регистрацию аккаунта.

Скрипт ставит acme.sh заранее с настоящим e-mail, переключает CA на Let's Encrypt и явно регистрирует аккаунт. `selfsteal.sh` затем видит готовую установку и не идёт по сломанной ветке.

## После установки

Скрипт не трогает конфиг Xray — он живёт в панели Remnawave, а не на ноде. Добавьте outbound вручную:

```json
{
  "tag": "warp",
  "protocol": "freedom",
  "settings": { "domainStrategy": "UseIPv4" },
  "streamSettings": {
    "sockopt": { "interface": "warp", "tcpFastOpen": true }
  }
}
```

Порядок в массиве `outbounds` важен: первый элемент — маршрут по умолчанию, поэтому `DIRECT` держите первым. Теги в правилах `routing` сверяются посимвольно — `DIRECT` и `direct` разные вещи.

### Почему `settings.domainStrategy: UseIPv4`, а не `AsIs` + sockopt

Документация XTLS предлагает связку `settings: AsIs` + `sockopt.domainStrategy`, чтобы работал happyEyeballs. На серверной стороне она не срабатывает: для инбаундов VLESS активна политика безопасности Freedom по умолчанию, из-за которой применяются `finalRules`, а при них домен резолвится через системный DNS **до** матчинга правил — и `sockopt.domainStrategy` теряет силу.

Резолв в самом Freedom использует секцию `dns` конфига, что и нужно. `sockopt.interface` при этом работает независимо от резолва.

## Диагностика

```bash
remnanode status                  # состояние ноды
remnanode logs                    # логи контейнера
wtm status                        # состояние WARP
systemctl status wg-quick@warp
ip -br a show warp
curl --interface warp https://www.cloudflare.com/cdn-cgi/trace   # ждём warp=on
sshd -T | grep -iE 'password|permitroot'
journalctl -t sshd -n 30          # логи SSH при socket-активации
```

Лог установки: `/var/log/remnanode-bootstrap.log`
Бэкапы изменённых конфигов: `/root/remnanode-bootstrap-backups/`

## Откат

```bash
# вернуть sshd_config
cp /root/remnanode-bootstrap-backups/sshd_config.<дата> /etc/ssh/sshd_config
sshd -t && systemctl restart ssh.socket

# сбросить состояние, чтобы пройти шаги заново
rm /var/lib/remnanode-bootstrap/state
```

Удаление компонентов — их собственными скриптами: `remnanode uninstall`, `wtm uninstall-script`.

## Ограничения

- Проверялось на Debian 13 (trixie) и Ubuntu 24.04, x86_64
- Не настраивает файрвол — если используете ufw/nftables, откройте 22, 443 и порт ноды сами
- Вариант B WARP требует `network_mode: host` у контейнера ноды; `remnanode.sh` ставит его по умолчанию, скрипт это проверяет
- Не редактирует конфиг Xray: он управляется панелью

## Лицензия

MIT
