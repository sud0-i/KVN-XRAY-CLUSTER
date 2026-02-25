#!/bin/bash

# Глобальные переменные
DB_PATH="/root/master_core.db"
MASTER_IP=$(curl -s4 ifconfig.me)

# ==========================================
# 0. ПОДГОТОВКА КЛЮЧЕЙ И ЗАВИСИМОСТЕЙ
# ==========================================
setup_master_env() {
    apt-get update >/dev/null 2>&1
    apt-get install -y sshpass sqlite3 curl wget jq >/dev/null 2>&1
    if [ ! -f /root/.ssh/id_ed25519 ]; then
        echo "⏳ Генерация SSH-ключа Master-узла..."
        ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519 >/dev/null 2>&1
    fi
}

# ==========================================
# 1. СИНХРОНИЗАЦИЯ КЛАСТЕРА
# ==========================================
sync_cluster() {
    echo "🔄 Запуск синхронизации кластера..."
    if [ ! -f "$DB_PATH" ]; then echo "❌ База данных не найдена!"; return; fi
    
    CLIENTS_JSON=$(sqlite3 "$DB_PATH" "SELECT '{\"id\":\"'||uuid||'\",\"email\":\"'||username||'\",\"flow\":\"xtls-rprx-vision\"}' FROM users WHERE status='active';" | paste -sd "," -)
    
    OUTBOUNDS_JSON=""
    INDEX=1
    while IFS='|' read -r EU_IP RU_EU_UUID EU_PUB; do
        if [ -n "$EU_IP" ]; then
            SNIPPET=$(cat <<EOF
    {
      "tag": "eu-out-$INDEX", "protocol": "vless",
      "settings": { "vnext": [{"address": "$EU_IP", "port": 443, "users": [{"id": "$RU_EU_UUID", "encryption": "none", "flow": "xtls-rprx-vision"}]}] },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "serverName": "www.microsoft.com", "publicKey": "$EU_PUB", "fingerprint": "chrome" } }
    }
EOF
)
            if [ $INDEX -gt 1 ]; then OUTBOUNDS_JSON="$OUTBOUNDS_JSON,"; fi
            OUTBOUNDS_JSON="$OUTBOUNDS_JSON$SNIPPET"
            INDEX=$((INDEX+1))
        fi
    done < /root/eu_nodes.list 2>/dev/null

    if [ -z "$OUTBOUNDS_JSON" ]; then echo "⚠️ Нет EU-нод. Синхронизация отложена."; return; fi

    RU_NODES=$(sqlite3 "$DB_PATH" "SELECT public_ip, public_domain, private_key FROM nodes WHERE role='ru_bridge' AND status='active';")
    
    for ROW in $RU_NODES; do
        RU_IP=$(echo "$ROW" | cut -d'|' -f1)
        RU_DOMAIN=$(echo "$ROW" | cut -d'|' -f2)
        RU_PK=$(echo "$ROW" | cut -d'|' -f3)

        echo "📡 Отправка конфигурации на RU-Мост: $RU_IP..."
        cat << CFG_EOF > /tmp/xray_ru_sync.json
{
  "log": {"loglevel": "warning"},
  "api": { "tag": "api", "services": ["HandlerService", "StatsService"] },
  "observatory": { "subjectSelector": ["eu-out-"], "probeUrl": "https://www.google.com/generate_204", "probeInterval": "1m" },
  "inbounds": [
    {
      "tag": "client-in", "port": 443, "protocol": "vless",
      "settings": { "clients": [$CLIENTS_JSON], "decryption": "none" },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "$RU_DOMAIN:443", "serverNames": ["$RU_DOMAIN"], "privateKey": "$RU_PK", "shortIds": [""] } }
    },
    { "tag": "api-in", "port": 10085, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"} }
  ],
  "outbounds": [ $OUTBOUNDS_JSON, { "protocol": "freedom", "tag": "direct" } ],
  "routing": {
    "balancers": [{ "tag": "eu-balancer", "selector": ["eu-out-"] }],
    "rules": [
      {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"},
      {"type": "field", "inboundTag": ["client-in"], "balancerTag": "eu-balancer"}
    ]
  }
}
CFG_EOF
        scp -o StrictHostKeyChecking=no -q /tmp/xray_ru_sync.json root@$RU_IP:/usr/local/etc/xray/config.json
        ssh -o StrictHostKeyChecking=no root@$RU_IP "systemctl restart xray"
    done
    rm -f /tmp/xray_ru_sync.json
    echo "✅ Кластер успешно синхронизирован!"
}

