#!/bin/bash
# =============================================================================
# SOCKS5 Proxy Installer (Dante/danted)
# Поддерживаемые ОС: Ubuntu 20.04 / 22.04 / 24.04, Debian 11/12
# Версия: 2.0
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Цвета для вывода
# -----------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Проверка прав root
# -----------------------------------------------------------------------------
[[ "$EUID" -ne 0 ]] && die "Скрипт необходимо запускать от имени root (sudo ./setup_socks5.sh)"

# -----------------------------------------------------------------------------
# Определение ОС
# -----------------------------------------------------------------------------
if [[ ! -f /etc/os-release ]]; then
    die "Не удалось определить операционную систему."
fi
# shellcheck disable=SC1091
source /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-0}"
info "Операционная система: ${PRETTY_NAME}"

case "$OS_ID" in
    ubuntu|debian) ;;
    *) warn "Скрипт тестировался только на Ubuntu/Debian. Продолжение на свой риск." ;;
esac

# -----------------------------------------------------------------------------
# Проверка версии dante-server в репозитории
# -----------------------------------------------------------------------------
info "Обновление списка пакетов..."
apt-get update -qq

DANTE_AVAILABLE=$(apt-cache show dante-server 2>/dev/null | awk '/^Version:/{print $2; exit}')
if [[ -z "$DANTE_AVAILABLE" ]]; then
    die "Пакет dante-server не найден в репозиториях. Добавьте universe (Ubuntu) или проверьте sources.list."
fi
info "Доступна версия dante-server: ${DANTE_AVAILABLE}"

# Минимальная поддерживаемая версия — 1.4.x (в 1.1.x broken auth)
DANTE_MAJOR=$(echo "$DANTE_AVAILABLE" | cut -d. -f1)
DANTE_MINOR=$(echo "$DANTE_AVAILABLE" | cut -d. -f2)
if [[ "$DANTE_MAJOR" -lt 1 ]] || { [[ "$DANTE_MAJOR" -eq 1 ]] && [[ "$DANTE_MINOR" -lt 4 ]]; }; then
    die "В репозитории обнаружена устаревшая версия dante-server (${DANTE_AVAILABLE}). Требуется >= 1.4.x. Обновите систему или добавьте сторонний репозиторий."
fi

# -----------------------------------------------------------------------------
# Установка пакетов
# -----------------------------------------------------------------------------
info "Установка необходимых пакетов..."
PACKAGES=(dante-server)

# curl нужен для определения внешнего IP; ставим если отсутствует
command -v curl &>/dev/null || PACKAGES+=(curl)

apt-get install -y "${PACKAGES[@]}" -qq
success "Пакеты установлены."

# -----------------------------------------------------------------------------
# Определение сетевого интерфейса
# -----------------------------------------------------------------------------
INTERFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)
[[ -z "$INTERFACE" ]] && INTERFACE=$(ip route | awk '/default/ {print $5; exit}')
[[ -z "$INTERFACE" ]] && die "Не удалось автоматически определить сетевой интерфейс. Укажите его вручную."

success "Сетевой интерфейс: ${INTERFACE}"

# -----------------------------------------------------------------------------
# Вспомогательная функция: генерация свободного порта
# -----------------------------------------------------------------------------
generate_random_port() {
    local port
    for _ in $(seq 1 50); do
        port=$(( (RANDOM * RANDOM % 54512) + 10000 ))
        if ! ss -tulnp 2>/dev/null | awk '{print $5}' | grep -qE ":${port}$"; then
            echo "$port"
            return 0
        fi
    done
    die "Не удалось найти свободный порт за 50 попыток."
}

# -----------------------------------------------------------------------------
# Вспомогательная функция: безопасная генерация имени пользователя
# (только буквы и цифры, первый символ — буква)
# -----------------------------------------------------------------------------
generate_username() {
    local prefix suffix
    prefix=$(tr -dc 'a-z' </dev/urandom | head -c 2)
    suffix=$(tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 6)
    echo "${prefix}${suffix}"
}

# -----------------------------------------------------------------------------
# Интерактивный ввод параметров
# -----------------------------------------------------------------------------
echo ""
echo "============================================================="
echo "      Установщик SOCKS5-прокси (Dante ${DANTE_AVAILABLE})"
echo "============================================================="
echo ""

