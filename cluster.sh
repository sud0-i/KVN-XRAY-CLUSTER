#!/bin/bash
# ==============================================================================
# 🚀 VPN CLOUD NATIVE v12.0 (Ansible-way: SSH Push Setup + Agent Pull Runtime)
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive
MASTER_IP=$(curl -s4 ifconfig.me)

install_deps() {
    if ! command -v go &> /dev/null; then
        echo "⏳ Установка зависимостей..."
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq jq sqlite3 curl openssl git build-essential nginx certbot python3-certbot-nginx ufw uuid-runtime fail2ban tar sshpass >/dev/null 2>&1
        
        wget -q https://go.dev/dl/go1.22.1.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.22.1.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.profile
    fi
}

# ==============================================================================
# 1. УСТАНОВКА МАСТЕРА
# ==============================================================================
install_master() {
    install_deps
    echo -e "\n🧠 УСТАНОВКА ЦЕНТРА УПРАВЛЕНИЯ"
    
    read -p "🤖 Telegram Bot Token: " TG_TOKEN
    read -p "🆔 Telegram Admin ID: " TG_CHAT_ID
    read -p "🌐 Домен Мастера (sub.master.com): " SUB_DOMAIN
    read -p "✉️ Email для SSL (Let's Encrypt): " SSL_EMAIL
    
    CLUSTER_TOKEN=$(openssl rand -hex 16)
    BRIDGE_UUID=$(uuidgen)
    
    # Генерация SSH ключа кластера (без пароля)
    if[ ! -f /root/.ssh/vpn_cluster_key ]; then
        echo "🔑 Генерация SSH-ключей кластера..."
        ssh-keygen -t ed25519 -f /root/.ssh/vpn_cluster_key -N "" -q
    fi
    
    mkdir -p /etc/orchestrator
    cat <<EOF > /etc/orchestrator/config.env
TG_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
SUB_DOMAIN="$SUB_DOMAIN"
CLUSTER_TOKEN="$CLUSTER_TOKEN"
BRIDGE_UUID="$BRIDGE_UUID"
MASTER_IP="$MASTER_IP"
EOF

    # NGINX
    systemctl stop nginx 2>/dev/null
    certbot certonly --standalone -d "$SUB_DOMAIN" -m "$SSL_EMAIL" --agree-tos -n
    
    cat <<EOF > /etc/nginx/sites-available/default
server { listen 80; server_name $SUB_DOMAIN; return 301 https://\$host\$request_uri; }
server {
    listen 443 ssl http2; server_name $SUB_DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$SUB_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$SUB_DOMAIN/privkey.pem;
    
    location /sub/ { proxy_pass http://127.0.0.1:8080/sub/; proxy_set_header X-Real-IP \$remote_addr; }
    location /api/ { proxy_pass http://127.0.0.1:8080/api/; proxy_set_header X-Real-IP \$remote_addr; }
    location /download/ { proxy_pass http://127.0.0.1:8080/download/; }
    location / { return 404; }
}
EOF
    systemctl restart nginx

    mkdir -p /usr/src/vpn-cluster
    cd /usr/src/vpn-cluster

    # --- MASTER GO CODE ---
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
	db.Exec(`CREATE TABLE IF NOT EXISTS exits (ip TEXT PRIMARY KEY, pub_key TEXT, ss_pass TEXT, xhttp_path TEXT)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, val TEXT)`)
	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('sni', 'www.microsoft.com')`)
	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('warp_domains', '"geosite:google","geosite:openai","geosite:netflix","geosite:instagram"')`)
}

func loadConfig() {
	data, _ := os.ReadFile("/etc/orchestrator/config.env")
	for _, l := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(l, "=", 2); if len(parts) != 2 { continue }
		k, v := parts[0], strings.Trim(parts[1], "\"")
		switch k {
		case "TG_TOKEN": cfg.Token = v; case "TG_CHAT_ID": cfg.ChatID = v
		case "SUB_DOMAIN": cfg.Domain = v; case "CLUSTER_TOKEN": cfg.ClusterToken = v
		case "BRIDGE_UUID": cfg.BridgeUUID = v; case "MASTER_IP": cfg.MasterIP = v
		}
	}
}

func authMw(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+cfg.ClusterToken { http.Error(w, "Unauthorized", 401); return }
		next(w, r)
	}
}

func handleSync(w http.ResponseWriter, r *http.Request) {
	bridgeIP := r.Header.Get("X-Bridge-IP")
	if bridgeIP != "" { db.Exec("UPDATE bridges SET last_seen=CURRENT_TIMESTAMP WHERE ip=?", bridgeIP) }

	var sni, warp string
	db.QueryRow("SELECT val FROM settings WHERE key='sni'").Scan(&sni)
	db.QueryRow("SELECT val FROM settings WHERE key='warp_domains'").Scan(&warp)

	users := []map[string]string{}
	uRows, _ := db.Query("SELECT uuid, name FROM users")
	for uRows.Next() { var u, n string; uRows.Scan(&u, &n); users = append(users, map[string]string{"uuid": u, "email": n}) }
	
	exits :=[]map[string]string{}
	eRows, _ := db.Query("SELECT ip, pub_key, ss_pass, xhttp_path FROM exits")
	for eRows.Next() { var ip, pk, ss, xp string; eRows.Scan(&ip, &pk, &ss, &xp); exits = append(exits, map[string]string{"ip": ip, "pub_key": pk, "ss_pass": ss, "xhttp_path": xp}) }

	json.NewEncoder(w).Encode(map[string]interface{}{"bridge_uuid": cfg.BridgeUUID, "sni": sni, "warp_domains": warp, "users": users, "exits": exits})
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	var stats[]map[string]interface{}
	json.NewDecoder(r.Body).Decode(&stats)
	for _, s := range stats {
		db.Exec("UPDATE users SET traffic_up=traffic_up+?, traffic_down=traffic_down+? WHERE name=?", int64(s["up"].(float64)), int64(s["down"].(float64)), s["email"].(string))
	}
	w.WriteHeader(200)
}

func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	isHTML := strings.HasSuffix(uuid, ".html")
	uuid = strings.TrimSuffix(uuid, ".html")

	var name string
	if db.QueryRow("SELECT name FROM users WHERE uuid=?", uuid).Scan(&name) != nil { http.Error(w, "Not found", 404); return }

	var sni string; db.QueryRow("SELECT val FROM settings WHERE key='sni'").Scan(&sni)

	var links[]string
	bRows, _ := db.Query("SELECT domain, pub_key, sid FROM bridges")
	for bRows.Next() {
		var d, pk, sid string; bRows.Scan(&d, &pk, &sid)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TCP-%s]", uuid, d, pk, sid, sni, name, d))
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=xhttp&path=%%2Fxtcp&sni=%s#%s-[xHTTP-%s]", uuid, d, pk, sid, sni, name, d))
	}
	
	if isHTML {
		u := "https://" + cfg.Domain + "/sub/" + uuid
		h := fmt.Sprintf(`<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>VPN Setup</title><script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script><style>body{background:#121212;color:#e0e0e0;font-family:sans-serif;text-align:center;padding:20px}.card{background:#1e1e1e;padding:30px;border-radius:16px;max-width:400px;margin:auto}.btn{display:block;padding:14px;margin-bottom:12px;border-radius:12px;text-decoration:none;font-weight:bold}.btn-ios{background:#007AFF;color:#fff}.btn-android{background:#3DDC84;color:#000}#qr{margin:20px auto;background:#fff;padding:10px;border-radius:8px;display:inline-block}.raw-link{background:#111;padding:10px;border-radius:8px;font-family:monospace;font-size:12px;word-break:break-all}</style></head><body><div class="card"><h2>Привет, %s!</h2><div id="qr"></div><a href="v2raytun://import/%s" class="btn btn-ios">🍏 Подключить iOS / Mac</a><a href="hiddify://install-config?url=%s" class="btn btn-android">🤖 Подключить Android</a><p>Прямая ссылка:</p><div class="raw-link">%s</div></div><script>new QRCode(document.getElementById("qr"), "%s");</script></body></html>`, name, u, u, u, u)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(h))
	} else {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
	}
}

