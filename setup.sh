#!/bin/bash

set -e

echo "======================================="
echo " 🚀 3x-ui + Xray Reality Setup"
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
read -p "  ➤ Домен для панели 3x-ui (например, panel.example.com): " PANEL_DOMAIN
read -p "  ➤ Домен для Xray Reality (например, xray.example.com): " XRAY_DOMAIN
read -p "  ➤ Email для Let's Encrypt: " LETSENCRYPT_EMAIL

# Создание .env
cat > .env <<EOF
PANEL_DOMAIN=$PANEL_DOMAIN
XRAY_DOMAIN=$XRAY_DOMAIN
LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL
EOF

echo "✅ Файл .env создан"

# Создание структуры
mkdir -p nginx/conf.d
mkdir -p nginx/html
mkdir -p nginx/logs
mkdir -p certbot/etc-letsencrypt
mkdir -p 3x-ui/data

echo "✅ Структура папок создана"

# Создание nginx.conf с SNI routing
cat > nginx/nginx.conf <<EOFNGINX
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events {
    worker_connections 1024;
}

# Stream модуль для SNI routing на порту 443
stream {
    map \$ssl_preread_server_name \$backend {
        $PANEL_DOMAIN panel_https;
        $XRAY_DOMAIN xray_reality;
        default xray_reality;
    }

    upstream panel_https {
        server 127.0.0.1:8443;
    }

    upstream xray_reality {
        server 3x-ui:443;
    }

    server {
        listen 443;
        listen [::]:443;
        proxy_pass \$backend;
        ssl_preread on;
    }
}

# HTTP модуль
http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;

    log_format main '\$remote_addr - \$remote_user [\$time_local] "\$request" '
                    '\$status \$body_bytes_sent "\$http_referer" '
                    '"\$http_user_agent" "\$http_x_forwarded_for"';

    access_log /var/log/nginx/access.log main;

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 65;
    gzip on;

    include /etc/nginx/conf.d/*.conf;
}
EOFNGINX

echo "✅ nginx.conf создан"

# HTTP конфиг для certbot
cat > nginx/conf.d/http.conf <<'EOFHTTP'
# HTTP для certbot и редиректа
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # ACME challenge для certbot
    location /.well-known/acme-challenge/ {
        root /usr/share/nginx/html;
    }

    # Редирект на HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}
EOFHTTP

echo "✅ HTTP конфиг создан"

# HTTPS конфиг для панели (создадим после получения сертификата)
cat > nginx/conf.d/panel.conf.template <<EOFPANEL
# Панель 3x-ui на внутреннем порту 8443
server {
    listen 8443 ssl;
    http2 on;
    server_name $PANEL_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers on;

    resolver 127.0.0.11 valid=30s;
    set \$upstream_3xui 3x-ui;

    location / {
        proxy_pass http://\$upstream_3xui:2053;
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

echo "✅ Шаблон конфига панели создан"

echo
echo "🌐 Запуск Nginx для получения сертификата..."
docker compose up -d nginx

sleep 3

echo
echo "🔑 Получение Let's Encrypt сертификата для панели..."
docker compose run --rm certbot \
  certonly --webroot \
  -w /usr/share/nginx/html \
  -d "$PANEL_DOMAIN" \
  --email "$LETSENCRYPT_EMAIL" \
  --agree-tos \
  --no-eff-email

if [ $? -eq 0 ]; then
    echo "✅ Сертификат получен"
    
    # Активируем конфиг панели
    cp nginx/conf.d/panel.conf.template nginx/conf.d/panel.conf
    
    echo "♻️ Перезапуск Nginx с SSL..."
    docker compose restart nginx
    
    echo
    echo "🚀 Запуск всего стека..."
    docker compose up -d
    
    echo
    echo "✅ Установка завершена!"
    echo "======================================="
    echo "🔗 Панель 3x-ui: https://$PANEL_DOMAIN"
    echo "🔑 Xray Reality: $XRAY_DOMAIN:443"
    echo "======================================="
    echo
    echo "📝 Важно:"
    echo "1. Зайди в панель: https://$PANEL_DOMAIN"
    echo "2. Создай inbound VLESS Reality на порту 443"
    echo "3. Укажи SNI: $XRAY_DOMAIN"
    echo "4. Настрой dest на любой популярный сайт"
else
    echo "❌ Ошибка получения сертификата"
    echo "Проверь:"
    echo "  - DNS записи для $PANEL_DOMAIN указывают на этот сервер"
    echo "  - Порт 80 открыт в файрволе"
    echo "  - docker compose logs nginx"
fi