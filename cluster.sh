#!/bin/bash

# ==============================================================================
# 🚀 VPN ORCHESTRATOR v6.1 (Master + Local/Remote Bridges + WARP)
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive

# Установка зависимостей
install_deps() {
    if ! command -v go &> /dev/null; then
        echo "⏳ Установка зависимостей..."
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq jq sqlite3 curl sshpass openssl git build-essential zip ufw >/dev/null 2>&1
        
        echo "⏳ Установка Go..."
        wget -q https://go.dev/dl/go1.22.1.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.1.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.profile
    fi
}

# ==============================================================================
# 1. УСТАНОВКА ORCHESTRATOR (MASTER)
# ==============================================================================
install_orchestrator() {
    install_deps
    echo -e "\n🧠 УСТАНОВКА ЦЕНТРА УПРАВЛЕНИЯ (БЕЗ VPN)"
    
    read -p "🤖 Telegram Bot Token: " TG_TOKEN
    read -p "🆔 Telegram Admin ID: " TG_CHAT_ID
    
    mkdir -p /etc/orchestrator
    echo "TG_TOKEN=\"$TG_TOKEN\"" > /etc/orchestrator/config.env
    echo "TG_CHAT_ID=\"$TG_CHAT_ID\"" >> /etc/orchestrator/config.env

    echo "⏳ Сборка Orchestrator Core..."
    mkdir -p /usr/src/orchestrator
    cd /usr/src/orchestrator

    # --- GO CODE START ---
    cat << 'GO_EOF' > main.go
package main

import (
	"database/sql"
	"encoding/hex"
	"fmt"
	"log"
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
	}
)

