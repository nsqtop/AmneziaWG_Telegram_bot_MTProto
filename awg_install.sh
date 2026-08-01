#!/bin/bash

# ======================================================
# AmneziaWG + MTProto Proxy + Telegram Bot Installer
# Version: 1.1 (Parallel execution ready)
# Author: System Admin
# ======================================================

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging
LOG_FILE="/var/log/awg-install.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${BLUE}======================================================${NC}"
echo -e "${BLUE}   AmneziaWG + MTProto + Telegram Bot Installer${NC}"
echo -e "${BLUE}======================================================${NC}"

# Check root privileges
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root!${NC}" 
    exit 1
fi

# Global variables
SERVER_IP=""
SERVER_PUB_KEY=""
BOT_TOKEN=""
ADMIN_ID=""
PROMO_CODE=""

# Detect OS
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS=$ID
        VERSION=$VERSION_ID
    else
        echo -e "${RED}Unsupported OS${NC}"
        exit 1
    fi
}

# Initial setup
initial_setup() {
    echo -e "${YELLOW}Performing initial system setup...${NC}"
    
    # Update system
    apt-get update -y || { echo -e "${RED}Failed to update packages${NC}"; exit 1; }
    
    # Install basic dependencies
    apt-get install -y curl wget git ufw fail2ban \
        software-properties-common python3-pip \
        python3-venv build-essential linux-headers-$(uname -r) || { echo -e "${RED}Failed to install dependencies${NC}"; exit 1; }
    
    echo -e "${GREEN}✓ Initial setup completed${NC}"
}

# Install AmneziaWG
install_amneziawg() {
    echo -e "${YELLOW}Installing AmneziaWG...${NC}"
    
    # Check if Ubuntu for PPA
    if [[ "$OS" == "ubuntu" ]]; then
        add-apt-repository ppa:amnezia/ppa -y || { echo -e "${RED}Failed to add Amnezia PPA${NC}"; exit 1; }
        apt-get update -y || { echo -e "${RED}Failed to update after adding repository${NC}"; exit 1; }
    else
        echo -e "${YELLOW}Warning: Non-Ubuntu OS detected. Attempting to install without PPA, this may fail if packages are missing.${NC}"
    fi
    
    # Install AmneziaWG
    apt-get install -y amneziawg-tools golang && cd /usr/src && rm -rf amneziawg-go && git clone https://github.com/amnezia-vpn/amneziawg-go.git && cd amneziawg-go && make && cp amneziawg-go /usr/bin/ || { echo -e "${RED}Failed to install AmneziaWG. Make sure you are using a supported OS.${NC}"; exit 1; }
    
    # Enable IP forwarding (idempotent)
    sed -i '/net.ipv4.ip_forward/d' /etc/sysctl.conf
    sed -i '/net.ipv6.conf.all.forwarding/d' /etc/sysctl.conf
    echo "net.ipv4.ip_forward = 1" >> /etc/sysctl.conf
    echo "net.ipv6.conf.all.forwarding = 1" >> /etc/sysctl.conf
    sysctl -p || echo -e "${YELLOW}Warning: Could not apply sysctl settings${NC}"
    
    # Create AmneziaWG directory
    mkdir -p /etc/amnezia/amneziawg
    chmod 700 /etc/amnezia/amneziawg
    
    echo -e "${GREEN}✓ AmneziaWG installed${NC}"
}

# Configure AmneziaWG
configure_amneziawg() {
    echo -e "${YELLOW}Configuring AmneziaWG (Port 443, Subnet 10.0.1.x)...${NC}"
    
    cd /etc/amnezia/amneziawg || { echo -e "${RED}Failed to change directory${NC}"; exit 1; }
    
    # Generate server keys if they don't exist
    if [[ ! -f server_private.key ]]; then
        awg genkey | tee server_private.key | awg pubkey > server_public.key
    fi
    
    SERVER_PRIV_KEY=$(cat server_private.key)
    SERVER_PUB_KEY=$(cat server_public.key)
    
    # Generate random obfuscation parameters for Anti-DPI
    JC=$((3 + RANDOM % 120))
    JMIN=$((10 + RANDOM % 50))
    JMAX=$((JMIN + RANDOM % 1000))
    S1=$((15 + RANDOM % 100))
    S2=$((15 + RANDOM % 100))
    H1=$((100000000 + RANDOM % 2000000000))
    H2=$((100000000 + RANDOM % 2000000000))
    H3=$((100000000 + RANDOM % 2000000000))
    H4=$((100000000 + RANDOM % 2000000000))
    
    # Get server IP
    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || echo "0.0.0.0")
    
    if [[ "$SERVER_IP" == "0.0.0.0" ]]; then
        echo -e "${YELLOW}Warning: Could not detect public IP. Using hostname -I${NC}"
        SERVER_IP=$(hostname -I | awk '{print $1}')
    fi
    
    # Get network interface
    INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
    if [[ -z "$INTERFACE" ]]; then
        INTERFACE="eth0"
        echo -e "${YELLOW}Warning: Could not detect network interface. Using eth0${NC}"
    fi
    
    # Create server config
    cat > /etc/amnezia/amneziawg/awg0.conf <<EOF
