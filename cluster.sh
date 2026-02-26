#!/bin/bash

# ==============================================================================
# 🚀 VPN CLOUD NATIVE v8.0 (Master API + Bridge Agents + EU Nodes)
# Архитектура: Pull-based (No SSH). Мастер раздает стейт, Агенты его применяют.
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive
MASTER_IP=$(curl -s4 ifconfig.me)

install_deps() {
    if ! command -v go &> /dev/null; then
        echo "⏳ Установка зависимостей..."
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq jq sqlite3 curl openssl git build-essential nginx certbot python3-certbot-nginx ufw uuid-runtime >/dev/null 2>&1
        
        wget -q https://go.dev/dl/go1.22.1.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.1.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.profile
    fi
}

install_master() {
    install_deps
    echo -e "\n🧠 УСТАНОВКА ЦЕНТРА УПРАВЛЕНИЯ (MASTER API)"
    
    read -p "🤖 Telegram Bot Token (Опционально): " TG_TOKEN
    read -p "🆔 Telegram Admin ID: " TG_CHAT_ID
    read -p "🌐 Домен Мастера для подписок (sub.master.com): " SUB_DOMAIN
    read -p "✉️ Email для SSL (Let's Encrypt): " SSL_EMAIL
    
    # Генерируем секреты кластера
    CLUSTER_TOKEN=$(openssl rand -hex 16)
    BRIDGE_UUID=$(uuidgen)
    
    mkdir -p /etc/orchestrator
    cat <<EOF > /etc/orchestrator/config.env
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SUB_DOMAIN="$SUB_DOMAIN"
CLUSTER_TOKEN="$CLUSTER_TOKEN"
BRIDGE_UUID="$BRIDGE_UUID"
MASTER_IP="$MASTER_IP"
EOF

    # SSL для Мастера
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

    mkdir -p /usr/src/vpn-cluster
    cd /usr/src/vpn-cluster

    # ==============================================================================
    # 🧠 КОД МАСТЕРА (API + BOT + DB) - Не требует Xray!
    # ==============================================================================
    cat << 'MASTER_EOF' > master.go
package main

import (
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
	"time"
	"crypto/rand"
	"encoding/hex"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	_ "modernc.org/sqlite"
)

var db *sql.DB
var cfg struct { Token, ChatID, Domain, ClusterToken, BridgeUUID, MasterIP string }

func initDB() {
	db, _ = sql.Open("sqlite", "/etc/orchestrator/core.db?_pragma=journal_mode(WAL)")
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, name TEXT, traffic_up INT DEFAULT 0, traffic_down INT DEFAULT 0)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS bridges (ip TEXT PRIMARY KEY, domain TEXT, pub_key TEXT, sid TEXT, last_seen DATETIME)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS exits (ip TEXT PRIMARY KEY, pub_key TEXT)`)
}

func loadConfig() {
	data, _ := os.ReadFile("/etc/orchestrator/config.env")
	for _, l := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(l, "=", 2)
		if len(parts) != 2 { continue }
		k, v := parts[0], strings.Trim(parts[1], "\"")
		switch k {
		case "TG_TOKEN": cfg.Token = v; case "TG_CHAT_ID": cfg.ChatID = v
		case "SUB_DOMAIN": cfg.Domain = v; case "CLUSTER_TOKEN": cfg.ClusterToken = v
		case "BRIDGE_UUID": cfg.BridgeUUID = v; case "MASTER_IP": cfg.MasterIP = v
		}
	}
}

// === API ДЛЯ АГЕНТОВ ===
func authMiddleware(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+cfg.ClusterToken { http.Error(w, "Unauthorized", 401); return }
		next(w, r)
	}
}

// Агент запрашивает стейт
func handleSync(w http.ResponseWriter, r *http.Request) {
	bridgeIP := r.Header.Get("X-Bridge-IP")
	if bridgeIP != "" { db.Exec("UPDATE bridges SET last_seen=CURRENT_TIMESTAMP WHERE ip=?", bridgeIP) }

	var users []map[string]string
	uRows, _ := db.Query("SELECT uuid, name FROM users")
	for uRows.Next() { var u, n string; uRows.Scan(&u, &n); users = append(users, map[string]string{"uuid": u, "email": n}) }
	
	var exits []map[string]string
	eRows, _ := db.Query("SELECT ip, pub_key FROM exits")
	for eRows.Next() { var ip, pk string; eRows.Scan(&ip, &pk); exits = append(exits, map[string]string{"ip": ip, "pub_key": pk}) }

	json.NewEncoder(w).Encode(map[string]interface{}{"bridge_uuid": cfg.BridgeUUID, "users": users, "exits": exits})
}

// Агент присылает статистику
func handleStats(w http.ResponseWriter, r *http.Request) {
	var stats[]map[string]interface{}
	json.NewDecoder(r.Body).Decode(&stats)
	for _, s := range stats {
		email := s["email"].(string)
		up := int64(s["up"].(float64))
		down := int64(s["down"].(float64))
		db.Exec("UPDATE users SET traffic_up=traffic_up+?, traffic_down=traffic_down+? WHERE name=?", up, down, email)
	}
	w.WriteHeader(200)
}

// Регистрация серверов (Вызывается bash скриптами при установке)
func handleRegister(w http.ResponseWriter, r *http.Request) {
	typ := r.URL.Query().Get("type")
	ip := r.URL.Query().Get("ip")
	pk := r.URL.Query().Get("pk")
	if typ == "eu" {
		db.Exec("INSERT OR REPLACE INTO exits (ip, pub_key) VALUES (?, ?)", ip, pk)
	} else if typ == "ru" {
		domain := r.URL.Query().Get("domain")
		sid := r.URL.Query().Get("sid")
		db.Exec("INSERT OR REPLACE INTO bridges (ip, domain, pub_key, sid, last_seen) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)", ip, domain, pk, sid)
	}
	w.WriteHeader(200)
}

// === ПОДПИСКИ ===
func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	isHTML := strings.HasSuffix(uuid, ".html")
	uuid = strings.TrimSuffix(uuid, ".html")

	var name string
	if db.QueryRow("SELECT name FROM users WHERE uuid=?", uuid).Scan(&name) != nil { http.Error(w, "Not found", 404); return }

	bRows, _ := db.Query("SELECT domain, pub_key, sid FROM bridges")
	var links[]string
	for bRows.Next() {
		var d, pk, sid string; bRows.Scan(&d, &pk, &sid)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=www.microsoft.com#%s-[%s]", uuid, d, pk, sid, name, d))
	}
	
	if isHTML {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		u := "https://" + cfg.Domain + "/sub/" + uuid
		html := fmt.Sprintf(`<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>VPN</title><style>body{background:#121212;color:#fff;font-family:sans-serif;text-align:center;padding:20px}.btn{display:block;padding:15px;margin:10px auto;background:#007AFF;color:#fff;text-decoration:none;border-radius:10px;max-width:300px}</style></head><body><h2>Привет, %s!</h2><a href="v2raytun://import/%s" class="btn">🚀 Подключить V2rayTun</a><a href="hiddify://install-config?url=%s" class="btn">🤖 Подключить Hiddify</a><p>Обычная ссылка:</p><code>%s</code></body></html>`, name, u, u, u)
		w.Write([]byte(html))
	} else {
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
	}
}