func init() {
	data, _ := os.ReadFile("/etc/orchestrator/config.env")
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "TG_TOKEN=") { config.Token = strings.Trim(strings.TrimPrefix(line, "TG_TOKEN="), "\"") }
		if strings.HasPrefix(line, "TG_CHAT_ID=") { fmt.Sscanf(strings.TrimPrefix(line, "TG_CHAT_ID="), "\"%d\"", &config.ChatID) }
	}

	var err error
	db, err = sql.Open("sqlite", "/etc/orchestrator/core.db?_pragma=busy_timeout(5000)&_pragma=journal_mode(WAL)")
	if err != nil { log.Fatal(err) }
	
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, name TEXT, active INTEGER DEFAULT 1, traffic INTEGER DEFAULT 0)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, created_at DATETIME DEFAULT CURRENT_TIMESTAMP)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS bridges (ip TEXT PRIMARY KEY, domain TEXT, user TEXT, pass TEXT, pub_key TEXT, sid TEXT, active INTEGER DEFAULT 1)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS exits (ip TEXT PRIMARY KEY, user TEXT, pass TEXT, pub_key TEXT, active INTEGER DEFAULT 1)`)
}

// === EXEC UTILS (Local & SSH) ===
func remoteExec(ip, user, pass, cmd string) (string, error) {
    // Если это локальный сервер Мастера, выполняем команду напрямую
	if ip == "127.0.0.1" || ip == "localhost" {
		out, err := exec.Command("bash", "-c", cmd).CombinedOutput()
		return string(out), err
	}

    // Иначе идем по SSH
	cfg := &ssh.ClientConfig{
		User: user,
		Auth:[]ssh.AuthMethod{ssh.Password(pass)},
		HostKeyCallback: ssh.InsecureIgnoreHostKey(),
		Timeout: 10 * time.Second,
	}
	client, err := ssh.Dial("tcp", ip+":22", cfg)
	if err != nil { return "", err }
	defer client.Close()

	session, err := client.NewSession()
	if err != nil { return "", err }
	defer session.Close()

	out, err := session.CombinedOutput(cmd)
	return string(out), err
}

// === LOGIC ===
func generateBridgeConfig(bridgeIP string) string {
    rows, _ := db.Query("SELECT ip, pub_key FROM exits WHERE active=1")
    var outbounds []string
    var balancers[]string
    
    bridgeUUID := "11111111-1111-1111-1111-111111111111" 

    for rows.Next() {
        var ip, pk string
        rows.Scan(&ip, &pk)
        out := fmt.Sprintf(`{
            "tag": "eu-%s", "protocol": "vless",
            "settings": { "vnext":[{ "address": "%s", "port": 443, "users":[{"id": "%s", "flow": "xtls-rprx-vision", "encryption": "none"}] }] },
            "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "serverName": "www.microsoft.com", "publicKey": "%s", "fingerprint": "chrome" } }
        }`, ip, ip, bridgeUUID, pk)
        outbounds = append(outbounds, out)
        balancers = append(balancers, fmt.Sprintf(`"eu-%s"`, ip))
    }
    
    outJson := "[]"; if len(outbounds) > 0 { outJson = "[" + strings.Join(outbounds, ",") + "]" }
    selJson := "[]"; if len(balancers) > 0 { selJson = "[" + strings.Join(balancers, ",") + "]" }
    
    return fmt.Sprintf(`
        jq --argjson newOut '%s' --argjson newSel '%s' '
        .outbounds = ([.outbounds[] | select(.tag=="direct" or .tag=="block")] + $newOut) | 
        .routing.balancers[0].selector = $newSel
        ' /usr/local/etc/xray/config.json > /tmp/cfg.tmp && mv /tmp/cfg.tmp /usr/local/etc/xray/config.json && systemctl restart xray
    `, outJson, selJson)
}

func reloadAllBridges() string {
    rows, _ := db.Query("SELECT ip, user, pass FROM bridges WHERE active=1")
    logMsg := "🔄 Обновление кластера:\n"
    var wg sync.WaitGroup
    
    for rows.Next() {
        var ip, u, p string; rows.Scan(&ip, &u, &p)
        wg.Add(1)
        go func(ip, u, p string) {
            defer wg.Done()
            cmd := generateBridgeConfig(ip)
            _, err := remoteExec(ip, u, p, cmd)
            if err != nil { log.Printf("Error updating %s: %v", ip, err) }
        }(ip, u, p)
        if ip == "127.0.0.1" { logMsg += "✅ Local Bridge обновлен\n" } else { logMsg += fmt.Sprintf("✅ Remote %s обновлен\n", ip) }
    }
    wg.Wait()
    return logMsg
}

func pushUserToBridges(uuid, name string) {
    rows, _ := db.Query("SELECT ip, user, pass FROM bridges WHERE active=1")
    cmd := fmt.Sprintf(`/usr/local/bin/xray api adinbnd -server=127.0.0.1:10085 -inbound=client-in -email=%s -id=%s -flow=xtls-rprx-vision`, name, uuid)
    for rows.Next() {
        var ip, u, p string; rows.Scan(&ip, &u, &p)
        go remoteExec(ip, u, p, cmd)
    }
}

func removeUserFromBridges(name string) {
    rows, _ := db.Query("SELECT ip, user, pass FROM bridges WHERE active=1")
    cmd := fmt.Sprintf(`/usr/local/bin/xray api rminbnd -server=127.0.0.1:10085 -inbound=client-in -email=%s`, name)
    for rows.Next() {
        var ip, u, p string; rows.Scan(&ip, &u, &p)
        go remoteExec(ip, u, p, cmd)
    }
}

// === BOT ===
func main() {
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
                msg.Text = "🧠 Orchestrator v6.1\nУправление кластером."
                msg.ReplyMarkup = tgbotapi.NewReplyKeyboard(
                    tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("👥 Users"), tgbotapi.NewKeyboardButton("🎫 Invite")),
                    tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🔄 Reload Cluster"), tgbotapi.NewKeyboardButton("📊 Status")),
                    tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📦 Backup")),
                )
            } else if txt == "👥 Users" {
                rows, _ := db.Query("SELECT name, uuid FROM users WHERE active=1")
                res := "Активные пользователи:\n"
                for rows.Next() {
                    var n, id string; rows.Scan(&n, &id)
                    res += fmt.Sprintf("👤 %s\n<code>%s</code>\n🗑 /del_%s\n\n", n, id, id)
                }
                msg.Text = res
                msg.ParseMode = "HTML"
            } else if txt == "🎫 Invite" {
                code := "INV-" + makeHex(4)
                db.Exec("INSERT INTO invites (code) VALUES (?)", code)
                msg.Text = fmt.Sprintf("✅ Инвайт: <code>%s</code>\n\n🔗 Ссылка:\nhttps://t.me/%s?start=%s", code, bot.Self.UserName, code)
                msg.ParseMode = "HTML"
            } else if txt == "🔄 Reload Cluster" {
                msg.Text = "⏳ Обновляю конфиги..."
                bot.Send(msg)
                msg.Text = reloadAllBridges()
            } else if txt == "📊 Status" {
                var uC, bC, eC int
                db.QueryRow("SELECT COUNT(*) FROM users").Scan(&uC)
                db.QueryRow("SELECT COUNT(*) FROM bridges").Scan(&bC)
                db.QueryRow("SELECT COUNT(*) FROM exits").Scan(&eC)
                msg.Text = fmt.Sprintf("📊 Состояние:\n👥 Users: %d\n🌉 RU Bridges: %d\n🇪🇺 EU Exits: %d", uC, bC, eC)
            } else if txt == "📦 Backup" {
                 exec.Command("tar", "-czf", "/tmp/backup.tar.gz", "/etc/orchestrator").Run()
                 doc := tgbotapi.NewDocument(update.Message.Chat.ID, tgbotapi.FilePath("/tmp/backup.tar.gz"))
                 bot.Send(doc); continue
            } else if strings.HasPrefix(txt, "/del_") {
                uuid := strings.TrimPrefix(txt, "/del_")
                var name string
                err := db.QueryRow("SELECT name FROM users WHERE uuid=?", uuid).Scan(&name)
                if err == nil {
                    db.Exec("DELETE FROM users WHERE uuid=?", uuid)
                    removeUserFromBridges(name)
                    msg.Text = "✅ Пользователь " + name + " удален со всех мостов."
                }
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
                
                rows, _ := db.Query("SELECT domain, pub_key, sid FROM bridges WHERE active=1")
                links := ""
                for rows.Next() {
                    var dom, pk, sid string; rows.Scan(&dom, &pk, &sid)
                    links += fmt.Sprintf("<code>vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com#%s</code>\n\n", uuid, dom, pk, sid, name)
                }
                
                msg.Text = fmt.Sprintf("✅ <b>Успешно!</b>\n\nТвои ключи доступа:\n\n%s", links)
                msg.ParseMode = "HTML"
            } else {
                msg.Text = "❌ Инвайт не найден."
            }
        }
        if msg.Text != "" { bot.Send(msg) }
    }
}

func makeHex(n int) string { b := make([]byte, n); rand.Read(b); return strings.ToUpper(hex.EncodeToString(b)) }
func makeUUID() string { 
    b := make([]byte, 16); rand.Read(b)
    b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80
    return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
GO_EOF
    # --- GO CODE END ---

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
    
    echo "✅ Orchestrator запущен! Напиши /start боту."
}

# ==============================================================================
# 2. ДОБАВИТЬ ЛОКАЛЬНЫЙ RU BRIDGE (НА МАСТЕРЕ)
# ==============================================================================
add_local_ru_bridge() {
    echo -e "\n🏠 ДОБАВЛЕНИЕ ЛОКАЛЬНОГО RU МОСТА"
    echo "Xray будет установлен на этот же сервер (вместе с Мастером)."
    read -p "Введи домен для подключения к этому мосту: " DOMAIN
    
    echo "⏳ Установка Xray..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    
    KEYS=$(xray x25519)
    PK=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
    PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
    SID=$(openssl rand -hex 4)
    
    cat <<JSON > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "services":["HandlerService", "StatsService"]},
  "inbounds":[
    { "tag": "api-in", "port": 10085, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"} },
    {
      "tag": "client-in", "port": 443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none", "fallbacks":[{"dest": 80}] },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"], "privateKey": "$PK", "shortIds": ["$SID"] } }
    }
  ],
  "outbounds":[ {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"} ],
  "routing": { 
      "balancers": [{"tag": "eu-balancer", "selector":["eu-"]}],
      "rules": [ {"type": "field", "inboundTag": ["api-in"], "outboundTag": "api"}, {"type": "field", "inboundTag": ["client-in"], "balancerTag": "eu-balancer"} ]
  }
}
JSON
    systemctl restart xray
    ufw allow 443/tcp >/dev/null 2>&1
    ufw allow 10085/tcp >/dev/null 2>&1
    ufw --force enable >/dev/null 2>&1
    
    sqlite3 /etc/orchestrator/core.db "INSERT OR REPLACE INTO bridges (ip, domain, user, pass, pub_key, sid) VALUES ('127.0.0.1', '$DOMAIN', 'local', 'local', '$PUB', '$SID')"
    echo "✅ Локальный мост развернут! Нажми 'Reload Cluster' в Telegram боте."
}

# ==============================================================================
# 3. ДОБАВИТЬ УДАЛЕННЫЙ RU BRIDGE (SSH)
# ==============================================================================
add_remote_ru_bridge() {
    echo -e "\n🌉 ДОБАВЛЕНИЕ УДАЛЕННОГО RU МОСТА"
    read -p "IP адрес сервера: " IP
    read -s -p "Root пароль: " PASS; echo ""
    read -p "Домен для подключения: " DOMAIN
    
    echo "⏳ Настройка сервера..."
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" << 'REMOTE_EOF'
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl jq openssl ufw >/dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        KEYS=$(xray x25519)
        PK=$(echo "$KEYS" | grep "Private" | awk '{print $3}')
        PUB=$(echo "$KEYS" | grep "Public" | awk '{print $3}')
        SID=$(openssl rand -hex 4)
        echo "$PUB|$SID" > /root/keys.txt
        
        cat <<JSON > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "api": {"tag": "api", "services":["HandlerService", "StatsService"]},
  "inbounds":[
    { "tag": "api-in", "port": 10085, "listen": "0.0.0.0", "protocol": "dokodemo-door", "settings": {"address": "127.0.0.1"} },
    {
      "tag": "client-in", "port": 443, "protocol": "vless",
      "settings": { "clients": [], "decryption": "none", "fallbacks": [{"dest": 80}] },
      "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "show": false, "dest": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"], "privateKey": "$PK", "shortIds": ["$SID"] } }
    }
  ],
  "outbounds":[ {"tag": "direct", "protocol": "freedom"}, {"tag": "block", "protocol": "blackhole"} ],
  "routing": { 
      "balancers": [{"tag": "eu-balancer", "selector":["eu-"]}],
      "rules": [ {"type": "field", "inboundTag":["api-in"], "outboundTag": "api"}, {"type": "field", "inboundTag":["client-in"], "balancerTag": "eu-balancer"} ]
  }
}
JSON
        systemctl restart xray
        ufw allow 443/tcp >/dev/null 2>&1; ufw allow 10085/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
REMOTE_EOF

    KEYS=$(sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$IP" "cat /root/keys.txt")
    PUB=$(echo $KEYS | cut -d'|' -f1)
    SID=$(echo $KEYS | cut -d'|' -f2)
    
    sqlite3 /etc/orchestrator/core.db "INSERT OR REPLACE INTO bridges (ip, domain, user, pass, pub_key, sid) VALUES ('$IP', '$DOMAIN', 'root', '$PASS', '$PUB', '$SID')"
    echo "✅ Удаленный мост добавлен! Нажми 'Reload Cluster' в боте."
}

# ==============================================================================
# 4. ДОБАВИТЬ EU NODE (+WARP)
# ==============================================================================
add_eu_node() {
    echo -e "\n🇪🇺 ДОБАВЛЕНИЕ EU НОДЫ (+WARP)"
    read -p "IP адрес EU ноды: " IP
    read -s -p "Root пароль: " PASS; echo ""
    BRIDGE_UUID="11111111-1111-1111-1111-111111111111"
    
    echo "⏳ Настройка сервера и WARP..."
    sshpass -p "$PASS" ssh -o StrictHostKeyChecking=no root@"$IP" "bash -s" << REMOTE_EOF
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl ufw gpg lsb-release >/dev/null 2>&1
        
        # 1. WARP
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
        echo "deb[arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ \$(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq cloudflare-warp >/dev/null 2>&1
        
        warp-cli --accept-tos registration new >/dev/null 2>&1
        warp-cli --accept-tos mode proxy >/dev/null 2>&1
        warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
        warp-cli --accept-tos connect >/dev/null 2>&1
        
        # 2. Xray
        bash -c "\$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        KEYS=\$(xray x25519)
        PK=\$(echo "\$KEYS" | grep "Private" | awk '{print \$3}')
        PUB=\$(echo "\$KEYS" | grep "Public" | awk '{print \$3}')
        echo "\$PUB" > /root/pub.key
        
        # 3. Config
        cat <<JSON > /usr/local/etc/xray/config.json
{
  "log": {"loglevel": "warning"},
  "inbounds":[
    {
        "port": 443, "protocol": "vless",
        "settings": { "clients":[{"id": "$BRIDGE_UUID", "flow": "xtls-rprx-vision"}], "decryption": "none" },
        "streamSettings": { "network": "tcp", "security": "reality", "realitySettings": { "dest": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"], "privateKey": "\$PK", "shortIds": [""] } }
    }
  ],
  "outbounds":[
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "socks", "tag": "warp", "settings": {"servers":[{"address": "127.0.0.1", "port": 40000}]}},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
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
    echo "✅ EU Нода добавлена. Нажми 'Reload Cluster' в боте."
}

# ==============================================================================
# MENU
# ==============================================================================
while true; do
    clear
    echo "🧠 VPN ORCHESTRATOR v6.1"
    echo "-----------------------------------"
    echo "1. 🛠 Установить Master"
    echo "2. 🏠 Добавить Локальный RU Bridge"
    echo "3. 🌉 Добавить Удаленный RU Bridge"
    echo "4. 🇪🇺 Добавить EU Node (+WARP)"
    echo "0. Выход"
    echo "-----------------------------------"
    read -p "Выбор: " C
    case $C in
        1) install_orchestrator ; read -p "Enter..." ;;
        2) add_local_ru_bridge ; read -p "Enter..." ;;
        3) add_remote_ru_bridge ; read -p "Enter..." ;;
        4) add_eu_node ; read -p "Enter..." ;;
        0) exit 0 ;;
    esac
done