# ==========================================
# 2. РАЗВЕРТЫВАНИЕ EU-НОДЫ
# ==========================================
deploy_eu_node() {
    setup_master_env
    echo -e "\n🇪🇺 РАЗВЕРТЫВАНИЕ EU-НОДЫ"
    read -p "IP сервера: " EU_IP
    read -p "Root-пароль: " EU_PASS
    RU_EU_UUID=$(cat /proc/sys/kernel/random/uuid)
    
    sshpass -p "$EU_PASS" ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/id_ed25519.pub root@$EU_IP >/dev/null 2>&1
    echo "⏳ Установка Xray на $EU_IP..."
    ssh -o StrictHostKeyChecking=no root@$EU_IP "bash -c \"\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install >/dev/null 2>&1"
    
    KEYS=$(ssh -o StrictHostKeyChecking=no root@$EU_IP "xray x25519")
    PK=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')
    PUB=$(echo "$KEYS" | grep "Public key:" | awk '{print $3}')

    ssh -o StrictHostKeyChecking=no root@$EU_IP "cat << 'EOF' > /usr/local/etc/xray/config.json
{
  \"log\": {\"loglevel\": \"warning\"},
  \"inbounds\": [{ \"port\": 443, \"protocol\": \"vless\", \"settings\": { \"clients\": [{\"id\": \"$RU_EU_UUID\", \"flow\": \"xtls-rprx-vision\"}], \"decryption\": \"none\" }, \"streamSettings\": { \"network\": \"tcp\", \"security\": \"reality\", \"realitySettings\": { \"dest\": \"www.microsoft.com:443\", \"serverNames\": [\"www.microsoft.com\"], \"privateKey\": \"$PK\", \"shortIds\": [\"\"] } } }],
  \"outbounds\": [{\"protocol\": \"freedom\", \"tag\": \"direct\"}]
}
EOF
systemctl restart xray; ufw --force enable; ufw allow 443/tcp; ufw allow 22/tcp"

    echo "$EU_IP|$RU_EU_UUID|$PUB" >> /root/eu_nodes.list
    sqlite3 "$DB_PATH" "INSERT INTO nodes (role, public_ip, status) VALUES ('eu_exit', '$EU_IP', 'active');"
    echo "✅ EU-Нода готова."
    sync_cluster
    read -p "Нажми Enter..." DUMMY
}

# ==========================================
# 3. РАЗВЕРТЫВАНИЕ RU-МОСТА
# ==========================================
deploy_ru_node() {
    setup_master_env
    echo -e "\n🇷🇺 РАЗВЕРТЫВАНИЕ RU-МОСТА"
    read -p "IP сервера: " RU_IP
    read -p "Root-пароль: " RU_PASS
    read -p "Домен SNI маскировки (например, mail.ru): " RU_DOMAIN
    
    sshpass -p "$RU_PASS" ssh-copy-id -o StrictHostKeyChecking=no -i /root/.ssh/id_ed25519.pub root@$RU_IP >/dev/null 2>&1
    echo "⏳ Установка Xray на $RU_IP..."
    ssh -o StrictHostKeyChecking=no root@$RU_IP "bash -c \"\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)\" @ install >/dev/null 2>&1"
    
    KEYS=$(ssh -o StrictHostKeyChecking=no root@$RU_IP "xray x25519")
    PK=$(echo "$KEYS" | grep "Private key:" | awk '{print $3}')

    ssh -o StrictHostKeyChecking=no root@$RU_IP "ufw --force enable; ufw allow 443/tcp; ufw allow 22/tcp; ufw allow from $MASTER_IP to any port 10085"
    
    sqlite3 "$DB_PATH" "INSERT INTO nodes (role, public_ip, public_domain, private_key, status) VALUES ('ru_bridge', '$RU_IP', '$RU_DOMAIN', '$PK', 'active');"
    echo "✅ RU-Мост базово настроен."
    sync_cluster
    read -p "Нажми Enter..." DUMMY
}