// === ГЕНЕРАЦИЯ BASH СКРИПТОВ УСТАНОВКИ ===
func handleInstallScripts(w http.ResponseWriter, r *http.Request) {
	typ := strings.TrimPrefix(r.URL.Path, "/install/")
	script := ""
	if typ == "bridge" {
		script = fmt.Sprintf(`#!/bin/bash
DOMAIN=$1
if[ -z "$DOMAIN" ]; then echo "Укажи домен моста!"; exit 1; fi
apt update && apt install -y curl uuid-runtime jq
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
KEYS=$(xray x25519); PK=$(echo "$KEYS" | grep Private | awk '{print $3}'); PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')
SID=$(openssl rand -hex 4)
echo "$PK|$SID" > /usr/local/etc/xray/agent_keys.txt
IP=$(curl -s4 ifconfig.me)
curl -H "Authorization: Bearer %s" "http://%s:8080/api/register?type=ru&ip=$IP&domain=$DOMAIN&pk=$PUB&sid=$SID"
wget -q http://%s:8080/download/agent -O /usr/local/bin/vpn-agent && chmod +x /usr/local/bin/vpn-agent
cat <<EOF > /etc/systemd/system/vpn-agent.service
[Unit]
Description=VPN Bridge Agent[Service]
ExecStart=/usr/local/bin/vpn-agent -master http://%s:8080 -token %s
Restart=always
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable vpn-agent && systemctl restart vpn-agent
echo "✅ Мост установлен и подключен к Мастеру!"
`, cfg.ClusterToken, cfg.MasterIP, cfg.MasterIP, cfg.MasterIP, cfg.ClusterToken)

	} else if typ == "eu" {
		script = fmt.Sprintf(`#!/bin/bash
apt update && apt install -y curl gpg lsb-release jq
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb[arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp
warp-cli --accept-tos registration new; warp-cli --accept-tos mode proxy; warp-cli --accept-tos proxy port 40000; warp-cli --accept-tos connect
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
KEYS=$(xray x25519); PK=$(echo "$KEYS" | grep Private | awk '{print $3}'); PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')
IP=$(curl -s4 ifconfig.me)
cat <<EOF > /usr/local/etc/xray/config.json
{"log":{"loglevel":"warning"},"inbounds":[{"port":443,"protocol":"vless","settings":{"clients":[{"id":"%s","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"$PK","shortIds":[""]}}}],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}},{"protocol":"blackhole","tag":"block"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","domain":["geosite:google","geosite:openai","geosite:netflix"],"outboundTag":"warp"},{"type":"field","ip":["geoip:private"],"outboundTag":"block"}]}}
EOF
systemctl restart xray
curl -H "Authorization: Bearer %s" "http://%s:8080/api/register?type=eu&ip=$IP&pk=$PUB"
echo "✅ EU Нода установлена!"
`, cfg.BridgeUUID, cfg.ClusterToken, cfg.MasterIP)
	}
	w.Write([]byte(script))
}