[Interface]
Address = 10.0.1.1/24
ListenPort = 443
MTU = 1200
PrivateKey = $SERVER_PRIV_KEY
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4
PostUp = iptables -A FORWARD -i awg0 -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE; ip6tables -A FORWARD -i awg0 -j ACCEPT; ip6tables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i awg0 -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE; ip6tables -D FORWARD -i awg0 -j ACCEPT; ip6tables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE
EOF
    
    # Create client config template
    mkdir -p /root/amneziawg-clients
    
    cat > /root/amneziawg-clients/client-template.conf <<EOF
[Interface]
PrivateKey = 
Address = 
DNS = 8.8.8.8, 1.1.1.1
MTU = 1200
Jc = $JC
Jmin = $JMIN
Jmax = $JMAX
S1 = $S1
S2 = $S2
H1 = $H1
H2 = $H2
H3 = $H3
H4 = $H4

[Peer]
PublicKey = $SERVER_PUB_KEY
Endpoint = $SERVER_IP:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
    
    # Enable AmneziaWG service
    systemctl enable awg-quick@awg0

    # Create clear_users script
    cat << 'SCRIPTEOF' > /opt/vpn/clear_users.sh
#!/bin/bash

echo -e "\e[33mОчистка всех конфигураций пользователей AmneziaWG...\e[0m"

# 1. Остановка бота
echo "Останавливаем Telegram-бота..."
systemctl stop telegram-bot-awg

# 2. Очистка базы данных бота
echo "Очищаем базу данных пользователей бота..."
echo "{}" > /opt/telegram-bot-awg/users.json

# 3. Удаление клиентских файлов
echo "Удаляем клиентские файлы (конфиги и QR-коды)..."
find /root/amneziawg-clients/ -type f -not -name 'client-template.conf' -delete

# 4. Очистка конфигурации сервера (удаление секций [Peer])
echo "Удаляем пиров из конфигурации сервера..."
sed -i '/^\[Peer\]/,$d' /etc/amnezia/amneziawg/awg0.conf

# Добавляем пустую строку в конец для порядка
echo "" >> /etc/amnezia/amneziawg/awg0.conf

# 5. Перезапуск интерфейса
echo "Перезапускаем интерфейс AmneziaWG..."
systemctl restart awg-quick@awg0

# 6. Запуск бота
echo "Запускаем Telegram-бота..."
systemctl start telegram-bot-awg

echo -e "\e[32mГотово! Все пользователи успешно удалены. База чиста.\e[0m"
SCRIPTEOF
    chmod +x /opt/vpn/clear_users.sh
 2>/dev/null || echo -e "${YELLOW}Warning: Could not enable AmneziaWG service${NC}"
    systemctl start awg-quick@awg0 2>/dev/null || echo -e "${YELLOW}Warning: Could not start AmneziaWG service${NC}"
    
    echo -e "${GREEN}✓ AmneziaWG configured with Anti-DPI parameters${NC}"
    echo -e "${BLUE}Server Public Key: ${SERVER_PUB_KEY}${NC}"
}

