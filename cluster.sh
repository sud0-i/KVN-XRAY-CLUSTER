#!/bin/bash

# ==============================================================================
# 🚀 VPN ORCHESTRATOR v7.0 (Auto-Sub, HTML DeepLinks, Custom WARP, Unified Bridge)
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive

install_deps() {
    if ! command -v go &> /dev/null; then
        echo "⏳ Установка зависимостей..."
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq jq sqlite3 curl sshpass openssl git build-essential nginx certbot python3-certbot-nginx zip ufw >/dev/null 2>&1
        
        wget -q https://go.dev/dl/go1.22.1.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.1.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.profile
    fi
}

# ==============================================================================
# 1. ORCHESTRATOR (MASTER)
# ==============================================================================
install_orchestrator() {
    install_deps
    echo -e "\n🧠 УСТАНОВКА ЦЕНТРА УПРАВЛЕНИЯ"
    
    read -p "🤖 Telegram Bot Token: " TG_TOKEN
    read -p "🆔 Telegram Admin ID: " TG_CHAT_ID
    read -p "🌐 Домен для подписок (sub.vpn.com): " SUB_DOMAIN
    read -p "✉️ Email для SSL (Let's Encrypt): " SSL_EMAIL
    
    mkdir -p /etc/orchestrator
    echo "TG_TOKEN=\"$TG_TOKEN\"" > /etc/orchestrator/config.env
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> /etc/orchestrator/config.env
    echo "SUB_DOMAIN=\"$SUB_DOMAIN\"" >> /etc/orchestrator/config.env

    echo "⏳ Настройка Nginx и SSL..."
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone -d "$SUB_DOMAIN" -m "$SSL_EMAIL" --agree-tos -n
    
    cat <<EOF > /etc/nginx/sites-available/default
server { listen 80; server_name $SUB_DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl; server_name $SUB_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUB_DOMAIN/privkey.pem;
    
    location /sub/ { proxy_pass http://127.0.0.1:8080/sub/; proxy_set_header X-Real-IP \$remote_addr; }
    location / { return 404; }
}
EOF
    systemctl start nginx

    echo "⏳ Сборка Orchestrator Core..."
    mkdir -p /usr/src/orchestrator
    cd /usr/src/orchestrator

    cat << 'GO_EOF' > main.go
package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
	"crypto/rand"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	_ "modernc.org/sqlite"
	"golang.org/x/crypto/ssh"
)

var (
	db     *sql.DB
	config struct {
		Token  string
		ChatID int64
		Domain string
	}
)

const htmlTemplate = `<!DOCTYPE html><html lang="ru"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>VPN Setup</title><style>body{background:#121212;color:#e0e0e0;font-family:sans-serif;display:flex;flex-direction:column;align-items:center;justify-content:center;min-height:100vh;margin:0;padding:20px;text-align:center}.card{background:#1e1e1e;padding:30px;border-radius:16px;max-width:400px;width:100%}.btn{display:block;width:100%;padding:14px;margin-bottom:12px;border-radius:12px;text-decoration:none;font-weight:bold;font-size:16px;box-sizing:border-box}.btn-ios{background:#007AFF;color:#fff}.btn-android{background:#3DDC84;color:#000}.btn-win{background:#00A4EF;color:#fff}.apps{background:#2a2a2a;padding:15px;border-radius:12px;margin-bottom:20px;text-align:left;font-size:14px}.apps a{color:#4da6ff;text-decoration:none;display:block;margin-bottom:8px}</style></head><body><div class="card"><h1>🔑 Привет, %s!</h1><div class="apps"><b>Шаг 1. Установи приложение:</b><br><br><a href="https://apps.apple.com/us/app/v2raytun/id6476628951">🍏 iOS: V2rayTun</a><a href="https://play.google.com/store/apps/details?id=com.v2raytun.android">🤖 Android: V2rayTun</a><a href="https://github.com/hiddify/hiddify-next/releases">💻 PC/Mac: Hiddify Next</a></div><p><b>Шаг 2. Нажми для настройки:</b></p><a href="v2raytun://import/%s" class="btn btn-win">🚀 Подключить V2rayTun</a><a href="hiddify://install-config?url=%s" class="btn btn-android">🤖 Подключить Hiddify</a><a href="v2box://install-sub?url=%s" class="btn btn-ios">🍏 Подключить V2Box</a></div></body></html>`

func init() {
	data, _ := os.ReadFile("/etc/orchestrator/config.env")
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "TG_TOKEN=") { config.Token = strings.Trim(strings.TrimPrefix(line, "TG_TOKEN="), "\"") }
		if strings.HasPrefix(line, "SUB_DOMAIN=") { config.Domain = strings.Trim(strings.TrimPrefix(line, "SUB_DOMAIN="), "\"") }
		if strings.HasPrefix(line, "TG_CHAT_ID=") { fmt.Sscanf(strings.TrimPrefix(line, "TG_CHAT_ID="), "\"%d\"", &config.ChatID) }
	}

	var err error
	db, err = sql.Open("sqlite", "/etc/orchestrator/core.db?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil { log.Fatal(err) }
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, name TEXT, active INTEGER DEFAULT 1)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS bridges (ip TEXT PRIMARY KEY, domain TEXT, user TEXT, pass TEXT, pub_key TEXT, sid TEXT, active INTEGER DEFAULT 1)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS exits (ip TEXT PRIMARY KEY, user TEXT, pass TEXT, pub_key TEXT, active INTEGER DEFAULT 1)`)
}

// === SSH & LOCAL EXEC ===
func remoteExec(ip, user, pass, cmd string) (string, error) {
	if ip == "127.0.0.1" || ip == "localhost" {
		out, err := exec.Command("bash", "-c", cmd).CombinedOutput()
		return string(out), err
	}
	cfg := &ssh.ClientConfig{User: user, Auth:[]ssh.AuthMethod{ssh.Password(pass)}, HostKeyCallback: ssh.InsecureIgnoreHostKey(), Timeout: 10 * time.Second}
	client, err := ssh.Dial("tcp", ip+":22", cfg); if err != nil { return "", err }
	defer client.Close()
	session, err := client.NewSession(); if err != nil { return "", err }
	defer session.Close()
	out, err := session.CombinedOutput(cmd)
	return string(out), err
}

// === XRAY LOGIC ===
func reloadAllBridges() string {
	rows, _ := db.Query("SELECT ip, pub_key FROM exits WHERE active=1")
	var outbounds, balancers[]string
	bridgeUUID := "11111111-1111-1111-1111-111111111111" 
	for rows.Next() {
		var eIP, pk string; rows.Scan(&eIP, &pk)
		outbounds = append(outbounds, fmt.Sprintf(`{"tag":"eu-%s","protocol":"vless","settings":{"vnext":[{"address":"%s","port":443,"users":[{"id":"%s","flow":"xtls-rprx-vision","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"www.microsoft.com","publicKey":"%s","fingerprint":"chrome"}}}`, eIP, eIP, bridgeUUID, pk))
		balancers = append(balancers, fmt.Sprintf(`"eu-%s"`, eIP))
	}
	
	outJson := "[]"; if len(outbounds)>0 { outJson = "["+strings.Join(outbounds, ",")+"]" }
	selJson := "[]"; if len(balancers)>0 { selJson = "["+strings.Join(balancers, ",")+"]" }
	
	patchCmd := fmt.Sprintf(`jq --argjson newOut '%s' --argjson newSel '%s' '.outbounds = ([.outbounds[] | select(.tag=="direct" or .tag=="block")] + $newOut) | .routing.balancers[0].selector = $newSel' /usr/local/etc/xray/config.json > /tmp/cfg.tmp && mv /tmp/cfg.tmp /usr/local/etc/xray/config.json && systemctl restart xray`, outJson, selJson)

	bRows, _ := db.Query("SELECT ip, user, pass FROM bridges WHERE active=1")
	logMsg := "🔄 Обновление кластера:\n"
	var wg sync.WaitGroup
	for bRows.Next() {
		var ip, u, p string; bRows.Scan(&ip, &u, &p)
		wg.Add(1)
		go func(ip, u, p string) {
			defer wg.Done()
			remoteExec(ip, u, p, patchCmd)
		}(ip, u, p)
		logMsg += fmt.Sprintf("✅ Bridge %s обновлен\n", ip)
	}
	wg.Wait()
	return logMsg
}

func pushUserToBridges(uuid, name string) {
	rows, _ := db.Query("SELECT ip, user, pass FROM bridges WHERE active=1")
	cmd := fmt.Sprintf(`/usr/local/bin/xray api adinbnd -server=127.0.0.1:10085 -inbound=client-in -email=%s -id=%s -flow=xtls-rprx-vision`, name, uuid)
	for rows.Next() { var ip, u, p string; rows.Scan(&ip, &u, &p); go remoteExec(ip, u, p, cmd) }
}

func removeUserFromBridges(name string) {
	rows, _ := db.Query("SELECT ip, user, pass FROM bridges WHERE active=1")
	cmd := fmt.Sprintf(`/usr/local/bin/xray api rminbnd -server=127.0.0.1:10085 -inbound=client-in -email=%s`, name)
	for rows.Next() { var ip, u, p string; rows.Scan(&ip, &u, &p); go remoteExec(ip, u, p, cmd) }
}

// === HTTP SERVER (Sub & API) ===
func startHTTPServer() {
	http.HandleFunc("/sub/", func(w http.ResponseWriter, r *http.Request) {
		path := strings.TrimPrefix(r.URL.Path, "/sub/")
		isHTML := strings.HasSuffix(path, ".html")
		uuid := strings.TrimSuffix(path, ".html")

		var name string
		err := db.QueryRow("SELECT name FROM users WHERE uuid=?", uuid).Scan(&name)
		if err != nil { http.Error(w, "Forbidden", 403); return }

		// Generate all VLESS links from active bridges
		bRows, _ := db.Query("SELECT domain, pub_key, sid FROM bridges WHERE active=1")
		var links[]string
		for bRows.Next() {
			var d, pk, sid string; bRows.Scan(&d, &pk, &sid)
			links = append(links, fmt.Sprintf("vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com#%s-(%s)", uuid, d, pk, sid, name, d))
		}
		
		subContent := strings.Join(links, "\n")
		subURL := fmt.Sprintf("https://%s/sub/%s", config.Domain, uuid)

		if isHTML {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			fmt.Fprintf(w, htmlTemplate, name, subURL, subURL, subURL)
		} else {
			w.Header().Set("Content-Type", "text/plain; charset=utf-8")
			w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(subContent))))
		}
	})

	// CLI Internal API
	http.HandleFunc("/api/cli", func(w http.ResponseWriter, r *http.Request) {
		act := r.URL.Query().Get("action")
		if act == "add" {
			name := r.URL.Query().Get("name")
			uuid := makeUUID()
			db.Exec("INSERT INTO users (uuid, name) VALUES (?, ?)", uuid, name)
			pushUserToBridges(uuid, name)
			fmt.Fprintf(w, "https://%s/sub/%s.html", config.Domain, uuid)
		} else if act == "del" {
			uuid := r.URL.Query().Get("uuid")
			var name string
			db.QueryRow("SELECT name FROM users WHERE uuid=?", uuid).Scan(&name)
			db.Exec("DELETE FROM users WHERE uuid=?", uuid)
			removeUserFromBridges(name)
			w.Write([]byte("Deleted"))
		} else if act == "list" {
			rows, _ := db.Query("SELECT name, uuid FROM users")
			for rows.Next() { var n, u string; rows.Scan(&n, &u); fmt.Fprintf(w, "%s | %s\n", n, u) }
		} else if act == "invite" {
			code := "INV-" + makeHex(4)
			db.Exec("INSERT INTO invites (code) VALUES (?)", code)
			w.Write([]byte(code))
		}
	})
	http.ListenAndServe("127.0.0.1:8080", nil)
}

func makeHex(n int) string { b := make([]byte, n); rand.Read(b); return strings.ToUpper(hex.EncodeToString(b)) }
func makeUUID() string { 
	b := make([]byte, 16); rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// === TELEGRAM BOT ===
func main() {
	go startHTTPServer()

	bot, err := tgbotapi.NewBotAPI(config.Token)
	if err != nil { log.Fatal(err) }
	
	u := tgbotapi.NewUpdate(0); u.Timeout = 60
	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		if update.Message == nil { continue }
		msg := tgbotapi.NewMessage(update.Message.Chat.ID, "")
		txt := update.Message.Text
		userID := update.Message.From.ID

		if int64(userID) == config.ChatID {
			if txt == "/start" || txt == "/menu" {
				msg.Text = "🧠 Orchestrator v7.0"
				msg.ReplyMarkup = tgbotapi.NewReplyKeyboard(
					tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("👥 Users"), tgbotapi.NewKeyboardButton("🎫 Invite")),
					tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🔄 Reload Cluster")),
				)
			} else if txt == "🎫 Invite" {
				code := "INV-" + makeHex(4)
				db.Exec("INSERT INTO invites (code) VALUES (?)", code)
				msg.Text = fmt.Sprintf("✅ Инвайт: <code>%s</code>\n\n🔗 Отправь другу:\nhttps://t.me/%s?start=%s", code, bot.Self.UserName, code)
				msg.ParseMode = "HTML"
			} else if txt == "🔄 Reload Cluster" {
				msg.Text = "⏳ Обновляю конфиги..."
				bot.Send(msg)
				msg.Text = reloadAllBridges()
			} else if txt == "👥 Users" {
				// Упрощенный вывод для админа
				msg.Text = "Смотри пользователей через CLI (меню сервера)."
			}
		}

		if strings.HasPrefix(txt, "/start INV-") {
			code := strings.TrimPrefix(txt, "/start ")
			var exists int
			err := db.QueryRow("SELECT 1 FROM invites WHERE code=?", code).Scan(&exists)
			
			if err == nil {
				uuid := makeUUID()
				name := update.Message.From.UserName
				if name == "" { name = fmt.Sprintf("user_%d", userID) }
				
				db.Exec("INSERT OR REPLACE INTO users (uuid, name) VALUES (?, ?)", uuid, name)
				db.Exec("DELETE FROM invites WHERE code=?", code)
				pushUserToBridges(uuid, name)
				
				pageURL := fmt.Sprintf("https://%s/sub/%s.html", config.Domain, uuid)
				msg.Text = fmt.Sprintf("✅ <b>Успешно!</b>\n\n👇 Нажми на ссылку ниже, чтобы подключить VPN:\n\n%s", pageURL)
				msg.ParseMode = "HTML"
			} else {
				msg.Text = "❌ Инвайт недействителен."
			}
		}
		if msg.Text != "" { bot.Send(msg) }
    }
}
GO_EOF

    go mod init orchestrator
    go get github.com/go-telegram-bot-api/telegram-bot-api/v5
    go get modernc.org/sqlite
    go get golang.org/x/crypto/ssh
    go build -ldflags="-s -w" -o /usr/local/bin/orchestrator
    
    cat <<EOF > /etc/systemd/system/orchestrator.service
