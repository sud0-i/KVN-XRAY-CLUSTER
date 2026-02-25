#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
DB_PATH="/root/master_core.db"
MASTER_IP=$(curl -s4 ifconfig.me)

if ! command -v jq &> /dev/null || ! command -v sqlite3 &> /dev/null; then
    apt-get update -q >/dev/null 2>&1
    apt-get install -yq jq sqlite3 curl sshpass openssl >/dev/null 2>&1
fi

# ==========================================
# ДАШБОРД (СТАТУС СИСТЕМЫ)
# ==========================================
show_dashboard() {
    clear
    echo "========================================================="
    echo "👑 MASTER-УЗЕЛ УПРАВЛЕНИЯ VPN CLUSTER v2.0 (xHTTP Edition)"
    echo "========================================================="
    
    local CPU=$(top -bn1 | grep load | awk '{printf "%.2f", $(NF-2)}')
    local RAM=$(free -m | awk 'NR==2{printf "%s/%sMB", $3,$2}')
    local CORE_STAT=$(systemctl is-active master-core 2>/dev/null)
    
    [[ "$CORE_STAT" == "active" ]] && CORE_STAT="🟢 Активен (Go Backend)" || CORE_STAT="🔴 Отключен"
    
    local USERS_COUNT="0"; local RU_COUNT="0"; local EU_COUNT="0"

    if [ -f "$DB_PATH" ]; then
        USERS_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
        RU_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM nodes WHERE role='ru_bridge';" 2>/dev/null || echo "0")
        EU_COUNT=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM nodes WHERE role='eu_exit';" 2>/dev/null || echo "0")
    fi

    echo "📊 Сервер: CPU: $CPU | RAM: $RAM"
    echo "⚙️  Ядро: $CORE_STAT"
    echo "🗄  База: 👥 Юзеров: $USERS_COUNT | 🇷🇺 Мостов: $RU_COUNT | 🇪🇺 Нод: $EU_COUNT"
    echo "========================================================="
}