func main() {
	loadConfig(); initDB()
	
	http.HandleFunc("/api/sync", authMiddleware(handleSync))
	http.HandleFunc("/api/stats", authMiddleware(handleStats))
	http.HandleFunc("/api/register", authMiddleware(handleRegister))
	http.HandleFunc("/sub/", handleSub)
	http.HandleFunc("/install/", handleInstallScripts)
	http.Handle("/download/", http.StripPrefix("/download/", http.FileServer(http.Dir("/etc/orchestrator/bin"))))
	
	go http.ListenAndServe("0.0.0.0:8080", nil)

	if cfg.Token != "" {
		bot, _ := tgbotapi.NewBotAPI(cfg.Token)
		u := tgbotapi.NewUpdate(0); u.Timeout = 60
		updates := bot.GetUpdatesChan(u)
		for update := range updates {
			if update.Message == nil { continue }
			txt := update.Message.Text
			if fmt.Sprintf("%d", update.Message.Chat.ID) == cfg.ChatID {
				msg := tgbotapi.NewMessage(update.Message.Chat.ID, "")
				if txt == "/start" || txt == "/menu" {
					msg.Text = "🧠 Master Control\n/invite - Создать инвайт\n/status - Статус нод"
				} else if txt == "/invite" {
					b := make([]byte, 4); rand.Read(b); code := "INV-" + strings.ToUpper(hex.EncodeToString(b))
					db.Exec("INSERT INTO invites (code) VALUES (?)", code)
					msg.Text = fmt.Sprintf("✅ Инвайт: <code>%s</code>\n🔗 https://t.me/%s?start=%s", code, bot.Self.UserName, code)
					msg.ParseMode = "HTML"
				} else if txt == "/status" {
					var bC, eC int; db.QueryRow("SELECT COUNT(*) FROM bridges WHERE last_seen > datetime('now', '-5 minute')").Scan(&bC)
					db.QueryRow("SELECT COUNT(*) FROM exits").Scan(&eC)
					msg.Text = fmt.Sprintf("📊 Online Мостов: %d\n🇪🇺 EU Нод: %d", bC, eC)
				}
				bot.Send(msg)
			}
			
			if strings.HasPrefix(txt, "/start INV-") {
				code := strings.TrimPrefix(txt, "/start ")
				var ex int
				if db.QueryRow("SELECT 1 FROM invites WHERE code=?", code).Scan(&ex) == nil {
					b := make([]byte, 16); rand.Read(b); b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80
					uuid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
					name := update.Message.From.UserName; if name == "" { name = fmt.Sprintf("user_%d", update.Message.From.ID) }
					db.Exec("INSERT INTO users (uuid, name) VALUES (?, ?)", uuid, name)
					db.Exec("DELETE FROM invites WHERE code=?", code)
					bot.Send(tgbotapi.NewMessage(update.Message.Chat.ID, fmt.Sprintf("✅ Готово! Настройка:\nhttps://%s/sub/%s.html", cfg.Domain, uuid)))
				}
			}
		}
	} else { select {} }
}
MASTER_EOF

    # ==============================================================================
    # 🕵️ КОД АГЕНТА (Ставится на RU-мосты) - Работает с Xray
    # ==============================================================================
    cat << 'AGENT_EOF' > agent.go
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io/ioutil"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"
	"crypto/sha256"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	proxyman "github.com/xtls/xray-core/app/proxyman/command"
	stats "github.com/xtls/xray-core/app/stats/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
)

