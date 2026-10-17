#!/usr/bin/env bash
#
# remnanode-bootstrap — интерактивная установка Remnawave-ноды на чистую VPS.
#
# Шаги:
#   1. Подготовка системы (пакеты)
#   2. Вход по SSH-ключу и отключение паролей
#   3. Tailscale
#   4. Проверка A-записи домена
#   5. Remnanode
#   6. Selfsteal (nginx + unix socket)
#   7. WARP, вариант B (host-интерфейс)
#   8. Файрвол (ufw)
#   9. BBR + fq
#  10. Инбаунд VLESS XHTTP поверх REALITY
#
# Запуск (подробности в README):
#   curl -fsSL -o bootstrap.sh https://raw.githubusercontent.com/alekvol/remnanode-bootstrap/main/bootstrap.sh
#   bash bootstrap.sh              # от root; или sudo bash bootstrap.sh
# или одной командой, только из root-шелла (через sudo не работает):
#   bash <(curl -fsSL https://raw.githubusercontent.com/alekvol/remnanode-bootstrap/main/bootstrap.sh)
#
# Весь диалог и stdin дочерних процессов берутся из /dev/tty (см. конец
# файла), поэтому пайп curl | bash тоже не ломает ввод. Но и он, и bash <(...)
# возвращают 0, если скачать скрипт не удалось, — для автоматизации
# скачивайте в файл.
#
set -Eeuo pipefail

# su без «-» (util-linux) сохраняет PATH пользователя, а в Debian там нет
# sbin: sshd, ufw, sysctl, modprobe и tc не находились бы, и sshd -t, например,
# выдавался бы за ошибку в конфиге.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Не VERSION: это имя занимает /etc/os-release, который мы сорсим в preflight.
readonly BOOTSTRAP_VERSION="1.6.0"
readonly STATE_DIR="/var/lib/remnanode-bootstrap"
readonly STATE_FILE="$STATE_DIR/state"
readonly LOG_FILE="/var/log/remnanode-bootstrap.log"
readonly BACKUP_DIR="/root/remnanode-bootstrap-backups"

readonly NODE_DIR="/opt/remnanode"

# remnanode.sh и selfsteal.sh больше не используются: ноду и nginx
# поднимаем своим docker compose (шаги 5 и 6).
readonly SS_DIR="/opt/selfsteal"
readonly SS_CONTAINER="selfsteal-nginx"
readonly SS_SOCKET="/dev/shm/nginx.sock"
readonly SS_NGINX_TAG="1.29-alpine"

# wtm.sh больше не используется: WARP поднимаем через wgcf сами (шаг 7).
readonly WARP_CONFIG="/etc/wireguard/warp.conf"
readonly WARP_ACCOUNT="/etc/wireguard/wgcf-account.toml"

# ─────────────────────────────────────────────────────────────────────────────
# Вывод
# ─────────────────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[0;31m'; C_GREEN=$'\033[0;32m'
    C_YELLOW=$'\033[0;33m'; C_BLUE=$'\033[0;34m'; C_CYAN=$'\033[0;36m'
    C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
else
    C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
    C_BOLD=""; C_DIM=""
fi

# Лог не должен ронять вызывающего и шуметь: до проверки на root файл в
# /var/log недоступен на запись, а err() вызывается как раз в этот момент.
# Группа нужна, чтобы 2>/dev/null действовал и на ошибку открытия файла.
log()      { { printf '%s\n' "$*" >>"$LOG_FILE"; } 2>/dev/null || true; }
info()     { printf '%s→%s %s\n' "$C_BLUE" "$C_RESET" "$*"; log "[INFO] $*"; }
ok()       { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; log "[ OK ] $*"; }
warn()     { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*"; log "[WARN] $*"; }
err()      { printf '%s✗%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; log "[FAIL] $*"; }
dim()      { printf '%s  %s%s\n' "$C_DIM" "$*" "$C_RESET"; }

hr() { printf '%s%s%s\n' "$C_DIM" "────────────────────────────────────────────────────────────" "$C_RESET"; }

banner() {
    printf '\n'
    hr
    printf '%s%s  %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"
    hr
}

die() { err "$*"; exit 1; }

trap 'err "Прервано на строке $LINENO. Лог: $LOG_FILE"' ERR

# ─────────────────────────────────────────────────────────────────────────────
# Ввод
# ─────────────────────────────────────────────────────────────────────────────

# ask_yn "Вопрос" [y|n] — возвращает 0 при «да»
ask_yn() {
    local prompt="$1" default="${2:-y}" hint reply
    [[ "$default" == "y" ]] && hint="[Y/n]" || hint="[y/N]"
    while true; do
        printf '%s?%s %s %s%s%s ' "$C_CYAN" "$C_RESET" "$prompt" "$C_DIM" "$hint" "$C_RESET"
        read -r reply </dev/tty || reply=""
        reply="${reply:-$default}"
        case "${reply,,}" in
            y|yes|д|да) return 0 ;;
            n|no|н|нет) return 1 ;;
            *) warn "Ответьте y или n." ;;
        esac
    done
}

# ask_var VARNAME "Вопрос" [значение по умолчанию]
ask_var() {
    local __var="$1" prompt="$2" default="${3:-}" reply
    if [[ -n "$default" ]]; then
        printf '%s?%s %s %s[%s]%s ' "$C_CYAN" "$C_RESET" "$prompt" "$C_DIM" "$default" "$C_RESET"
    else
        printf '%s?%s %s ' "$C_CYAN" "$C_RESET" "$prompt"
    fi
    read -r reply </dev/tty || reply=""
    printf -v "$__var" '%s' "${reply:-$default}"
}

pause() {
    printf '%s  Enter — продолжить...%s' "$C_DIM" "$C_RESET"
    read -r </dev/tty || true
    printf '\n'
}

# ─────────────────────────────────────────────────────────────────────────────
# Состояние (позволяет перезапустить скрипт и пропустить сделанное)
# ─────────────────────────────────────────────────────────────────────────────
state_done()  { grep -qxF "$1" "$STATE_FILE" 2>/dev/null; }
state_mark()  { mkdir -p "$STATE_DIR"; echo "$1" >> "$STATE_FILE"; }
state_unmark() { sed -i "/^$1\$/d" "$STATE_FILE" 2>/dev/null || true; }

# Возвращает 0, если шаг нужно выполнять
should_run() {
    local key="$1" title="$2"
    if state_done "$key"; then
        info "$title — уже выполнено ранее."
        ask_yn "  Выполнить заново?" n || return 1
    fi
    return 0
}

# Ключи шагов, завершившихся ошибкой в этом запуске.
FAILED_STEPS=()

# run_step KEY FUNC — выполняет шаг и переживает его неудачу: остальные
# шаги идут дальше, а итог покажет, что не получилось. Без этого return 1
# из шага под set -e обрывал весь скрипт, и сервер оставался, например,
# без файрвола.
#
# Внимание: функция, вызванная в контексте ||, выполняется с выключенным
# set -e — bash так устроен. Поэтому шаги проверяют важные команды сами
# (|| return 1), а не надеются на errexit.
run_step() {
    local key="$1" fn="$2"
    "$fn" && return 0
    FAILED_STEPS+=("$key")
    # Отметка прошлого успешного запуска больше не верна: иначе следующий
    # запуск предложил бы пропустить упавший шаг, а итог показал бы ✓.
    state_unmark "$key"
    warn "Шаг «$key» не завершён — подробности выше. Продолжаю со следующего."
    return 0
}

step_failed() {
    local k
    for k in "${FAILED_STEPS[@]}"; do [[ "$k" == "$1" ]] && return 0; done
    return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

# На свежей VPS в первые минуты после загрузки apt держат unattended-upgrades
# и cloud-init. У apt-get, в отличие от apt, тайм-аут блокировки dpkg по
# умолчанию 0 — он сразу падает. DPkg::Lock::Timeout заставляет ждать.
readonly APT_LOCK_WAIT=600

# apt-get update с ожиданием блокировки списков пакетов: DPkg::Lock::Timeout
# на /var/lib/apt/lists/lock не действует, поэтому повторяем сами.
apt_update() {
    local i out
    for ((i = 0; i < APT_LOCK_WAIT / 10; i++)); do
        out=$(apt-get update -q 2>&1) && { printf '%s\n' "$out" >>"$LOG_FILE"; return 0; }
        printf '%s\n' "$out" >>"$LOG_FILE"
        grep -q 'Could not get lock' <<<"$out" || return 1
        ((i)) || info "apt занят другим процессом (обычно unattended-upgrades после загрузки) — жду до $((APT_LOCK_WAIT / 60)) минут..."
        sleep 10
    done
    return 1
}

# apt-get install с выводом в лог. confdef/confold — чтобы dpkg не задал
# вопрос про изменённый конфиг: вывод уходит в лог, и вопрос висел бы
# невидимым. Если пакет не нашёлся (списки устарели — шаг 1 мог пройти
# давно), обновляем списки и пробуем ещё раз.
apt_install() {
    local opts=(-y -q -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT"
                -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)
    export DEBIAN_FRONTEND=noninteractive
    apt-get install "${opts[@]}" "$@" >>"$LOG_FILE" 2>&1 && return 0
    apt_update || return 1
    apt-get install "${opts[@]}" "$@" >>"$LOG_FILE" 2>&1
}

# Дождаться, пока dpkg освободится, ничего не ставя. Нужно перед чужими
# установщиками (install.sh Tailscale), которые блокировку не ждут.
apt_wait_lock() {
    apt-get install -y -q -o "DPkg::Lock::Timeout=$APT_LOCK_WAIT" >>"$LOG_FILE" 2>&1 || true
}

# Запущен ли контейнер с этим именем. Нужен, чтобы при повторном запуске
# не принимать за конфликт порты, которые держат наши же контейнеры.
container_running() {
    have docker || return 1
    docker ps --filter "name=^$1\$" --filter status=running --format '{{.Names}}' 2>/dev/null \
        | grep -qx "$1"
}

# Контейнер selfsteal.sh от прежних версий скрипта (до 1.3) держит 80
# (network_mode: host). Шаг 6 сам предложит его остановить. Одного
# compose-файла мало: шаг 6 оставляет файлы старой установки на месте.
legacy_selfsteal_running() {
    { [[ -f /opt/nginx-selfsteal/docker-compose.yml ]] && container_running nginx-selfsteal; } \
        || { [[ -f /opt/caddy/docker-compose.yml ]] && container_running caddy-selfsteal; }
}

# Под tmux/screen обрыв SSH не убивает установку. Переменные TMUX и STY
# sudo вычищает, поэтому смотрим ещё и на предков процесса.
under_multiplexer() {
    [[ -n "${TMUX:-}${STY:-}${ZELLIJ:-}" ]] && return 0
    local pid=$$ comm
    while [[ "$pid" =~ ^[0-9]+$ ]] && (( pid > 1 )); do
        comm=$(cat "/proc/$pid/comm" 2>/dev/null) || return 1
        case "$comm" in tmux*|screen*|SCREEN*|zellij*|mosh-server*) return 0 ;; esac
        pid=$(awk '/^PPid:/{print $2}' "/proc/$pid/status" 2>/dev/null) || return 1
    done
    return 1
}

# docker compose для ноды. --project-directory нужен, чтобы env_file: .env
# искался рядом с compose-файлом, а не в текущем каталоге.
node_compose() {
    docker compose -f "$NODE_DIR/docker-compose.yml" --project-directory "$NODE_DIR" "$@"
}

# Число ключей в authorized_keys. Считаем через ssh-keygen, а не grep:
# он понимает и строки с опциями (restrict,command="..." ssh-ed25519 ...),
# и FIDO-типы (sk-ssh-ed25519@openssh.com). Всегда печатает число.
count_keys() {
    local f="$1"
    [[ -f "$f" ]] || { printf '0'; return 0; }
    { ssh-keygen -l -f "$f" 2>/dev/null || true; } | grep -c . || true
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    local dst
    dst="$BACKUP_DIR/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
    cp -a "$f" "$dst"
    dim "Бэкап: $dst"
}

public_ip() {
    local ip=""
    for u in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -4 -sS --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]') || true
        [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "$ip"; return 0; }
    done
    return 1
}

port_busy() {
    ss -tlnH "sport = :$1" 2>/dev/null | grep -q . && return 0
    return 1
}

# Метки из латиницы, цифр и дефиса; зона — буквы или punycode
# (xn--p1ai — это .рф, без него кириллические домены отвергались).
valid_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+([a-zA-Z]{2,}|xn--[a-zA-Z0-9-]+)$ ]]
}