# ==========================================
# ФУНКЦИЯ 1: Установка Master-узла (Control Plane)
# ==========================================
install_master() {
    echo -e "\n👑 УСТАНОВКА ЯДРА УПРАВЛЕНИЯ (MASTER-NODE)"
    read -p "🌐 Введи домен для сервера подписок (напр. sub.domain.com): " SUB_DOMAIN
    read -p "✉️ Email для SSL (Let's Encrypt): " SSL_EMAIL
    read -p "🤖 Введи Токен Telegram-бота: " TG_TOKEN
    read -p "🆔 Введи твой Chat ID (Telegram): " TG_CHAT_ID

    echo "⏳ 1/6 Установка зависимостей..."
    apt-get update >/dev/null 2>&1
    apt-get install -yq nginx certbot python3-certbot-nginx sqlite3 curl ufw git sshpass >/dev/null 2>&1

    echo "⏳ 2/6 Настройка Telegram конфига..."
    echo "TG_TOKEN=\"$TG_TOKEN\"" > /root/.vpn_tg.conf
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> /root/.vpn_tg.conf
    chmod 600 /root/.vpn_tg.conf

    echo "⏳ 3/6 Получение SSL-сертификата..."
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone -d "$SUB_DOMAIN" -m "$SSL_EMAIL" --agree-tos -n
    
    if[ ! -f "/etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem" ]; then
        echo "❌ Ошибка SSL! Проверь, что домен привязан к IP этого сервера."
        read -p "Нажми Enter..." DUMMY; return
    fi

    echo "⏳ 4/6 Настройка Nginx (Reverse Proxy)..."
    cat <<EOF > /etc/nginx/sites-available/default
server { listen 80; server_name $SUB_DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2;
    server_name $SUB_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUB_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location / { return 404; }
    location /sub/ {
        proxy_pass http://127.0.0.1:8080/sub/;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0";
    }
}
EOF
    systemctl restart nginx

    echo "⏳ 5/6 Компиляция ядра Go (С поддержкой xHTTP)..."
    cd /tmp
    wget -q https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    
    mkdir -p /usr/src/master-core && cd /usr/src/master-core
    go mod init master-core >/dev/null 2>&1
    go get github.com/go-telegram-bot-api/telegram-bot-api/v5 >/dev/null 2>&1
    go get modernc.org/sqlite >/dev/null 2>&1
    go get google.golang.org/grpc >/dev/null 2>&1
    go get github.com/xtls/xray-core/app/proxyman/command >/dev/null 2>&1
    go get github.com/xtls/xray-core/common/protocol >/dev/null 2>&1
    go get github.com/xtls/xray-core/proxy/vless >/dev/null 2>&1

    cat << 'GO_EOF' > main.go
package main

import (
	"bufio"
	"context"
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	_ "modernc.org/sqlite"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	proxymancommand "github.com/xtls/xray-core/app/proxyman/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
)

var db *sql.DB
var adminChatID int64

func initDB() {
	var err error
	db, err = sql.Open("sqlite", "/root/master_core.db?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil { log.Fatal(err) }

	db.Exec(`CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT, internal_ip TEXT, public_ip TEXT, public_domain TEXT, pbk TEXT, sid TEXT, status TEXT DEFAULT 'active')`)
	db.Exec(`ALTER TABLE nodes ADD COLUMN pbk TEXT`) // На случай если БД уже была создана
	db.Exec(`ALTER TABLE nodes ADD COLUMN sid TEXT`)
	
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, username TEXT, chat_id INTEGER, traffic_limit_gb INTEGER DEFAULT 0, expire_at DATETIME, max_ips INTEGER DEFAULT 3, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS user_ips (uuid TEXT, ip_address TEXT, last_seen DATETIME, PRIMARY KEY (uuid, ip_address))`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, target_name TEXT, created_at DATETIME)`)
}

func getClientIP(r *http.Request) string {
	ip := r.Header.Get("X-Forwarded-For")
	if ip == "" { ip = r.Header.Get("X-Real-IP") }
	if ip == "" { ip, _, _ = net.SplitHostPort(r.RemoteAddr) }
	return strings.Split(ip, ",")[0]
}

func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	if len(uuid) != 36 { http.Error(w, "Invalid UUID", http.StatusBadRequest); return }

	clientIP := getClientIP(r)
	now := time.Now()

	var status string
	var maxIPs int
	err := db.QueryRow(`SELECT status, max_ips FROM users WHERE uuid = ?`, uuid).Scan(&status, &maxIPs)
	if err == sql.ErrNoRows || status != "active" {
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#❌_АККАУНТ_НЕАКТИВЕН", uuid)))))
		return
	}

	db.Exec(`INSERT INTO user_ips (uuid, ip_address, last_seen) VALUES (?, ?, ?) ON CONFLICT(uuid, ip_address) DO UPDATE SET last_seen = ?`, uuid, clientIP, now, now)
	db.Exec(`DELETE FROM user_ips WHERE last_seen < ?`, now.Add(-24*time.Hour))
	
	var ipCount int
	db.QueryRow(`SELECT COUNT(*) FROM user_ips WHERE uuid = ?`, uuid).Scan(&ipCount)
	if ipCount > maxIPs {
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_ПРЕВЫШЕН_ЛИМИТ_УСТРОЙСТВ", uuid)))))
		return
	}

	// Генерация ссылок для RU-мостов
	rows, _ := db.Query(`SELECT public_ip, public_domain, pbk, sid FROM nodes WHERE role = 'ru_bridge' AND status = 'active'`)
	defer rows.Close()
	var links[]string
	
	for rows.Next() {
		var ip, sni, pbk, sid string
		rows.Scan(&ip, &sni, &pbk, &sid)
		
		// 1. Профиль TCP-Vision (Быстрый)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=%s#🇷🇺_RU-Мост_Vision", uuid, ip, pbk, sid, sni))
		
		// 2. Профиль xHTTP (Резервный)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&type=xhttp&path=%%2Fxhttp&fp=chrome&sni=%s#🛡_RU-Мост_xHTTP", uuid, ip, pbk, sid, sni))
	}
	
	if len(links) == 0 { links = append(links, fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_НЕТ_ДОСТУПНЫХ_СЕРВЕРОВ", uuid)) }
	w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
}

func startHTTPServer() {
	http.HandleFunc("/sub/", handleSub)
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", nil))
}

func main() {
	initDB()
	defer db.Close()

	var token string
	file, err := os.Open("/root/.vpn_tg.conf")
	if err == nil {
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			line := scanner.Text()
			if strings.HasPrefix(line, "TG_TOKEN=") { token = strings.Trim(strings.TrimPrefix(line, "TG_TOKEN="), "\"") }
			if strings.HasPrefix(line, "TG_CHAT_ID=") { adminChatID, _ = strconv.ParseInt(strings.Trim(strings.TrimPrefix(line, "TG_CHAT_ID="), "\""), 10, 64) }
		}
		file.Close()
	}
	if token == "" { log.Fatal("❌ Токен Telegram не найден.") }

	go startHTTPServer()
	bot, _ := tgbotapi.NewBotAPI(token)
	u := tgbotapi.NewUpdate(0); u.Timeout = 60
	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		if update.Message == nil { continue }
	}
}
GO_EOF

    go mod tidy >/dev/null 2>&1
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /usr/local/bin/master-core main.go
    rm -rf /usr/local/go /tmp/go1.21.6.linux-amd64.tar.gz

    echo "⏳ 6/6 Настройка Systemd для Master-Core..."
    cat <<EOF > /etc/systemd/system/master-core.service