func main() {
	loadConfig(); initDB()
	http.HandleFunc("/api/sync", authMw(handleSync))
	http.HandleFunc("/api/stats", authMw(handleStats))
	http.HandleFunc("/sub/", handleSub)
	http.Handle("/download/", http.StripPrefix("/download/", http.FileServer(http.Dir("/etc/orchestrator/bin"))))
	go http.ListenAndServe("127.0.0.1:8080", nil)

	if cfg.Token != "" {
		bot, _ := tgbotapi.NewBotAPI(cfg.Token)
		u := tgbotapi.NewUpdate(0); u.Timeout = 60
		updates := bot.GetUpdatesChan(u)
		
		mainKeyboard := tgbotapi.NewReplyKeyboard(
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📊 Статус кластера"), tgbotapi.NewKeyboardButton("👥 Юзеры и Трафик")),
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🎫 Создать инвайт"), tgbotapi.NewKeyboardButton("⚙️ Настройки")),
		)

		for update := range updates {
			if update.Message == nil { continue }
			txt := update.Message.Text
			chatID := update.Message.Chat.ID
			
			if fmt.Sprintf("%d", chatID) == cfg.ChatID {
				msg := tgbotapi.NewMessage(chatID, "")
				if txt == "/start" || txt == "/menu" {
					msg.Text = "🧠 Master API v12.0"
					msg.ReplyMarkup = mainKeyboard
				} else if txt == "🎫 Создать инвайт" || txt == "/invite" {
					b := make([]byte, 4); rand.Read(b); code := "INV-" + strings.ToUpper(hex.EncodeToString(b))
					db.Exec("INSERT INTO invites (code) VALUES (?)", code)
					msg.Text = fmt.Sprintf("✅ Инвайт: <code>%s</code>\n🔗 Перешли юзеру:\nhttps://t.me/%s?start=%s", code, bot.Self.UserName, code)
					msg.ParseMode = "HTML"
				} else if txt == "👥 Юзеры и Трафик" || txt == "/users" {
					rows, _ := db.Query("SELECT name, traffic_up, traffic_down FROM users")
					res := "📊 *Статистика:*\n\n"
					for rows.Next() { 
						var n string; var u, d int64; rows.Scan(&n, &u, &d)
						res += fmt.Sprintf("👤 *%s*\n 🔽 %.2f GB | 🔼 %.2f GB\n\n", n, float64(d)/1073741824, float64(u)/1073741824) 
					}
					msg.Text = res
					msg.ParseMode = "Markdown"
				} else if txt == "📊 Статус кластера" {
					var bC, eC int
					db.QueryRow("SELECT COUNT(*) FROM bridges WHERE last_seen > datetime('now', '-5 minute')").Scan(&bC)
					db.QueryRow("SELECT COUNT(*) FROM exits").Scan(&eC)
					var sni, warp string
					db.QueryRow("SELECT val FROM settings WHERE key='sni'").Scan(&sni)
					db.QueryRow("SELECT val FROM settings WHERE key='warp_domains'").Scan(&warp)
					
					msg.Text = fmt.Sprintf("🌐 *Инфраструктура:*\n\n🇷🇺 Активных мостов: *%d*\n🇪🇺 EU-нод: *%d*\n\n🎭 SNI: `%s`\n🚀 WARP: `%s`", bC, eC, sni, warp)
					msg.ParseMode = "Markdown"
				} else if txt == "⚙️ Настройки" {
					msg.Text = "Доступные команды:\n`/sni www.apple.com` - Сменить маскировку\n`/warp geosite:google,domain:chatgpt.com` - Домены WARP"
					msg.ParseMode = "Markdown"
				} else if strings.HasPrefix(txt, "/sni ") {
					newSNI := strings.TrimPrefix(txt, "/sni ")
					db.Exec("UPDATE settings SET val=? WHERE key='sni'", newSNI)
					msg.Text = "✅ SNI изменен."
				} else if strings.HasPrefix(txt, "/warp ") {
					nW := strings.TrimPrefix(txt, "/warp ")
					parts := strings.Split(nW, ",")
					for i, p := range parts { parts[i] = fmt.Sprintf(`"%s"`, strings.TrimSpace(p)) }
					db.Exec("UPDATE settings SET val=? WHERE key='warp_domains'", strings.Join(parts, ","))
					msg.Text = "✅ WARP изменен."
				}
				if msg.Text != "" { bot.Send(msg) }
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
					bot.Send(tgbotapi.NewMessage(chatID, fmt.Sprintf("✅ Профиль создан!\n\n👇 Ссылка для VPN:\nhttps://%s/sub/%s.html", cfg.Domain, uuid)))
				}
			}
		}
	} else { select {} }
}
MASTER_EOF

    # --- AGENT GO CODE ---
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
	masterURL, token, lastHash string
	knownUsers = make(map[string]string)
)

