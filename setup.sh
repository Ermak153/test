#!/bin/bash

set -e

echo "======================================="
echo " 🚀 3x-ui + Xray Reality + HTTPS Proxy Installer"
echo "======================================="

# Проверяем зависимости
if ! command -v docker &> /dev/null; then
  echo "⚡ Docker не найден. Устанавливаем..."
  apt update
  apt install -y docker.io
  systemctl enable docker
  systemctl start docker
  echo "✅ Docker установлен"
fi

if ! docker compose version &> /dev/null; then
  echo "⚡ Docker Compose (v2) не найден. Устанавливаем последнюю версию..."

  # Устанавливаем зависимости
  apt update -y
  apt install -y curl jq

  # Определяем последнюю версию с GitHub
  COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)

  # Скачиваем бинарник и делаем его исполняемым
  mkdir -p /usr/lib/docker/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64 -o /usr/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/lib/docker/cli-plugins/docker-compose

  echo "✅ Docker Compose v2 установлен (версия ${COMPOSE_VERSION})"
else
  echo "✅ Docker Compose уже установлен"
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
echo "🔒 Поднимаем Fail2ban и применяем фильтры..."
docker compose up -d fail2ban
echo "✅ Fail2ban поднят"

# Запускаем nginx без SSL (для валидации доменов)
echo
echo "🌐 Запуск nginx для HTTP-челленджа..."
docker compose up -d nginx

sleep 3

echo
echo "🔑 Получаем Let's Encrypt сертификаты..."
docker compose run --rm certbot \
  certonly --webroot \
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