[Unit]
Description=VPN Orchestrator
After=network.target
[Service]
ExecStart=/usr/local/bin/orchestrator
Restart=always
User=root
WorkingDirectory=/etc/orchestrator
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable orchestrator
    systemctl restart orchestrator
    echo "✅ Master запущен!"
}

# ==============================================================================
# 2. ДОБАВИТЬ RU BRIDGE (Unified Local & Remote)
# ==============================================================================
add_ru_bridge() {
    echo -e "\n🌉 ДОБАВЛЕНИЕ RU МОСТА"
    echo "💡 Если хочешь установить мост на этот же сервер — введи 127.0.0.1"
    read -p "IP адрес: " IP
    read -p "Домен моста (напр. bridge1.vpn.com): " DOMAIN
    
    if [ "$IP" == "127.0.0.1" ] ||[ "$IP" == "localhost" ]; then
        USER="local"; PASS="local"
        echo "⏳ Установка локального моста..."
        CMD_EXEC="bash -c"
    else
        read -s -p "Root пароль: " PASS; echo ""
        USER="root"
        echo "⏳ Установка удаленного моста ($IP)..."
        CMD_EXEC="sshpass -p $PASS ssh -o StrictHostKeyChecking=no root@$IP bash -c"
    fi

    # Скрипт установки, который выполняется на целевом сервере (локально или по SSH)
    $CMD_EXEC '
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl jq openssl ufw >/dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        KEYS=$(xray x25519)
        PK=$(echo "$KEYS" | grep "Private" | awk "{print \$3}")
        PUB=$(echo "$KEYS" | grep "Public" | awk "{print \$3}")
        SID=$(openssl rand -hex 4)
        echo "$PUB|$SID" > /root/keys.txt
        
        cat <<JSON > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "services":["HandlerService"]},
  "inbounds":[
    { "tag": "api-in", "port": 10085, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"} },
    {
      "tag": "client-in", "port": 443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none", "fallbacks":[{"dest": 80}] },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "www.microsoft.com:443", "serverNames":["www.microsoft.com"], "privateKey": "$PK", "shortIds": ["$SID"] } }
    }
  ],
  "outbounds":[ {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"} ],
  "routing": { 
      "balancers":[{"tag": "eu-balancer", "selector":["eu-"]}],
      "rules":[ {"type": "field", "inboundTag":["api-in"], "outboundTag": "api"}, {"type": "field", "inboundTag":["client-in"], "balancerTag": "eu-balancer"} ]
  }
}
JSON
        systemctl restart xray
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 10085/tcp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
    '

    # Забираем ключи
    if [ "$IP" == "127.0.0.1" ]; then
        KEYS=$(cat /root/keys.txt)
    else
        KEYS=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@$IP "cat /root/keys.txt")
    fi

    PUB=$(echo $KEYS | cut -d'|' -f1)
    SID=$(echo $KEYS | cut -d'|' -f2)
    
    sqlite3 /etc/orchestrator/core.db "INSERT OR REPLACE INTO bridges (ip, domain, user, pass, pub_key, sid) VALUES ('$IP', '$DOMAIN', '$USER', '$PASS', '$PUB', '$SID')"
    echo "✅ Мост развернут! Нажми 'Reload Cluster' в Telegram боте."
}