# Install MTProto Proxy (Docker)
# Install MTProto Proxy (Docker)
install_mtproto() {
    echo -e "${YELLOW}Installing MTProto Proxy (via Docker)...${NC}"
    
    # Check if docker is installed
    if ! command -v docker &> /dev/null; then
        echo -e "${YELLOW}Installing Docker...${NC}"
        apt-get update
        apt-get install -y ca-certificates curl gnupg lsb-release
        mkdir -p /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg || true
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin docker-compose || {
            apt-get install -y docker.io docker-compose
        }
    fi
    
    systemctl enable docker
    systemctl start docker

    mkdir -p /opt/mtproxy
    
    # Generate secret if not exists
    if [ -f /root/mtproto-info.txt ]; then
        secret=$(grep "MTProxy Secret:" /root/mtproto-info.txt | awk '{print $3}')
    fi
    
    if [ -z "$secret" ]; then
        secret=$(head -c 16 /dev/urandom | xxd -ps)
    fi
    
    PROXY_IP=$SERVER_IP
    PROXY_PORT=8443
    PROXY_SECRET=$secret

    cat > /opt/mtproxy/docker-compose.yml <<DOCKEREOF
version: '3'
services:
  mtproxy:
    image: telegrammessenger/proxy:latest
    restart: always
    ports:
      - "${PROXY_PORT}:443"
    environment:
      - SECRET=${PROXY_SECRET}
      - WORKERS=1
DOCKEREOF

    cd /opt/mtproxy
    docker-compose down 2>/dev/null || true
    docker-compose up -d || { echo -e "${RED}Failed to start MTProto container${NC}"; exit 1; }
    
    echo -e "${GREEN}✓ MTProto Proxy installed and running via Docker${NC}"
    
    cat > /root/mtproto-info.txt <<INFOEOF
MTProxy IP: $PROXY_IP
MTProxy Port: $PROXY_PORT
MTProxy Secret: $PROXY_SECRET
MTProxy Link: tg://proxy?server=$PROXY_IP&port=$PROXY_PORT&secret=$PROXY_SECRET
INFOEOF
}