type State struct {
	BridgeUUID  string              `json:"bridge_uuid"`
	SNI         string              `json:"sni"`
	WarpDomains string              `json:"warp_domains"`
	Users[]map[string]string `json:"users"`
	Exits       []map[string]string `json:"exits"`
}

func syncWithMaster() {
	req, _ := http.NewRequest("GET", masterURL+"/api/sync", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil || resp.StatusCode != 200 { return }
	defer resp.Body.Close()

	var state State
	json.NewDecoder(resp.Body).Decode(&state)

	eJSON, _ := json.Marshal(state.Exits)
	cHash := fmt.Sprintf("%x", sha256.Sum256([]byte(string(eJSON)+state.SNI+state.WarpDomains)))
	
	if cHash != lastHash {
		buildAndRestartXray(state)
		lastHash = cHash
		knownUsers = make(map[string]string)
		for _, u := range state.Users { knownUsers[u["uuid"]] = u["email"] }
		return
	}

	newKnown := make(map[string]string)
	for _, u := range state.Users {
		newKnown[u["uuid"]] = u["email"]
		if _, ok := knownUsers[u["uuid"]]; !ok { alterUserXray(u["uuid"], u["email"], false) }
	}
	for uuid, email := range knownUsers {
		if _, ok := newKnown[uuid]; !ok { alterUserXray(uuid, email, true) }
	}
	knownUsers = newKnown
}

func buildAndRestartXray(state State) {
	keys, _ := ioutil.ReadFile("/usr/local/etc/xray/agent_keys.txt")
	p := strings.Split(strings.TrimSpace(string(keys)), "|")
	if len(p) != 2 { return }
	pk, sid := p[0], p[1]

	var clientArr[]string
	for _, u := range state.Users {
		clientArr = append(clientArr, fmt.Sprintf(`{"id":"%s","email":"%s","flow":"xtls-rprx-vision"}`, u["uuid"], u["email"]))
	}
	clientsJSON := "[" + strings.Join(clientArr, ",") + "]"

	var outbounds, balancers[]string
	for _, e := range state.Exits {
		ip, pub, ss, xp := e["ip"], e["pub_key"], e["ss_pass"], e["xhttp_path"]
		outbounds = append(outbounds, fmt.Sprintf(`{"tag":"eu-tcp-%s","protocol":"vless","settings":{"vnext":[{"address":"%s","port":443,"users":[{"id":"%s","flow":"xtls-rprx-vision","encryption":"none"}]}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"serverName":"%s","publicKey":"%s","fingerprint":"chrome"}}}`, ip, ip, state.BridgeUUID, state.SNI, pub))
		outbounds = append(outbounds, fmt.Sprintf(`{"tag":"eu-xh-%s","protocol":"vless","settings":{"vnext":[{"address":"%s","port":4433,"users":[{"id":"%s","encryption":"none"}]}]},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/%s","mode":"auto"},"realitySettings":{"serverName":"%s","publicKey":"%s","fingerprint":"chrome"}}}`, ip, ip, state.BridgeUUID, xp, state.SNI, pub))
		outbounds = append(outbounds, fmt.Sprintf(`{"tag":"eu-ss-%s","protocol":"shadowsocks","settings":{"servers":[{"address":"%s","port":5000,"method":"2022-blake3-aes-128-gcm","password":"%s"}]}}`, ip, ip, ss))
		balancers = append(balancers, fmt.Sprintf(`"eu-tcp-%s"`, ip), fmt.Sprintf(`"eu-xh-%s"`, ip), fmt.Sprintf(`"eu-ss-%s"`, ip))
	}
	
	oStr := "[]"; if len(outbounds)>0 { oStr = "["+strings.Join(outbounds, ",")+"]" }
	sStr := "\"block\""; if len(balancers)>0 { sStr = strings.Join(balancers, ",") }

	cfg := fmt.Sprintf(`{"log":{"loglevel":"warning"},"api":{"tag":"api","services":["HandlerService","StatsService"]},"stats":{},"policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}}},"inbounds":[{"tag":"api-in","port":10085,"listen":"127.0.0.1","protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}},{"tag":"client-in","port":443,"protocol":"vless","settings":{"clients":%s,"decryption":"none","fallbacks":[{"dest":80}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"%s:443","serverNames":["%s"],"privateKey":"%s","shortIds":["%s"]}}},{"tag":"client-xh","port":8001,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":%s,"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"/xtcp","mode":"auto"}}}],"outbounds":[%s,{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"observatory":{"subjectSelector":[%s],"probeUrl":"https://www.google.com/generate_204","probeInterval":"1m","enableConcurrency":true},"routing":{"domainStrategy":"IPIfNonMatch","balancers":[{"tag":"eu-balancer","selector":[%s],"strategy":{"type":"leastPing"}}],"rules":[{"type":"field","inboundTag":["api-in"],"outboundTag":"api"},{"type":"field","inboundTag":["client-in","client-xh"],"balancerTag":"eu-balancer"},{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}}`, clientsJSON, state.SNI, state.SNI, pk, sid, clientsJSON, strings.Trim(oStr, "[]"), sStr, sStr)

	ioutil.WriteFile("/usr/local/etc/xray/config.json",[]byte(cfg), 0644)
	exec.Command("systemctl", "restart", "xray").Run()
}

func alterUserXray(uuid, email string, remove bool) {
	conn, err := grpc.Dial("127.0.0.1:10085", grpc.WithTransportCredentials(insecure.NewCredentials())); if err != nil { return }
	defer conn.Close()
	c := proxyman.NewHandlerServiceClient(conn)
	if remove {
		c.AlterInbound(context.Background(), &proxyman.AlterInboundRequest{Tag: "client-in", Operation: serial.ToTypedMessage(&proxyman.RemoveUserOperation{Email: email})})
		c.AlterInbound(context.Background(), &proxyman.AlterInboundRequest{Tag: "client-xh", Operation: serial.ToTypedMessage(&proxyman.RemoveUserOperation{Email: email})})
	} else {
		c.AlterInbound(context.Background(), &proxyman.AlterInboundRequest{Tag: "client-in", Operation: serial.ToTypedMessage(&proxyman.AddUserOperation{User: &protocol.User{Level: 0, Email: email, Account: serial.ToTypedMessage(&vless.Account{Id: uuid, Flow: "xtls-rprx-vision"})}})})
		c.AlterInbound(context.Background(), &proxyman.AlterInboundRequest{Tag: "client-xh", Operation: serial.ToTypedMessage(&proxyman.AddUserOperation{User: &protocol.User{Level: 0, Email: email, Account: serial.ToTypedMessage(&vless.Account{Id: uuid})}})})
	}
}

func sendStats() {
	conn, err := grpc.Dial("127.0.0.1:10085", grpc.WithTransportCredentials(insecure.NewCredentials())); if err != nil { return }
	defer conn.Close()
	resp, err := stats.NewStatsServiceClient(conn).QueryStats(context.Background(), &stats.QueryStatsRequest{Pattern: "user>>>", Reset_: true})
	if err != nil { return }

	aggr := make(map[string]map[string]int64)
	for _, s := range resp.Stat {
		p := strings.Split(s.Name, ">>>")
		if len(p) == 4 {
			e, t, v := p[1], p[3], s.Value
			if aggr[e] == nil { aggr[e] = make(map[string]int64) }
			if t == "downlink" { aggr[e]["down"] += v } else { aggr[e]["up"] += v }
		}
	}
	var pl []map[string]interface{}
	for e, d := range aggr { pl = append(pl, map[string]interface{}{"email": e, "up": d["up"], "down": d["down"]}) }
	if len(pl) > 0 {
		b, _ := json.Marshal(pl)
		req, _ := http.NewRequest("POST", masterURL+"/api/stats", bytes.NewBuffer(b))
		req.Header.Set("Authorization", "Bearer "+token)
		http.DefaultClient.Do(req)
	}
}

func main() {
	flag.StringVar(&masterURL, "master", "", ""); flag.StringVar(&token, "token", "", ""); flag.Parse()
	for { syncWithMaster(); sendStats(); time.Sleep(30 * time.Second) }
}
AGENT_EOF

    echo "⏳ Компиляция Мастера и Агента..."
    go mod init vpn-core
    go get github.com/go-telegram-bot-api/telegram-bot-api/v5 modernc.org/sqlite
    go get github.com/xtls/xray-core@latest
    
    go build -ldflags="-s -w" -o /usr/local/bin/vpn-master master.go
    
    mkdir -p /etc/orchestrator/bin
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /etc/orchestrator/bin/agent agent.go

    cat <<EOF > /etc/systemd/system/vpn-master.service[Unit]
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
}