# ==============================================================================
# 3. ДОБАВИТЬ EU NODE (+WARP)
# ==============================================================================
add_eu_node() {
    echo -e "\n🇪🇺 ДОБАВЛЕНИЕ EU НОДЫ (+WARP)"
    read -p "IP адрес: " IP
    read -s -p "Root пароль: " PASS; echo ""
    BRIDGE_UUID="11111111-1111-1111-1111-111111111111"
    
    echo "⏳ Установка Xray и WARP..."
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" << REMOTE_EOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl ufw gpg lsb-release jq >/dev/null 2>&1
        
        # Install WARP
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb[arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ \$(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq cloudflare-warp >/dev/null 2>&1
        
        warp-cli --accept-tos registration new >/dev/null 2>&1
        warp-cli --accept-tos mode proxy >/dev/null 2>&1
        warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
        warp-cli --accept-tos connect >/dev/null 2>&1
        
        # Install Xray
        bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        KEYS=\$(xray x25519)
        PK=\$(echo "\$KEYS" | grep "Private" | awk '{print \$3}')
        PUB=\$(echo "\$KEYS" | grep "Public" | awk '{print \$3}')
        echo "\$PUB" > /root/pub.key
        
        cat <<JSON > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds":[
    {
        "port": 443, "protocol": "vless",
        "settings": { "clients":[{"id": "$BRIDGE_UUID", "flow": "xtls-rprx-vision"}], "decryption": "none" },
        "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"], "privateKey": "\$PK", "shortIds":[""] } }
    }
  ],
  "outbounds":[
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "socks", "tag": "warp", "settings": {"servers":[{"address": "127.0.0.1", "port": 40000}]}},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules":[
      {"type": "field", "domain":["geosite:google", "geosite:openai", "geosite:netflix", "geosite:instagram"], "outboundTag": "warp"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "block"}
    ]
  }
}
JSON
        systemctl restart xray
        ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