# ─────────────────────────────────────────────────────────────────────────────
# Предварительные проверки
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    banner "Предварительные проверки"

    # Не подсказываем «sudo $0»: на минимальных образах sudo нет, а при запуске
    # через bash <(...) в $0 лежит /dev/fd/63, и через sudo он не откроется.
    [[ $EUID -eq 0 ]] || die "Нужен root. Зайдите под root (или sudo -i) и запустите заново."
    ok "Запущено от root"

    # Под sudo без -i в HOME может остаться каталог пользователя, и ключ
    # SSH с acme.sh легли бы к нему, а не к root.
    local root_home
    root_home=$(getent passwd root 2>/dev/null | cut -d: -f6) || root_home=""
    if [[ -n "$root_home" && "$HOME" != "$root_home" ]]; then
        export HOME="$root_home"
        dim "HOME переключён на $root_home"
    fi

    # Шаги 3 и 5 уводят в браузер, apt и выпуск сертификата идут минутами.
    # Оборвись SSH в это время — bash получит SIGHUP и умрёт посреди шага.
    if under_multiplexer; then
        ok "Сессия под tmux/screen — обрыв SSH установку не прервёт"
    else
        warn "Запуск не под tmux/screen: обрыв SSH прервёт установку посреди шага."
        dim "Надёжнее: apt-get install -y tmux && tmux new -s rn, запустить скрипт там,"
        dim "а после обрыва вернуться командой tmux attach -t rn."
        ask_yn "  Продолжить без tmux?" y || exit 0
    fi

    [[ -r /etc/os-release ]] || die "Не найден /etc/os-release"
    # Сорсим в субшелле: os-release определяет VERSION, NAME и прочие общие
    # имена, и в основном шелле они затирали бы наши переменные.
    local os_id os_like os_name
    # shellcheck disable=SC1091
    os_id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}") || os_id=""
    os_like=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}") || os_like=""
    os_name=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}") || os_name=""
    case "${os_id}${os_like}" in
        *debian*|*ubuntu*) ok "ОС: ${os_name:-$os_id}" ;;
        *) die "Поддерживаются только Debian и Ubuntu. Обнаружено: ${os_name:-${os_id:-неизвестно}}" ;;
    esac

    if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "aarch64" ]]; then
        warn "Архитектура $(uname -m) не проверялась. Продолжаем на свой риск."
    fi

    mkdir -p "$STATE_DIR" "$BACKUP_DIR"
    touch "$LOG_FILE"; chmod 600 "$LOG_FILE"
    ok "Лог: $LOG_FILE"

    # На минимальном образе Debian curl не предустановлен, а проверки ниже
    # (и public_ip) без него молча превращаются в «нет сети».
    if ! have curl; then
        warn "curl не установлен — ставлю, он нужен для проверок ниже"
        apt_install curl ca-certificates \
            || die "Не удалось установить curl — проверьте apt и сеть, лог: $LOG_FILE"
        have curl || die "curl не появился после установки"
        ok "curl установлен"
    fi

    if ! ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; then
        warn "ICMP до 1.1.1.1 не проходит (может быть заблокирован хостером)."
    fi
    curl -fsS --max-time 10 https://github.com >/dev/null 2>&1 \
        || die "Нет доступа к github.com — установка невозможна"
    ok "Сеть до github.com работает"

    SERVER_IP=$(public_ip) || die "Не удалось определить внешний IPv4"
    ok "Внешний IP сервера: $C_BOLD$SERVER_IP$C_RESET"

    # 80 нужен nginx для выпуска и продления сертификата (HTTP-01), 443 —
    # Xray под REALITY. При повторном запуске их держат наши же контейнеры,
    # и это не конфликт: иначе Enter (ответ по умолчанию) завершал бы скрипт.
    local warn_ports=() p
    for p in 80 443; do
        port_busy "$p" || continue
        [[ "$p" == 80 ]] && container_running "$SS_CONTAINER" && continue
        [[ "$p" == 443 ]] && container_running remnanode && continue
        if [[ "$p" == 80 ]] && legacy_selfsteal_running; then
            dim "Порт 80 держит прежняя установка selfsteal.sh — шаг 6 предложит её остановить"
            dim "(на «Выполнить заново?» шага 6 ответьте y)."
            continue
        fi
        warn_ports+=("$p")
    done
    if ((${#warn_ports[@]})); then
        warn "Порты заняты сторонними процессами: ${warn_ports[*]}"
        dim "80 нужен nginx для выпуска и продления сертификата, 443 — Xray под REALITY."
        ss -tlnp "( sport = :80 or sport = :443 )" 2>/dev/null | sed 's/^/    /' || true
        ask_yn "  Всё равно продолжить?" n || exit 0
    else
        ok "Порты 80 и 443 свободны (или заняты нашими же контейнерами)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 1. Система
# ─────────────────────────────────────────────────────────────────────────────
step_system() {
    should_run "system" "Подготовка системы" || return 0
    banner "Шаг 1/10 — Подготовка системы"

    info "Обновляю списки пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    apt_update \
        || { err "apt-get update не удался, смотрите $LOG_FILE"; return 1; }

    local pkgs=(curl wget ca-certificates gnupg jq git dnsutils
                iproute2 nano less openssl cron)
    info "Ставлю базовые пакеты: ${pkgs[*]}"
    apt_install "${pkgs[@]}" || { err "Не удалось поставить пакеты, смотрите $LOG_FILE"; return 1; }
    ok "Пакеты установлены"

    state_mark "system"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 2. SSH по ключу
# ─────────────────────────────────────────────────────────────────────────────
ssh_reload() {
    have sshd || { err "sshd не найден в PATH ($PATH) — НЕ перезапускаю"; return 1; }
    if ! sshd -t; then
        err "sshd -t нашёл ошибку в конфиге — НЕ перезапускаю"
        return 1
    fi
    # Debian 13 / Ubuntu 24: sshd работает через socket-активацию,
    # там systemctl reload ssh падает с 'Cannot bind any address'.
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        systemctl restart ssh.socket
        dim "Перезапущен ssh.socket (socket-активация)"
    else
        systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || {
            err "Не удалось перезагрузить sshd"; return 1; }
        dim "Выполнен reload ssh.service"
    fi
    return 0
}

# Итоговый конфиг sshd для типичного входа root снаружи. Без -C sshd -T
# показывает только глобальные значения, а Match-блок из дропина провайдера
# (Match User root / PasswordAuthentication yes) молча вернул бы пароль.
# lport обязателен: при Match LocalPort в конфиге sshd -T без него падает —
# и с -C, и без. Берём порт текущей сессии, иначе 22.
readonly SSHD_TEST_SPEC="user=root,host=remnanode-check,addr=198.51.100.1"
sshd_dump() {
    local lport=22 c="${SSH_CONNECTION:-}"
    c="${c##* }"
    [[ "$c" =~ ^[0-9]+$ ]] && lport="$c"
    sshd -T -C "$SSHD_TEST_SPEC,lport=$lport" 2>/dev/null
}

step_ssh() {
    should_run "ssh" "Настройка SSH" || return 0
    banner "Шаг 2/10 — Вход по SSH-ключу"

    printf '%sВ Termius: Keychain → New Key → Generate, тип ED25519.%s\n' "$C_DIM" "$C_RESET"
    printf '%sЗатем откройте ключ и скопируйте ПУБЛИЧНУЮ часть (ssh-ed25519 AAAA...).%s\n\n' "$C_DIM" "$C_RESET"

    local akfile="$HOME/.ssh/authorized_keys"
    mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
    touch "$akfile"; chmod 600 "$akfile"

    local existing=0
    existing=$(count_keys "$akfile")
    if (( existing > 0 )); then
        ok "В authorized_keys уже есть ключей: $existing"
        ssh-keygen -l -f "$akfile" 2>/dev/null | sed 's/^/    /' || true
    fi

    local addkey_default="n"
    (( existing == 0 )) && addkey_default="y"
    if ask_yn "Добавить новый публичный ключ?" "$addkey_default"; then
        local pubkey
        while true; do
            printf '%s?%s Вставьте публичный ключ одной строкой:\n  ' "$C_CYAN" "$C_RESET"
            read -r pubkey </dev/tty || pubkey=""
            [[ -z "$pubkey" ]] && { warn "Пусто, попробуйте ещё раз."; continue; }
            local tmpk; tmpk=$(mktemp)
            printf '%s\n' "$pubkey" > "$tmpk"
            if ssh-keygen -l -f "$tmpk" >/dev/null 2>&1; then
                local fp; fp=$(ssh-keygen -l -f "$tmpk")
                rm -f "$tmpk"
                ok "Ключ корректен: $fp"
                if grep -qxF "$pubkey" "$akfile"; then
                    warn "Такой ключ уже есть — пропускаю"
                else
                    backup_file "$akfile"
                    # Файл без \n в конце (ручная правка, панель хостера):
                    # иначе ключ приклеился бы к последней строке и сломал оба.
                    if [[ -s "$akfile" && -n "$(tail -c1 "$akfile")" ]]; then
                        printf '\n' >> "$akfile" || { err "Не удалось записать $akfile"; return 1; }
                    fi
                    printf '%s\n' "$pubkey" >> "$akfile" || { err "Не удалось записать $akfile"; return 1; }
                    ok "Ключ добавлен в $akfile"
                fi
                break
            fi
            rm -f "$tmpk"
            err "Это не похоже на публичный ключ. Нужна строка вида: ssh-ed25519 AAAAC3... comment"
        done
    fi

    chmod 700 "$HOME/.ssh"; chmod 600 "$akfile"
    ok "Права выставлены: ~/.ssh = 700, authorized_keys = 600"

    local nkeys; nkeys=$(count_keys "$akfile")
    if [[ ! "$nkeys" =~ ^[0-9]+$ ]] || (( nkeys == 0 )); then
        warn "Ключей нет — отключать пароль нельзя, пропускаю харденинг."
        state_mark "ssh"; return 0
    fi

    hr
    printf '%s%sСЕЙЧАС ОТКРОЙТЕ НОВОЕ ОКНО TERMIUS И ПРОВЕРЬТЕ ВХОД ПО КЛЮЧУ.%s\n' "$C_BOLD" "$C_YELLOW" "$C_RESET"
    printf '%sЭту сессию не закрывайте. Если ключ не работает — пароль отключать нельзя.%s\n' "$C_DIM" "$C_RESET"
    hr
    pause

    if ! ask_yn "Вход по ключу работает, отключить парольную аутентификацию?" n; then
        info "Пароль оставлен включённым."
        state_mark "ssh"; return 0
    fi

    local confirm
    ask_var confirm "Введите YES заглавными для подтверждения:"
    if [[ "$confirm" != "YES" ]]; then
        info "Не подтверждено — пароль оставлен."
        state_mark "ssh"; return 0
    fi

    local cfg=/etc/ssh/sshd_config
    backup_file "$cfg"

    # Провайдеры (hostup, cloud-init) кладут свои дропины в sshd_config.d/
    # с именами 00-* и 50-*, а sshd берёт ПЕРВОЕ встреченное значение.
    # Поэтому пишем не в дропин, а в основной конфиг ДО строки Include.
    info "Ищу конфликтующие дропины..."
    grep -rlE '^\s*(PasswordAuthentication|PermitRootLogin)\s' \
        /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/    /' || dim "    (не найдено)"

    # Блок перед Include перекрывает глобальные значения, но не Match-блоки:
    # внутри Match действует своё значение для совпавших подключений.
    if grep -rqiE '^\s*Match\s' "$cfg" /etc/ssh/sshd_config.d/ 2>/dev/null; then
        warn "В конфиге есть Match-блоки — они переопределяют настройки для части входов:"
        grep -rniE '^\s*Match\s' "$cfg" /etc/ssh/sshd_config.d/ 2>/dev/null | sed 's/^/    /'
    fi

    sed -i '/# >>> remnanode-bootstrap/,/# <<< remnanode-bootstrap/d' "$cfg" \
        || { err "Не удалось отредактировать $cfg"; return 1; }

    local block
    block=$(cat <<'EOF'
# >>> remnanode-bootstrap
# Стоит ДО Include: sshd применяет первое встреченное значение,
# поэтому этот блок перекрывает и sshd_config.d/*, и строки ниже.
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitRootLogin prohibit-password
# <<< remnanode-bootstrap
EOF
)

    if grep -qE '^\s*Include\s' "$cfg"; then
        awk -v b="$block" '
            /^[[:space:]]*Include[[:space:]]/ && !ins { print b; print ""; ins=1 }
            { print }
        ' "$cfg" > "$cfg.new" && mv "$cfg.new" "$cfg" \
            || { err "Не удалось записать $cfg"; return 1; }
        dim "Блок вставлен перед строкой Include"
    else
        { printf '%s\n\n' "$block"; cat "$cfg"; } > "$cfg.new" && mv "$cfg.new" "$cfg" \
            || { err "Не удалось записать $cfg"; return 1; }
        dim "Блок добавлен в начало файла (Include отсутствует)"
    fi

    if ! ssh_reload; then
        err "Откатываю конфиг"
        local last; last=$(ls -t "$BACKUP_DIR"/sshd_config.* 2>/dev/null | head -1)
        [[ -n "$last" ]] && cp -a "$last" "$cfg" && ssh_reload
        die "SSH не настроен — разберитесь вручную перед продолжением"
    fi

    # Сверяем итог для входа root снаружи, с учётом Match-блоков. Решает
    # permitrootlogin: при prohibit-password sshd сам отвергает пароль root,
    # даже если Match разрешил PasswordAuthentication. Дыра — только когда
    # Match вернул ещё и PermitRootLogin yes.
    printf '\n'
    local eff pa kb pr pk bad=0
    if ! eff=$(sshd_dump) || [[ -z "$eff" ]]; then
        err "Не удалось проверить итоговые настройки: sshd -T -C завершился ошибкой"
        bad=1
    else
        pa=$(awk '$1=="passwordauthentication"{print $2}' <<<"$eff")
        kb=$(awk '$1=="kbdinteractiveauthentication"{print $2}' <<<"$eff")
        pr=$(awk '$1=="permitrootlogin"{print $2}' <<<"$eff")
        pk=$(awk '$1=="pubkeyauthentication"{print $2}' <<<"$eff")
        dim "Для входа root снаружи (sshd -T -C): password=$pa kbd-interactive=$kb permitrootlogin=$pr pubkey=$pk"
        if [[ "$pr" == yes && ( "$pa" != no || "$kb" != no ) ]]; then
            err "root по-прежнему входит по паролю: это разрешает Match-блок (список выше)"
            dim "Уберите из него PermitRootLogin yes / PasswordAuthentication yes / KbdInteractiveAuthentication yes"
            bad=1
        elif [[ "$pa" != no || "$kb" != no ]]; then
            warn "Match-блок разрешает пароль, но не для root (permitrootlogin=$pr) — root его не примет"
        else
            ok "Вход по паролю отключён"
        fi
        if [[ "$pk" == yes ]]; then
            ok "Вход по ключу включён"
        else
            err "pubkeyauthentication = $pk — вход по ключу не работает"
            bad=1
        fi
    fi

    # cloud-init может вернуть свой дропин после перезагрузки
    if [[ -f /etc/cloud/cloud.cfg ]] && ! grep -q '^ssh_pwauth:' /etc/cloud/cloud.cfg; then
        echo "ssh_pwauth: false" >> /etc/cloud/cloud.cfg
        dim "В /etc/cloud/cloud.cfg добавлено ssh_pwauth: false"
    fi

    warn "Проверьте вход по ключу ЕЩЁ РАЗ, не закрывая эту сессию."
    pause
    if (( bad )); then
        dim "Исправьте и запустите скрипт снова — шаг 2 выполнится заново."
        return 1
    fi
    state_mark "ssh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 3. Tailscale
# ─────────────────────────────────────────────────────────────────────────────
step_tailscale() {
    should_run "tailscale" "Tailscale" || return 0
    banner "Шаг 3/10 — Tailscale"

    if ! ask_yn "Установить Tailscale?" y; then
        info "Пропускаю."; return 0
    fi

    if have tailscale; then
        ok "Tailscale уже установлен: $(tailscale version | head -1)"
    else
        info "Ставлю Tailscale..."
        # install.sh от Tailscale блокировку dpkg не ждёт и падал бы, пока
        # после загрузки работает unattended-upgrades.
        apt_wait_lock
        curl -fsSL https://tailscale.com/install.sh | sh \
            || { err "Установка Tailscale не удалась"; return 1; }
        have tailscale || { err "tailscale не найден после установки"; return 1; }
        ok "Tailscale установлен"
    fi

    if tailscale status >/dev/null 2>&1; then
        ok "Уже подключён к сети:"
        tailscale status | head -5 | sed 's/^/    /'
    else
        printf '\n%sДва способа авторизации:%s\n' "$C_DIM" "$C_RESET"
        dim "  1) Auth key — заранее создать на https://login.tailscale.com/admin/settings/keys"
        dim "  2) Ссылка — скрипт выведет URL, откроете его в браузере"
        printf '\n'
        local authkey=""
        ask_var authkey "Auth key (Enter — авторизоваться по ссылке):"
        if [[ -n "$authkey" ]]; then
            tailscale up --authkey="$authkey" --ssh || warn "tailscale up завершился с ошибкой"
        else
            info "Откройте ссылку ниже в браузере и подтвердите вход:"
            tailscale up --ssh || warn "tailscale up завершился с ошибкой"
        fi
        if tailscale status >/dev/null 2>&1; then
            ok "Подключено. Tailscale IP: $(tailscale ip -4 2>/dev/null | head -1)"
        else
            # Не отмечаем шаг: интерфейс tailscale0 при этом уже есть, и шаг 8
            # иначе закрыл бы порт ноды на тейлнет без единого пира.
            err "Не подключено: tailscale up не прошёл (просроченный или уже использованный auth key?)"
            dim "Доделать вручную: tailscale up --ssh — или запустите скрипт снова."
            return 1
        fi
    fi

    dim "Флаг --ssh включает Tailscale SSH: запасной вход, если основной SSH отвалится."
    state_mark "tailscale"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 4. Домен
# ─────────────────────────────────────────────────────────────────────────────
step_dns() {
    # Домен, сохранённый прошлым запуском: подставим его умолчанием,
    # чтобы при повторном проходе не набирать заново.
    local saved=""
    [[ -f "$STATE_DIR/domain" ]] && saved=$(cat "$STATE_DIR/domain" 2>/dev/null || true)
    DOMAIN="${DOMAIN:-$saved}"

    if ! should_run "dns" "A-запись домена"; then
        [[ -n "$DOMAIN" ]] && info "Домен из прошлого запуска: $DOMAIN"
        return 0
    fi

    banner "Шаг 4/10 — A-запись домена"

    printf '%sСертификат Let'"'"'s Encrypt выпускается по HTTP-01 через порт 80.%s\n' "$C_DIM" "$C_RESET"
    printf '%sДля этого домен ОБЯЗАН резолвиться в IP этого сервера.%s\n\n' "$C_DIM" "$C_RESET"

    printf '  %sДобавьте у регистратора или в панели DNS:%s\n' "$C_BOLD" "$C_RESET"
    printf '      %sТип:%s   A\n' "$C_DIM" "$C_RESET"
    printf '      %sИмя:%s   ваш поддомен (например seafile)\n' "$C_DIM" "$C_RESET"
    printf '      %sЗначение:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$SERVER_IP" "$C_RESET"
    printf '      %sTTL:%s   минимальный (60–300)\n\n' "$C_DIM" "$C_RESET"
    warn "Если домен за Cloudflare — проксирование (оранжевое облако) должно быть ВЫКЛЮЧЕНО."
    dim "Иначе на 80 и 443 ответит CDN: сертификат не выпустится, а REALITY не заработает."
    printf '\n'

    # Ввод держим в локальной d, а в DOMAIN кладём только вместе с записью в
    # файл. Иначе отказ от повторного ввода оставлял бы в DOMAIN отвергнутую
    # строку, и шаги 6 и 10 взяли бы её вместо сохранённого домена.
    local d="${DOMAIN:-}" resolved
    while true; do
        ask_var d "Полный домен для selfsteal (например seafile.example.com):" "$d"

        if [[ -z "$d" ]]; then
            warn "Домен не введён."
            ask_yn "  Пропустить шаг целиком?" y && { info "Пропускаю."; return 0; }
            d="${DOMAIN:-}"
            continue
        fi

        if ! valid_domain "$d"; then
            err "Домен выглядит некорректно."
            dim "Кириллический домен вводите в punycode: сайт.рф → xn--80aswg.xn--p1ai"
            ask_yn "  Ввести заново?" y || { info "Пропускаю шаг."; return 0; }
            d="${DOMAIN:-}"   # отвергнутую строку умолчанием не подставляем
            continue
        fi

        # Проверку можно не делать: DNS ещё не распространился, домен за
        # сплит-хорайзоном, или пользователь просто знает, что запись верна.
        if ! ask_yn "  Проверить A-запись через DNS?" y; then
            warn "Проверка пропущена — если запись неверна, сертификат не выпустится."
            break
        fi

        info "Проверяю A-запись $d..."
        resolved=$(dig +short A "$d" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1 || true)

        if [[ -z "$resolved" ]]; then
            err "A-запись не найдена. DNS ещё не распространился или запись не создана."
        elif [[ "$resolved" == "$SERVER_IP" ]]; then
            ok "$d → $resolved (совпадает с IP сервера)"
            break
        else
            err "$d → $resolved, а сервер имеет $SERVER_IP"
            dim "Если это IP Cloudflare — отключите проксирование."
        fi

        ask_yn "  Проверить ещё раз?" y || {
            ask_yn "  Продолжить без корректной A-записи (сертификат не выпустится)?" n && break
        }
    done

    # Домен сменился: nginx и сертификат шага 6, а с ними подсказка шага 10,
    # относятся к старому. Снимаем их отметки, чтобы следующие шаги
    # выполнились заново, а не пропустились по Enter.
    if [[ -n "$saved" && "$d" != "$saved" ]]; then
        local k
        for k in selfsteal xhttp; do
            state_done "$k" || continue
            state_unmark "$k"
            warn "Домен сменился — шаг «$k» будет выполнен заново под $d"
        done
    fi

    DOMAIN="$d"
    echo "$DOMAIN" > "$STATE_DIR/domain" || { err "Не удалось сохранить домен в $STATE_DIR/domain"; return 1; }
    state_mark "dns"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 5. Remnanode
# ─────────────────────────────────────────────────────────────────────────────
# Дистрибутив и кодовое имя для репозитория Docker: "<debian|ubuntu> <codename>".
# Preflight пускает и производные (Mint, Pop!_OS — по ID_LIKE), а у
# download.docker.com есть только debian и ubuntu, причём с их кодовыми
# именами, а не производных.
docker_repo_target() {
    local id like codename
    id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")
    like=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID_LIKE:-}")
    case "$id" in
        debian|ubuntu)
            codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}") ;;
        *)
            if [[ "$like" == *ubuntu* ]]; then
                id=ubuntu
                codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${UBUNTU_CODENAME:-}")
            else
                id=debian
                codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${DEBIAN_CODENAME:-}")
            fi ;;
    esac
    [[ "$codename" =~ ^[a-z]+$ ]] || return 1
    printf '%s %s' "$id" "$codename"
}

# Подключает официальный репозиторий Docker. Если apt-get update с ним не
# проходит, docker.list убирается: битый список ломает любой следующий
# apt-get update, в том числе повторный шаг 1.
readonly DOCKER_LIST=/etc/apt/sources.list.d/docker.list
add_docker_repo() {
    local target os_id codename
    target=$(docker_repo_target) \
        || { err "Не удалось определить дистрибутив и кодовое имя для репозитория Docker"; return 1; }
    read -r os_id codename <<<"$target"
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$os_id/gpg" \
        -o /etc/apt/keyrings/docker.asc || { err "Не скачался ключ Docker"; return 1; }
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
        "$(dpkg --print-architecture)" "$os_id" "$codename" > "$DOCKER_LIST" \
        || { err "Не удалось записать $DOCKER_LIST"; return 1; }
    if ! apt_update; then
        rm -f "$DOCKER_LIST"
        err "Репозиторий Docker для $os_id $codename недоступен, смотрите $LOG_FILE"
        return 1
    fi
}

# Версия-кандидат пакета в apt; пусто, если пакета нет.
apt_candidate() {
    local c
    c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/{print $2; exit}') || true
    [[ -n "$c" && "$c" != "(none)" ]] && printf '%s' "$c"
}

install_docker() {
    if ! have docker; then
        info "Ставлю Docker из официального репозитория..."
        add_docker_repo || return 1
        if ! apt_install docker-ce docker-ce-cli containerd.io \
                docker-buildx-plugin docker-compose-plugin; then
            rm -f "$DOCKER_LIST"
            err "Установка Docker не удалась, смотрите $LOG_FILE"
            return 1
        fi
    fi

    # Docker из пакета дистрибутива (docker.io) ставится без compose. Плагин
    # есть в Ubuntu (docker-compose-v2) и в Debian 13 (docker-compose 2.x).
    # В Debian 12 docker-compose — это python-версия 1.x: она даёт только
    # команду docker-compose, а не плагин, поэтому её пропускаем и берём
    # docker-compose-plugin из репозитория Docker. С docker.io он не конфликтует.
    if ! docker compose version >/dev/null 2>&1; then
        info "Плагина docker compose нет — доставляю..."
        apt_update || warn "apt-get update не прошёл, смотрите $LOG_FILE"
        local pkg cand
        for pkg in docker-compose-plugin docker-compose-v2 docker-compose; do
            cand=$(apt_candidate "$pkg") || continue
            [[ "$pkg" == docker-compose && "$cand" != 2* ]] && continue
            apt_install "$pkg" && docker compose version >/dev/null 2>&1 && break
        done
        if ! docker compose version >/dev/null 2>&1 && [[ ! -f "$DOCKER_LIST" ]]; then
            info "В репозиториях дистрибутива плагина нет — беру docker-compose-plugin у Docker"
            add_docker_repo && apt_install docker-compose-plugin
        fi
        docker compose version >/dev/null 2>&1 \
            || { err "Плагин docker compose недоступен, смотрите $LOG_FILE"; return 1; }
    fi
    ok "Docker готов: $(docker --version)"
}

# Значение ключа из .env, без кавычек. Пустая строка, если ключа нет.
env_value() {
    local file="$1" key="$2" v=""
    [[ -f "$file" ]] || return 1
    v=$(grep -m1 -E "^[[:space:]]*$key=" "$file" 2>/dev/null | cut -d= -f2- | tr -d '"'\''[:space:]') || true
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

# Из панели нередко копируют всю строку SECRET_KEY="eyJ..." вместо самого
# токена — тогда в .env попадало SECRET_KEY=SECRET_KEY="...", и нода не
# проходила авторизацию, хотя контейнер «работал».
normalize_secret() {
    local s="$1"
    s="${s//\"/}"; s="${s//\'/}"
    s="${s//[[:space:]]/}"
    s="${s#export}"
    # В цикле: в .env от прошлых версий бывает и SECRET_KEY=SECRET_KEY=...
    while [[ "$s" == SECRET_KEY=* ]]; do s="${s#SECRET_KEY=}"; done
    printf '%s' "$s"
}

# Похоже ли на SECRET_KEY из панели: base64 от JSON, то есть начинается с eyJ.
secret_ok() { [[ "$1" =~ ^[A-Za-z0-9+/=_-]{20,}$ && "$1" == eyJ* ]]; }

step_remnanode() {
    should_run "remnanode" "Remnanode" || return 0
    banner "Шаг 5/10 — Установка Remnanode"

    printf '%sСтавим ноду своим docker-compose, без внешнего установщика.%s\n' "$C_DIM" "$C_RESET"
    printf '%sК штатному набору добавлен том /dev/shm — через него нода видит%s\n' "$C_DIM" "$C_RESET"
    printf '%sunix-сокет, который создаёт соседний контейнер с nginx.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Устанавливать ноду сейчас?" y; then
        info "Пропускаю."; return 0
    fi

    install_docker || return 1

    mkdir -p "$NODE_DIR" && chmod 700 "$NODE_DIR" \
        || { err "Не удалось создать $NODE_DIR"; return 1; }

    # ── SECRET_KEY и порт ─────────────────────────────────────────────────
    local secret="" port="" old="" prev_port=""
    old=$(env_value "$NODE_DIR/.env" SECRET_KEY) || old=""
    port=$(env_value "$NODE_DIR/.env" NODE_PORT) || port=$(env_value "$NODE_DIR/.env" APP_PORT) || port=""
    prev_port="$port"

    # .env от прошлых версий мог сохранить ключ вместе с префиксом
    # SECRET_KEY="..." — тогда нода не авторизуется. Чиним и его.
    if [[ -n "$old" ]]; then
        secret=$(normalize_secret "$old")
        if ! secret_ok "$secret"; then
            warn "SECRET_KEY в $NODE_DIR/.env не похож на ключ из панели — нужно ввести заново"
            secret=""
        elif [[ "$secret" != "$old" ]]; then
            info "SECRET_KEY в $NODE_DIR/.env был записан с лишним префиксом — исправляю"
        fi
    fi
    if [[ -n "$secret" ]]; then
        ok "SECRET_KEY найден в $NODE_DIR/.env — переиспользую"
        ask_yn "  Заменить на новый?" n && secret=""
    fi
    if [[ -z "$secret" ]]; then
        printf '\n%sSECRET_KEY из панели: Nodes → Create/Manage node → скопировать eyJ...%s\n' "$C_DIM" "$C_RESET"
        while true; do
            ask_var secret "SECRET_KEY:" ""
            secret=$(normalize_secret "$secret")
            if [[ -z "$secret" ]]; then
                warn "Пусто."
            elif [[ ! "$secret" =~ ^[A-Za-z0-9+/=_-]{20,}$ ]]; then
                err "Это не похоже на SECRET_KEY: нужна одна строка base64 вида eyJ..."
            elif [[ "$secret" != eyJ* ]]; then
                warn "Ключ обычно начинается с eyJ, а этот — нет."
                ask_yn "  Всё равно использовать?" n && break
            else
                break
            fi
        done
    fi

    # Занятый порт нода не забиндит и уйдёт в цикл перезапусков, а проверка
    # «порт слушается» после запуска увидела бы чужой процесс — например,
    # sshd, перенесённый на популярный 2222. Свободен он должен быть до
    # запуска; исключение — его уже держит наша же нода с прошлого раза.
    local def_port="${port:-2222}"
    [[ -z "$prev_port" ]] && port_busy "$def_port" && def_port=2223
    while true; do
        ask_var port "Порт API ноды:" "$def_port"
        if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
            err "Нужно число 1–65535."; continue
        fi
        if port_busy "$port" && ! { [[ "$port" == "$prev_port" ]] && container_running remnanode; }; then
            err "Порт $port уже занят:"
            ss -tlnpH "sport = :$port" 2>/dev/null | sed 's/^/    /'
            def_port=""
            continue
        fi
        break
    done
    dim "Тот же порт должен стоять в записи ноды в панели."

    # ── Версия образа ─────────────────────────────────────────────────────
    # Нода 3.3.0+ рвёт TLS-хендшейк, если панель старее 3.3.0: она не шлёт
    # производный SNI, и нода просто не выходит в онлайн с 'unknown sni'.
    local tag="latest"
    printf '\n'
    warn "Нода 3.3.0+ работает только с панелью 3.3.0 и новее."
    dim "На старой панели нода останется офлайн с 'unknown sni' в логах."
    if ! ask_yn "Ваша панель 3.3.0 или новее?" y; then
        tag="3.2.2"
        info "Беру образ $tag — совместим со старой панелью."
    fi
    ask_var tag "Тег образа ноды:" "$tag"

    # ── Файлы ─────────────────────────────────────────────────────────────
    backup_file "$NODE_DIR/.env"
    cat > "$NODE_DIR/.env" <<EOF || { err "Не удалось записать $NODE_DIR/.env"; return 1; }
### NODE ###
NODE_PORT=$port

### XRAY ###
SECRET_KEY=$secret
EOF
    chmod 600 "$NODE_DIR/.env"
    ok "Записан $NODE_DIR/.env"

    backup_file "$NODE_DIR/docker-compose.yml"
    cat > "$NODE_DIR/docker-compose.yml" <<EOF || { err "Не удалось записать $NODE_DIR/docker-compose.yml"; return 1; }
services:
  remnanode:
    container_name: remnanode
    hostname: remnanode
    image: ghcr.io/remnawave/node:$tag
    env_file:
      - .env
    network_mode: host
    restart: always
    cap_add:
      - NET_ADMIN
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    volumes:
      # unix-сокет selfsteal: REALITY отдаёт сюда чужой трафик,
      # а создаёт сокет соседний контейнер с nginx
      - /dev/shm:/dev/shm
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    ok "Записан $NODE_DIR/docker-compose.yml"
    dim "network_mode: host — нужен и для WARP (вариант B), и для XHTTP за nginx"

    # Замена CLI remnanode, который ставил внешний установщик.
    cat > /usr/local/bin/rn <<EOF
#!/usr/bin/env bash
# Обёртка над docker compose для ноды Remnawave. Создана remnanode-bootstrap.
exec docker compose -f "$NODE_DIR/docker-compose.yml" --project-directory "$NODE_DIR" "\$@"
EOF
    chmod 755 /usr/local/bin/rn
    ok "Команда rn установлена: rn ps, rn logs -f, rn restart"

    # ── Запуск ────────────────────────────────────────────────────────────
    info "Поднимаю контейнер..."
    node_compose up -d || { err "docker compose up завершился с ошибкой"; return 1; }

    sleep 3
    if docker ps --filter name=remnanode --filter status=running --format '{{.Names}}' | grep -qx remnanode; then
        ok "Контейнер remnanode работает"
    else
        err "Контейнер не поднялся"
        node_compose logs --tail 30 2>&1 | sed 's/^/    /' || true
        return 1
    fi

    if port_busy "$port"; then
        ok "Порт $port слушается"
    else
        warn "Порт $port не слушается — панель до ноды не достучится"
    fi

    # Логи сперва в переменную: в пайпе grep -q выходит на первом совпадении,
    # compose ловит SIGPIPE, и pipefail делал условие ложным — ровно тогда,
    # когда ошибка в логах есть.
    local logs
    logs=$(node_compose logs --tail 200 2>&1) || true
    if grep -qi 'unknown sni' <<<"$logs"; then
        err "В логах есть 'unknown sni' — панель старее ноды"
        dim "Переустановите с тегом 3.2.2 либо обновите панель."
    fi

    state_mark "remnanode"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 6. Selfsteal + предварительная подготовка acme.sh
# ─────────────────────────────────────────────────────────────────────────────
prepare_acme() {
    # Готовые установщики ставили acme.sh со случайным e-mail вида
    # user12345@<hostname>; при коротком имени хоста (stellar-gecko) адрес
    # невалиден, и Let's Encrypt отказывал в регистрации аккаунта. Поэтому
    # ставим acme.sh сами, с настоящим e-mail, и регистрируемся явно.
    banner "Подготовка acme.sh"

    local acme_home="$HOME/.acme.sh"
    local email=""

    while true; do
        ask_var email "E-mail для Let's Encrypt (реальный адрес — на него регистрируется аккаунт):" "${ACME_EMAIL:-}"
        [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+$ ]] && valid_domain "${email#*@}" && break
        err "Некорректный e-mail. Нужен вид name@domain.tld"
    done
    ACME_EMAIL="$email"

    if [[ -f "$acme_home/acme.sh" ]]; then
        ok "acme.sh уже установлен: $acme_home"
    else
        info "Ставлю acme.sh с e-mail $email..."
        # Не die: вызывающий (step_selfsteal) рассчитывает пережить неудачу
        # и перейти к следующему шагу, а die убил бы весь скрипт.
        curl -fsSL https://get.acme.sh | sh -s email="$email" >>"$LOG_FILE" 2>&1 \
            || { err "Установка acme.sh не удалась, смотрите $LOG_FILE"; return 1; }
        [[ -f "$acme_home/acme.sh" ]] || { err "acme.sh не найден после установки"; return 1; }
        ok "acme.sh установлен"
    fi

    info "Переключаю CA по умолчанию на Let's Encrypt..."
    "$acme_home/acme.sh" --set-default-ca --server letsencrypt >>"$LOG_FILE" 2>&1 \
        || warn "Не удалось сменить CA (смотрите лог)"

    info "Регистрирую аккаунт..."
    if "$acme_home/acme.sh" --register-account -m "$email" --server letsencrypt >>"$LOG_FILE" 2>&1; then
        ok "Аккаунт Let's Encrypt зарегистрирован"
    else
        # Уже зарегистрирован — тоже нормально
        if grep -qi 'already' <(tail -20 "$LOG_FILE"); then
            ok "Аккаунт уже был зарегистрирован ранее"
        else
            warn "Регистрация вернула ошибку. Хвост лога:"
            tail -10 "$LOG_FILE" | sed 's/^/    /'
            ask_yn "  Продолжить всё равно?" n || return 1
        fi
    fi

    local acct="$acme_home/ca/acme-v02.api.letsencrypt.org/directory/account.json"
    [[ -f "$acct" ]] && ok "account.json на месте" || warn "account.json не найден — возможны проблемы при выпуске"
    return 0
}

# Значение ключа из конфига домена acme.sh (Le_Webroot='...').
acme_conf_value() {
    grep -m1 "^$2=" "$1" 2>/dev/null | cut -d= -f2- | sed "s/^'//; s/'\$//"
}

# Покрывает ли сертификат домен (по SAN, с учётом wildcard) и действует ли
# он ещё хотя бы MARGIN секунд.
cert_ok() {
    local crt="$1" domain="$2" margin="${3:-0}"
    [[ -s "$crt" ]] || return 1
    openssl x509 -in "$crt" -noout -checkend "$margin" >/dev/null 2>&1 || return 1
    openssl x509 -in "$crt" -noout -checkhost "$domain" 2>/dev/null | grep -q 'does match'
}

# Копия конфига acme.sh в бэкапы. У RSA- и ECC-конфигов одно имя файла
# ($domain.conf), поэтому в имя бэкапа входит каталог.
backup_acme_conf() {
    local c="$1" dst
    [[ -f "$c" ]] || return 0
    mkdir -p "$BACKUP_DIR" || return 1
    dst="$BACKUP_DIR/acme-$(basename "$(dirname "$c")").conf.$(date +%Y%m%d-%H%M%S)"
    cp -a "$c" "$dst" && dim "Бэкап: $dst"
}

# Снимает с автопродления запись acme.sh. Файлы сертификата acme.sh не
# удаляет, конфиг переименовывает в .removed.
acme_remove() {
    local acme="$1" c="$2" d
    d=$(acme_conf_value "$c" Le_Domain)
    [[ -n "$d" ]] || return 1
    backup_acme_conf "$c"
    if [[ "$(basename "$(dirname "$c")")" == *_ecc ]]; then
        "$acme" --remove -d "$d" --ecc >>"$LOG_FILE" 2>&1
    else
        "$acme" --remove -d "$d" >>"$LOG_FILE" 2>&1
    fi
}

# Выпуск и установка сертификата. HTTP-01 через webroot, а не TLS-ALPN:
# 443 занят Xray под REALITY, и продление по ALPN туда просто не забиндится.
# Webroot обслуживает наш же nginx на 80, поэтому продление не требует
# останова чего-либо и работает само из крона acme.sh.
#
# Сертификат всегда ведёт acme.sh: просто скопированный файл никто бы не
# продлевал. Если acme.sh уже ведёт сертификат домена (наш прошлый запуск
# или прежний установщик), заново не выпускаем — у Let's Encrypt лимит
# 5 одинаковых сертификатов в неделю. Но продление идёт тем способом,
# каким сертификат выпущен: standalone на 80 или TLS-ALPN на 443 теперь
# не пройдут, поэтому такой сертификат один раз перевыпускаем через наш
# webroot. DNS-01 портов не касается — его оставляем как есть.
issue_cert() {
    local domain="$1" acme="$HOME/.acme.sh/acme.sh" webroot="$SS_DIR/acme"
    [[ -x "$acme" ]] || { err "acme.sh не найден"; return 1; }
    mkdir -p "$SS_DIR/ssl" "$webroot/.well-known/acme-challenge" \
        || { err "Не удалось создать каталоги в $SS_DIR"; return 1; }

    # Ведём ECC-сертификат (умолчание acme.sh 3.x). --ecc указываем явно,
    # чтобы не подхватить старый RSA-каталог того же домена.
    local dir="$HOME/.acme.sh/${domain}_ecc"
    local conf="$dir/$domain.conf" rc=0 method="" kl="" bak="" mark=0

    # Возврат к домену, который раньше сняли с продления при смене домена:
    # acme.sh переименовал его конфиг в .removed, а ключ домена остался.
    if [[ ! -f "$conf" && -f "$conf.removed" ]]; then
        mv "$conf.removed" "$conf" || { err "Не удалось вернуть конфиг acme.sh для $domain"; return 1; }
    fi
    if [[ -f "$conf" ]]; then
        method=$(acme_conf_value "$conf" Le_Webroot)
        kl=$(acme_conf_value "$conf" Le_Keylength)
    fi
    # Длину ключа берём прежнюю: иначе acme.sh создаст новый ключ ещё до
    # заказа, и при неудаче прежний сертификат остался бы без своего ключа.
    [[ "$kl" == ec-* ]] || kl=ec-256
    local issue=("$acme" --issue -d "$domain" --keylength "$kl" --webroot "$webroot" --server letsencrypt)

    if [[ -f "$conf" && "$method" == "$webroot" ]]; then
        info "acme.sh уже ведёт сертификат для $domain — продлеваю, если пора..."
        "$acme" --renew -d "$domain" --ecc >>"$LOG_FILE" 2>&1 || rc=$?
    elif [[ -f "$conf" && "$method" == dns_* ]]; then
        info "acme.sh ведёт сертификат для $domain через DNS ($method) — оставляю этот способ"
        "$acme" --renew -d "$domain" --ecc >>"$LOG_FILE" 2>&1 || rc=$?
    elif [[ -f "$conf" ]]; then
        warn "acme.sh ведёт сертификат для $domain другим способом: $method"
        dim "Так продление больше не пройдёт: 80 занимает наш nginx, 443 — Xray. Перевыпускаю один раз через webroot."
        # acme.sh перепишет конфиг домена (способ, хуки) ещё до заказа у CA
        # и при неудаче не откатит. Сохраняем, чтобы вернуть рабочий способ.
        backup_acme_conf "$conf"
        bak="$conf.bootstrap-bak"
        cp -p "$conf" "$bak" || { err "Не удалось сохранить $conf"; return 1; }
        mark=$(wc -l <"$LOG_FILE" 2>/dev/null) || mark=0
        "${issue[@]}" --force >>"$LOG_FILE" 2>&1 || rc=$?
        (( rc == 0 )) && { rm -f "$bak"; bak=""; }
    else
        info "Выпускаю сертификат через HTTP-01 (webroot на порту 80)..."
        "${issue[@]}" >>"$LOG_FILE" 2>&1 || rc=$?
    fi

    # 2 — RENEW_SKIP: сертификат есть и продлевать рано. Это не ошибка.
    if (( rc != 0 && rc != 2 )); then
        err "Выпуск не удался (код $rc), хвост лога:"
        tail -15 "$LOG_FILE" | sed 's/^/    /'
        if [[ -n "$bak" ]]; then
            # Лог в переменную: grep -q в пайпе под pipefail «не находит» найденное.
            local new_log
            new_log=$(tail -n +"$((mark + 1))" "$LOG_FILE" 2>/dev/null) || new_log=""
            if grep -qiE 'rateLimited|too many certificates' <<<"$new_log" \
                && cert_ok "$dir/fullchain.cer" "$domain" 86400; then
                rm -f "$bak"
                warn "Let's Encrypt упёрся в лимит. Ставлю прежний действующий сертификат — его продлит крон через webroot"
            else
                if mv -f "$bak" "$conf"; then
                    warn "Вернул прежний способ продления: $method"
                else
                    err "Не удалось вернуть конфиг acme.sh — прежний лежит в $bak"
                fi
                return 1
            fi
        elif [[ -f "$conf" ]] && cert_ok "$dir/fullchain.cer" "$domain" 86400; then
            # Продлить не вышло, но прежний сертификат действует — ставим его,
            # крон acme.sh попробует снова.
            warn "Ставлю действующий сертификат acme.sh — продление крон повторит сам"
        else
            return 1
        fi
    fi

    # Кладёт файлы туда, откуда их читает nginx, и запоминает пути и
    # reloadcmd для каждого автопродления из крона acme.sh. reload, а не
    # restart: перезапуск контейнера пересоздаёт сокет и рвёт соединения.
    "$acme" --install-cert -d "$domain" --ecc \
        --key-file       "$SS_DIR/ssl/private.key" \
        --fullchain-file "$SS_DIR/ssl/fullchain.crt" \
        --reloadcmd      "docker exec $SS_CONTAINER nginx -s reload >/dev/null 2>&1 || docker restart $SS_CONTAINER >/dev/null 2>&1 || true" \
        >>"$LOG_FILE" 2>&1 \
        || { err "install-cert не удался, смотрите $LOG_FILE"; return 1; }

    cert_ok "$SS_DIR/ssl/fullchain.crt" "$domain" \
        || { err "Установленный сертификат не подходит к $domain или уже истёк"; return 1; }
    ok "Сертификат для $domain на месте, продление ведёт acme.sh"

    # selfsteal.sh удалял из crontab строку acme.sh --cron и ставил свою
    # обёртку в /opt/nginx-selfsteal — с удалением каталога продление бы
    # встало. --install-cronjob идемпотентен: добавит строку, только если её нет.
    "$acme" --install-cronjob >>"$LOG_FILE" 2>&1 \
        || warn "Не удалось поставить крон acme.sh — сертификат не будет продлеваться сам, смотрите $LOG_FILE"

    # Другие записи acme.sh, которые ставят файлы туда же: сертификат домена
    # до смены на шаге 4 (слушатель на 80 — default_server, так что он
    # продлевался бы и дальше, затирая наш) и RSA-сертификат этого же домена
    # от прежнего установщика. Снимаем их с продления.
    local c rd
    for c in "$HOME"/.acme.sh/*/*.conf; do
        [[ -f "$c" && "$c" != "$conf" && "$c" != *.csr.conf ]] || continue
        if [[ "$(acme_conf_value "$c" Le_RealFullChainPath)" == "$SS_DIR/ssl/fullchain.crt" \
              || "$(acme_conf_value "$c" Le_RealKeyPath)" == "$SS_DIR/ssl/private.key" \
              || "$c" == "$HOME/.acme.sh/$domain/$domain.conf" ]]; then
            rd=$(acme_conf_value "$c" Le_Domain)
            if acme_remove "$acme" "$c"; then
                dim "Сертификат $rd ($(basename "$(dirname "$c")")) снят с автопродления"
            else
                warn "Не удалось снять $c с автопродления — продлеваясь, он может затереть сертификат $domain"
            fi
        fi
    done
    return 0
}

# Конфиг только с портом 80: нужен, пока сертификата нет и основной
# server-блок стартовать не может.
write_acme_only_conf() {
    local domain="$1"
    cat > "$SS_DIR/conf.d/acme-only.conf" <<EOF || { err "Не удалось записать acme-only.conf"; return 1; }
server {
    listen 80 default_server;
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 404; }
}
EOF
}

# Страница-заглушка. Её видит тот, кто пришёл на домен без ключа REALITY.
# Берём стоковую «Welcome to nginx!» из того же образа: её отдают миллионы
# свежих серверов, и ноду по ней не выделить. Прежняя своя заглушка была
# одинаковой на всех установках этим скриптом — по её хешу ноды легко
# собрать в один список.
write_decoy_page() {
    local f="$SS_DIR/html/index.html" cid rc=1
    # Страницу пользователя не трогаем, старую заглушку скрипта заменяем.
    if [[ -s "$f" ]] && ! grep -q 'Service is being set up' "$f"; then
        return 0
    fi
    # Запасной копии страницы в скрипте нет намеренно: она отличалась бы от
    # страницы в запущенном образе (текст меняется между версиями nginx).
    # docker create сам скачает образ; docker cp сохраняет mtime файла из
    # образа, а с ним Last-Modified и ETag, как у настоящего свежего nginx.
    cid=$(docker create "nginx:$SS_NGINX_TAG" 2>>"$LOG_FILE") \
        || { err "Не удалось получить образ nginx:$SS_NGINX_TAG — смотрите $LOG_FILE"; return 1; }
    rm -f "$f.new"
    docker cp "$cid:/usr/share/nginx/html/index.html" "$f.new" >>"$LOG_FILE" 2>&1 \
        && [[ -s "$f.new" ]] && mv "$f.new" "$f" && rc=0
    docker rm -f "$cid" >/dev/null 2>&1 || true
    (( rc == 0 )) || { rm -f "$f.new"; err "Не удалось взять страницу из образа nginx"; return 1; }
}

write_nginx_files() {
    local domain="$1"
    mkdir -p "$SS_DIR/conf.d" "$SS_DIR/html" "$SS_DIR/logs" "$SS_DIR/ssl" \
             "$SS_DIR/acme/.well-known/acme-challenge" \
        || { err "Не удалось создать каталоги в $SS_DIR"; return 1; }

    # Хвосты прерванного выпуска: acme-only.conf рядом с selfsteal.conf дал бы
    # два default_server на 80, и nginx бы не стартовал.
    rm -f "$SS_DIR/conf.d/acme-only.conf" "$SS_DIR/conf.d/selfsteal.conf.pending"

    cat > "$SS_DIR/nginx.conf" <<'EOF' || { err "Не удалось записать $SS_DIR/nginx.conf"; return 1; }
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log crit;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    access_log    off;
    server_tokens off;

    sendfile      on;
    tcp_nopush    on;
    keepalive_timeout 65;
    gzip          on;

    include /etc/nginx/conf.d/*.conf;
}
EOF

    cat > "$SS_DIR/conf.d/selfsteal.conf" <<EOF || { err "Не удалось записать selfsteal.conf"; return 1; }
# Порт 80: ACME-челлендж и редирект. Нужен для выпуска и продления
# сертификата по HTTP-01 — 443 занят Xray, туда acme.sh не попадёт.
server {
    listen 80 default_server;
    server_name $domain;

    location /.well-known/acme-challenge/ {
        root /var/www/acme;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Unix-сокет: сюда REALITY отдаёт трафик, который не принадлежит нашим
# клиентам. TLS терминирует nginx, поэтому ssl здесь обязателен, а
# proxy_protocol — потому что Xray шлёт его при xver: 1.
server {
    listen unix:$SS_SOCKET ssl proxy_protocol;
    http2 on;
    server_name $domain;

    set_real_ip_from unix:;
    real_ip_header proxy_protocol;

    ssl_certificate     /etc/nginx/ssl/fullchain.crt;
    ssl_certificate_key /etc/nginx/ssl/private.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root  /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    write_decoy_page || return 1

    cat > "$SS_DIR/docker-compose.yml" <<EOF || { err "Не удалось записать $SS_DIR/docker-compose.yml"; return 1; }
services:
  nginx:
    image: nginx:$SS_NGINX_TAG
    container_name: $SS_CONTAINER
    restart: unless-stopped
    network_mode: host
    # Сокет живёт в /dev/shm до перезагрузки хоста. После SIGKILL (docker kill,
    # OOM, таймаут docker stop) nginx его не убирает, и следующий старт падает
    # с "Address already in use" — поэтому перед запуском удаляем.
    entrypoint: ["/bin/sh", "-c", "rm -f $SS_SOCKET && exec /docker-entrypoint.sh nginx -g 'daemon off;'"]
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf:ro
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./html:/var/www/html:ro
      - ./acme:/var/www/acme:ro
      - ./ssl:/etc/nginx/ssl:ro
      - ./logs:/var/log/nginx
      # сокет создаётся здесь, а читает его контейнер ноды
      - /dev/shm:/dev/shm
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
    ok "Конфигурация записана в $SS_DIR"
}

ss_compose() {
    docker compose -f "$SS_DIR/docker-compose.yml" --project-directory "$SS_DIR" "$@"
}

step_selfsteal() {
    should_run "selfsteal" "Selfsteal" || return 0
    banner "Шаг 6/10 — Selfsteal (nginx + unix socket)"

    DOMAIN="${DOMAIN:-$(cat "$STATE_DIR/domain" 2>/dev/null || true)}"
    # Без домена шаг 6 невозможен, но пропущенный шаг 4 — осознанный выбор
    # (другой target REALITY), а не ошибка: даём пропустить и этот шаг.
    if [[ -z "$DOMAIN" ]]; then
        warn "Домен не задан (шаг 4 пропущен) — без него selfsteal не настроить."
        ask_yn "  Пропустить шаг 6?" y && { info "Пропускаю."; return 0; }
        err "Сначала пройдите шаг 4 — запустите скрипт снова"
        return 1
    fi
    valid_domain "$DOMAIN" || { err "Домен '$DOMAIN' некорректен — пройдите шаг 4 заново"; return 1; }
    info "Домен: $DOMAIN"

    printf '%snginx поднимается контейнером и слушает unix-сокет. TLS терминирует%s\n' "$C_DIM" "$C_RESET"
    printf '%sон же: REALITY отдаёт ему чужой трафик как есть, при xver: 1.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Настроить selfsteal?" y; then
        info "Пропускаю."; return 0
    fi

    # Прежние установки, которые этот запуск остановил. Если дальше шаг не
    # удастся, сокет останется без слушателя, а REALITY рвёт КАЖДОЕ входящее
    # соединение, когда target недоступен, — нода легла бы целиком. Поэтому
    # без работающего нашего nginx поднимаем прежнюю установку обратно.
    local -a ss_stopped=()
    local rc=0 d
    selfsteal_setup || rc=$?
    if (( ${#ss_stopped[@]} )) && ! container_running "$SS_CONTAINER"; then
        # Наш контейнер мог остаться в цикле перезапусков: он держал бы 80, а
        # его entrypoint удалял бы сокет, который создаст прежний nginx.
        [[ -f "$SS_DIR/docker-compose.yml" ]] && { ss_compose down >>"$LOG_FILE" 2>&1 || true; }
        for d in "${ss_stopped[@]}"; do
            warn "Шаг не завершён — поднимаю обратно прежнюю установку $d, иначе REALITY останется без target"
            if docker compose -f "$d/docker-compose.yml" --project-directory "$d" up -d >>"$LOG_FILE" 2>&1; then
                ok "$d снова работает"
            else
                err "Не удалось поднять $d — нода без REALITY target! Вручную: cd $d && docker compose up -d"
            fi
        done
    fi
    return "$rc"
}

# Тело шага 6. Остановленные прежние установки дописывает в ss_stopped
# вызывающего (step_selfsteal).
selfsteal_setup() {
    have docker || { err "Нужен Docker — пройдите шаг 5"; return 1; }

    # Повторная проверка: DNS мог не успеть распространиться на шаге 4.
    local resolved
    resolved=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1 || true)
    if [[ "$resolved" == "$SERVER_IP" ]]; then
        ok "A-запись корректна ($resolved)"
    else
        err "A-запись сейчас: '${resolved:-нет}', ожидался $SERVER_IP"
        dim "Без неё Let's Encrypt не подтвердит домен."
        ask_yn "  Продолжить?" n || return 0
    fi

    # Установка от внешнего скрипта держит и порт 80, и тот же сокет.
    local old_dir running
    for old_dir in /opt/nginx-selfsteal /opt/caddy; do
        [[ -f "$old_dir/docker-compose.yml" ]] || continue
        # Остановленную прошлым запуском не трогаем — и не поднимаем при неудаче.
        running=$(docker compose -f "$old_dir/docker-compose.yml" --project-directory "$old_dir" \
                  ps -q --status running 2>/dev/null) || running=""
        if [[ -z "$running" ]]; then
            dim "Прежняя установка $old_dir уже остановлена"
            continue
        fi
        warn "Найдена прежняя установка: $old_dir"
        dim "Она занимает порт 80 и тот же сокет — вместе они не уживутся."
        if ask_yn "  Остановить её?" y; then
            docker compose -f "$old_dir/docker-compose.yml" --project-directory "$old_dir" down \
                >>"$LOG_FILE" 2>&1 || true
            ss_stopped+=("$old_dir")
            ok "Прежний контейнер остановлен, файлы в $old_dir не тронуты"
        else
            err "Продолжать без остановки нельзя"
            return 1
        fi
    done

    # Наш же nginx с прошлого запуска держит 80 и сам обслуживает челлендж —
    # это не помеха. Мешает только чужой процесс.
    if port_busy 80 && ! container_running "$SS_CONTAINER"; then
        warn "Порт 80 занят сторонним процессом — ACME-челлендж не пройдёт:"
        ss -tlnp "sport = :80" 2>/dev/null | sed 's/^/    /'
        ask_yn "  Продолжить?" n || return 0
    fi

    prepare_acme || { err "acme.sh не готов"; return 1; }

    write_nginx_files "$DOMAIN" || return 1

    # Без файлов сертификата основной server-блок не стартует: nginx падает
    # на отсутствующем ssl_certificate. Тогда сперва поднимаем только
    # слушатель на 80, выпускаем сертификат, потом включаем всё. Если файлы
    # есть, nginx стартует с ними, а issue_cert всё равно сверит сертификат
    # с доменом и сроком: домен могли сменить на шаге 4.
    local bootstrap=0
    if [[ ! -s "$SS_DIR/ssl/fullchain.crt" || ! -s "$SS_DIR/ssl/private.key" ]]; then
        bootstrap=1
        info "Сертификата нет — временно поднимаю только слушатель на 80"
        mv "$SS_DIR/conf.d/selfsteal.conf" "$SS_DIR/conf.d/selfsteal.conf.pending" \
            && write_acme_only_conf "$DOMAIN" || return 1
    fi
    ss_compose up -d --force-recreate >>"$LOG_FILE" 2>&1 || { err "nginx не поднялся, смотрите $LOG_FILE"; return 1; }
    sleep 2

    local issued=0
    issue_cert "$DOMAIN" && issued=1

    if (( bootstrap )); then
        rm -f "$SS_DIR/conf.d/acme-only.conf"
        mv "$SS_DIR/conf.d/selfsteal.conf.pending" "$SS_DIR/conf.d/selfsteal.conf"
    fi
    if (( ! issued )); then
        err "Сертификат для $DOMAIN не получен"
        # Без сертификата полный конфиг не стартует — не оставляем nginx
        # перезапускаться по кругу.
        (( bootstrap )) && ss_compose down >>"$LOG_FILE" 2>&1
        return 1
    fi

    info "Поднимаю nginx..."
    ss_compose up -d --force-recreate >>"$LOG_FILE" 2>&1 || { err "nginx не поднялся, смотрите $LOG_FILE"; return 1; }
    sleep 2

    # ── Проверки ──────────────────────────────────────────────────────────
    printf '\n'
    if container_running "$SS_CONTAINER"; then
        ok "Контейнер $SS_CONTAINER работает"
    else
        err "Контейнер не поднялся"
        ss_compose logs --tail 30 2>&1 | sed 's/^/    /' || true
        return 1
    fi

    ok "Сертификат: $SS_DIR/ssl/fullchain.crt"
    openssl x509 -in "$SS_DIR/ssl/fullchain.crt" -noout -subject -enddate 2>/dev/null | sed 's/^/    /'

    [[ -S "$SS_SOCKET" ]] && ok "Unix-сокет $SS_SOCKET создан" \
        || err "Сокет $SS_SOCKET отсутствует — REALITY target не заработает"

    grep -q 'proxy_protocol' "$SS_DIR/conf.d/selfsteal.conf" 2>/dev/null \
        && ok "proxy_protocol включён (нужен при xver: 1)" \
        || err "proxy_protocol не найден в конфиге"

    printf '\n%sВ панели у инбаунда REALITY должно стоять:%s\n' "$C_BOLD" "$C_RESET"
    dim "serverNames: [\"$DOMAIN\"]"
    dim "target:      \"$SS_SOCKET\""
    dim "xver:        1"

    state_mark "selfsteal"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 7. WARP, вариант B
# ─────────────────────────────────────────────────────────────────────────────
install_wgcf() {
    # Флага --version у wgcf нет (корневая команда cobra без Version), так
    # что проверяем только наличие бинарника.
    have wgcf && { ok "wgcf уже установлен: $(command -v wgcf)"; return 0; }

    local arch
    case "$(uname -m)" in
        x86_64)  arch=amd64 ;;
        aarch64) arch=arm64 ;;
        *) err "Архитектура $(uname -m) не поддерживается wgcf"; return 1 ;;
    esac

    # Версию берём из API, а если его лимит (60 запросов в час на IP — на
    # общих адресах VPS выбирается быстро) исчерпан, из редиректа
    # releases/latest на страницу тега.
    local ver
    ver=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
          | grep -o '"tag_name": *"[^"]*' | cut -d'"' -f4) || true
    if [[ -z "$ver" ]]; then
        ver=$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
              https://github.com/ViRb3/wgcf/releases/latest 2>/dev/null) || true
        ver="${ver##*/tag/}"
    fi
    [[ "$ver" =~ ^v[0-9][0-9.]*$ ]] || { err "Не удалось узнать версию wgcf (GitHub недоступен?)"; return 1; }

    local tmp
    tmp=$(mktemp -d)
    info "Скачиваю wgcf $ver ($arch)..."
    if ! curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/$ver/wgcf_${ver#v}_linux_$arch" \
         -o "$tmp/wgcf"; then
        rm -rf "$tmp"; err "Не удалось скачать wgcf"; return 1
    fi
    # Пустой или чужой архитектуры файл установится молча и сломается позже,
    # уже на регистрации, где причина будет неочевидна.
    [[ -s "$tmp/wgcf" ]] || { rm -rf "$tmp"; err "Скачанный wgcf пуст"; return 1; }
    chmod +x "$tmp/wgcf"
    # --help печатает справку и выходит с 0. --version тут не годится:
    # такого флага нет, и проверка падала на любом хосте.
    # Запуск из $tmp, чтобы wgcf не подхватил чужой wgcf-account.toml из cwd.
    if ! (cd "$tmp" && ./wgcf --help >/dev/null 2>&1); then
        rm -rf "$tmp"; err "Скачанный wgcf не запускается на этой системе"; return 1
    fi
    install -m 755 "$tmp/wgcf" /usr/local/bin/wgcf || { rm -rf "$tmp"; err "Не удалось установить wgcf"; return 1; }
    rm -rf "$tmp"
    ok "wgcf $ver установлен"
}

# Приводит профиль от wgcf к виду, пригодному для wg-quick в варианте B.
adapt_warp_profile() {
    local f="$1"

    # DNS от Cloudflare нам не нужен: wg-quick прописал бы его системе целиком.
    sed -i '/^DNS =/d' "$f"

    # Главное в варианте B. Без Table = off wg-quick добавит маршрут по
    # умолчанию через WARP, и ВЕСЬ трафик сервера уйдёт в Cloudflare —
    # включая SSH-ответы и связь с панелью. С ним интерфейс просто
    # поднимается, а в туннель попадают только сокеты, привязанные к нему
    # через sockopt.interface.
    #
    # Ставим сразу после [Interface], а не после MTU: строки MTU в профиле
    # может не оказаться (другой формат, чужой профиль). Прежние Table
    # убираем — wg-quick берёт последнее значение, и Table = auto ниже
    # перекрыл бы наше.
    sed -i -E '/^[[:space:]]*Table[[:space:]]*=/d' "$f"
    sed -i '/^\[Interface\]/a Table = off' "$f"

    grep -q '^PersistentKeepalive' "$f" || sed -i '/^Endpoint =/a PersistentKeepalive = 25' "$f"

    # wgcf пишет IPv4 и IPv6 одной строкой Address. Если IPv6 на хосте
    # выключен, вырезаем только IPv6-токен, не трогая строку целиком.
    if ipv6_disabled; then
        warn "IPv6 на хосте выключен — убираю IPv6 из профиля"
        sed -i -E 's#,[[:space:]]*[0-9A-Fa-f:]+/128##g' "$f"
        sed -i -E '/^AllowedIPs/ s#,[[:space:]]*::/0##' "$f"
    fi
}

# IPv6 выключен целиком (ipv6.disable=1 — тогда нет /proc/net/if_inet6) или
# через sysctl disable_ipv6 — тогда файл на месте, но новый интерфейс warp
# получит disable_ipv6 от default, и wg-quick упадёт на ip -6 address add
# с 'Permission denied'.
ipv6_disabled() {
    [[ -f /proc/net/if_inet6 ]] || return 0
    [[ "$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)" == 1 ]] && return 0
    [[ "$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)" == 1 ]] && return 0
    return 1
}

# Watchdog от wtm.sh (его ставили wtm install-warp и прежние версии этого
# скрипта) перезапускает службу при любом inactive, в том числе после ручного
# stop, и дублировал бы наш. Вызывать до перезапуска службы.
remove_wtm_watchdog() {
    [[ -f /etc/cron.d/wtm-warp-watchdog ]] || return 0
    backup_file /etc/cron.d/wtm-warp-watchdog
    pkill -f /opt/wtm/warp-watchdog.sh 2>/dev/null || true
    rm -f /etc/cron.d/wtm-warp-watchdog /opt/wtm/warp-watchdog.sh /run/wtm-warp-watchdog.stamp
    rmdir /opt/wtm 2>/dev/null || true
    info "Убран watchdog от wtm.sh (/etc/cron.d/wtm-warp-watchdog) — его заменяет наш"
}

install_warp_watchdog() {
    cat > /usr/local/bin/warp-watchdog <<'EOF' || { err "Не удалось записать warp-watchdog"; return 1; }
#!/usr/bin/env bash
# Перезапускает wg-quick@warp, если туннель не работает. Вариант B опирается
# на живой интерфейс: без него sockopt.interface отправит трафик в никуда.
# Создан remnanode-bootstrap.

# Остановленную вручную службу не трогаем: systemctl disable или stop —
# осознанное решение админа. "failed" — не решение, его поднимаем.
systemctl is-enabled --quiet wg-quick@warp || exit 0
[[ "$(systemctl is-active wg-quick@warp)" == inactive ]] && exit 0

reason=""
if ! ip link show warp >/dev/null 2>&1; then
    reason="интерфейс warp отсутствует"
else
    # Частый отказ — интерфейс на месте, а Cloudflare не отвечает. При
    # PersistentKeepalive handshake обновляется каждые ~2 минуты, так что
    # старше 5 минут — туннель мёртв. 0 — handshake ещё не было, ждём.
    hs=$(wg show warp latest-handshakes 2>/dev/null | awk '{print $2; exit}')
    if [[ "$hs" =~ ^[0-9]+$ ]] && (( hs > 0 )); then
        age=$(( $(date +%s) - hs ))
        (( age > 300 )) && reason="handshake с Cloudflare не обновлялся ${age} с"
    fi
fi
[[ -n "$reason" ]] || exit 0
logger -t warp-watchdog "$reason, перезапускаю wg-quick@warp"
systemctl restart wg-quick@warp
EOF
    chmod 755 /usr/local/bin/warp-watchdog
    printf '*/5 * * * * root /usr/local/bin/warp-watchdog\n' > /etc/cron.d/warp-watchdog \
        || { err "Не удалось записать /etc/cron.d/warp-watchdog"; return 1; }
    chmod 644 /etc/cron.d/warp-watchdog
    ok "Watchdog установлен: проверка каждые 5 минут (интерфейс и свежесть handshake)"
}

step_warp() {
    should_run "warp" "WARP" || return 0
    banner "Шаг 7/10 — WARP (вариант B, host-интерфейс)"

    printf '%sВариант B поднимает kernel-интерфейс wg-quick@warp и привязывает%s\n' "$C_DIM" "$C_RESET"
    printf '%sк нему сокеты Xray через sockopt.interface. Быстрее варианта A,%s\n' "$C_DIM" "$C_RESET"
    printf '%sключи WireGuard в конфиг Xray не попадают.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Устанавливать WARP?" y; then
        info "Пропускаю."; return 0
    fi

    local reuse=0
    if [[ -f "$WARP_CONFIG" ]]; then
        ok "Конфигурация WARP уже есть: $WARP_CONFIG"
        ask_yn "  Перерегистрировать аккаунт заново?" n || reuse=1
    fi

    # wireguard-tools, адаптация профиля и watchdog нужны и при повторном
    # запуске: профиль мог остаться от wtm.sh или от прошлого прогона,
    # упавшего сразу после его записи.
    info "Ставлю wireguard-tools..."
    apt_install wireguard-tools \
        || { err "Не удалось поставить wireguard-tools, смотрите $LOG_FILE"; return 1; }

    if (( reuse )); then
        info "Привожу существующий профиль к варианту B..."
        backup_file "$WARP_CONFIG"
        adapt_warp_profile "$WARP_CONFIG"
    else
        install_wgcf || return 1

        local tmp
        tmp=$(mktemp -d) || { err "mktemp не отработал"; return 1; }
        info "Регистрирую аккаунт WARP..."
        # Современный wgcf требует явного согласия с условиями: старое
        # `yes | wgcf register` больше не проходит.
        if ! (cd "$tmp" && wgcf register --accept-tos >>"$LOG_FILE" 2>&1); then
            rm -rf "$tmp"
            err "Регистрация в Cloudflare не удалась, смотрите $LOG_FILE"
            dim "Часть дата-центров заблокирована на стороне Cloudflare."
            return 1
        fi
        ok "Аккаунт зарегистрирован"

        if ! (cd "$tmp" && wgcf generate >>"$LOG_FILE" 2>&1); then
            rm -rf "$tmp"; err "wgcf generate не отработал"; return 1
        fi
        [[ -f "$tmp/wgcf-profile.conf" ]] || { rm -rf "$tmp"; err "Профиль не создан"; return 1; }

        adapt_warp_profile "$tmp/wgcf-profile.conf"

        mkdir -p /etc/wireguard
        backup_file "$WARP_CONFIG"
        if ! install -m 600 "$tmp/wgcf-profile.conf" "$WARP_CONFIG"; then
            rm -rf "$tmp"; err "Не удалось записать $WARP_CONFIG"; return 1
        fi
        # В прежнем аккаунте device_id, access_token и, возможно, ключ WARP+ —
        # без них старым устройством через wgcf уже не управлять.
        backup_file "$WARP_ACCOUNT"
        install -m 600 "$tmp/wgcf-account.toml" "$WARP_ACCOUNT" 2>/dev/null || true
        rm -rf "$tmp"
        ok "Профиль установлен: $WARP_CONFIG"
    fi

    # Без Table = off служба увела бы в WARP весь трафик сервера вместе с
    # этой SSH-сессией — такой профиль не запускаем.
    if ! grep -q '^Table = off' "$WARP_CONFIG"; then
        err "В профиле нет Table = off — не запускаю: весь трафик сервера ушёл бы в WARP"
        return 1
    fi
    ok "Table = off — маршрут по умолчанию остаётся прежним"

    remove_wtm_watchdog

    # restart, а не enable --now: уже запущенную службу --now не трогает,
    # и после перерегистрации интерфейс жил бы со старыми ключами.
    info "Запускаю wg-quick@warp..."
    if systemctl enable wg-quick@warp >>"$LOG_FILE" 2>&1 \
        && systemctl restart wg-quick@warp >>"$LOG_FILE" 2>&1; then
        ok "Служба запущена"
    else
        err "wg-quick@warp не запустился"
        journalctl -u wg-quick@warp -n 20 --no-pager 2>/dev/null | sed 's/^/    /' || true
        return 1
    fi

    install_warp_watchdog || return 1
    verify_warp || return 1
    state_mark "warp"
}

verify_warp() {
    printf '\n'
    if ip -br a show warp >/dev/null 2>&1; then
        ok "Интерфейс warp поднят:"
        ip -br a show warp | sed 's/^/    /'
    else
        err "Интерфейс warp не найден — вариант B работать не будет"
        dim "Диагностика: journalctl -u wg-quick@warp -n 30"
        return 1
    fi

    # Без Table = off wg-quick не трогает main-таблицу: он добавляет правило
    # по fwmark и свою таблицу 51820, и `ip route show default` по-прежнему
    # показывает eth0. Поэтому спрашиваем ядро, куда уйдёт обычный пакет.
    local dev
    dev=$(ip route get 1.1.1.1 2>/dev/null | grep -o 'dev [^ ]*' | awk '{print $2; exit}') || true
    if [[ "$dev" == "warp" ]]; then
        err "Обычный трафик сервера уходит в warp — в варианте B так быть не должно"
        dim "Проверьте Table = off в $WARP_CONFIG и вывод ip rule"
        return 1
    fi
    ok "Обычный трафик идёт мимо WARP, через ${dev:-?}"

    local trace
    trace=$(curl --interface warp -sS --max-time 12 \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=' || true)
    if [[ "$trace" == "warp=on" ]]; then
        ok "Трафик через интерфейс warp реально идёт в Cloudflare (warp=on)"
    else
        warn "Проверка через интерфейс вернула: '${trace:-пусто}'"
        dim "Диагностика: systemctl status wg-quick@warp"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 8. Файрвол
# ─────────────────────────────────────────────────────────────────────────────

# Порты, на которых реально слушает SSH, — закрыться от себя нельзя.
# Под socket-активацией (Ubuntu 24.04) слушает systemd, и Port/ListenAddress
# из конфига не действуют: порт задаёт ssh.socket (его меняют через
# systemctl edit). Иначе — listenaddress из sshd -T: в нём уже итоговый
# порт, и из Port, и из ListenAddress host:port, который Port не перекрывает.
# Плюс порт, на который пришла текущая сессия. Пусто — ошибка, а не «22».
ssh_ports() {
    local out ports="" c="${SSH_CONNECTION:-}"
    if systemctl is-active --quiet ssh.socket 2>/dev/null; then
        ports=$(systemctl show -p Listen --value ssh.socket 2>/dev/null \
            | awk '$2=="(Stream)"{n=split($1,a,":"); print a[n]}') || ports=""
    fi
    if out=$(sshd_dump) && [[ -n "$out" ]]; then
        ports+=$'\n'$(awk '$1=="listenaddress"{n=split($2,a,":"); print a[n]}' <<<"$out")
    fi
    [[ -n "$c" ]] && ports+=$'\n'"${c##* }"
    ports=$(grep -E '^[0-9]+$' <<<"$ports" | sort -un) || ports=""
    [[ -n "$ports" ]] || return 1
    printf '%s\n' "$ports"
}

# Порт API ноды из .env. Новое имя NODE_PORT, старое APP_PORT.
node_port() {
    local env=/opt/remnanode/.env p=""
    [[ -f "$env" ]] || return 1
    p=$(grep -m1 -E '^[[:space:]]*(NODE_PORT|APP_PORT)=' "$env" \
        | cut -d= -f2- | tr -d '"'\''[:space:]')
    [[ "$p" =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$p"
}

# Есть ли правило, разрешающее указанный TCP-порт.
# У выключенного ufw `status` печатает только "Status: inactive" и правил
# не показывает вообще — добавленные, но не применённые лежат в `show added`.
# Поэтому смотрим оба места: до включения работает первое, после — второе.
ssh_rule_present() {
    local port="$1" out
    # Вывод в переменную: grep -q в пайпе под pipefail может «не найти» найденное.
    out=$(ufw show added 2>/dev/null) || out=""
    grep -qE "allow[[:space:]]+(in[[:space:]]+)?${port}/tcp" <<<"$out" && return 0
    out=$(ufw status 2>/dev/null) || out=""
    grep -qE "^${port}/tcp" <<<"$out"
}

# Контейнеры с опубликованными наружу портами. Docker пишет свои правила
# в цепочку DOCKER-USER, минуя ufw, поэтому такие порты остаются открытыми
# даже при deny incoming — про них надо предупредить отдельно.
docker_published() {
    have docker || return 0
    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
        | grep -E '0\.0\.0\.0:|\[::\]:' || true
}

# Пропускает ли tailscaled трафик тейлнета сам, мимо ufw. В режиме по
# умолчанию (--netfilter-mode=on) он ставит переход в цепочку ts-input
# первым правилом INPUT в таблице filter — той же, что у ufw через
# iptables-nft, — а в ts-input лежат `-i tailscale0 -j ACCEPT` и
# `-p udp --dport 41641 -j ACCEPT`. ufw запрещает трафик политикой цепочки,
# а не явным DROP, поэтому эти ACCEPT срабатывают при любом порядке правил.
tailscale_owns_input() {
    iptables -C INPUT -j ts-input 2>/dev/null && return 0
    have nft && nft list chain ip filter INPUT 2>/dev/null | grep -q 'jump ts-input'
}

is_tailnet_or_local() {
    local ip="$1" a b
    case "$ip" in
        127.*|::1|fd7a:115c:a1e0:*) return 0 ;;
    esac
    IFS=. read -r a b _ <<<"$ip"
    [[ "$a" == 100 && "$b" =~ ^[0-9]+$ ]] && (( b >= 64 && b <= 127 ))
}

# Адреса, с которых сейчас установлены соединения на порт ноды, кроме
# тейлнета (100.64.0.0/10, fd7a:115c:a1e0::/48) и loopback. Обычно это панель.
node_peers_outside_tailnet() {
    local port="$1" peer ip
    ss -Htn state established "( sport = :$port )" 2>/dev/null | awk '{print $4}' \
        | while read -r peer; do
            ip="${peer%:*}"; ip="${ip#[}"; ip="${ip%]}"; ip="${ip#::ffff:}"
            is_tailnet_or_local "$ip" || printf '%s\n' "$ip"
        done | sort -u
}

step_firewall() {
    should_run "firewall" "Файрвол" || return 0
    banner "Шаг 8/10 — Файрвол (ufw)"

    printf '%sНаружу открываются только 22, 80 и 443. Порт ноды доступен%s\n' "$C_DIM" "$C_RESET"
    printf '%sтолько из тейлнета, снаружи закрыт. Всё исходящее разрешено.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Настроить ufw?" y; then
        info "Пропускаю."; return 0
    fi

    if have ufw; then
        ok "ufw уже установлен"
    else
        info "Ставлю ufw..."
        apt_install ufw || { err "Не удалось поставить ufw, смотрите $LOG_FILE"; return 1; }
        ok "ufw установлен"
    fi

    # ── Собираем список портов ────────────────────────────────────────────
    local sshp
    sshp=$(ssh_ports | tr '\n' ' ') || sshp=""
    sshp="${sshp% }"
    if [[ -z "$sshp" ]]; then
        warn "Не удалось определить порт SSH: sshd -T не отработал, ssh.socket не активен"
        ask_var sshp "Порт SSH, который открыть в ufw:" ""
        [[ "$sshp" =~ ^[0-9]+$ ]] || { err "Без порта SSH ufw не включаю"; return 1; }
    fi
    ok "SSH слушает порт(ы): $sshp"

    local nodep=""
    if nodep=$(node_port); then
        ok "Порт ноды из /opt/remnanode/.env: $nodep"
    else
        warn "Не удалось прочитать порт ноды из /opt/remnanode/.env"
        ask_var nodep "Порт API ноды (Enter — пропустить правило для тейлнета):" ""
        [[ "$nodep" =~ ^[0-9]+$ ]] || nodep=""
    fi

    # tailscaled создаёт tailscale0 при старте, ещё до авторизации, так что
    # интерфейс — не признак работающего тейлнета.
    local ts_if=""
    if ip link show tailscale0 >/dev/null 2>&1; then
        ts_if="tailscale0"
        if tailscale status >/dev/null 2>&1; then
            ok "Тейлнет подключён: $(tailscale ip -4 2>/dev/null | head -1)"
        else
            warn "tailscale0 есть, но Tailscale не подключён — доделайте: tailscale up --ssh"
            if [[ -n "$nodep" ]]; then
                err "Пока Tailscale не подключён, порт ноды $nodep закрыт для всех, включая панель."
                ask_yn "  Всё равно продолжить?" n || return 0
            fi
        fi
    else
        warn "Интерфейс tailscale0 не найден — правил для тейлнета не будет"
        if [[ -n "$nodep" ]]; then
            err "Порт ноды $nodep останется закрытым для всех, включая панель."
            ask_yn "  Всё равно продолжить?" n || return 0
        fi
    fi

    # ── Откуда к ноде ходит панель ────────────────────────────────────────
    # Порт ноды останется открыт только на tailscale0. Если панель сейчас
    # подключена по публичному адресу, после ufw enable нода молча уйдёт
    # в офлайн.
    if [[ -n "$nodep" ]]; then
        local outside
        outside=$(node_peers_outside_tailnet "$nodep")
        if [[ -n "$outside" ]]; then
            warn "К порту ноды $nodep сейчас подключены не из тейлнета:"
            printf '%s\n' "$outside" | sed 's/^/    /'
            dim "Скорее всего это панель. После включения ufw она потеряет связь с нодой."
            dim "Укажите в панели адрес ноды из тейлнета (tailscale ip -4) и запустите шаг снова."
            ask_yn "  Всё равно продолжить?" n || return 0
        fi
    fi

    # ── Tailscale и ufw ───────────────────────────────────────────────────
    local ts_open=0
    if [[ -n "$ts_if" ]] && tailscale_owns_input; then
        ts_open=1
        printf '\n'
        warn "tailscaled сам пропускает весь входящий трафик тейлнета и 41641/udp — раньше правил ufw."
        dim "Ограничить устройства тейлнета одним портом ufw здесь не может: это делается"
        dim "ACL в админке Tailscale — https://login.tailscale.com/admin/acls"
        dim "Правила ufw для tailscale0 ниже всё равно добавятся — на случай --netfilter-mode=off."
    fi

    # ── Область правила для тейлнета ──────────────────────────────────────
    local ts_wide="n"
    if [[ -n "$ts_if" ]] && (( ! ts_open )); then
        printf '\n%sДоступ из тейлнета можно открыть двумя способами:%s\n' "$C_DIM" "$C_RESET"
        dim "  узко — только порт ноды${nodep:+ ($nodep)}; всё остальное закрыто и внутри тейлнета"
        dim "  широко — любой порт этого сервера доступен вашим устройствам в тейлнете"
        ask_yn "Открыть тейлнету весь интерфейс (широко)?" n && ts_wide="y"
    fi

    # ── Входящий 41641/udp ────────────────────────────────────────────────
    local ts_udp="n"
    if [[ -n "$ts_if" ]] && (( ts_open )); then
        ts_udp="y"   # tailscaled его уже открыл; правило ufw — на случай --netfilter-mode=off
    elif [[ -n "$ts_if" ]]; then
        printf '\n%sTailscale слушает UDP 41641 для прямых соединений между пирами.%s\n' "$C_DIM" "$C_RESET"
        dim "Закрыть можно: связь сохранится, но при неудачной пробивке NAT"
        dim "трафик пойдёт через DERP-релеи — лишняя задержка и чужой сервер в пути."
        dim "Риска в открытом порте нет: там WireGuard, чужой пакет отбрасывается."
        ask_yn "Разрешить входящий 41641/udp?" y && ts_udp="y"
    fi

    # ── План ──────────────────────────────────────────────────────────────
    printf '\n%sБудут применены правила:%s\n' "$C_BOLD" "$C_RESET"
    dim "default deny incoming / allow outgoing"
    local p
    for p in $sshp; do dim "allow $p/tcp                      (SSH)"; done
    dim "allow 80/tcp                       (HTTP-01: выпуск и продление сертификата)"
    dim "allow 443/tcp                      (VLESS REALITY, selfsteal)"
    if [[ -n "$ts_if" ]]; then
        if [[ "$ts_wide" == "y" ]]; then
            dim "allow in on tailscale0             (весь тейлнет)"
        elif [[ -n "$nodep" ]]; then
            dim "allow in on tailscale0 port $nodep    (только API ноды)"
        fi
        [[ "$ts_udp" == "y" ]] && dim "allow 41641/udp                    (прямые соединения Tailscale)"
        (( ts_open )) && dim "(сейчас tailscaled и так пропускает тейлнет целиком, см. выше)"
    fi
    printf '\n'

    warn "Вы сейчас подключены по SSH. Правило для порта $sshp добавляется ДО включения."
    ask_yn "Применить?" y || { info "Отменено."; return 0; }

    # ── Применение ────────────────────────────────────────────────────────
    # Порядок важен: сначала SSH, потом всё остальное, включение — последним.
    for p in $sshp; do
        ufw allow "$p"/tcp comment 'ssh' >/dev/null || { err "Не удалось добавить правило для SSH — не включаю ufw"; return 1; }
    done
    ok "SSH разрешён: $sshp"

    { ufw default deny incoming  >/dev/null \
        && ufw default allow outgoing >/dev/null \
        && ufw allow 80/tcp  comment 'http acme'   >/dev/null \
        && ufw allow 443/tcp comment 'vless reality' >/dev/null; } \
        || { err "Не удалось задать базовые правила ufw — не включаю"; return 1; }
    ok "Открыты 80 и 443"

    if [[ -n "$ts_if" ]]; then
        if [[ "$ts_wide" == "y" ]]; then
            ufw allow in on "$ts_if" comment 'tailnet' >/dev/null
            ok "Тейлнету открыт весь интерфейс"
        elif [[ -n "$nodep" ]]; then
            ufw allow in on "$ts_if" to any port "$nodep" proto tcp comment 'remnanode api' >/dev/null
            ok "Порт ноды $nodep открыт только на tailscale0"
        fi
        if [[ "$ts_udp" == "y" ]]; then
            ufw allow 41641/udp comment 'tailscale direct' >/dev/null
            ok "Разрешён входящий 41641/udp"
        fi
    fi

    # Проверяем, что правило для SSH действительно есть — для каждого порта.
    # Без него включение ufw запирает нас снаружи.
    local sp
    for sp in $sshp; do
        if ! ssh_rule_present "$sp"; then
            err "Правило для SSH-порта $sp не найдено — НЕ включаю ufw"
            ufw show added 2>/dev/null | sed 's/^/    /'
            return 1
        fi
    done
    ok "Правило для SSH на месте"

    ufw --force enable >/dev/null || { err "ufw enable вернул ошибку"; return 1; }
    ok "ufw включён"

    # После включения правило обязано быть видно уже в status. Если его нет —
    # выключаем немедленно, пока текущая сессия жива: established-соединения
    # ufw пропускает, но новый вход был бы невозможен.
    local st
    st=$(ufw status 2>/dev/null) || st=""
    for sp in $sshp; do
        if ! grep -qE "^$sp/tcp" <<<"$st"; then
            err "После включения правило для SSH-порта $sp не видно в ufw status — выключаю ufw обратно"
            ufw disable >/dev/null 2>&1 || true
            ufw status | sed 's/^/    /'
            return 1
        fi
    done

    # ── Проверка результата ───────────────────────────────────────────────
    printf '\n'
    info "Итоговые правила:"
    ufw status verbose | sed 's/^/    /'

    printf '\n'
    # || true обязателен: grep -m1 закрывает пайп, ufw ловит SIGPIPE,
    # pipefail превращает это в ошибку присваивания и роняет скрипт.
    local policy; policy=$(ufw status verbose | grep -m1 '^Default:' || true)
    [[ "$policy" == *"deny (incoming)"* ]] \
        && ok "Политика по умолчанию: входящие запрещены" \
        || err "Политика по умолчанию не deny incoming: $policy"

    if [[ -n "$nodep" ]]; then
        # Правило порта ноды обязано быть привязано к интерфейсу. Строка
        # без "on tailscale0" означает, что порт открыт всему интернету.
        local node_rules
        node_rules=$(ufw status 2>/dev/null | grep -E "(^|[[:space:]])$nodep(/tcp)?[[:space:]]") || node_rules=""
        if grep -qv 'on tailscale0' <<<"$node_rules" && [[ -n "$node_rules" ]]; then
            err "Порт ноды $nodep разрешён не только на tailscale0 — проверьте вывод выше"
            printf '%s\n' "$node_rules" | sed 's/^/    /'
        else
            ok "Порт ноды $nodep снаружи закрыт"
        fi
    fi

    local pub; pub=$(docker_published)
    if [[ -n "$pub" ]]; then
        warn "Есть контейнеры с опубликованными портами:"
        printf '%s\n' "$pub" | sed 's/^/    /'
        dim "Docker пишет правила в цепочку DOCKER-USER, минуя ufw — такие порты"
        dim "остаются открытыми снаружи даже при deny incoming. Для ноды это не"
        dim "проблема, пока контейнер в network_mode: host."
    else
        ok "Контейнеров с опубликованными наружу портами нет"
    fi

    printf '\n'
    warn "Проверьте вход по SSH из нового окна, не закрывая эту сессию."
    dim "Снаружи убедиться, что порт ноды закрыт: nmap -Pn -p $nodep <IP сервера>"
    dim "Откатить всё: ufw disable"
    pause

    state_mark "firewall"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 9. BBR
# ─────────────────────────────────────────────────────────────────────────────
step_bbr() {
    should_run "bbr" "BBR + fq" || return 0
    banner "Шаг 9/10 — BBR + fq"

    printf '%sBBR меняет алгоритм контроля перегрузки TCP, fq — дисциплину очереди.%s\n' "$C_DIM" "$C_RESET"
    printf '%sНа отдачу через VPN влияет заметно, но требует поддержки в ядре.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Включить BBR + fq?" y; then
        info "Пропускаю."; return 0
    fi

    # tcp_available_congestion_control перечисляет только ЗАГРУЖЕННЫЕ
    # алгоритмы. В Debian и Ubuntu tcp_bbr собран модулем
    # (CONFIG_TCP_CONG_BBR=m) и сам не подгружается, поэтому до modprobe
    # список выглядит как «reno cubic» даже там, где BBR прекрасно есть.
    local avail=/proc/sys/net/ipv4/tcp_available_congestion_control
    if ! grep -qw bbr "$avail" 2>/dev/null; then
        info "Подгружаю модуль tcp_bbr..."
        modprobe tcp_bbr 2>/dev/null || true
    fi
    if ! grep -qw bbr "$avail" 2>/dev/null; then
        warn "BBR недоступен: модуль tcp_bbr не загрузился"
        dim "Ядро: $(uname -r)"
        dim "Проверьте: grep TCP_CONG_BBR /boot/config-\$(uname -r)"
        dim "  =m — модуль есть, но не загружается; =y — встроен; нет строки — не собран"
        return 0
    fi
    ok "BBR доступен ядру"

    # Чтобы модуль был на месте и после перезагрузки, до применения sysctl.
    echo tcp_bbr > /etc/modules-load.d/bbr.conf

    cat > /etc/sysctl.d/99-bbr.conf <<'EOF' || { err "Не удалось записать /etc/sysctl.d/99-bbr.conf"; return 1; }
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    # Только свой файл: sysctl --system возвращает ошибку, если не применился
    # хоть один ключ из любого файла системы (устаревший tcp_tw_recycle в
    # sysctl.conf, read-only ключи в LXC/OpenVZ), и под set -e это обрывало
    # весь скрипт. Что применилось на самом деле — проверяем ниже.
    sysctl -p /etc/sysctl.d/99-bbr.conf >>"$LOG_FILE" 2>&1 \
        || warn "Не все ключи применились (в LXC/OpenVZ default_qdisc обычно read-only), подробности в $LOG_FILE"

    local cc qd
    cc=$(sysctl -n net.ipv4.tcp_congestion_control)
    qd=$(sysctl -n net.core.default_qdisc)
    [[ "$cc" == "bbr" ]] && ok "tcp_congestion_control = bbr" || warn "BBR не применился: $cc"
    [[ "$qd" == "fq"  ]] && ok "default_qdisc = fq"          || warn "fq не применился: $qd"

    # default_qdisc действует на интерфейсы при их создании, поэтому на уже
    # поднятом останется прежний fq_codel до перезагрузки. Меняем на месте.
    local dev
    dev=$(ip route show default | awk '{print $5; exit}')
    if [[ -n "$dev" ]]; then
        local root_kind parent qd_ok=1
        root_kind=$(tc qdisc show dev "$dev" 2>/dev/null | awk '/ root /{print $2; exit}')
        if [[ "$root_kind" == mq ]]; then
            # Многоочередная карта (virtio-net с несколькими очередями): под mq
            # свой qdisc на каждую очередь. Меняем их, а не корень — fq в корне
            # свёл бы весь трафик в одну очередь. У mq, поставленного ядром,
            # handle 0, а по parent :N дочерние не адресуются (ядро не ищет
            # qdisc с handle 0). Поэтому сначала даём mq handle 1: — дочерние
            # при этом пересоздаются из default_qdisc, уже fq, — а затем
            # явно ставим fq на 1:N на случай, если default_qdisc не применился.
            tc qdisc replace dev "$dev" root handle 1: mq 2>/dev/null || qd_ok=0
            for parent in $(tc qdisc show dev "$dev" 2>/dev/null \
                    | awk '{for (i = 1; i < NF; i++) if ($i == "parent") print $(i + 1)}'); do
                tc qdisc replace dev "$dev" parent "$parent" fq 2>/dev/null || qd_ok=0
            done
        else
            tc qdisc replace dev "$dev" root fq 2>/dev/null || qd_ok=0
        fi
        if (( qd_ok )); then
            ok "На $dev применён fq без перезагрузки"
        else
            warn "Не удалось сменить qdisc на $dev — fq вступит в силу после перезагрузки"
        fi
        dim "Сейчас: $(tc qdisc show dev "$dev" 2>/dev/null | awk '{print $2}' | sort | uniq -c | xargs)"
    fi

    dim "Проверить на живых соединениях: ss -tin | grep -c bbr"

    state_mark "bbr"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 10. Инбаунд XHTTP
# ─────────────────────────────────────────────────────────────────────────────
step_xhttp() {
    should_run "xhttp" "Инбаунд XHTTP" || return 0
    banner "Шаг 10/10 — Инбаунд VLESS XHTTP поверх REALITY"

    DOMAIN="${DOMAIN:-$(cat "$STATE_DIR/domain" 2>/dev/null || true)}"

    printf '%sXHTTP добавляется вторым инбаундом рядом с уже работающим REALITY.%s\n' "$C_DIM" "$C_RESET"
    printf '%sОн слушает абстрактный unix-сокет, TCP-порт не занимает и nginx%s\n' "$C_DIM" "$C_RESET"
    printf '%sне задействует: трафик приходит к нему через fallback.%s\n\n' "$C_DIM" "$C_RESET"
    dim "При network_mode: host абстрактный сокет виден всему хосту, а прав доступа"
    dim "у таких сокетов нет. Чужих он всё равно не пустит: VLESS проверяет UUID."
    printf '\n'

    if ! ask_yn "Сгенерировать конфигурацию XHTTP?" y; then
        info "Пропускаю."; return 0
    fi

    local path tag sock="@xhttp"
    # Путь не секрет, но угадываемый путь упрощает активное прощупывание.
    path=$(openssl rand -hex 8 2>/dev/null) || path=$(head -c8 /dev/urandom | od -An -tx1 | tr -d ' \n')
    ask_var path "Путь XHTTP (без ведущего слэша):" "$path"
    path="${path#/}"
    ask_var tag "Тег инбаунда:" "VLESS-XHTTP"

    local out="$STATE_DIR/xhttp-inbound.json"
    cat > "$out" <<EOF
{
  "tag": "$tag",
  "listen": "$sock",
  "protocol": "vless",
  "settings": {
    "decryption": "none",
    "clients": []
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {
      "path": "/$path"
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls", "quic"]
  }
}
EOF
    ok "Инбаунд записан: $out"

    hr
    printf '%s1. Добавьте этот инбаунд в конфиг Xray в панели:%s\n\n' "$C_BOLD" "$C_RESET"
    sed 's/^/    /' "$out"

    printf '\n%s2. В уже существующем инбаунде REALITY на 443 добавьте fallback:%s\n\n' "$C_BOLD" "$C_RESET"
    cat <<EOF
    "settings": {
      "decryption": "none",
      "clients": [ ... оставьте как есть ... ],
      "fallbacks": [
        { "dest": "$sock" }
      ]
    }
EOF
    hr

    printf '\n%sПочему fallback без "path"%s\n' "$C_BOLD" "$C_RESET"
    dim "Разбор по path на xhttp работает некорректно (Xray-core #4832)."
    dim "Поэтому fallback один и без условий: XHTTP-инбаунд сам сверяет путь"
    dim "и отвергает чужие запросы. Это схема из официального примера"
    dim "VLESS-XHTTP-REALITY/steal_oneself."

    printf '\n%sЧто остаётся без изменений%s\n' "$C_BOLD" "$C_RESET"
    dim "realitySettings.target — по-прежнему $SS_SOCKET, xver: 1."
    dim "Непрошедший проверку REALITY трафик как и раньше уходит в nginx."
    dim "Конфигурация nginx не меняется, порт не добавляется."

    if [[ -n "$DOMAIN" ]] && valid_domain "$DOMAIN"; then
        printf '\n%sКлиентская ссылка соберётся в панели сама. Её узнаваемые части:%s\n' "$C_DIM" "$C_RESET"
        dim "type=xhttp  mode=stream-up  path=/$path  security=reality  sni=$DOMAIN"
    fi

    printf '\n'
    warn "Панель пересоберёт конфиг и перезапустит Xray на ноде."
    dim "Проверить после применения: rn logs -f"

    state_mark "xhttp"
}


# ─────────────────────────────────────────────────────────────────────────────
# Итог
# ─────────────────────────────────────────────────────────────────────────────
summary() {
    banner "Готово"

    printf '%sЧто сделано:%s\n' "$C_BOLD" "$C_RESET"
    local k
    for k in system ssh tailscale dns remnanode selfsteal warp firewall bbr xhttp; do
        if step_failed "$k"; then
            printf '  %s✗%s %s %s(ошибка в этом запуске — подробности выше и в логе)%s\n' \
                "$C_RED" "$C_RESET" "$k" "$C_DIM" "$C_RESET"
        elif state_done "$k"; then
            printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$k"
        else
            printf '  %s·%s %s %s(пропущено)%s\n' "$C_DIM" "$C_RESET" "$k" "$C_DIM" "$C_RESET"
        fi
    done
    if ((${#FAILED_STEPS[@]})); then
        printf '\n'
        warn "Не завершены шаги: ${FAILED_STEPS[*]}. Исправьте причину и запустите скрипт снова —"
        dim "пройденные шаги он предложит пропустить."
    fi

    printf '\n%sОсталось сделать вручную — в панели Remnawave:%s\n' "$C_BOLD" "$C_RESET"
    printf '\n1. Добавьте ноду, если ещё не добавлена, и убедитесь, что она online.\n'
    printf '2. В конфиг Xray добавьте outbound warp (вариант B):\n\n'

    cat <<'JSON'
    {
      "tag": "warp",
      "protocol": "freedom",
      "settings": { "domainStrategy": "UseIPv4" },
      "streamSettings": {
        "sockopt": { "interface": "warp", "tcpFastOpen": true }
      }
    }
JSON

    printf '\n3. Порядок outbounds важен: первый элемент — маршрут по умолчанию.\n'
    printf '   Держите DIRECT первым, warp — ниже.\n'
    printf '4. Теги в правилах routing должны совпадать посимвольно с тегами outbounds.\n'

    printf '\n%sПолезные команды:%s\n' "$C_BOLD" "$C_RESET"
    dim "rn ps                       — состояние ноды"
    dim "rn logs -f                  — логи контейнера"
    dim "rn restart                  — перезапуск ноды"
    dim "warp-watchdog               — поднять warp, если упал"
    dim "systemctl status wg-quick@warp"
    dim "sshd -T -C $SSHD_TEST_SPEC,lport=22 | grep -iE 'password|kbdinteractive|permitroot'"
    dim "                            — пароль для root с учётом Match-блоков"
    dim "curl --interface warp https://www.cloudflare.com/cdn-cgi/trace"

    printf '\n%sЛог установки: %s%s\n' "$C_DIM" "$LOG_FILE" "$C_RESET"
    printf '%sБэкапы конфигов: %s%s\n\n' "$C_DIM" "$BACKUP_DIR" "$C_RESET"
}

# ─────────────────────────────────────────────────────────────────────────────
# main
# ─────────────────────────────────────────────────────────────────────────────
main() {
    clear 2>/dev/null || true
    printf '\n%s%s  remnanode-bootstrap v%s%s\n' "$C_BOLD" "$C_CYAN" "$BOOTSTRAP_VERSION" "$C_RESET"
    printf '%s  Интерактивная установка Remnawave-ноды%s\n' "$C_DIM" "$C_RESET"

    preflight

    printf '\n%sБудут выполнены 10 шагов. Каждый можно пропустить.%s\n' "$C_DIM" "$C_RESET"
    ask_yn "Начинаем?" y || { info "Отменено."; exit 0; }

    # Через run_step: неудача одного шага не отменяет остальные. Раньше
    # return 1, например, из шага WARP обрывал скрипт до файрвола.
    run_step system    step_system
    run_step ssh       step_ssh
    run_step tailscale step_tailscale
    run_step dns       step_dns
    run_step remnanode step_remnanode
    run_step selfsteal step_selfsteal
    run_step warp      step_warp
    run_step firewall  step_firewall
    run_step bbr       step_bbr
    run_step xhttp     step_xhttp
    summary

    ((${#FAILED_STEPS[@]} == 0)) || exit 1
}

# Без терминала (ssh host 'cmd' без -t, cloud-init, cron) каждый read из
# /dev/tty падает: вопросы молча получали ответ по умолчанию — скрипт ставил
# пакеты и Tailscale без спроса, — а циклы ввода крутились бесконечно.
if ! { : </dev/tty; } 2>/dev/null; then
    err "Нет терминала: скрипт интерактивный. Подключитесь с ssh -t или из обычной SSH-сессии."
    exit 1
fi

# stdin для всего скрипта и дочерних процессов — терминал. Иначе при запуске
# через пайп (curl | bash) apt или dpkg могли бы прочитать из stdin кусок
# текста самого скрипта.
main "$@" </dev/tty