# ==============================================================================
# 2. РАЗВЕРТЫВАНИЕ УЗЛОВ (PUSH VIA SSH KEY)
# ==============================================================================
deploy_node() {
    TYPE=$1
    if [ "$TYPE" == "ru" ]; then
        echo -e "\n🌉 ДОБАВЛЕНИЕ RU-МОСТА (Ingress)"
        echo "💡 Введи 127.0.0.1 для установки моста на этот же сервер."
        read -p "IP адрес сервера: " IP
        read -p "Домен для моста (bridge.vpn.com): " DOMAIN
    else
        echo -e "\n🇪🇺 ДОБАВЛЕНИЕ EU-НОДЫ (Egress + WARP)"
        read -p "IP адрес сервера: " IP
    fi

    # Локальная установка
    if[ "$IP" == "127.0.0.1" ]; then
        CMD_PREFIX="bash -s"
    else
        read -s -p "Root пароль от $IP: " PASS; echo ""
        echo "⏳ Копирование SSH-ключа на удаленный сервер..."
        sshpass -p "$PASS" ssh-copy-id -i /root/.ssh/vpn_cluster_key.pub -o StrictHostKeyChecking=no root@$IP >/dev/null 2>&1
        CMD_PREFIX="ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP bash -s"
    fi

    M_IP=$(curl -s4 ifconfig.me)
    C_TOK=$(grep CLUSTER_TOKEN /etc/orchestrator/config.env | cut -d'"' -f2)
    B_UUID=$(grep BRIDGE_UUID /etc/orchestrator/config.env | cut -d'"' -f2)
    M_DOM=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)

    echo "⏳ Запуск автоматической настройки сервера..."
    
    RAW_OUT=$($CMD_PREFIX "$M_IP" "$C_TOK" "$B_UUID" "$M_DOM" "$TYPE" "$DOMAIN" << 'EOF'
        MASTER_IP=$1; TOKEN=$2; BRIDGE_UUID=$3; MASTER_DOM=$4; TYPE=$5; DOMAIN=$6
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl jq openssl ufw >/dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        KEYS=$(xray x25519)
        PK=$(echo "$KEYS" | grep Private | awk '{print $3}')
        PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')
        
        if [ "$TYPE" == "ru" ]; then
            SID=$(openssl rand -hex 4)
            echo "$PK|$SID" > /usr/local/etc/xray/agent_keys.txt
            
            # Установка агента
            wget -q https://$MASTER_DOM/download/agent -O /usr/local/bin/vpn-agent
            chmod +x /usr/local/bin/vpn-agent
            cat <<SVC > /etc/systemd/system/vpn-agent.service
[Unit]
Description=VPN Agent
[Service]
ExecStart=/usr/local/bin/vpn-agent -master https://$MASTER_DOM -token $TOKEN
Restart=always
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload && systemctl enable vpn-agent && systemctl restart vpn-agent
            ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
            
            # Отдаем Мастеру данные для записи в БД
            echo "NODE_DATA|ru|$PUB|$SID"
            
        elif [ "$TYPE" == "eu" ]; then
            # Установка WARP
            apt-get install -yq gpg lsb-release >/dev/null 2>&1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb[arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
            apt-get update -q >/dev/null 2>&1
            apt-get install -yq cloudflare-warp >/dev/null 2>&1
            warp-cli --accept-tos registration new >/dev/null 2>&1
            warp-cli --accept-tos mode proxy >/dev/null 2>&1
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
            warp-cli --accept-tos connect >/dev/null 2>&1
            
            SS_PASS=$(openssl rand -base64 16)
            XP=$(openssl rand -hex 6)
            
            cat <<XCFG > /usr/local/etc/xray/config.json
{"log":{"loglevel":"warning"},"inbounds":[{"port":5000,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":"$SS_PASS","network":"tcp,udp"}},{"port":443,"protocol":"vless","settings":{"clients":[{"id":"$BRIDGE_UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"$PK","shortIds":[""]}}},{"port":4433,"protocol":"vless","settings":{"clients":[{"id":"$BRIDGE_UUID"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/$XP","mode":"auto"},"realitySettings":{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"$PK","shortIds":[""]}}}],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}},{"protocol":"blackhole","tag":"block"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","domain":["geosite:google","geosite:openai","geosite:netflix"],"outboundTag":"warp"},{"type":"field","ip":["geoip:private"],"outboundTag":"block"}]}}
XCFG
            systemctl restart xray
            ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
            
            echo "NODE_DATA|eu|$PUB|$SS_PASS|$XP"
        fi
        
        # Hardening: Отключаем парольный вход (Только по ключам)
        sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
EOF
)

    # Разбираем вывод от удаленного скрипта
    DATA=$(echo "$RAW_OUT" | grep "NODE_DATA")
    
    if[ -z "$DATA" ]; then
        echo "❌ Ошибка деплоя. Лог: $RAW_OUT"
        return
    fi

    T=$(echo "$DATA" | cut -d'|' -f2)
    PUB=$(echo "$DATA" | cut -d'|' -f3)

    if[ "$T" == "ru" ]; then
        SID=$(echo "$DATA" | cut -d'|' -f4)
        sqlite3 /etc/orchestrator/core.db "INSERT OR REPLACE INTO bridges (ip, domain, pub_key, sid, last_seen) VALUES ('$IP', '$DOMAIN', '$PUB', '$SID', CURRENT_TIMESTAMP)"
        echo "✅ RU-Мост успешно развернут и защищен SSH-ключом!"
    elif [ "$T" == "eu" ]; then
        SS=$(echo "$DATA" | cut -d'|' -f4)
        XP=$(echo "$DATA" | cut -d'|' -f5)
        sqlite3 /etc/orchestrator/core.db "INSERT OR REPLACE INTO exits (ip, pub_key, ss_pass, xhttp_path) VALUES ('$IP', '$PUB', '$SS', '$XP')"
        echo "✅ EU-Нода успешно развернута и защищена SSH-ключом! Агенты подхватят её через 30 секунд."
    fi
}

