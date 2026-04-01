#!/bin/bash
# =============================================================================
# SOCKS5 Proxy Uninstaller (Dante/danted)
# Версия: 2.0
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

[[ "$EUID" -ne 0 ]] && die "Скрипт необходимо запускать от имени root (sudo ./uninstall_socks5.sh)"

echo ""
echo "============================================================="
echo "      Удаление SOCKS5-прокси (Dante/danted)"
echo "============================================================="
echo ""
read -rp "Вы уверены, что хотите полностью удалить SOCKS5-прокси? (y/n): " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { info "Удаление отменено."; exit 0; }

# -----------------------------------------------------------------------------
# Считываем порт и пользователей ДО удаления конфига
# -----------------------------------------------------------------------------
PROXY_PORT=""
PROXY_USERS=()

if [[ -f /etc/danted.conf ]]; then
    # Извлекаем порт из строки вида: internal: <iface> port = <port>
    PROXY_PORT=$(grep -E '^\s*internal:' /etc/danted.conf 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="port" || $i=="=") continue; else if($(i+1)=="=" || $(i-1)=="=") print $i}' \
        | grep -E '^[0-9]+$' | head -n1 || true)

    # Более надёжный вариант парсинга порта
    if [[ -z "$PROXY_PORT" ]]; then
        PROXY_PORT=$(grep -oP 'port\s*=\s*\K[0-9]+' /etc/danted.conf | head -n1 || true)
    fi
fi

# Ищем системных пользователей со shell /usr/sbin/nologin или /bin/false,
# созданных не ранее чем стандартные системные аккаунты (UID >= 100, <= 999)
mapfile -t PROXY_USERS < <(
    getent passwd | awk -F: '$7 ~ /nologin|false/ && $3 >= 100 && $3 <= 999 {print $1}' \
    | grep -vE '^(nobody|daemon|bin|sys|sync|games|man|lp|mail|news|uucp|proxy|www-data|backup|list|irc|gnats|systemd|messagebus|sshd|_apt|landscape|pollinate|ubuntu)$' \
    || true
)

# -----------------------------------------------------------------------------
# Остановка и удаление службы
# -----------------------------------------------------------------------------
info "Остановка службы danted..."
if systemctl is-active --quiet danted 2>/dev/null; then
    systemctl stop danted
    success "Служба остановлена."
else
    warn "Служба danted уже не запущена."
fi

systemctl disable danted 2>/dev/null || true
success "Служба отключена из автозагрузки."

# -----------------------------------------------------------------------------
# Удаление пакета
# -----------------------------------------------------------------------------
info "Удаление пакета dante-server..."
if dpkg -l dante-server &>/dev/null; then
    apt-get remove --purge -y dante-server -qq
    apt-get autoremove -y -qq
    success "Пакет dante-server удалён."
else
    warn "Пакет dante-server не установлен."
fi

# -----------------------------------------------------------------------------
# Удаление конфигов и файлов
# -----------------------------------------------------------------------------
info "Удаление конфигурационных файлов..."
FILES_TO_REMOVE=(
    /etc/danted.conf
    /etc/pam.d/sockd
    /run/danted.pid
    /var/run/danted.pid
    /etc/logrotate.d/danted
    /var/log/danted.log
)
for f in "${FILES_TO_REMOVE[@]}"; do
    if [[ -e "$f" ]]; then
        rm -f "$f"
        info "  Удалён: ${f}"
    fi
done

# Бэкапы конфигов
find /etc -maxdepth 1 -name 'danted.conf.bak.*' -exec rm -f {} \; 2>/dev/null || true
success "Конфигурационные файлы удалены."

# -----------------------------------------------------------------------------
# Удаление пользователей
# -----------------------------------------------------------------------------
if [[ ${#PROXY_USERS[@]} -gt 0 ]]; then
    echo ""
    warn "Обнаружены системные пользователи, которые могли использоваться прокси:"
    for u in "${PROXY_USERS[@]}"; do
        echo "  - ${u}"
    done
    read -rp "Удалить всех перечисленных пользователей? (y/n): " del_users
    if [[ "$del_users" =~ ^[Yy]$ ]]; then
        for u in "${PROXY_USERS[@]}"; do
            if id "$u" &>/dev/null; then
                userdel "$u" 2>/dev/null && success "Пользователь '${u}' удалён." \
                    || warn "Не удалось удалить пользователя '${u}'."
            fi
        done
    else
        info "Пользователи оставлены без изменений."
    fi
else
    info "Прокси-пользователи не найдены."
fi

# -----------------------------------------------------------------------------
# Очистка UFW
# -----------------------------------------------------------------------------
if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [[ -n "$PROXY_PORT" ]]; then
        info "Удаление правила UFW для порта ${PROXY_PORT}/tcp..."
        ufw delete allow "${PROXY_PORT}/tcp" 2>/dev/null && \
            success "Правило UFW удалено." || \
            warn "Правило UFW для порта ${PROXY_PORT} не найдено (возможно, уже удалено)."
    else
        warn "Порт прокси не определён — правило UFW нужно удалить вручную: ufw delete allow <порт>/tcp"
    fi
else
    info "UFW не активен, пропуск очистки правил."
fi

# -----------------------------------------------------------------------------
# Итог
# -----------------------------------------------------------------------------
echo ""
echo "============================================================="
success "SOCKS5-прокси (Dante) полностью удалён."
echo "============================================================="
echo ""

read -rp "Хотите перезагрузить сервер? (y/n) [n]: " reboot_choice
reboot_choice="${reboot_choice:-n}"
if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
    info "Перезагрузка через 3 секунды..."
    sleep 3
    reboot
else
    info "Перезагрузка отменена. Система работает без прокси."
fi
