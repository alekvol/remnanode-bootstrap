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
#
# Запуск от root, одной командой:
#   bash <(curl -fsSL https://raw.githubusercontent.com/alekvol/remnanode-bootstrap/main/bootstrap.sh)
#
# Через пайп (curl | bash) запускать нельзя: bash займёт stdin текстом самого
# скрипта, и вложенным установщикам не останется канала для диалога.
#
set -Eeuo pipefail

# Не VERSION: это имя занимает /etc/os-release, который мы сорсим в preflight.
readonly BOOTSTRAP_VERSION="1.3.0"
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

readonly R_WTM="https://github.com/DigneZzZ/remnawave-scripts/raw/main/wtm.sh"

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

# Лог не должен ронять вызывающего: до проверки на root файл в /var/log
# недоступен на запись, а err() вызывается как раз в этот момент.
log()      { printf '%s\n' "$*" >>"$LOG_FILE" 2>/dev/null || true; }
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

# Возвращает 0, если шаг нужно выполнять
should_run() {
    local key="$1" title="$2"
    if state_done "$key"; then
        info "$title — уже выполнено ранее."
        ask_yn "  Выполнить заново?" n || return 1
    fi
    return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# Утилиты
# ─────────────────────────────────────────────────────────────────────────────
have() { command -v "$1" >/dev/null 2>&1; }

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

# Запуск внешнего скрипта. Пайп не используем: скриптам нужен stdin для диалога.
run_remote() {
    local url="$1"; shift
    local tmp; tmp=$(mktemp /tmp/rb-XXXXXX.sh)
    info "Скачиваю $url"
    curl -fsSL --max-time 60 "$url" -o "$tmp" || { rm -f "$tmp"; die "Не удалось скачать $url"; }
    local lines; lines=$(wc -l < "$tmp")
    dim "Получено строк: $lines"
    info "Запускаю: bash $tmp $*"
    bash "$tmp" "$@" </dev/tty
    local rc=$?
    rm -f "$tmp"
    return $rc
}

# ─────────────────────────────────────────────────────────────────────────────
# Предварительные проверки
# ─────────────────────────────────────────────────────────────────────────────
preflight() {
    banner "Предварительные проверки"

    # Не подсказываем sudo: на минимальных образах его нет, а при запуске
    # через bash <(...) в $0 лежит /dev/fd/63 и совет получился бы бессмысленным.
    [[ $EUID -eq 0 ]] || die "Нужен root. Зайдите под root и запустите заново."
    ok "Запущено от root"

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
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq \
            && apt-get install -y -qq curl ca-certificates >/dev/null \
            || die "Не удалось установить curl — проверьте apt и сеть"
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

    local warn_ports=()
    for p in 80 443; do
        port_busy "$p" && warn_ports+=("$p")
    done
    if ((${#warn_ports[@]})); then
        warn "Порты уже заняты: ${warn_ports[*]}"
        dim "Selfsteal требует свободные 80 и 443 на время выпуска сертификата."
        ss -tlnp "( sport = :80 or sport = :443 )" 2>/dev/null | sed 's/^/    /' || true
        ask_yn "  Всё равно продолжить?" n || exit 0
    else
        ok "Порты 80 и 443 свободны"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 1. Система
# ─────────────────────────────────────────────────────────────────────────────
step_system() {
    should_run "system" "Подготовка системы" || return 0
    banner "Шаг 1/9 — Подготовка системы"

    info "Обновляю списки пакетов..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq

    local pkgs=(curl wget ca-certificates gnupg jq git dnsutils
                iproute2 nano less openssl cron)
    info "Ставлю базовые пакеты: ${pkgs[*]}"
    apt-get install -y -qq "${pkgs[@]}" >/dev/null
    ok "Пакеты установлены"

    state_mark "system"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 2. SSH по ключу
# ─────────────────────────────────────────────────────────────────────────────
ssh_reload() {
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

sshd_effective() { sshd -T 2>/dev/null | grep -iE "^$1 " | awk '{print $2}'; }

step_ssh() {
    should_run "ssh" "Настройка SSH" || return 0
    banner "Шаг 2/9 — Вход по SSH-ключу"

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
                    printf '%s\n' "$pubkey" >> "$akfile"
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

    sed -i '/# >>> remnanode-bootstrap/,/# <<< remnanode-bootstrap/d' "$cfg"

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
        ' "$cfg" > "$cfg.new"
        mv "$cfg.new" "$cfg"
        dim "Блок вставлен перед строкой Include"
    else
        { printf '%s\n\n' "$block"; cat "$cfg"; } > "$cfg.new"
        mv "$cfg.new" "$cfg"
        dim "Блок добавлен в начало файла (Include отсутствует)"
    fi

    if ! ssh_reload; then
        err "Откатываю конфиг"
        local last; last=$(ls -t "$BACKUP_DIR"/sshd_config.* 2>/dev/null | head -1)
        [[ -n "$last" ]] && cp -a "$last" "$cfg" && ssh_reload
        die "SSH не настроен — разберитесь вручную перед продолжением"
    fi

    printf '\n'
    local pa pr pk
    pa=$(sshd_effective passwordauthentication)
    pr=$(sshd_effective permitrootlogin)
    pk=$(sshd_effective pubkeyauthentication)
    [[ "$pa" == "no"  ]] && ok "passwordauthentication = no"  || err "passwordauthentication = $pa"
    [[ "$pk" == "yes" ]] && ok "pubkeyauthentication = yes"   || err "pubkeyauthentication = $pk"
    ok "permitrootlogin = $pr"

    # cloud-init может вернуть свой дропин после перезагрузки
    if [[ -f /etc/cloud/cloud.cfg ]] && ! grep -q '^ssh_pwauth:' /etc/cloud/cloud.cfg; then
        echo "ssh_pwauth: false" >> /etc/cloud/cloud.cfg
        dim "В /etc/cloud/cloud.cfg добавлено ssh_pwauth: false"
    fi

    warn "Проверьте вход по ключу ЕЩЁ РАЗ, не закрывая эту сессию."
    pause
    state_mark "ssh"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 3. Tailscale
# ─────────────────────────────────────────────────────────────────────────────
step_tailscale() {
    should_run "tailscale" "Tailscale" || return 0
    banner "Шаг 3/9 — Tailscale"

    if ! ask_yn "Установить Tailscale?" y; then
        info "Пропускаю."; return 0
    fi

    if have tailscale; then
        ok "Tailscale уже установлен: $(tailscale version | head -1)"
    else
        info "Ставлю Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
        have tailscale || die "Установка Tailscale не удалась"
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
            warn "Не подключено — можно доделать позже: tailscale up --ssh"
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

    banner "Шаг 4/9 — A-запись домена"

    printf '%sSelfsteal выпускает сертификат Let'"'"'s Encrypt через TLS-ALPN на 443.%s\n' "$C_DIM" "$C_RESET"
    printf '%sДля этого домен ОБЯЗАН резолвиться в IP этого сервера.%s\n\n' "$C_DIM" "$C_RESET"

    printf '  %sДобавьте у регистратора или в панели DNS:%s\n' "$C_BOLD" "$C_RESET"
    printf '      %sТип:%s   A\n' "$C_DIM" "$C_RESET"
    printf '      %sИмя:%s   ваш поддомен (например seafile)\n' "$C_DIM" "$C_RESET"
    printf '      %sЗначение:%s %s%s%s\n' "$C_DIM" "$C_RESET" "$C_BOLD" "$SERVER_IP" "$C_RESET"
    printf '      %sTTL:%s   минимальный (60–300)\n\n' "$C_DIM" "$C_RESET"
    warn "Если домен за Cloudflare — проксирование (оранжевое облако) должно быть ВЫКЛЮЧЕНО."
    dim "TLS-ALPN требует, чтобы 443 отвечал ваш сервер, а не CDN."
    printf '\n'

    while true; do
        ask_var DOMAIN "Полный домен для selfsteal (например seafile.example.com):" "${DOMAIN:-}"

        if [[ -z "$DOMAIN" ]]; then
            warn "Домен не введён."
            ask_yn "  Пропустить шаг целиком?" y && { info "Пропускаю."; return 0; }
            continue
        fi

        if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; then
            err "Домен выглядит некорректно."
            ask_yn "  Ввести заново?" y || { info "Пропускаю шаг."; return 0; }
            continue
        fi

        # Проверку можно не делать: DNS ещё не распространился, домен за
        # сплит-хорайзоном, или пользователь просто знает, что запись верна.
        if ! ask_yn "  Проверить A-запись через DNS?" y; then
            warn "Проверка пропущена — если запись неверна, сертификат не выпустится."
            break
        fi

        info "Проверяю A-запись $DOMAIN..."
        local resolved
        resolved=$(dig +short A "$DOMAIN" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$' | tail -1 || true)

        if [[ -z "$resolved" ]]; then
            err "A-запись не найдена. DNS ещё не распространился или запись не создана."
        elif [[ "$resolved" == "$SERVER_IP" ]]; then
            ok "$DOMAIN → $resolved (совпадает с IP сервера)"
            break
        else
            err "$DOMAIN → $resolved, а сервер имеет $SERVER_IP"
            dim "Если это IP Cloudflare — отключите проксирование."
        fi

        ask_yn "  Проверить ещё раз?" y || {
            ask_yn "  Продолжить без корректной A-записи (сертификат не выпустится)?" n && break
        }
    done

    echo "$DOMAIN" > "$STATE_DIR/domain"
    state_mark "dns"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 5. Remnanode
# ─────────────────────────────────────────────────────────────────────────────
install_docker() {
    have docker || {
        info "Ставлю Docker из официального репозитория..."
        export DEBIAN_FRONTEND=noninteractive
        install -m 0755 -d /etc/apt/keyrings
        local os_id
        os_id=$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-debian}")
        curl -fsSL "https://download.docker.com/linux/$os_id/gpg" \
            -o /etc/apt/keyrings/docker.asc || { err "Не скачался ключ Docker"; return 1; }
        chmod a+r /etc/apt/keyrings/docker.asc
        local codename
        codename=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_CODENAME:-}")
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
            "$(dpkg --print-architecture)" "$os_id" "$codename" > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin >/dev/null \
            || { err "Установка Docker не удалась"; return 1; }
    }
    docker compose version >/dev/null 2>&1 || { err "Плагин docker compose недоступен"; return 1; }
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

step_remnanode() {
    should_run "remnanode" "Remnanode" || return 0
    banner "Шаг 5/9 — Установка Remnanode"

    printf '%sСтавим ноду своим docker-compose, без внешнего установщика.%s\n' "$C_DIM" "$C_RESET"
    printf '%sК штатному набору добавлен том /dev/shm — через него нода видит%s\n' "$C_DIM" "$C_RESET"
    printf '%sunix-сокет, который создаёт соседний контейнер с nginx.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Устанавливать ноду сейчас?" y; then
        info "Пропускаю."; return 0
    fi

    install_docker || return 1

    mkdir -p "$NODE_DIR"
    chmod 700 "$NODE_DIR"

    # ── SECRET_KEY и порт ─────────────────────────────────────────────────
    local secret="" port=""
    secret=$(env_value "$NODE_DIR/.env" SECRET_KEY) || secret=""
    port=$(env_value "$NODE_DIR/.env" NODE_PORT) || port=$(env_value "$NODE_DIR/.env" APP_PORT) || port=""

    if [[ -n "$secret" ]]; then
        ok "SECRET_KEY найден в $NODE_DIR/.env — переиспользую"
        ask_yn "  Заменить на новый?" n && secret=""
    fi
    if [[ -z "$secret" ]]; then
        printf '\n%sSECRET_KEY из панели: Nodes → Create/Manage node → скопировать eyJ...%s\n' "$C_DIM" "$C_RESET"
        while true; do
            ask_var secret "SECRET_KEY:" ""
            [[ -n "$secret" ]] && break
            warn "Пусто."
        done
    fi

    while true; do
        ask_var port "Порт API ноды:" "${port:-2222}"
        [[ "$port" =~ ^[0-9]+$ ]] && ((port > 0 && port < 65536)) && break
        err "Нужно число 1–65535."
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
    cat > "$NODE_DIR/.env" <<EOF
### NODE ###
NODE_PORT=$port

### XRAY ###
SECRET_KEY=$secret
EOF
    chmod 600 "$NODE_DIR/.env"
    ok "Записан $NODE_DIR/.env"

    backup_file "$NODE_DIR/docker-compose.yml"
    cat > "$NODE_DIR/docker-compose.yml" <<EOF
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

    if node_compose logs --tail 200 2>&1 | grep -qi 'unknown sni'; then
        err "В логах есть 'unknown sni' — панель старее ноды"
        dim "Переустановите с тегом 3.2.2 либо обновите панель."
    fi

    state_mark "remnanode"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 6. Selfsteal + предварительная подготовка acme.sh
# ─────────────────────────────────────────────────────────────────────────────
prepare_acme() {
    # Известная проблема: selfsteal.sh при первой установке acme.sh
    # генерирует случайный e-mail вида user12345@<hostname>. Если у хоста
    # короткое имя (stellar-gecko), адрес невалиден и Let's Encrypt
    # отказывает в регистрации аккаунта. Ставим acme.sh заранее сами,
    # с настоящим e-mail — тогда selfsteal увидит готовую установку
    # и не пойдёт по сломанной ветке.
    banner "Подготовка acme.sh (обход ошибки регистрации аккаунта)"

    local acme_home="$HOME/.acme.sh"
    local email=""

    while true; do
        ask_var email "E-mail для Let's Encrypt (реальный, на него шлют уведомления об истечении):" "${ACME_EMAIL:-}"
        [[ "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-zA-Z]{2,}$ ]] && break
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

# Выпуск и установка сертификата. HTTP-01 через webroot, а не TLS-ALPN:
# 443 занят Xray под REALITY, и продление по ALPN туда просто не забиндится.
# Webroot обслуживает наш же nginx на 80, поэтому продление не требует
# останова чего-либо и работает само из крона acme.sh.
issue_cert() {
    local domain="$1" acme="$HOME/.acme.sh/acme.sh"
    [[ -x "$acme" ]] || { err "acme.sh не найден"; return 1; }

    mkdir -p "$SS_DIR/ssl" "$SS_DIR/acme/.well-known/acme-challenge"

    # Действующий сертификат от прежней установки лучше переиспользовать:
    # у Let's Encrypt лимит 5 одинаковых сертификатов в неделю.
    local old
    for old in /opt/nginx-selfsteal/ssl /opt/caddy/ssl; do
        [[ -f "$old/fullchain.crt" && -f "$old/private.key" ]] || continue
        openssl x509 -in "$old/fullchain.crt" -noout -checkend 604800 >/dev/null 2>&1 || continue
        openssl x509 -in "$old/fullchain.crt" -noout -subject 2>/dev/null | grep -q "$domain" || continue
        info "Беру действующий сертификат из $old"
        cp -a "$old/fullchain.crt" "$SS_DIR/ssl/fullchain.crt"
        cp -a "$old/private.key"   "$SS_DIR/ssl/private.key"
        ok "Сертификат переиспользован, выпуск не нужен"
        return 0
    done

    info "Выпускаю сертификат через HTTP-01 (webroot на порту 80)..."
    "$acme" --issue -d "$domain" --webroot "$SS_DIR/acme" \
        --server letsencrypt >>"$LOG_FILE" 2>&1 \
        || { err "Выпуск не удался, хвост лога:"; tail -15 "$LOG_FILE" | sed 's/^/    /'; return 1; }

    # --reloadcmd выполняется и при каждом автопродлении из крона acme.sh.
    "$acme" --install-cert -d "$domain" \
        --key-file       "$SS_DIR/ssl/private.key" \
        --fullchain-file "$SS_DIR/ssl/fullchain.crt" \
        --reloadcmd      "docker restart $SS_CONTAINER >/dev/null 2>&1 || true" \
        >>"$LOG_FILE" 2>&1 \
        || { err "install-cert не удался, смотрите $LOG_FILE"; return 1; }

    ok "Сертификат выпущен и установлен"
}

# Конфиг только с портом 80: нужен, пока сертификата нет и основной
# server-блок стартовать не может.
write_acme_only_conf() {
    local domain="$1"
    cat > "$SS_DIR/conf.d/acme-only.conf" <<EOF
server {
    listen 80 default_server;
    server_name $domain;
    location /.well-known/acme-challenge/ { root /var/www/acme; }
    location / { return 404; }
}
EOF
}

write_nginx_files() {
    local domain="$1"
    mkdir -p "$SS_DIR/conf.d" "$SS_DIR/html" "$SS_DIR/logs" "$SS_DIR/ssl" \
             "$SS_DIR/acme/.well-known/acme-challenge"

    cat > "$SS_DIR/nginx.conf" <<'EOF'
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

    cat > "$SS_DIR/conf.d/selfsteal.conf" <<EOF
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

    # Страница-заглушка. Её видит тот, кто пришёл на домен без ключа REALITY,
    # поэтому выглядеть она должна как обычный скучный сайт.
    if [[ ! -s "$SS_DIR/html/index.html" ]]; then
        cat > "$SS_DIR/html/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>$domain</title>
<style>
body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif;color:#2b3440;background:#f6f7f9}
main{max-width:34rem;padding:2rem;text-align:center}
h1{font-size:1.5rem;font-weight:600;margin:0 0 .75rem}
p{margin:0;color:#6b7684}
</style>
</head>
<body>
<main>
<h1>Service is being set up</h1>
<p>This site is not configured yet. Please check back later.</p>
</main>
</body>
</html>
EOF
    fi

    cat > "$SS_DIR/docker-compose.yml" <<EOF
services:
  nginx:
    image: nginx:$SS_NGINX_TAG
    container_name: $SS_CONTAINER
    restart: unless-stopped
    network_mode: host
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
    banner "Шаг 6/9 — Selfsteal (nginx + unix socket)"

    DOMAIN="${DOMAIN:-$(cat "$STATE_DIR/domain" 2>/dev/null || true)}"
    [[ -n "$DOMAIN" ]] || { err "Домен не задан — сначала пройдите шаг 4"; return 1; }
    info "Домен: $DOMAIN"

    printf '%snginx поднимается контейнером и слушает unix-сокет. TLS терминирует%s\n' "$C_DIM" "$C_RESET"
    printf '%sон же: REALITY отдаёт ему чужой трафик как есть, при xver: 1.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Настроить selfsteal?" y; then
        info "Пропускаю."; return 0
    fi

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
    local old_dir
    for old_dir in /opt/nginx-selfsteal /opt/caddy; do
        [[ -f "$old_dir/docker-compose.yml" ]] || continue
        warn "Найдена прежняя установка: $old_dir"
        dim "Она занимает порт 80 и тот же сокет — вместе они не уживутся."
        if ask_yn "  Остановить её?" y; then
            docker compose -f "$old_dir/docker-compose.yml" --project-directory "$old_dir" down \
                >>"$LOG_FILE" 2>&1 || true
            ok "Прежний контейнер остановлен, файлы в $old_dir не тронуты"
        else
            err "Продолжать без остановки нельзя"
            return 1
        fi
    done

    if port_busy 80; then
        warn "Порт 80 занят — ACME-челлендж не пройдёт:"
        ss -tlnp "sport = :80" 2>/dev/null | sed 's/^/    /'
        ask_yn "  Продолжить?" n || return 0
    fi

    prepare_acme || { err "acme.sh не готов"; return 1; }

    write_nginx_files "$DOMAIN"

    # Пока сертификата нет, основной server-блок не стартует: nginx падает
    # на отсутствующем ssl_certificate. Поэтому сперва поднимаем только
    # слушатель на 80, выпускаем сертификат, потом включаем всё.
    if [[ ! -f "$SS_DIR/ssl/fullchain.crt" ]]; then
        info "Сертификата нет — временно поднимаю только слушатель на 80"
        mv "$SS_DIR/conf.d/selfsteal.conf" "$SS_DIR/conf.d/selfsteal.conf.pending"
        write_acme_only_conf "$DOMAIN"
        ss_compose up -d >>"$LOG_FILE" 2>&1 || { err "nginx не поднялся"; return 1; }
        sleep 2

        if ! issue_cert "$DOMAIN"; then
            mv "$SS_DIR/conf.d/selfsteal.conf.pending" "$SS_DIR/conf.d/selfsteal.conf"
            rm -f "$SS_DIR/conf.d/acme-only.conf"
            err "Сертификат не выпущен"
            return 1
        fi

        rm -f "$SS_DIR/conf.d/acme-only.conf"
        mv "$SS_DIR/conf.d/selfsteal.conf.pending" "$SS_DIR/conf.d/selfsteal.conf"
    else
        ok "Сертификат уже на месте: $SS_DIR/ssl/fullchain.crt"
    fi

    info "Поднимаю nginx..."
    ss_compose up -d --force-recreate >>"$LOG_FILE" 2>&1 || { err "nginx не поднялся"; return 1; }
    sleep 2

    # ── Проверки ──────────────────────────────────────────────────────────
    printf '\n'
    if docker ps --filter "name=$SS_CONTAINER" --filter status=running --format '{{.Names}}' \
        | grep -qx "$SS_CONTAINER"; then
        ok "Контейнер $SS_CONTAINER работает"
    else
        err "Контейнер не поднялся"
        ss_compose logs --tail 30 2>&1 | sed 's/^/    /' || true
        return 1
    fi

    if [[ -f "$SS_DIR/ssl/fullchain.crt" ]]; then
        ok "Сертификат: $SS_DIR/ssl/fullchain.crt"
        openssl x509 -in "$SS_DIR/ssl/fullchain.crt" -noout -subject -enddate 2>/dev/null | sed 's/^/    /'
    else
        err "Файл сертификата отсутствует"
    fi

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
step_warp() {
    should_run "warp" "WARP" || return 0
    banner "Шаг 7/9 — WARP (вариант B, host-интерфейс)"

    printf '%sВариант B привязывает сокеты Xray к kernel-интерфейсу wg-quick@warp%s\n' "$C_DIM" "$C_RESET"
    printf '%sчерез sockopt.interface. Быстрее варианта A, ключи не попадают в конфиг Xray.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Устанавливать WARP?" y; then
        info "Пропускаю."; return 0
    fi

    info "Ставлю CLI wtm..."
    run_remote "$R_WTM" "@" "install-script" || warn "wtm.sh вернул ненулевой код"

    if have wtm; then
        ok "CLI wtm установлен"
        printf '\n%sДалее ставим ТОЛЬКО WARP (без Tor).%s\n' "$C_DIM" "$C_RESET"
        if ask_yn "Запустить wtm install-warp?" y; then
            wtm install-warp </dev/tty || warn "install-warp вернул ошибку"
        fi
        if ask_yn "Включить watchdog (автоперезапуск wg-quick@warp)?" y; then
            wtm watchdog-on </dev/tty || warn "watchdog-on вернул ошибку"
        fi
    else
        warn "CLI wtm не найден — установите WARP вручную"
    fi

    printf '\n'
    info "Проверяю интерфейс..."
    if ip -br a show warp >/dev/null 2>&1; then
        ok "Интерфейс warp поднят:"
        ip -br a show warp | sed 's/^/    /'
        local trace
        trace=$(curl --interface warp -sS --max-time 12 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null | grep -E '^warp=' || true)
        if [[ "$trace" == "warp=on" ]]; then
            ok "Трафик через интерфейс warp реально идёт в Cloudflare (warp=on)"
        else
            warn "Проверка через интерфейс вернула: '${trace:-пусто}'"
            dim "Диагностика: systemctl status wg-quick@warp"
        fi
    else
        err "Интерфейс warp не найден — вариант B работать не будет"
        dim "Диагностика: journalctl -u wg-quick@warp -n 30"
    fi

    [[ -f /etc/wireguard/warp-sockopt-outbound.json ]] \
        && ok "Готовый outbound: /etc/wireguard/warp-sockopt-outbound.json" \
        || dim "Файл outbound не найден — используйте блок из итоговой инструкции"

    state_mark "warp"
}

# ─────────────────────────────────────────────────────────────────────────────
# Шаг 8. Файрвол
# ─────────────────────────────────────────────────────────────────────────────

# Порты, на которых реально слушает sshd. Берём из sshd -T, а не из конфига:
# порт мог быть переопределён дропином, а закрыться от себя нельзя.
ssh_ports() {
    local p
    p=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}')
    [[ -n "$p" ]] || p=22
    printf '%s\n' "$p"
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
    local port="$1"
    ufw show added 2>/dev/null | grep -qE "allow[[:space:]]+(in[[:space:]]+)?${port}/tcp" && return 0
    ufw status    2>/dev/null | grep -qE "^${port}/tcp" && return 0
    return 1
}

# Контейнеры с опубликованными наружу портами. Docker пишет свои правила
# в цепочку DOCKER-USER, минуя ufw, поэтому такие порты остаются открытыми
# даже при deny incoming — про них надо предупредить отдельно.
docker_published() {
    have docker || return 0
    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null \
        | grep -E '0\.0\.0\.0:|\[::\]:' || true
}

step_firewall() {
    should_run "firewall" "Файрвол" || return 0
    banner "Шаг 8/9 — Файрвол (ufw)"

    printf '%sНаружу открываются только 22, 80 и 443. Порт ноды доступен%s\n' "$C_DIM" "$C_RESET"
    printf '%sтолько из тейлнета, снаружи закрыт. Всё исходящее разрешено.%s\n\n' "$C_DIM" "$C_RESET"

    if ! ask_yn "Настроить ufw?" y; then
        info "Пропускаю."; return 0
    fi

    if have ufw; then
        ok "ufw уже установлен"
    else
        info "Ставлю ufw..."
        export DEBIAN_FRONTEND=noninteractive
        apt-get install -y -qq ufw >/dev/null || { err "Не удалось поставить ufw"; return 1; }
        ok "ufw установлен"
    fi

    # ── Собираем список портов ────────────────────────────────────────────
    local sshp
    sshp=$(ssh_ports | tr '\n' ' ')
    ok "SSH слушает порт(ы): $sshp"

    local nodep=""
    if nodep=$(node_port); then
        ok "Порт ноды из /opt/remnanode/.env: $nodep"
    else
        warn "Не удалось прочитать порт ноды из /opt/remnanode/.env"
        ask_var nodep "Порт API ноды (Enter — пропустить правило для тейлнета):" ""
        [[ "$nodep" =~ ^[0-9]+$ ]] || nodep=""
    fi

    local ts_if=""
    if ip link show tailscale0 >/dev/null 2>&1; then
        ts_if="tailscale0"
        ok "Интерфейс тейлнета: tailscale0"
    else
        warn "Интерфейс tailscale0 не найден — правил для тейлнета не будет"
        if [[ -n "$nodep" ]]; then
            err "Порт ноды $nodep останется закрытым для всех, включая панель."
            ask_yn "  Всё равно продолжить?" n || return 0
        fi
    fi

    # ── Область правила для тейлнета ──────────────────────────────────────
    local ts_wide="n"
    if [[ -n "$ts_if" ]]; then
        printf '\n%sДоступ из тейлнета можно открыть двумя способами:%s\n' "$C_DIM" "$C_RESET"
        dim "  узко — только порт ноды${nodep:+ ($nodep)}; всё остальное закрыто и внутри тейлнета"
        dim "  широко — любой порт этого сервера доступен вашим устройствам в тейлнете"
        ask_yn "Открыть тейлнету весь интерфейс (широко)?" n && ts_wide="y"
    fi

    # ── Входящий 41641/udp ────────────────────────────────────────────────
    local ts_udp="n"
    if [[ -n "$ts_if" ]]; then
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
    dim "allow 80/tcp                       (HTTP, выпуск сертификата)"
    dim "allow 443/tcp                      (VLESS REALITY, selfsteal)"
    if [[ -n "$ts_if" ]]; then
        if [[ "$ts_wide" == "y" ]]; then
            dim "allow in on tailscale0             (весь тейлнет)"
        elif [[ -n "$nodep" ]]; then
            dim "allow in on tailscale0 port $nodep    (только API ноды)"
        fi
        [[ "$ts_udp" == "y" ]] && dim "allow 41641/udp                    (прямые соединения Tailscale)"
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

    ufw default deny incoming  >/dev/null
    ufw default allow outgoing >/dev/null
    ufw allow 80/tcp  comment 'http acme'   >/dev/null
    ufw allow 443/tcp comment 'vless reality' >/dev/null
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

    # Проверяем, что правило для SSH действительно есть. Без него включение
    # ufw обрывает текущую сессию и запирает нас снаружи.
    local first_ssh; first_ssh=${sshp%% *}
    if ! ssh_rule_present "$first_ssh"; then
        err "Правило для SSH не найдено — НЕ включаю ufw"
        ufw show added 2>/dev/null | sed 's/^/    /'
        return 1
    fi
    ok "Правило для SSH на месте"

    ufw --force enable >/dev/null || { err "ufw enable вернул ошибку"; return 1; }
    ok "ufw включён"

    # После включения правило обязано быть видно уже в status. Если его нет —
    # выключаем немедленно, пока текущая сессия жива: established-соединения
    # ufw пропускает, но новый вход был бы невозможен.
    if ! ufw status | grep -qE "^$first_ssh/tcp"; then
        err "После включения правило для SSH не видно в ufw status — выключаю ufw обратно"
        ufw disable >/dev/null 2>&1 || true
        ufw status | sed 's/^/    /'
        return 1
    fi

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
        if ufw status | grep -E "(^|[[:space:]])$nodep(/tcp)?[[:space:]]" | grep -qv 'on tailscale0'; then
            err "Порт ноды $nodep разрешён не только на tailscale0 — проверьте вывод выше"
            ufw status | grep -E "(^|[[:space:]])$nodep" | sed 's/^/    /'
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
    banner "Шаг 9/9 — BBR + fq"

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

    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    sysctl --system >/dev/null 2>&1

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
        if tc qdisc replace dev "$dev" root fq 2>/dev/null; then
            ok "На $dev применён fq без перезагрузки"
        else
            warn "Не удалось сменить qdisc на $dev — fq вступит в силу после перезагрузки"
        fi
        dim "Сейчас: $(tc qdisc show dev "$dev" 2>/dev/null | head -1)"
    fi

    dim "Проверить на живых соединениях: ss -tin | grep -c bbr"

    state_mark "bbr"
}

# ─────────────────────────────────────────────────────────────────────────────
# Итог
# ─────────────────────────────────────────────────────────────────────────────
summary() {
    banner "Готово"

    printf '%sЧто сделано:%s\n' "$C_BOLD" "$C_RESET"
    for k in system ssh tailscale dns remnanode selfsteal warp firewall bbr; do
        if state_done "$k"; then
            printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$k"
        else
            printf '  %s·%s %s %s(пропущено)%s\n' "$C_DIM" "$C_RESET" "$k" "$C_DIM" "$C_RESET"
        fi
    done

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
    dim "wtm status                  — состояние WARP"
    dim "systemctl status wg-quick@warp"
    dim "sshd -T | grep -i password  — проверить, что пароль отключён"
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

    printf '\n%sБудут выполнены 9 шагов. Каждый можно пропустить.%s\n' "$C_DIM" "$C_RESET"
    ask_yn "Начинаем?" y || { info "Отменено."; exit 0; }

    step_system
    step_ssh
    step_tailscale
    step_dns
    step_remnanode
    step_selfsteal
    step_warp
    # Шаг может вернуть ненулевой код (например, отказался включать ufw).
    # Без || это под set -e обрывает весь скрипт вместе с оставшимися шагами.
    step_firewall || warn "Шаг файрвола не завершён — подробности выше"
    step_bbr
    summary
}

main "$@"