REMOTE_EOF

    PUB=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$IP" "cat /root/pub.key")
    sqlite3 /etc/orchestrator/core.db "INSERT OR REPLACE INTO exits (ip, user, pass, pub_key) VALUES ('$IP', 'root', '$PASS', '$PUB')"
    echo "✅ EU Нода добавлена! Нажми 'Reload Cluster' в боте."
}

# ==============================================================================
# 4. УПРАВЛЕНИЕ МАРШРУТАМИ WARP (EU)
# ==============================================================================
manage_warp() {
    echo -e "\n🌍 НАСТРОЙКА ДОМЕНОВ ДЛЯ WARP"
    echo "Текущие ноды в базе:"
    sqlite3 /etc/orchestrator/core.db "SELECT ip FROM exits WHERE active=1"
    
    echo "Формат: geosite:google, domain:chatgpt.com, full:api.openai.com"
    read -p "Введи домены через запятую: " DOMAINS
    
    if [ -z "$DOMAINS" ]; then return; fi
    
    # Конвертируем строку в JSON массив
    JSON_DOMS=$(echo "$DOMAINS" | jq -R 'split(",") | map(gsub("^\\s+|\\s+$";""))')
    
    # Обходим все EU ноды и применяем
    IPS=$(sqlite3 /etc/orchestrator/core.db "SELECT ip, pass FROM exits WHERE active=1")
    for ROW in $IPS; do
        IP=$(echo $ROW | cut -d'|' -f1)
        PASS=$(echo $ROW | cut -d'|' -f2)
        echo "⏳ Обновляю $IP..."
        
        sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" << REMOTE_EOF
            jq --argjson doms '$JSON_DOMS' '.routing.rules |= map(if .outboundTag == "warp" then .domain = \$doms else . end)' /usr/local/etc/xray/config.json > /tmp/cfg.tmp
            mv /tmp/cfg.tmp /usr/local/etc/xray/config.json
            systemctl restart xray
REMOTE_EOF
        echo "✅ Обновлено!"
    done
}