# ==========================================
# 4. УСТАНОВКА ЯДРА УПРАВЛЕНИЯ (MASTER)
# ==========================================
install_master_node() {
    setup_master_env
    echo -e "\n👑 УСТАНОВКА ЯДРА УПРАВЛЕНИЯ"
    read -p "Домен для Master-узла (например, sub.domain.com): " MASTER_DOMAIN
    read -p "Токен Telegram-бота: " TG_TOKEN
    read -p "Chat ID (ID Админа): " TG_CHAT_ID

    echo "TG_TOKEN=\"$TG_TOKEN\"" > /root/.vpn_tg.conf
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> /root/.vpn_tg.conf

    echo "⏳ 1/4 Установка Nginx и выпуск SSL..."
    apt-get install -y nginx certbot python3-certbot-nginx >/dev/null 2>&1
    systemctl stop nginx
    certbot certonly --standalone -d "$MASTER_DOMAIN" --non-interactive --agree-tos -m "admin@$MASTER_DOMAIN"

    cat << EOF > /etc/nginx/sites-available/default
server { listen 80; server_name $MASTER_DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl; server_name $MASTER_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$MASTER_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$MASTER_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    location /sub/ {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
    }
}
EOF
    systemctl start nginx; systemctl enable nginx

    echo "⏳ 2/4 Установка Go..."
    cd /tmp && wget -q https://go.dev/dl/go1.21.6.linux-amd64.tar.gz
    rm -rf /usr/local/go && tar -C /usr/local -xzf go1.21.6.linux-amd64.tar.gz
    export PATH=$PATH:/usr/local/go/bin
    
    echo "⏳ 3/4 Компиляция Master Core..."
    mkdir -p /usr/src/master-core && cd /usr/src/master-core
    
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
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	_ "modernc.org/sqlite"

	proxymancommand "github.com/xtls/xray-core/app/proxyman/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
)

var db *sql.DB
var adminChatID int64

func initDB() {
	var err error
	db, err = sql.Open("sqlite", "/root/master_core.db")
	if err != nil { log.Fatal(err) }
	db.Exec(`CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT, internal_ip TEXT, public_ip TEXT, public_domain TEXT, private_key TEXT, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, username TEXT, chat_id INTEGER, traffic_limit_gb INTEGER DEFAULT 0, expire_at DATETIME, max_ips INTEGER DEFAULT 3, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS user_ips (uuid TEXT, ip_address TEXT, last_seen DATETIME, PRIMARY KEY (uuid, ip_address))`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, target_name TEXT, created_at DATETIME)`)
}

func getClientIP(r *http.Request) string {
	ip := r.Header.Get("X-Forwarded-For")
	if ip == "" { ip, _, _ = net.SplitHostPort(r.RemoteAddr) }
	return strings.Split(ip, ",")[0]
}

func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	if len(uuid) != 36 { http.Error(w, "Invalid UUID", http.StatusBadRequest); return }

	clientIP := getClientIP(r)
	now := time.Now()
	var status string; var maxIPs int
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
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_ПРЕВЫШЕН_ЛИМИТ_УСТРОЙСТВ_(%d_из_%d)", uuid, ipCount, maxIPs)))))
		return
	}

	rows, _ := db.Query(`SELECT public_ip, public_domain FROM nodes WHERE role = 'ru_bridge' AND status = 'active'`)
	defer rows.Close()
	var links []string
	for rows.Next() {
		var ip, domain string; rows.Scan(&ip, &domain)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=%s#🇷🇺_RU_(%s)", uuid, ip, domain, domain))
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=vk.com&allowInsecure=1#🛡_Обход_Вайтлиста", uuid, ip))
	}
	if len(links) == 0 { links = append(links, fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_НЕТ_СЕРВЕРОВ", uuid)) }
	w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
}

func startHTTPServer() {
	http.HandleFunc("/sub/", handleSub)
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", nil))
}

func addClientToNode(nodeIP, uuid, email string) error {
	conn, err := grpc.Dial(nodeIP+":10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil { return err }
	defer conn.Close()
	client := proxymancommand.NewHandlerServiceClient(conn)
	acc, _ := serial.ToTypedMessage(&vless.Account{Id: uuid, Flow: "xtls-rprx-vision"})
	user := &protocol.User{Level: 0, Email: email, Account: acc}
	op, _ := serial.ToTypedMessage(&proxymancommand.AddUserOperation{User: user})
	_, err = client.AlterInbound(context.Background(), &proxymancommand.AlterInboundRequest{Tag: "client-in", Operation: op})
	return err
}

func genUUID() string {
	b := make([]byte, 16); rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

func genInviteCode() string {
	b := make([]byte, 4); rand.Read(b)
	return "INV-" + strings.ToUpper(hex.EncodeToString(b))
}

func main() {
	initDB(); defer db.Close()
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
	if token == "" { log.Fatal("Token not found") }

	go startHTTPServer()
	bot, err := tgbotapi.NewBotAPI(token)
	if err != nil { log.Panic(err) }
	
	u := tgbotapi.NewUpdate(0); u.Timeout = 60
	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		if update.Message == nil { continue }
		chatID := update.Message.Chat.ID; text := update.Message.Text
		isAdmin := chatID == adminChatID

		if isAdmin && text == "/invite" {
			code := genInviteCode()
			db.Exec(`INSERT INTO invites (code, target_name, created_at) VALUES (?, ?, ?)`, code, "NewUser", time.Now())
			bot.Send(tgbotapi.NewMessage(chatID, "✅ Инвайт создан: `"+code+"`\n\nАктивация: `/start "+code+"`"))
			continue
		}

		if strings.HasPrefix(text, "/start INV-") {
			code := strings.TrimSpace(strings.TrimPrefix(text, "/start "))
			var targetName string
			err := db.QueryRow(`SELECT target_name FROM invites WHERE code = ?`, code).Scan(&targetName)
			if err == sql.ErrNoRows { bot.Send(tgbotapi.NewMessage(chatID, "❌ Код недействителен.")); continue }

			newUUID := genUUID()
			db.Exec(`INSERT INTO users (uuid, username, chat_id) VALUES (?, ?, ?)`, newUUID, targetName, chatID)
			db.Exec(`DELETE FROM invites WHERE code = ?`, code)

			rows, _ := db.Query(`SELECT public_ip FROM nodes WHERE role = 'ru_bridge' AND status = 'active'`)
			for rows.Next() {
				var nodeIP string; rows.Scan(&nodeIP)
				addClientToNode(nodeIP, newUUID, targetName)
			}
			rows.Close()
			bot.Send(tgbotapi.NewMessage(chatID, fmt.Sprintf("✅ Подписка:\n`https://%s/sub/%s`", bot.Self.UserName, newUUID))) # Условный вывод
		}
	}
}
GO_EOF

    go mod init master-core >/dev/null 2>&1
    go get github.com/go-telegram-bot-api/telegram-bot-api/v5 modernc.org/sqlite google.golang.org/grpc github.com/xtls/xray-core/app/proxyman/command github.com/xtls/xray-core/common/protocol github.com/xtls/xray-core/proxy/vless >/dev/null 2>&1
    go mod tidy >/dev/null 2>&1
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /usr/local/bin/master-core main.go
    rm -rf /usr/local/go /usr/src/master-core /tmp/go1.21.6.linux-amd64.tar.gz

    echo "⏳ 4/4 Настройка Systemd сервиса..."
    cat <<EOF > /etc/systemd/system/master-core.service