# ==============================================================================
# 3. UTILITIES
# ==============================================================================
harden_system() {
    echo "🛡️ УСИЛЕНИЕ БЕЗОПАСНОСТИ МАСТЕРА"
    if free | awk '/^Swap:/ {exit !$2}'; then echo "✅ SWAP уже есть!"; else
        fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile; swapon /swapfile
        echo "/swapfile none swap sw 0 0" >> /etc/fstab; echo "✅ SWAP создан!"
    fi
    apt-get install -yq fail2ban >/dev/null 2>&1
    echo -e "[sshd]\nenabled=true\nport=1:65535\nmaxretry=5\nbantime=24h" > /etc/fail2ban/jail.local
    systemctl restart fail2ban; echo "✅ Fail2Ban включен."
    
    TG_TOKEN=$(grep "TG_TOKEN" /etc/orchestrator/config.env | cut -d'"' -f2)
    TG_CHAT=$(grep "TG_CHAT_ID" /etc/orchestrator/config.env | cut -d'"' -f2)
    cat <<EOF > /etc/profile.d/tg_ssh_notify.sh
#!/bin/bash
if[ -n "\$SSH_CLIENT" ]; then
    IP=\$(echo "\$SSH_CLIENT" | awk '{print \$1}')
    curl -s -X POST "https://api.telegram.org/bot$TG_TOKEN/sendMessage" -d chat_id="$TG_CHAT" -d text="🚨 Вход по SSH на \$(hostname) с IP \$IP" >/dev/null 2>&1 &
fi
EOF
    chmod +x /etc/profile.d/tg_ssh_notify.sh
    echo "✅ SSH-алерты включены!"
}