# --- Логин ---
read -rp "Хотите ввести логин вручную? (y/n) [n]: " choice_login
if [[ "$choice_login" =~ ^[Yy]$ ]]; then
    while true; do
        read -rp "Введите имя пользователя (только буквы/цифры, начиная с буквы): " username
        if [[ "$username" =~ ^[a-zA-Z][a-zA-Z0-9]{2,31}$ ]]; then
            break
        else
            warn "Некорректное имя. Длина 3–32 символа, начинается с буквы, только a-z/A-Z/0-9."
        fi
    done
else
    username=$(generate_username)
    info "Сгенерирован логин: ${username}"
fi

# --- Пароль ---
read -rp "Хотите ввести пароль вручную? (y/n) [n]: " choice_pass
if [[ "$choice_pass" =~ ^[Yy]$ ]]; then
    while true; do
        read -rsp "Введите пароль (минимум 8 символов): " password
        echo
        read -rsp "Повторите пароль: " password2
        echo
        if [[ "$password" == "$password2" ]] && [[ ${#password} -ge 8 ]]; then
            break
        else
            warn "Пароли не совпадают или слишком короткий (< 8 символов)."
        fi
    done
else
    password=$(tr -dc 'a-zA-Z0-9!@#%^&*' </dev/urandom | head -c 16)
    info "Сгенерирован пароль: ${password}"
fi

# --- Порт ---
read -rp "Хотите ввести порт вручную? (y/n) [n]: " choice_port
if [[ "$choice_port" =~ ^[Yy]$ ]]; then
    while true; do
        read -rp "Введите порт (1024–65535): " port
        if [[ "$port" =~ ^[0-9]+$ ]] && \
           [[ "$port" -ge 1024 ]] && \
           [[ "$port" -le 65535 ]] && \
           ! ss -tulnp 2>/dev/null | awk '{print $5}' | grep -qE ":${port}$"; then
            break
        else
            warn "Порт занят, вне диапазона или некорректен. Попробуйте другой."
        fi
    done
else
    port=$(generate_random_port)
    info "Сгенерирован порт: ${port}"
fi

# --- Уровень логирования ---
echo ""
echo "Уровень логирования соединений:"
echo "  1) Минимальный  — только ошибки (по умолчанию)"
echo "  2) Стандартный  — ошибки + подключения/отключения"
echo "  3) Подробный    — ошибки + все события + данные"
read -rp "Выберите уровень [1]: " log_choice
log_choice="${log_choice:-1}"

case "$log_choice" in
    2) LOG_RULES="error connect disconnect" ;;
    3) LOG_RULES="error connect disconnect data" ;;
    *) LOG_RULES="error" ;;
esac

read -rp "Сохранять логи в файл /var/log/danted.log? (y/n) [y]: " choice_logfile
choice_logfile="${choice_logfile:-y}"
if [[ "$choice_logfile" =~ ^[Yy]$ ]]; then
    LOGOUTPUT="/var/log/danted.log"
else
    LOGOUTPUT="syslog"
fi

info "Логирование: ${LOG_RULES} → ${LOGOUTPUT}"

# -----------------------------------------------------------------------------
# Создание системного пользователя
# -----------------------------------------------------------------------------

# Удаляем пользователя если уже существует (переустановка)
if id "$username" &>/dev/null; then
    warn "Пользователь '${username}' уже существует. Будет обновлён пароль."
else
    useradd --system --no-create-home --shell /usr/sbin/nologin "$username"
    success "Системный пользователь '${username}' создан."
fi

# Устанавливаем пароль через chpasswd (безопаснее, чем passwd в pipe)
echo "${username}:${password}" | chpasswd
success "Пароль установлен."

# -----------------------------------------------------------------------------
# Бэкап старого конфига и запись нового
# -----------------------------------------------------------------------------
if [[ -f /etc/danted.conf ]]; then
    BACKUP="/etc/danted.conf.bak.$(date +%Y%m%d_%H%M%S)"
    cp /etc/danted.conf "$BACKUP"
    info "Старый конфиг сохранён: ${BACKUP}"
fi

cat > /etc/danted.conf <<EOF
# ======================================================
# danted.conf — автоматически сгенерирован setup_socks5.sh
# Дата: $(date '+%Y-%m-%d %H:%M:%S')
# ======================================================

# Логирование
logoutput: ${LOGOUTPUT}

# Привязка к конкретному интерфейсу (не 0.0.0.0) обеспечивает
# корректный BND.ADDR при ответах клиенту
internal: ${INTERFACE} port = ${port}
external: ${INTERFACE}