var (
	masterURL string
	token     string
	lastExitsHash string
	knownUsers = make(map[string]bool)
)

type State struct {
	BridgeUUID string              `json:"bridge_uuid"`
	Users      []map[string]string `json:"users"`
	Exits      []map[string]string `json:"exits"`
}

func syncWithMaster() {
	req, _ := http.NewRequest("GET", masterURL+"/api/sync", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != 200 { return }
	defer resp.Body.Close()

	var state State
	json.NewDecoder(resp.Body).Decode(&state)

	// 1. Сверяем EU ноды (генерация конфига)
	exitsJSON, _ := json.Marshal(state.Exits)
	currentHash := fmt.Sprintf("%x", sha256.Sum256(exitsJSON))
	
	if currentHash != lastExitsHash {
		buildAndRestartXray(state.BridgeUUID, state.Exits)
		lastExitsHash = currentHash
		// После рестарта Xray забывает юзеров. Очищаем кэш, чтобы залить их заново.
		knownUsers = make(map[string]bool)
		time.Sleep(2 * time.Second)
	}

	// 2. Сверяем Юзеров (gRPC)
	newKnown := make(map[string]bool)
	for _, u := range state.Users {
		uuid, email := u["uuid"], u["email"]
		newKnown[uuid] = true
		if !knownUsers[uuid] {
			addUserToXray(uuid, email)
		}
	}
	// Удаление старых (для простоты здесь пропускаем, можно добавить rminbnd)
	knownUsers = newKnown
}

func buildAndRestartXray(bridgeUUID string, exits []map[string]string) {
	keys, _ := ioutil.ReadFile("/usr/local/etc/xray/agent_keys.txt")
	parts := strings.Split(strings.TrimSpace(string(keys)), "|")
	if len(parts) != 2 { return }
	pk, sid := parts[0], parts[1]

	var outbounds[]string
	var balancers []string
	for _, e := range exits {
		ip, pub := e["ip"], e["pub_key"]
		outbounds = append(outbounds, fmt.Sprintf(`{"tag":"eu-%s","protocol":"vless","settings":{"vnext":[{"address":"%s","port":443,"users":[{"id":"%s","flow":"xtls-rprx-vision","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"www.microsoft.com","publicKey":"%s","fingerprint":"chrome"}}}`, ip, ip, bridgeUUID, pub))
		balancers = append(balancers, fmt.Sprintf(`"eu-%s"`, ip))
	}
	
	outStr := "[]"; if len(outbounds)>0 { outStr = "["+strings.Join(outbounds, ",")+"]" }
	selStr := "\"block\""; if len(balancers)>0 { selStr = strings.Join(balancers, ",") }

	cfg := fmt.Sprintf(`{"log":{"loglevel":"warning"},"api":{"tag":"api","services":["HandlerService","StatsService"]},"stats":{},"policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}}},"inbounds":[{"tag":"api-in","port":10085,"listen":"127.0.0.1","protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}},{"tag":"client-in","port":443,"protocol":"vless","settings":{"clients":[],"decryption":"none","fallbacks":[{"dest":80}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"%s","shortIds":["%s"]}}}],"outbounds":[%s,{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"routing":{"domainStrategy":"IPIfNonMatch","balancers":[{"tag":"eu-balancer","selector":[%s]}],"rules":[{"type":"field","inboundTag":["api-in"],"outboundTag":"api"},{"type":"field","inboundTag":["client-in"],"balancerTag":"eu-balancer"},{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}}`, pk, sid, strings.Trim(outStr, "[]"), selStr)

	ioutil.WriteFile("/usr/local/etc/xray/config.json",[]byte(cfg), 0644)
	exec.Command("systemctl", "restart", "xray").Run()
}

func addUserToXray(uuid, email string) {
	conn, err := grpc.Dial("127.0.0.1:10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil { return }
	defer conn.Close()
	c := proxyman.NewHandlerServiceClient(conn)
	c.AlterInbound(context.Background(), &proxyman.AlterInboundRequest{
		Tag: "client-in",
		Operation: serial.ToTypedMessage(&proxyman.AddUserOperation{
			User: &protocol.User{Level: 0, Email: email, Account: serial.ToTypedMessage(&vless.Account{Id: uuid, Flow: "xtls-rprx-vision"})},
		}),
	})
}

func sendStats() {
	conn, err := grpc.Dial("127.0.0.1:10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil { return }
	defer conn.Close()
	c := stats.NewStatsServiceClient(conn)
	resp, err := c.QueryStats(context.Background(), &stats.QueryStatsRequest{Pattern: "user>>>", Reset_: true})
	if err != nil { return }

	var payload []map[string]interface{}
	for _, s := range resp.Stat {
		p := strings.Split(s.Name, ">>>")
		if len(p) == 4 {
			payload = append(payload, map[string]interface{}{"email": p[1], "type": p[3], "value": s.Value})
		}
	}
	
	// Упрощенная агрегация для отправки
	aggr := make(map[string]map[string]int64)
	for _, p := range payload {
		e := p["email"].(string); t := p["type"].(string); v := p["value"].(int64)
		if aggr[e] == nil { aggr[e] = make(map[string]int64) }
		if t == "downlink" { aggr[e]["down"] += v } else { aggr[e]["up"] += v }
	}
	
	var finalPayload []map[string]interface{}
	for e, data := range aggr { finalPayload = append(finalPayload, map[string]interface{}{"email": e, "up": data["up"], "down": data["down"]}) }
	
	if len(finalPayload) > 0 {
		b, _ := json.Marshal(finalPayload)
		req, _ := http.NewRequest("POST", masterURL+"/api/stats", bytes.NewBuffer(b))
		req.Header.Set("Authorization", "Bearer "+token)
		http.DefaultClient.Do(req)
	}
}

func main() {
	flag.StringVar(&masterURL, "master", "", "")
	flag.StringVar(&token, "token", "", "")
	flag.Parse()

	for {
		syncWithMaster()
		sendStats()
		time.Sleep(30 * time.Second)
	}
}
AGENT_EOF

    echo "⏳ Компиляция Мастера..."
    go mod init vpn-cluster
    go get github.com/go-telegram-bot-api/telegram-bot-api/v5 modernc.org/sqlite
    go build -ldflags="-s -w" -o /usr/local/bin/vpn-master master.go
    
    echo "⏳ Компиляция Агента..."
    mkdir -p /etc/orchestrator/bin
    go get google.golang.org/grpc github.com/xtls/xray-core/app/proxyman/command github.com/xtls/xray-core/app/stats/command github.com/xtls/xray-core/common/protocol github.com/xtls/xray-core/common/serial github.com/xtls/xray-core/proxy/vless
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /etc/orchestrator/bin/agent agent.go

    cat <<EOF > /etc/systemd/system/vpn-master.service
[Unit]
Description=VPN Master API
[Service]
ExecStart=/usr/local/bin/vpn-master
Restart=always
WorkingDirectory=/etc/orchestrator
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable vpn-master && systemctl restart vpn-master
    
    echo "✅ Мастер установлен!"
    echo "---------------------------------------------------"
    echo "Твой CLUSTER_TOKEN: $CLUSTER_TOKEN"
    echo "Точка API: http://$MASTER_IP:8080"
    echo "---------------------------------------------------"
}

# ==============================================================================
# MENU
# ==============================================================================
show_commands() {
    clear
    TOKEN=$(grep CLUSTER_TOKEN /etc/orchestrator/config.env | cut -d'"' -f2)
    API="http://$(curl -s4 ifconfig.me):8080"
    echo "========================================================="
    echo "🚀 ДОБАВЛЕНИЕ СЕРВЕРОВ В КЛАСТЕР"
    echo "========================================================="
    echo "👉 Чтобы добавить RU-мост (Bridge), выполни на нем команду:"
    echo "curl -sL $API/install/bridge | bash -s -- твой-домен-моста.ru"
    echo ""
    echo "👉 Чтобы добавить EU-ноду (Exit), выполни на ней команду:"
    echo "curl -sL $API/install/eu | bash"
    echo "========================================================="
    echo "Агенты сами свяжутся с Мастером и настроят Xray!"
    read -p "Нажми Enter..."
}

while true; do
    clear
    echo "🧠 CLOUD NATIVE ORCHESTRATOR v8.0"
    echo "-----------------------------------"
    if [ ! -f /usr/local/bin/vpn-master ]; then
        echo "1. 🛠 Установить Master API"
    else
        echo "2. 🚀 Показать команды для деплоя нод (RU/EU)"
    fi
    echo "0. Выход"
    echo "-----------------------------------"
    read -p "Выбор: " C
    case $C in
        1) install_master ; read -p "Enter..." ;;
        2) show_commands ;;
        0) exit 0 ;;
    esac
done