# ==============================================================================
# 5. УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ (CLI)
# ==============================================================================
manage_users_cli() {
    while true; do
        clear
        echo "👥 УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ"
        echo "-----------------------------------"
        curl -s "http://127.0.0.1:8080/api/cli?action=list"
        echo "-----------------------------------"
        echo "1) ➕ Добавить юзера"
        echo "2) ➖ Удалить юзера (по UUID)"
        echo "3) 🎫 Сгенерировать инвайт"
        echo "0) ↩️ Назад"
        read -p "Выбор: " U_OPT
        
        case $U_OPT in
            1)
                read -p "Имя: " NAME
                LINK=$(curl -s "http://127.0.0.1:8080/api/cli?action=add&name=$NAME")
                echo "✅ Создан! Ссылка: $LINK"
                read -p "Enter..." ;;
            2)
                read -p "UUID: " UUID_DEL
                curl -s "http://127.0.0.1:8080/api/cli?action=del&uuid=$UUID_DEL"
                echo "✅ Удален!"
                read -p "Enter..." ;;
            3)
                CODE=$(curl -s "http://127.0.0.1:8080/api/cli?action=invite")
                echo "🎫 Инвайт: $CODE (Пусть юзер отправит боту /start $CODE)"
                read -p "Enter..." ;;
            0) return ;;
        esac
    done
}

# ==============================================================================
# MENU
# ==============================================================================
while true; do
    clear
    echo "🧠 VPN ORCHESTRATOR v7.0"
    echo "-----------------------------------"
    echo "1. 🛠 Установить Master"
    echo "2. 🌉 Добавить RU Bridge (Мост)"
    echo "3. 🇪🇺 Добавить EU Node (+WARP)"
    echo "-----------------------------------"
    echo "4. 🌍 Настроить домены для WARP"
    echo "5. 👥 Управление пользователями"
    echo "0. Выход"
    echo "-----------------------------------"
    read -p "Выбор: " C
    case $C in
        1) install_orchestrator ; read -p "Enter..." ;;
        2) add_ru_bridge ; read -p "Enter..." ;;
        3) add_eu_node ; read -p "Enter..." ;;
        4) manage_warp ; read -p "Enter..." ;;
        5) manage_users_cli ;;
        0) exit 0 ;;
    esac
done