# Метод аутентификации
clientmethod: none
socksmethod: username

# Привилегированный пользователь (нужен для проверки /etc/shadow)
user.privileged: root
user.unprivileged: nobody

# Правило: разрешить клиентское подключение от любого IP
client pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        log: ${LOG_RULES}
}

# Правило: разрешить проксирование TCP и UDP с аутентификацией
socks pass {
        from: 0.0.0.0/0 to: 0.0.0.0/0
        socksmethod: username
        protocol: tcp udp
        log: ${LOG_RULES}
}
EOF

success "Конфигурация записана в /etc/danted.conf"

# -----------------------------------------------------------------------------
# Настройка ротации логов (если пишем в файл)
# -----------------------------------------------------------------------------
if [[ "$LOGOUTPUT" == "/var/log/danted.log" ]]; then
    cat > /etc/logrotate.d/danted <<'LOGROTATE'
/var/log/danted.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    postrotate
        systemctl kill -s HUP danted.service >/dev/null 2>&1 || true
    endscript
}
LOGROTATE
    touch /var/log/danted.log
    success "Ротация логов настроена (/etc/logrotate.d/danted)."
fi

# -----------------------------------------------------------------------------
# Проверка конфигурации перед запуском
# -----------------------------------------------------------------------------
info "Проверка синтаксиса конфигурации..."
if ! danted -V 2>&1 | grep -qi "dante\|version"; then
    warn "danted -V не вернул ожидаемый вывод, пропускаем синтаксическую проверку."
fi

# -----------------------------------------------------------------------------
# Настройка UFW
# -----------------------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow "${port}/tcp" >/dev/null
    success "Порт ${port}/tcp открыт в UFW."
else
    warn "UFW не активен или не установлен. Убедитесь, что порт ${port} открыт в вашем файрволе вручную."
fi

# -----------------------------------------------------------------------------
# Перезапуск и проверка службы
# -----------------------------------------------------------------------------
info "Запуск danted..."
systemctl daemon-reload
systemctl enable danted >/dev/null 2>&1
systemctl restart danted

# Небольшая пауза и проверка статуса
sleep 2
if systemctl is-active --quiet danted; then
    success "Служба danted запущена и работает."
else
    error "Служба danted не запустилась! Диагностика:"
    journalctl -u danted -n 20 --no-pager >&2
    die "Установка прервана из-за ошибки запуска danted."
fi

# -----------------------------------------------------------------------------
# Определение внешнего IP
# -----------------------------------------------------------------------------
info "Определение внешнего IP-адреса..."
EXTERNAL_IP=""
for endpoint in "https://ifconfig.me" "https://api.ipify.org" "https://icanhazip.com"; do
    EXTERNAL_IP=$(curl -s --max-time 5 "$endpoint" 2>/dev/null || true)
    [[ "$EXTERNAL_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
    EXTERNAL_IP=""
done
if [[ -z "$EXTERNAL_IP" ]]; then
    warn "Не удалось определить внешний IP автоматически."
    EXTERNAL_IP="<ВАШ_ВНЕШНИЙ_IP>"
fi

# -----------------------------------------------------------------------------
# Итоговый вывод
# -----------------------------------------------------------------------------
echo ""
echo "============================================================="
echo -e "${GREEN}  SOCKS5-прокси успешно установлен!${NC}"
echo "============================================================="
echo "  IP-адрес : ${EXTERNAL_IP}"
echo "  Порт     : ${port}"
echo "  Логин    : ${username}"
echo "  Пароль   : ${password}"
echo "-------------------------------------------------------------"
echo "  Строки для антидетект-браузеров:"
echo "  ${EXTERNAL_IP}:${port}:${username}:${password}"
echo "  socks5://${username}:${password}@${EXTERNAL_IP}:${port}"
echo "-------------------------------------------------------------"
echo "  Проверка через curl:"
echo "  curl -x socks5://${username}:${password}@${EXTERNAL_IP}:${port} https://ifconfig.me"
echo "-------------------------------------------------------------"
if [[ "$LOGOUTPUT" == "/var/log/danted.log" ]]; then
    echo "  Логи       : tail -f /var/log/danted.log"
else
    echo "  Логи       : journalctl -u danted -f"
fi
echo "  Статус     : systemctl status danted"
echo "  Конфиг     : /etc/danted.conf"
echo "============================================================="
echo ""
