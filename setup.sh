#!/bin/bash

set -e

echo "======================================="
echo " 🚀 3x-ui + Xray Reality + HTTPS Proxy + Nginx"
echo "======================================="

# Проверка Docker
if ! command -v docker &> /dev/null; then
  echo "⚡ Docker не найден. Устанавливаем..."
  apt update
  apt install -y docker.io
  systemctl enable docker
  systemctl start docker
  echo "✅ Docker установлен"
fi

# Проверка Docker Compose
if ! docker compose version &> /dev/null; then
  echo "⚡ Docker Compose (v2) не найден. Устанавливаем..."
  apt update -y
  apt install -y curl jq
  
  COMPOSE_VERSION=$(curl -s https://api.github.com/repos/docker/compose/releases/latest | jq -r .tag_name)
  mkdir -p /usr/lib/docker/cli-plugins
  curl -SL https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64 \
    -o /usr/lib/docker/cli-plugins/docker-compose
  chmod +x /usr/lib/docker/cli-plugins/docker-compose
  
  echo "✅ Docker Compose установлен (${COMPOSE_VERSION})"
fi

# Ввод параметров
echo
echo "🔧 Введи параметры:"
read -p "  ➤ Домен для панели (например, panel.example.com): " PANEL_DOMAIN
read -p "  ➤ Домен для Xray Reality (например, xray.example.com): " XRAY_DOMAIN
read -p "  ➤ Домен для HTTPS Proxy (например, proxy.example.com): " PROXY_DOMAIN
read -p "  ➤ Email для Let's Encrypt: " LETSENCRYPT_EMAIL

echo
echo "🔐 HTTPS Proxy:"
read -p "  ➤ Логин: " PROXY_USER
read -s -p "  ➤ Пароль: " PROXY_PASS
echo

# Создание .env
cat > .env <<EOF
PANEL_DOMAIN=$PANEL_DOMAIN
XRAY_DOMAIN=$XRAY_DOMAIN
PROXY_DOMAIN=$PROXY_DOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
EOF

echo "✅ Файл .env создан"

# Создание структуры папок
mkdir -p nginx/conf/{http.d,stream.d}
mkdir -p nginx/html
mkdir -p nginx/logs
mkdir -p certbot/etc-letsencrypt
mkdir -p https-proxy/users
mkdir -p 3x-ui/data
mkdir -p fail2ban/{jail.d,filter.d,action.d}

echo "✅ Структура папок создана"

# Генерация htpasswd для прокси
docker run --rm httpd:alpine htpasswd -nb "$PROXY_USER" "$PROXY_PASS" > ./https-proxy/users/htpasswd
echo "✅ htpasswd создан"

# Создание основного nginx.conf
cat > nginx/conf/nginx.conf <<'EOFNGINX'
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

# Stream модуль для роутинга по SNI
stream {
    include /etc/nginx/stream.d/*.conf;
}

# HTTP модуль для панели и certbot
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                    '$status $body_bytes_sent "$http_referer" '
                    '"$http_user_agent" "$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    types_hash_max_size 2048;

    gzip on;
    gzip_vary on;
    gzip_types text/plain text/css text/xml text/javascript 
               application/x-javascript application/xml+rss application/json;

    include /etc/nginx/http.d/*.conf;
}
EOFNGINX

echo "✅ nginx.conf создан"

# Создание SNI routing конфига
cat > nginx/conf/stream.d/sni-routing.conf <<EOFSNI
# Маппинг SNI -> upstream
map \$ssl_preread_server_name \$backend {
    # Для Xray Reality
    $XRAY_DOMAIN xray;
    
    # Для панели и прокси - обычный HTTPS
    default https_backend;
}

# Upstream для Xray Reality
upstream xray {
    server 3x-ui:8443;
}

# Upstream для обычного HTTPS (панель, прокси)
upstream https_backend {
    server 127.0.0.1:8443;
}

# Основной сервер на 443 с SNI routing
server {
    listen 443 reuseport;
    listen [::]:443 reuseport;
    
    proxy_pass \$backend;
    ssl_preread on;
}
EOFSNI

echo "✅ SNI routing конфиг создан"

# Создание HTTP redirect конфига
cat > nginx/conf/http.d/http-redirect.conf <<'EOFHTTP'
# HTTP -> HTTPS редирект + webroot для certbot
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Для ACME challenge
    location /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
    }

    # Редирект всего остального на HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}
EOFHTTP

echo "✅ HTTP redirect конфиг создан"

# Создание конфига панели
cat > nginx/conf/http.d/panel.conf <<EOFPANEL
# Панель 3x-ui
server {
    listen 8443 ssl http2;
    server_name $PANEL_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    location / {
        proxy_pass http://3x-ui:2053;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        
        # WebSocket support
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        
        proxy_redirect off;
        proxy_buffering off;
    }
}
EOFPANEL

echo "✅ Конфиг панели создан"

# Создание конфига прокси
cat > nginx/conf/http.d/proxy.conf <<EOFPROXY
# HTTPS Proxy
server {
    listen 8443 ssl http2;
    server_name $PROXY_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$PROXY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PROXY_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        proxy_pass http://https-proxy:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOFPROXY

echo "✅ Конфиг прокси создан"

echo
echo "📦 Билдим контейнеры..."
docker compose build

echo
echo "🌐 Запуск Nginx для HTTP-челленджа..."
docker compose up -d nginx

sleep 5

echo
echo "🔑 Получение Let's Encrypt сертификатов..."

# Получение сертификата для панели
docker compose run --rm certbot \
  certonly --webroot \
  -w /usr/share/nginx/html \
  -d "$PANEL_DOMAIN" \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos \
  --no-eff-email

# Получение сертификата для прокси
docker compose run --rm certbot \
  certonly --webroot \
  -w /usr/share/nginx/html \
  -d "$PROXY_DOMAIN" \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos \
  --no-eff-email

echo "✅ Сертификаты получены"

echo
echo "♻️ Перезапуск Nginx с SSL..."
docker compose restart nginx

echo
echo "🚀 Запуск всего стека..."
docker compose up -d

echo
echo "✅ Установка завершена!"
echo "======================================="
echo "🔗 Панель: https://$PANEL_DOMAIN"
echo "🔑 Xray Reality: $XRAY_DOMAIN:443"
echo "🌐 HTTPS Proxy: https://$PROXY_DOMAIN"
echo "👤 Логин прокси: $PROXY_USER"
echo "🔒 Пароль прокси: $PROXY_PASS"
echo "======================================="
echo
echo "⚠️  ВАЖНО: В панели 3x-ui настрой Xray Reality на порт 8443"
echo "   SNI routing автоматически перенаправит трафик"