# Предварительная проверка зависимостей на Master-узле
apt-get update >/dev/null 2>&1
apt-get install -y sshpass sqlite3 curl jq >/dev/null 2>&1

DB_PATH="/root/master_core.db"
MASTER_IP=$(curl -s4 ifconfig.me) # IP самого Мастера для белых списков файрвола

# ==========================================
# ФУНКЦИЯ 0: Установка Master-узла (Control Plane)
# ==========================================
install_master() {
    clear
    echo "👑 УСТАНОВКА ЯДРА УПРАВЛЕНИЯ (MASTER-NODE)"
    echo "Внимание: Этот сервер не будет пропускать VPN-трафик."
    echo "Он управляет БД, ботом и выдает подписки."
    echo "------------------------------------------------"
    
    read -p "🌐 Введи домен для сервера подписок (напр. sub.domain.com): " SUB_DOMAIN
    read -p "✉️ Email для SSL (Let's Encrypt): " SSL_EMAIL
    read -p "🤖 Введи Токен Telegram-бота: " TG_TOKEN
    read -p "🆔 Введи твой Chat ID (Telegram): " TG_CHAT_ID

    echo "⏳ 1/6 Установка зависимостей..."
    apt-get update >/dev/null 2>&1
    apt-get install -yq nginx certbot python3-certbot-nginx sqlite3 curl ufw git >/dev/null 2>&1

    echo "⏳ 2/6 Настройка Telegram конфига..."
    echo "TG_TOKEN=\"$TG_TOKEN\"" > /root/.vpn_tg.conf
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> /root/.vpn_tg.conf
    chmod 600 /root/.vpn_tg.conf

    echo "⏳ 3/6 Получение SSL-сертификата..."
    systemctl stop nginx
    certbot certonly --standalone -d "$SUB_DOMAIN" -m "$SSL_EMAIL" --agree-tos -n
    
    if[ ! -f "/etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem" ]; then
        echo "❌ Ошибка SSL! Проверь, что домен привязан к IP этого сервера."
        return 1
    fi

    echo "⏳ 4/6 Настройка Nginx (Reverse Proxy)..."
    cat <<EOF > /etc/nginx/sites-available/default
server {
    listen 80;
    server_name $SUB_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $SUB_DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUB_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Защита от сканеров (отдаем 404 на корень)
    location / {
        return 404;
    }

    # Проксирование запросов подписок на Go-бэкенд
    location /sub/ {
        proxy_pass http://127.0.0.1:8080/sub/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        
        # Отключаем кеширование подписок
        add_header Cache-Control "no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0";
    }
}
EOF
    systemctl restart nginx

    echo "⏳ 5/6 Настройка окружения Go и компиляция ядра..."
    cd /tmp
    wget -q https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    
    # Функция из твоего скрипта
    comp_main 

    # Убираем за собой Go, чтобы не занимать место
    rm -rf /usr/local/go /tmp/go1.21.6.linux-amd64.tar.gz

    echo "⏳ 6/6 Настройка Systemd для Master-Core..."
    cat <<EOF > /etc/systemd/system/master-core.service
[Unit]
Description=VPN Cluster Master Core (Go Backend)
After=network.target

[Service]
ExecStart=/usr/local/bin/master-core
Restart=always
RestartSec=5
User=root
WorkingDirectory=/root
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable master-core
    systemctl restart master-core

    # Файрвол: открываем только веб и SSH. gRPC порты (10085) здесь не нужны, они на мостах.
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw --force enable >/dev/null 2>&1

    clear
    echo "🎉 MASTER-УЗЕЛ УСПЕШНО УСТАНОВЛЕН!"
    echo "🌍 Ссылка для подписок настроена на: https://$SUB_DOMAIN/sub/"
    echo "🤖 Telegram бот запущен и ждет команд."
    echo ""
    echo "Следующий шаг: В главном меню добавь EU-Ноду, а затем RU-Мост."
    read -p "Нажми Enter для возврата в меню..."
}

# ==========================================
# ФУНКЦИЯ 1: Развертывание EU-Ноды (Точка выхода)
# ==========================================
deploy_eu_node() {
    echo -e "\n🇪🇺 РАЗВЕРТЫВАНИЕ EU-НОДЫ"
    read -p "Введи публичный IP сервера: " EU_IP
    read -p "Введи Root-пароль: " EU_PASS
    
    # Генерируем уникальный UUID для связи RU-моста и EU-ноды
    RU_EU_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    echo "⏳ Подключаюсь к $EU_IP и устанавливаю ядро..."

    # Выполняем скрипт на удаленном сервере через SSH
    sshpass -p "$EU_PASS" ssh -o StrictHostKeyChecking=no root@"$EU_IP" "bash -s" << EOF
        apt-get update >/dev/null 2>&1
        apt-get install -y curl unzip ufw >/dev/null 2>&1
        
        # Установка Xray
        bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

        # Генерация ключей Reality для EU-ноды
        KEYS=\$(xray x25519)
        PK=\$(echo "\$KEYS" | grep "Private key:" | awk '{print \$3}')
        PUB=\$(echo "\$KEYS" | grep "Public key:" | awk '{print \$3}')
        
        # Сохраняем публичный ключ в файл, чтобы Master мог его прочитать
        echo "\$PUB" > /root/eu_pub.key

        # Создаем конфиг EU-ноды
        cat << 'CFG_EOF' > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$RU_EU_UUID", "flow": "xtls-rprx-vision"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "tcp",
      "security": "reality",
      "realitySettings": {
        "dest": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": "\$PK",
        "shortIds": [""]
      }
    }
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
CFG_EOF

        systemctl restart xray
        ufw --force enable
        ufw allow 443/tcp
        ufw allow 22/tcp
