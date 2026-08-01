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