# Setup Telegram Bot
setup_telegram_bot() {
    echo -e "${YELLOW}Setting up AWG Telegram Bot (Isolated)...${NC}"
    
    mkdir -p /opt/telegram-bot-awg
    cd /opt/telegram-bot-awg || { echo -e "${RED}Failed to create bot directory${NC}"; exit 1; }
    
    python3 -m venv /opt/telegram-bot-awg/venv || { echo -e "${RED}Failed to create virtual environment${NC}"; exit 1; }
    /opt/telegram-bot-awg/venv/bin/pip install "python-telegram-bot[job-queue]==20.8" qrcode pillow || { echo -e "${RED}Failed to install Python packages${NC}"; exit 1; }
    
    echo -e "${BLUE}Please enter your AWG Telegram Bot Token (Should be DIFFERENT from the standard WG bot):${NC}"
    read -r BOT_TOKEN
    if [[ -z "$BOT_TOKEN" ]]; then
        echo -e "${RED}Bot token is required${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Please enter your Telegram User ID (admin):${NC}"
    read -r ADMIN_ID
    if [[ -z "$ADMIN_ID" ]]; then
        echo -e "${RED}Admin ID is required${NC}"
        exit 1
    fi
    
    echo -e "${BLUE}Please enter a Promo Code for users to auto-get AWG VPN (leave empty to disable):${NC}"
    read -r PROMO_CODE
    
    # Create bot script
    cat > /opt/telegram-bot-awg/bot.py <<'EOF'
#!/opt/telegram-bot-awg/venv/bin/python
import os
import subprocess
import json
import logging
import qrcode
from io import BytesIO
from datetime import datetime, time
import string
import random
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup
from telegram.ext import Application, CommandHandler, MessageHandler, filters, ContextTypes, CallbackQueryHandler
import re

logging.basicConfig(level=logging.ERROR)
logger = logging.getLogger(__name__)

BOT_TOKEN = os.environ.get('BOT_TOKEN')
ADMIN_ID = int(os.environ.get('ADMIN_ID', 0))

USERS_FILE = '/opt/telegram-bot-awg/users.json'
AWG_DIR = '/etc/amnezia/amneziawg'
CLIENTS_DIR = '/root/amneziawg-clients'
PROMO_FILE = '/opt/telegram-bot-awg/promo.txt'
SERVER_PUB_KEY = None
SERVER_IP = None

def load_promo():
    if os.path.exists(PROMO_FILE):
        with open(PROMO_FILE, 'r') as f:
            return f.read().strip()
    return os.environ.get('PROMO_CODE', '')

def save_promo(code):
    with open(PROMO_FILE, 'w') as f:
        f.write(code)

PROMO_CODE = load_promo()

def get_proxy_link():
    try:
        with open('/root/mtproto-info.txt', 'r') as f:
            for line in f:
                if line.startswith('MTProxy Link:'):
                    return line.replace('MTProxy Link: ', '').strip()
    except:
        pass
    return "Прокси пока не настроен"

def get_unified_caption():
    proxy_link = get_proxy_link()
    return (
        "✅ *VPN Доступ предоставлен!*\n\n"
        "Ваш индивидуальный конфигурационный файл / QR-код для подключения.\n\n"
        "📱 *Как подключиться?*\n"
        "⚠️ _Обычный WireGuard НЕ подойдет!_\n"
        "1. Установите приложение *AmneziaWG*:\n"
        "• [iOS / macOS](https://apps.apple.com/us/app/amneziawg/id6478942365)\n"
        "• [Android](https://play.google.com/store/apps/details?id=org.amnezia.awg)\n"
        "• [Windows](https://github.com/amnezia-vpn/amneziawg-windows-client/releases)\n"
        "2. Откройте приложение, нажмите «+» и выберите «Отсканировать QR-код» или импортируйте файл.\n\n"
        "🛡️ *Telegram Proxy (MTProto)*\n"
        f"🔗 [Нажмите сюда, чтобы подключить Telegram к прокси]({proxy_link})"
    )

async def rotate_promo_job(context: ContextTypes.DEFAULT_TYPE):
    global PROMO_CODE
    if not ADMIN_ID: return
    new_promo = ''.join(random.choices(string.ascii_uppercase + string.digits, k=8))
    PROMO_CODE = new_promo
    save_promo(new_promo)
    try:
        await context.bot.send_message(
            chat_id=ADMIN_ID,
            text=f"🔄 *Ежедневное обновление промокода!*\n\nНовый промокод для получения VPN: `{new_promo}`\n\n_Пользователи могут отправить этот код боту для получения доступа._",
            parse_mode='Markdown'
        )
    except Exception as e:
        logger.error(f"Failed to send new promo to admin: {e}")

def load_server_key():
    global SERVER_PUB_KEY, SERVER_IP
    try:
        with open(f'{AWG_DIR}/server_public.key', 'r') as f:
            SERVER_PUB_KEY = f.read().strip()
        
        with open(f'{AWG_DIR}/awg0.conf', 'r') as f:
            content = f.read()
            with open(f'{CLIENTS_DIR}/client-template.conf', 'r') as tf:
                template = tf.read()
                match = re.search(r'Endpoint = (.+):443', template)
                if match:
                    SERVER_IP = match.group(1)
                else:
                    SERVER_IP = subprocess.check_output(['curl', '-s', 'ifconfig.me']).decode().strip()
    except Exception as e:
        logger.error(f"Error loading server info: {e}")
        SERVER_PUB_KEY = None
        SERVER_IP = "YOUR_SERVER_IP"

def get_awg_params():
    params = {}
    try:
        with open(f'{CLIENTS_DIR}/client-template.conf', 'r') as f:
            for line in f:
                line = line.strip()
                for k in ['Jc', 'Jmin', 'Jmax', 'S1', 'S2', 'H1', 'H2', 'H3', 'H4']:
                    if line.startswith(f"{k} ="):
                        params[k] = line.split('=')[1].strip()
    except:
        pass
    return params

def load_users():
    if os.path.exists(USERS_FILE):
        try:
            with open(USERS_FILE, 'r') as f:
                return json.load(f)
        except:
            return {}
    return {}

def save_users(users):
    try:
        with open(USERS_FILE, 'w') as f:
            json.dump(users, f, indent=2)
        return True
    except:
        return False

def get_next_client_ip():
    users = load_users()
    used_ips = []
    for user in users.values():
        try:
            ip = user.get('ip', '10.0.1.2')
            used_ips.append(int(ip.split('.')[-1]))
        except:
            used_ips.append(2)
    
    for i in range(2, 255):
        if i not in used_ips:
            return f"10.0.1.{i}"
    return None

def generate_awg_config(client_name, tg_user=None):
    try:
        private_key = subprocess.check_output(['awg', 'genkey']).decode().strip()
        public_key = subprocess.check_output(['awg', 'pubkey'], input=private_key.encode()).decode().strip()
        
        client_ip = get_next_client_ip()
        if not client_ip:
            return None, None, None
            
        awg_params = get_awg_params()
        awg_params_str = "\n".join([f"{k} = {v}" for k, v in awg_params.items()])
        
        config = f"""[Interface]
PrivateKey = {private_key}
Address = {client_ip}/24
DNS = 8.8.8.8, 1.1.1.1
MTU = 1200
{awg_params_str}

[Peer]
PublicKey = {SERVER_PUB_KEY}
Endpoint = {SERVER_IP}:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
"""
        
        config_file = f"{CLIENTS_DIR}/{client_name}.conf"
        with open(config_file, 'w') as f:
            f.write(config)
        
        with open(f'{AWG_DIR}/awg0.conf', 'a') as f:
            f.write(f"\n[Peer]\nPublicKey = {public_key}\nAllowedIPs = {client_ip}/32\n")
        
        subprocess.run(['awg', 'set', 'awg0', 'peer', public_key, 'allowed-ips', f'{client_ip}/32'], check=False, timeout=10)
        
        users = load_users()
        user_data = {
            'ip': client_ip,
            'private_key': private_key,
            'public_key': public_key,
            'created': datetime.now().isoformat()
        }
        if tg_user:
            user_data['tg_id'] = tg_user.id
            user_data['tg_username'] = tg_user.username
            user_data['tg_fullname'] = tg_user.full_name
        users[client_name] = user_data
        save_users(users)
        
        return config, client_ip, private_key
    except Exception as e:
        logger.error(f"Error generating config: {e}")
        return None, None, None

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    
    if user_id != ADMIN_ID:
        args = context.args
        if args and PROMO_CODE and args[0] == PROMO_CODE:
            await process_promo(update, context)
        else:
            await update.message.reply_text("👋 Welcome to AmneziaWG VPN!\nPlease provide a valid promo code to get your VPN access.\nUsage: /start <promocode> or just send the code in chat.")
        return
    
    keyboard = [
        [InlineKeyboardButton("📱 Generate Client (QR + File)", callback_data='generate_client')],
        [InlineKeyboardButton("📋 List Clients", callback_data='list_clients')],
        [InlineKeyboardButton("🗑️ Delete Client", callback_data='delete_client')],
        [InlineKeyboardButton("📊 Proxy Info", callback_data='proxy_info')],
        [InlineKeyboardButton("📦 MTProto Link", callback_data='mtproto_link')]
    ]
    reply_markup = InlineKeyboardMarkup(keyboard)
    
    await update.message.reply_text(
        "🔐 *AmneziaWG VPN Management Bot*\n\n"
        f"Текущий промокод: `{PROMO_CODE}`\n\n"
        "Select an action:",
        reply_markup=reply_markup,
        parse_mode='Markdown'
    )

async def button_callback(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    user_id = update.effective_user.id
    if user_id != ADMIN_ID:
        await query.edit_message_text("⛔ Access denied.")
        return
    
    if query.data == 'generate_client':
        await query.edit_message_text("📱 Enter client name (only letters/numbers):")
        context.user_data['action'] = 'generate_client'
    elif query.data == 'list_clients':
        await list_clients(update, context)
    elif query.data == 'delete_client':
        await delete_client_prompt(update, context)
    elif query.data == 'proxy_info':
        await proxy_info(update, context)
    elif query.data == 'mtproto_link':
        await mtproto_link(update, context)

async def send_unified_config(context_or_update, client_name, config_data):
    qr = qrcode.QRCode(version=1, box_size=10, border=5)
    qr.add_data(config_data)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    bio = BytesIO()
    img.save(bio, 'PNG')
    bio.seek(0)
    
    caption = get_unified_caption()
    
    if isinstance(context_or_update, Update):
        await context_or_update.message.reply_photo(photo=bio, caption=caption, parse_mode='Markdown')
        config_file = f"{CLIENTS_DIR}/{client_name}.conf"
        with open(config_file, 'rb') as f:
            await context_or_update.message.reply_document(document=f, filename=f"{client_name}.conf")

async def process_promo(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user = update.effective_user
    base_client_name = f"tg_{user.id}"
    if user.username:
        base_client_name += f"_{user.username}"
    
    users = load_users()
    client_name = base_client_name
    counter = 1
    while client_name in users:
        client_name = f"{base_client_name}_{counter}"
        counter += 1

    await update.message.reply_text("⏳ Generating your personal AmneziaWG (Anti-DPI) VPN configuration...")
    config, client_ip, private_key = generate_awg_config(client_name, user)
    if not config:
        await update.message.reply_text("❌ Server is full or error occurred. Please contact admin.")
        return
        
    try:
        await context.bot.send_message(
            chat_id=ADMIN_ID,
            text=(
                f"🆕 *New Promo Code Usage*\n"
                f"User: {user.full_name} (@{user.username or 'N/A'})\n"
                f"ID: {user.id}\n"
                f"Client: {client_name}"
            ),
            parse_mode='Markdown'
        )
    except Exception as e:
        logger.error(f"Failed to notify admin: {e}")

    config_file = f"{CLIENTS_DIR}/{client_name}.conf"
    try:
        with open(config_file, 'r') as f:
            config_data = f.read()
        await send_unified_config(update, client_name, config_data)
    except Exception as e:
        logger.error(f"Error sending config to user: {e}")
        await update.message.reply_text("❌ Error retrieving your configuration. Contact admin.")

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    text = update.message.text.strip()
    
    if user_id != ADMIN_ID:
        if PROMO_CODE and text == PROMO_CODE:
            await process_promo(update, context)
        else:
            await update.message.reply_text("❌ Invalid promo code.")
        return
    
    client_name = text
    
    if not client_name:
        await update.message.reply_text("❌ Client name cannot be empty.")
        return
    
    if not re.match(r'^[a-zA-Z0-9_-]+$', client_name):
        await update.message.reply_text("❌ Invalid client name. Use only letters, numbers, underscore and dash.")
        return
    
    action = context.user_data.get('action')
    
    if action == 'generate_client':
        await generate_action(update, context, client_name)
    else:
        await update.message.reply_text("❌ Unknown action. Please use /start")
    
    context.user_data['action'] = None

async def generate_action(update: Update, context: ContextTypes.DEFAULT_TYPE, client_name):
    try:
        users = load_users()
        if client_name in users:
            await update.message.reply_text(f"❌ Client '{client_name}' already exists.")
            return
        
        config, client_ip, private_key = generate_awg_config(client_name)
        if not config:
            await update.message.reply_text("❌ No available IP addresses or error generating config.")
            return
        
        await send_unified_config(update, client_name, config)
    except Exception as e:
        await update.message.reply_text(f"❌ Error: {str(e)}")

async def list_clients(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if user_id != ADMIN_ID: return
    
    users = load_users()
    if not users:
        await update.callback_query.edit_message_text("📋 No clients configured.")
        return
    
    text = "📋 *Connected AWG Clients:*\n\n"
    for name, info in users.items():
        created = info.get('created', 'Unknown')[:10]
        text += f"• *{name}*: IP {info.get('ip', 'N/A')}\n  Created: {created}\n"
        if info.get('tg_id'):
            text += f"  👤 User: {info.get('tg_fullname', '')} (@{info.get('tg_username', 'N/A')}) ID: {info.get('tg_id')}\n"
    
    await update.callback_query.edit_message_text(text, parse_mode='Markdown')

async def delete_client_prompt(update: Update, context: ContextTypes.DEFAULT_TYPE):
    user_id = update.effective_user.id
    if user_id != ADMIN_ID: return
    
    users = load_users()
    if not users:
        await update.callback_query.edit_message_text("📋 No clients to delete.")
        return
    
    keyboard = [[InlineKeyboardButton(name, callback_data=f'delete_{name}')] for name in users.keys()]
    keyboard.append([InlineKeyboardButton("❌ Cancel", callback_data='cancel_delete')])
    await update.callback_query.edit_message_text("🗑️ Select client to delete:", reply_markup=InlineKeyboardMarkup(keyboard))

async def delete_client_action(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    
    user_id = update.effective_user.id
    if user_id != ADMIN_ID: return
    
    client_name = query.data.replace('delete_', '')
    users = load_users()
    if client_name not in users:
        await query.edit_message_text("❌ Client not found.")
        return
    
    try:
        config_file = f"{CLIENTS_DIR}/{client_name}.conf"
        if os.path.exists(config_file):
            os.remove(config_file)
        
        public_key = users[client_name].get('public_key')
        del users[client_name]
        save_users(users)
        
        if public_key:
            subprocess.run(['awg', 'set', 'awg0', 'peer', public_key, 'remove'], check=False, timeout=10)
            try:
                with open(f'{AWG_DIR}/awg0.conf', 'r') as f:
                    content = f.read()
                new_content = []
                blocks = content.split('[Peer]')
                new_content.append(blocks[0])
                for block in blocks[1:]:
                    if f"PublicKey = {public_key}" in block: continue
                    new_content.append('[Peer]' + block)
                with open(f'{AWG_DIR}/awg0.conf', 'w') as f:
                    f.write(''.join(new_content))
            except Exception as e:
                logger.error(f"Error updating awg0.conf: {e}")
        
        await query.edit_message_text(f"✅ Client '{client_name}' deleted successfully.")
    except Exception as e:
        await query.edit_message_text(f"❌ Error deleting client: {str(e)}")

async def cancel_delete(update: Update, context: ContextTypes.DEFAULT_TYPE):
    query = update.callback_query
    await query.answer()
    await query.edit_message_text("❌ Operation cancelled.")

async def proxy_info(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        with open('/root/mtproto-info.txt', 'r') as f:
            info = f.read()
        await update.callback_query.edit_message_text(f"📊 *MTProto Proxy Info*\n\n{info}", parse_mode='Markdown')
    except:
        await update.callback_query.edit_message_text("❌ Proxy info not available.")

async def mtproto_link(update: Update, context: ContextTypes.DEFAULT_TYPE):
    try:
        with open('/root/mtproto-info.txt', 'r') as f:
            link = [line for line in f.readlines() if line.startswith('MTProxy Link:')][0]
        await update.callback_query.edit_message_text(f"🔗 *MTProto Proxy Link*\n\n{link}\n\nClick to connect.", parse_mode='Markdown')
    except:
        await update.callback_query.edit_message_text("❌ MTProto link not available.")

async def error_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    logger.error(f"Error: {context.error}")

def main():
    load_server_key()
    app = Application.builder().token(BOT_TOKEN).build()
    
    # Add JobQueue for promo rotation
    if ADMIN_ID:
        job_queue = app.job_queue
        # Run rotation every 24 hours
        job_queue.run_repeating(rotate_promo_job, interval=86400, first=86400)
    
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CallbackQueryHandler(button_callback))
    app.add_handler(CallbackQueryHandler(delete_client_action, pattern='^delete_'))
    app.add_handler(CallbackQueryHandler(cancel_delete, pattern='^cancel_delete'))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    app.add_error_handler(error_handler)
    app.run_polling(allowed_updates=Update.ALL_TYPES)

if __name__ == '__main__':
    main()

EOF
    
    cat > /etc/systemd/system/telegram-bot-awg.service <<EOF
[Unit]
Description=Telegram AmneziaWG Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=/opt/telegram-bot-awg
Environment="BOT_TOKEN=$BOT_TOKEN"
Environment="ADMIN_ID=$ADMIN_ID"
Environment="PROMO_CODE=$PROMO_CODE"
ExecStart=/opt/telegram-bot-awg/venv/bin/python /opt/telegram-bot-awg/bot.py
Restart=on-failure
RestartSec=10
User=root
StandardOutput=append:/var/log/telegram-bot-awg.log
StandardError=append:/var/log/telegram-bot-awg-error.log

[Install]
WantedBy=multi-user.target
EOF
    
    touch /var/log/telegram-bot-awg.log
    touch /var/log/telegram-bot-awg-error.log
    
    systemctl daemon-reload
    systemctl enable telegram-bot-awg 2>/dev/null || echo -e "${YELLOW}Warning: Could not enable telegram-bot-awg service${NC}"
    systemctl start telegram-bot-awg 2>/dev/null || echo -e "${YELLOW}Warning: Could not start telegram-bot-awg service${NC}"
    
    echo -e "${GREEN}✓ AWG Telegram Bot configured and started${NC}"
}

# Configure firewall
configure_firewall() {
    echo -e "${YELLOW}Configuring firewall...${NC}"
    
    ufw default deny incoming 2>/dev/null
    ufw default allow outgoing 2>/dev/null
    ufw allow 22/tcp 2>/dev/null
    ufw allow 443/udp 2>/dev/null
    ufw allow 443/tcp 2>/dev/null
    
    if [[ -f /etc/ssh/sshd_config ]]; then
        SSH_PORT=$(grep "^Port" /etc/ssh/sshd_config | awk '{print $2}')
        if [[ -n "$SSH_PORT" && "$SSH_PORT" != "22" ]]; then
            ufw allow "$SSH_PORT"/tcp 2>/dev/null
        fi
    fi
    
    ufw --force enable 2>/dev/null || echo -e "${YELLOW}Warning: Could not enable UFW${NC}"
    echo -e "${GREEN}✓ Firewall configured for AWG${NC}"
}

# Setup auto-updates
setup_updates() {
    echo -e "${YELLOW}Setting up automatic updates...${NC}"
    
    apt-get install -y unattended-upgrades || echo -e "${YELLOW}Warning: Could not install unattended-upgrades${NC}"
    
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
EOF
    
    echo -e "${GREEN}✓ Automatic updates configured${NC}"
}

# Show completion message
show_completion() {
    echo -e "${BLUE}======================================================${NC}"
    echo -e "${GREEN}✅ AmneziaWG Installation complete!${NC}"
    echo -e "${BLUE}======================================================${NC}"
    
    SERVER_IP=$(curl -s ifconfig.me || curl -s icanhazip.com || hostname -I | awk '{print $1}')
    
    if [[ -f /etc/amnezia/amneziawg/server_public.key ]]; then
        SERVER_PUB_KEY=$(cat /etc/amnezia/amneziawg/server_public.key)
    else
        SERVER_PUB_KEY="Not available"
    fi
    
    echo -e "${GREEN}AmneziaWG Configuration:${NC}"
    echo -e "Server IP: ${SERVER_IP}"
    echo -e "Port: 443"
    echo -e "Subnet: 10.0.1.x"
    echo -e "Obfuscation: Enabled (Anti-DPI)"
    echo -e ""
    
    echo -e "${GREEN}MTProto Proxy:${NC}"
    if [[ -f /root/mtproto-info.txt ]]; then
        cat /root/mtproto-info.txt
    else
        echo "Check standard WG bot for MTProxy info."
    fi
    echo -e ""
    
    echo -e "${GREEN}AWG Bot:${NC}"
    echo -e "Use /start in Telegram to interact"
    echo -e "Logs: /var/log/telegram-bot-awg.log"
    echo -e ""
    
    echo -e "${YELLOW}Important files:${NC}"
    echo -e "Server config: /etc/amnezia/amneziawg/awg0.conf"
    echo -e "Client configs: /root/amneziawg-clients/"
    echo -e ""
    echo -e "${RED}⚠️  Note:${NC} Clients MUST use the official AmneziaWG app to connect (standard WireGuard app will not work due to obfuscation)."
}

# Verify installation and status
verify_installation() {
    echo -e "${YELLOW}Verifying installation and services status...${NC}"
    local HAS_ERRORS=0

    # 1. Check IP Forwarding
    FORWARDING=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$FORWARDING" == "1" ]]; then
        echo -e "${GREEN}✓ IP Forwarding is ENABLED${NC}"
    else
        echo -e "${RED}✗ IP Forwarding is DISABLED${NC}"
        HAS_ERRORS=1
    fi

    # 2. Check AmneziaWG Service
    if systemctl is-active --quiet awg-quick@awg0; then
        echo -e "${GREEN}✓ AmneziaWG Service is RUNNING${NC}"
    else
        echo -e "${RED}✗ AmneziaWG Service is NOT RUNNING${NC}"
        HAS_ERRORS=1
    fi

    # 3. Check MTProto Service (Docker)
    if docker ps | grep -q mtproxy; then
        echo -e "${GREEN}✓ MTProto Proxy is RUNNING (Docker)${NC}"
    else
        echo -e "${RED}✗ MTProto Proxy is NOT RUNNING${NC}"
        HAS_ERRORS=1
    fi

    # 4. Check Telegram Bot Service
    if systemctl is-active --quiet telegram-bot-awg; then
        echo -e "${GREEN}✓ Telegram Bot Service is RUNNING${NC}"
    else
        echo -e "${RED}✗ Telegram Bot Service is NOT RUNNING${NC}"
        HAS_ERRORS=1
    fi

    # 5. Check UFW rules for AmneziaWG (port 443)
    if ufw status | grep -q "443/udp"; then
        echo -e "${GREEN}✓ UFW rule for AmneziaWG (443/udp) is PRESENT${NC}"
    else
        echo -e "${RED}✗ UFW rule for AmneziaWG (443/udp) is MISSING${NC}"
        HAS_ERRORS=1
    fi

    if [[ $HAS_ERRORS -eq 1 ]]; then
        echo -e "${RED}⚠️  Some checks failed. Please review the errors above and check the logs: ${LOG_FILE}${NC}"
    else
        echo -e "${GREEN}✅ All services are up and running perfectly!${NC}"
    fi
}

# Main execution
main() {
    detect_os
    
    if [[ "$OS" != "ubuntu" && "$OS" != "debian" ]]; then
        echo -e "${RED}Error: Only Ubuntu and Debian are supported${NC}"
        exit 1
    fi
    
    initial_setup
    install_amneziawg
    configure_amneziawg
    install_mtproto
    setup_telegram_bot
    configure_firewall
    setup_updates
    show_completion
    verify_installation
}

main