[Unit]
Description=VPN Master Control Plane
After=network.target nginx.service

[Service]
ExecStart=/usr/local/bin/master-core
WorkingDirectory=/root
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable master-core.service; systemctl restart master-core.service
    echo "✅ Master-узел запущен! Твой домен подписок: https://$MASTER_DOMAIN/sub/"
    read -p "Нажми Enter..." DUMMY
}

# ==========================================
# ГЛАВНОЕ МЕНЮ
# ==========================================
while true; do
    clear
    echo "======================================"
    echo "👑 MASTER-УЗЕЛ УПРАВЛЕНИЯ VPN CLUSTER"
    echo "======================================"
    echo "1. 🚀 Установить ядро управления (Nginx + Bot + SQLite)"
    echo "2. 🔄 Восстановить Master-узел из бекапа (В разработке)"
    echo "--------------------------------------"
    echo "3. ➕ Развернуть новый RU-Мост (введи IP и пароль)"
    echo "4. ➕ Развернуть новую EU-Ноду (введи IP и пароль)"
    echo "5. 🗑 Удалить мертвый мост/ноду (В разработке)"
    echo "6. 👥 Управление пользователями (Через Telegram)"
    echo "--------------------------------------"
    echo "7. 📦 Отправить бекап в Telegram (В разработке)"
    echo "0. ❌ Выход"
    echo "======================================"
    read -p "Выбор: " CHOICE

    case $CHOICE in
        1) install_master_node ;;
        3) deploy_ru_node ;;
        4) deploy_eu_node ;;
        0) exit 0 ;;
        *) echo "⚠️ Неверный выбор или в разработке."; sleep 1 ;;
    esac
done