EOF

    # Забираем публичный ключ Reality с EU-ноды
    EU_PUB_KEY=$(sshpass -p "$EU_PASS" ssh -o StrictHostKeyChecking=no root@"$EU_IP" "cat /root/eu_pub.key")

    # Сохраняем связку (UUID + PubKey) локально на Master, чтобы потом передавать её RU-мостам
    echo "$EU_IP|$RU_EU_UUID|$EU_PUB_KEY" >> /root/eu_nodes.list

    # Записываем ноду в БД
    sqlite3 "$DB_PATH" "INSERT INTO nodes (role, public_ip, status) VALUES ('eu_exit', '$EU_IP', 'active');"
    
    echo "✅ EU-Нода успешно развернута и добавлена в кластер!"
}

# ==========================================
# ФУНКЦИЯ 2: Развертывание RU-Моста (с Observatory)
# ==========================================
deploy_ru_node() {
    echo -e "\n🇷🇺 РАЗВЕРТЫВАНИЕ RU-МОСТА (С БАЛАНСИРОВЩИКОМ)"
    read -p "Введи публичный IP RU-сервера: " RU_IP
    read -p "Введи Root-пароль: " RU_PASS
    read -p "Введи домен для маскировки (SNI) [например, mail.ru]: " RU_DOMAIN
    
    if [ ! -f /root/eu_nodes.list ] || [ ! -s /root/eu_nodes.list ]; then
        echo "❌ Ошибка: Список EU-нод пуст! Сначала разверните EU-Ноду."
        return
    fi

    echo "⏳ Подключаюсь к $RU_IP и устанавливаю транзитный мост..."

    # 1. Генерируем массив исходящих соединений (Outbounds) для всех EU-нод
    OUTBOUNDS_JSON=""
    INDEX=1
    while IFS='|' read -r EU_IP RU_EU_UUID EU_PUB; do
        if [ -n "$EU_IP" ]; then
            # Формируем кусок JSON для конкретной EU-ноды
            SNIPPET=$(cat <<EOF
    {
      "tag": "eu-out-$INDEX",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$EU_IP",
          "port": 443,
          "users": [{"id": "$RU_EU_UUID", "encryption": "none", "flow": "xtls-rprx-vision"}]
        }]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "serverName": "www.microsoft.com",
          "publicKey": "$EU_PUB",
          "fingerprint": "chrome"
        }
      }
    }
EOF
)
            if [ $INDEX -gt 1 ]; then OUTBOUNDS_JSON="$OUTBOUNDS_JSON,"; fi
            OUTBOUNDS_JSON="$OUTBOUNDS_JSON$SNIPPET"
            INDEX=$((INDEX+1))
        fi
    done < /root/eu_nodes.list

    # 2. Выполняем установку и заливаем собранный конфиг на RU-мост
    sshpass -p "$RU_PASS" ssh -o StrictHostKeyChecking=no root@"$RU_IP" "bash -s" << EOF
        apt-get update >/dev/null 2>&1
        apt-get install -y curl unzip ufw >/dev/null 2>&1
        bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

        KEYS=\$(xray x25519)
        PK=\$(echo "\$KEYS" | grep "Private key:" | awk '{print \$3}')

        cat << 'CFG_EOF' > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "api": {
    "tag": "api",
    "services": ["HandlerService", "StatsService"]
  },
  
  "observatory": {
    "subjectSelector": ["eu-out-"],
    "probeUrl": "https://www.google.com/generate_204",
    "probeInterval": "1m"
  },

  "inbounds": [
    {
      "tag": "client-in",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$RU_DOMAIN:443",
          "serverNames": ["$RU_DOMAIN"],
          "privateKey": "\$PK",
          "shortIds": [""]
        }
      }
    },
    {
      "tag": "api-in",
      "port": 10085,
      "listen": "0.0.0.0",
      "protocol": "dokodemo-door",
      "settings": {"address": "127.0.0.1"}
    }
  ],
  
  "outbounds": [
    $OUTBOUNDS_JSON,
    {
      "protocol": "freedom",
      "tag": "direct"
    }
  ],
  
  "routing": {
    "balancers": [
      {
        "tag": "eu-balancer",
        "selector": ["eu-out-"]
      }
    ],
    "rules": [
      {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
      {"type": "field", "inboundTag": ["client-in"], "balancerTag": "eu-balancer"}
    ]
  }
}
CFG_EOF

        systemctl restart xray
        ufw --force enable
        ufw allow 443/tcp
        ufw allow 22/tcp
        ufw allow from $MASTER_IP to any port 10085
EOF

    sqlite3 "$DB_PATH" "INSERT INTO nodes (role, internal_ip, public_ip, public_domain, status) VALUES ('ru_bridge', '$RU_IP', '$RU_IP', '$RU_DOMAIN', 'active');"
    echo "✅ RU-Мост развернут! Балансировщик активен и распределяет трафик между $INDEX EU-нодами."
}

comp_main() {

echo "⏳ Компиляция Master Core..."
mkdir -p /usr/src/master-core && cd /usr/src/master-core

# Создаем модуль
go mod init master-core

# Подтягиваем драйвер БД и Telegram
go get github.com/go-telegram-bot-api/telegram-bot-api/v5
go get modernc.org/sqlite

# Подтягиваем ядро Xray для gRPC (это загрузит Protobuf схемы Xray)
go get google.golang.org/grpc
go get github.com/xtls/xray-core/app/proxyman/command
go get github.com/xtls/xray-core/common/protocol
go get github.com/xtls/xray-core/proxy/vless

# Чистим зависимости и компилируем
go mod tidy
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /usr/local/bin/master-core main.go

echo "✅ Бэкенд скомпилирован!"

}
