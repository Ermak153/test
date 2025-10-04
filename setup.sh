#!/bin/bash

set -e

echo "======================================="
echo " 🚀 3x-ui + Xray Reality + HTTPS Proxy Installer"
echo "======================================="

# Проверяем зависимости
if ! command -v docker &> /dev/null; then
  echo "❌ Docker не найден! Установи Docker перед запуском."
  exit 1
fi

if ! command -v docker compose &> /dev/null; then
  echo "❌ Docker Compose не найден! Установи его перед запуском."
  exit 1
fi

echo
echo "🔧 Введи основные параметры:"
read -p "  ➤ Домен для панели (например, panel.example.com): " PANEL_DOMAIN
read -p "  ➤ Домен для Xray Reality (можно тот же, например, panel.example.com): " XRAY_DOMAIN
read -p "  ➤ Домен для HTTPS Proxy (например, proxy.example.com): " PROXY_DOMAIN
read -p "  ➤ Email для Let's Encrypt (например, admin@example.com): " LETSENCRYPT_EMAIL

echo
echo "🔐 Настройка HTTPS Proxy:"
read -p "  ➤ Логин для прокси: " PROXY_USER
read -s -p "  ➤ Пароль для прокси: " PROXY_PASS
echo

# Создаём .env
cat > .env <<EOF
PANEL_DOMAIN=$PANEL_DOMAIN
XRAY_DOMAIN=$XRAY_DOMAIN
PROXY_DOMAIN=$PROXY_DOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
EOF

echo "✅ Файл .env создан."

# Генерация htpasswd
mkdir -p ./https-proxy/users
docker run --rm httpd:alpine htpasswd -nb "$PROXY_USER" "$PROXY_PASS" > ./https-proxy/users/htpasswd
echo "✅ Файл htpasswd создан для $PROXY_USER"

# Создаём сетку и тома
echo
echo "📦 Билдим контейнеры..."
docker compose build

echo
echo "🔒 Перезапуск Fail2ban для применения всех фильтров..."
docker compose restart fail2ban
echo "✅ Fail2ban перезапущен и готов к работе"

echo
echo "ℹ️ Проверяем статус Fail2ban..."
docker exec -it fail2ban fail2ban-client status

# Запускаем nginx без SSL (для валидации доменов)
echo
echo "🌐 Запуск nginx для HTTP-челленджа..."
docker compose up -d nginx

sleep 3

echo
echo "🔑 Получаем Let's Encrypt сертификаты..."
docker compose run --rm certbot certonly --webroot \
  -w /usr/share/nginx/html \
  -d "$PANEL_DOMAIN" \
  -d "$PROXY_DOMAIN" \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos \
  --no-eff-email

echo
echo "♻️ Перезапускаем Nginx с SSL..."
docker compose restart nginx

echo
echo "🚀 Запускаем весь стек..."
docker compose up -d

echo
echo "✅ Установка завершена!"
echo "======================================="
echo "🔗 Панель: https://$PANEL_DOMAIN"
echo "🔑 HTTPS Proxy: https://$PROXY_DOMAIN"
echo "👤 Логин: $PROXY_USER"
echo "🔒 Пароль: $PROXY_PASS"
echo "======================================="