[Unit]
Description=VPN Cluster Master Core
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
    systemctl enable master-core >/dev/null 2>&1
    systemctl restart master-core

    ufw allow 22/tcp >/dev/null 2>&1
    ufw allow 80/tcp >/dev/null 2>&1
    ufw allow 443/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1

    echo "✅ MASTER-УЗЕЛ УСПЕШНО УСТАНОВЛЕН!"
    read -p "Нажми Enter..." DUMMY
}

# ==========================================
# ФУНКЦИЯ 2: Развертывание EU-Ноды (Точка выхода)
# ==========================================
deploy_eu_node() {
    echo -e "\n🇪🇺 РАЗВЕРТЫВАНИЕ EU-НОДЫ"
    if[ ! -f "$DB_PATH" ]; then echo "❌ Сначала установи Master-узел (Пункт 1)!"; read -p "Нажми Enter..."; return; fi

    read -p "Введи публичный IP EU-сервера: " EU_IP
    read -s -p "Введи Root-пароль: " EU_PASS; echo ""
    
    RU_EU_UUID=$(cat /proc/sys/kernel/random/uuid)
    echo "⏳ Подключаюсь к $EU_IP и устанавливаю ядро..."

    sshpass -p "$EU_PASS" ssh -o StrictHostKeyChecking=no root@"$EU_IP" "bash -s" << EOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl unzip ufw >/dev/null 2>&1
        bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        KEYS=\$(xray x25519); PK=\$(echo "\$KEYS" | grep "Private key:" | awk '{print \$3}'); PUB=\$(echo "\$KEYS" | grep "Public key:" | awk '{print \$3}')
        echo "\$PUB" > /root/eu_pub.key
        cat << 'CFG_EOF' > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds":[{
    "port": 443,
    "protocol": "vless",
    "settings": {"clients":[{"id": "$RU_EU_UUID", "flow": "xtls-rprx-vision"}], "decryption": "none"},
    "streamSettings": {"network": "tcp", "security": "reality", "realitySettings": {"dest": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"], "privateKey": "\$PK", "shortIds": [""]}}
  }],
  "outbounds": [{"protocol": "freedom", "tag": "direct"}]
}
CFG_EOF
        systemctl restart xray
        ufw allow 443/tcp >/dev/null 2>&1; ufw allow 22/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
EOF

    EU_PUB_KEY=$(sshpass -p "$EU_PASS" ssh -o StrictHostKeyChecking=no root@"$EU_IP" "cat /root/eu_pub.key")
    echo "$EU_IP|$RU_EU_UUID|$EU_PUB_KEY" >> /root/eu_nodes.list
    sqlite3 "$DB_PATH" "INSERT INTO nodes (role, public_ip, status) VALUES ('eu_exit', '$EU_IP', 'active');"
    echo "✅ EU-Нода успешно развернута!"
    read -p "Нажми Enter..." DUMMY
}