create_backup() {
    TG_TOKEN=$(grep "TG_TOKEN" /etc/orchestrator/config.env | cut -d'"' -f2)
    TG_CHAT=$(grep "TG_CHAT_ID" /etc/orchestrator/config.env | cut -d'"' -f2)
    
    # Архивация БД, конфигов и SSH КЛЮЧЕЙ
    tar -czf /tmp/backup.tar.gz /etc/orchestrator/core.db /etc/orchestrator/config.env /root/.ssh/vpn_cluster_key /root/.ssh/vpn_cluster_key.pub 2>/dev/null
    curl -s -F chat_id="$TG_CHAT" -F document=@"/tmp/backup.tar.gz" -F caption="📦 Full Backup $(date +%F)" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" >/dev/null
    rm -f /tmp/backup.tar.gz
    echo "✅ Полный бекап с SSH-ключами отправлен в Telegram!"
}

# ==============================================================================
# MENU
# ==============================================================================
while true; do
    clear
    echo "🧠 VPN CLOUD NATIVE v12.0 (Ansible-way)"
    echo "---------------------------------------"
    if [ ! -f /usr/local/bin/vpn-master ]; then
        echo "1. 🛠 Установить Master API"
    else
        echo "2. 🌉 Добавить RU-Мост (Local / Remote SSH)"
        echo "3. 🇪🇺 Добавить EU-Ноду (Remote SSH)"
    fi
    echo "---------------------------------------"
    echo "4. 🛡️ Усилить безопасность Мастера (SWAP, Alerts)"
    echo "5. 📦 Сделать полный бекап в Telegram"
    echo "0. Выход"
    echo "---------------------------------------"
    read -p "Выбор: " C
    case $C in
        1) install_master ; read -p "Enter..." ;;
        2) deploy_node "ru" ; read -p "Enter..." ;;
        3) deploy_node "eu" ; read -p "Enter..." ;;
        4) harden_system ; read -p "Enter..." ;;
        5) create_backup ; read -p "Enter..." ;;
        0) exit 0 ;;
    esac
done
