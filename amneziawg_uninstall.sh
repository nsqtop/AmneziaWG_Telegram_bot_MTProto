#!/bin/bash

# ======================================================
# AmneziaWG + MTProto Proxy + Telegram Bot Uninstaller
# ======================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   AmneziaWG Полное удаление и очистка${NC}"
echo -e "${BLUE}======================================================${NC}"
echo -e "${RED}ВНИМАНИЕ: Это действие удалит все настройки VPN, ключи и конфиги пользователей!${NC}"
echo -e "У вас есть 5 секунд чтобы отменить операцию (Ctrl+C)..."
sleep 5

# 1. Остановка и удаление Telegram-бота
echo -e "${YELLOW}[1/5] Удаление Telegram-бота...${NC}"
systemctl stop telegram-bot-awg 2>/dev/null || true
systemctl disable telegram-bot-awg 2>/dev/null || true
rm -f /etc/systemd/system/telegram-bot-awg.service
rm -rf /opt/telegram-bot-awg
rm -f /var/log/telegram-bot-awg.log
rm -f /var/log/telegram-bot-awg-error.log

# 2. Остановка и удаление MTProto Proxy
echo -e "${YELLOW}[2/5] Удаление MTProto Proxy...${NC}"
systemctl stop mtproto 2>/dev/null || true
systemctl disable mtproto 2>/dev/null || true
rm -f /etc/systemd/system/mtproto.service
rm -rf /etc/mtproto
rm -rf /opt/MTProxy
rm -f /usr/local/bin/mtproto-proxy
rm -f /root/mtproto-info.txt

# 3. Остановка и удаление AmneziaWG
echo -e "${YELLOW}[3/5] Удаление AmneziaWG и сброс конфигураций...${NC}"
systemctl stop awg-quick@awg0 2>/dev/null || true
systemctl disable awg-quick@awg0 2>/dev/null || true

# Выгружаем модуль ядра, если он завис (игнорируем ошибки)
modprobe -r amneziawg 2>/dev/null || true

# Удаляем пакеты
apt-get remove --purge -y amneziawg amneziawg-tools amneziawg-dkms 2>/dev/null || true
apt-get autoremove -y 2>/dev/null || true

# Удаляем PPA репозиторий
add-apt-repository --remove ppa:amnezia/ppa -y 2>/dev/null || true

# Очистка директорий с конфигами
rm -rf /etc/amnezia
rm -rf /root/amneziawg-clients

# 4. Очистка Firewall (UFW)
echo -e "${YELLOW}[4/5] Удаление правил Firewall...${NC}"
ufw delete allow 51821/udp 2>/dev/null || true
ufw delete allow 443/tcp 2>/dev/null || true

# 5. Перезагрузка systemd
echo -e "${YELLOW}[5/5] Применение изменений...${NC}"
systemctl daemon-reload

echo -e "${BLUE}======================================================${NC}"
echo -e "${GREEN}✅ AmneziaWG, MTProto Proxy и Telegram-бот полностью удалены!${NC}"
echo -e "${YELLOW}Теперь вы можете заново запустить установку:${NC}"
echo -e "bash /opt/vpn/amneziawg_install.sh"
echo -e "${BLUE}======================================================${NC}"