# ==========================================
# ФУНКЦИЯ 3: Развертывание RU-Моста
# ==========================================
deploy_ru_node() {
    echo -e "\n🇷🇺 РАЗВЕРТЫВАНИЕ RU-МОСТА (TCP-Vision + xHTTP)"
    if [ ! -f /root/eu_nodes.list ] ||[ ! -s /root/eu_nodes.list ]; then
        echo "❌ Ошибка: Список EU-нод пуст! Сначала разверните EU-Ноду (Пункт 4)."
        read -p "Нажми Enter..."; return
    fi

    read -p "Введи публичный IP RU-сервера: " RU_IP
    read -s -p "Введи Root-пароль: " RU_PASS; echo ""
    read -p "Введи сайт для маскировки (SNI)[например, vk.com или mail.ru]: " RU_DOMAIN
    
    echo "⏳ Подключаюсь к $RU_IP и устанавливаю транзитный мост..."

    OUTBOUNDS_JSON=""
    INDEX=1
    while IFS='|' read -r EU_IP RU_EU_UUID EU_PUB; do
        if [ -n "$EU_IP" ]; then
            SNIPPET=$(cat <<EOF
    { "tag": "eu-out-$INDEX", "protocol": "vless", "settings": { "vnext":[{ "address": "$EU_IP", "port": 443, "users":[{"id": "$RU_EU_UUID", "encryption": "none", "flow": "xtls-rprx-vision"}] }] }, "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "serverName": "www.microsoft.com", "publicKey": "$EU_PUB", "fingerprint": "chrome" } } }
EOF
)
            if [ $INDEX -gt 1 ]; then OUTBOUNDS_JSON="$OUTBOUNDS_JSON,"; fi
            OUTBOUNDS_JSON="$OUTBOUNDS_JSON$SNIPPET"
            INDEX=$((INDEX+1))
        fi
    done < /root/eu_nodes.list

    # Выполняем скрипт на RU-мосте. Генерируем REALITY ключи и сохраняем конфиг с fallback.
    RAW_DATA=$(sshpass -p "$RU_PASS" ssh -o StrictHostKeyChecking=no root@"$RU_IP" "bash -s" << EOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl unzip ufw openssl >/dev/null 2>&1
        bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        KEYS=\$(xray x25519)
        PK=\$(echo "\$KEYS" | grep "Private key:" | awk '{print \$3}')
        PUB=\$(echo "\$KEYS" | grep "Public key:" | awk '{print \$3}')
        SHORTID=\$(openssl rand -hex 4)

        cat << 'CFG_EOF' > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "services":["HandlerService", "StatsService"]},
  "observatory": {"subjectSelector": ["eu-out-"], "probeUrl": "https://www.google.com/generate_204", "probeInterval": "1m"},
  "inbounds":[
    {
      "tag": "client-in",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none",
        "fallbacks":[{"path": "/xhttp", "dest": 8001, "xver": 1}]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "$RU_DOMAIN:443",
          "serverNames": ["$RU_DOMAIN"],
          "privateKey": "\$PK",
          "shortIds": ["\$SHORTID"]
        }
      }
    },
    {
      "tag": "client-xhttp",
      "listen": "127.0.0.1",
      "port": 8001,
      "protocol": "vless",
      "settings": {"clients":[], "decryption": "none"},
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {"mode": "auto", "path": "/xhttp"},
        "sockopt": {"acceptProxyProtocol": true}
      }
    },
    { "tag": "api-in", "port": 10085, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"} }
  ],
  "outbounds":[ $OUTBOUNDS_JSON, {"protocol": "freedom", "tag": "direct"} ],
  "routing": { 
    "balancers":[{"tag": "eu-balancer", "selector": ["eu-out-"]}], 
    "rules":[ 
      {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"}, 
      {"type": "field", "inboundTag": ["client-in", "client-xhttp"], "balancerTag": "eu-balancer"} 
    ] 
  }
}
CFG_EOF
        systemctl restart xray
        ufw allow 443/tcp >/dev/null 2>&1; ufw allow 22/tcp >/dev/null 2>&1
        ufw allow from $MASTER_IP to any port 10085 >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        
        # Выводим ключи для Мастера
        echo "RU_KEYS|\$PUB|\$SHORTID"
EOF
)
    
    RU_PUB=$(echo "$RAW_DATA" | grep "RU_KEYS" | awk -F'|' '{print $2}')
    RU_SID=$(echo "$RAW_DATA" | grep "RU_KEYS" | awk -F'|' '{print $3}')

    if [ -n "$RU_PUB" ] &&[ -n "$RU_SID" ]; then
        sqlite3 "$DB_PATH" "INSERT INTO nodes (role, internal_ip, public_ip, public_domain, pbk, sid, status) VALUES ('ru_bridge', '$RU_IP', '$RU_IP', '$RU_DOMAIN', '$RU_PUB', '$RU_SID', 'active');"
        echo "✅ RU-Мост развернут! В подписку добавлены xHTTP и Vision профили."
    else
        echo "❌ Ошибка получения ключей с RU-моста."
    fi
    read -p "Нажми Enter..." DUMMY
}

# ==========================================
# ОСНОВНОЙ ЦИКЛ МЕНЮ
# ==========================================
while true; do
    show_dashboard
    echo "--- 🛠 ИНИЦИАЛИЗАЦИЯ И СИСТЕМА ---"
    echo "1) 🚀 Установить ядро управления (Master-Core)"
    echo "2) ♻️ Восстановить Master-узел из бекапа"
    
    echo ""
    echo "--- 🌐 УПРАВЛЕНИЕ ИНФРАСТРУКТУРОЙ ---"
    echo "4) ➕ Развернуть новую EU-Ноду (Точка выхода)"
    echo "5) ➕ Развернуть новый RU-Мост (Точка входа)"
    
    echo ""
    echo "0) 🚪 Выход"
    echo "========================================================="
    read -p "Выбор: " ACTION

    case $ACTION in
        1) install_master ;;
        4) deploy_eu_node ;;
        5) deploy_ru_node ;;
        0) clear; exit 0 ;;
        *) echo "❌ Неверный выбор!"; sleep 1 ;;
    esac
done
