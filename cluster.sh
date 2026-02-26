#!/bin/bash
# ==============================================================================
# 🚀 VPN CLOUD NATIVE v13.0 (Master API + Agents + TLS/Nextcloud Fake + Deletion)
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
	db.Exec(`CREATE TABLE IF NOT EXISTS bridges (ip TEXT PRIMARY KEY, domain TEXT, pub_key TEXT, sid TEXT, mode TEXT, last_seen DATETIME)`)
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
	
	exits := []map[string]string{}
	eRows, _ := db.Query("SELECT ip, pub_key, ss_pass, xhttp_path FROM exits")
	for eRows.Next() { var ip, pk, ss, xp string; eRows.Scan(&ip, &pk, &ss, &xp); exits = append(exits, map[string]string{"ip": ip, "pub_key": pk, "ss_pass": ss, "xhttp_path": xp}) }

	json.NewEncoder(w).Encode(map[string]interface{}{"bridge_uuid": cfg.BridgeUUID, "sni": sni, "warp_domains": warp, "users": users, "exits": exits})
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	var stats []map[string]interface{}
	json.NewDecoder(r.Body).Decode(&stats)
	for _, s := range stats {
		db.Exec("UPDATE users SET traffic_up=traffic_up+?, traffic_down=traffic_down+? WHERE name=?", int64(s["up"].(float64)), int64(s["down"].(float64)), s["email"].(string))
	}
	w.WriteHeader(200)
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	typ, ip, pk := r.URL.Query().Get("type"), r.URL.Query().Get("ip"), r.URL.Query().Get("pk")
	if typ == "eu" {
		db.Exec("INSERT OR REPLACE INTO exits (ip, pub_key, ss_pass, xhttp_path) VALUES (?, ?, ?, ?)", ip, pk, r.URL.Query().Get("ss"), r.URL.Query().Get("xp"))
	} else if typ == "ru" {
		mode := r.URL.Query().Get("mode")
		if mode == "" { mode = "reality" }
		db.Exec("INSERT OR REPLACE INTO bridges (ip, domain, pub_key, sid, mode, last_seen) VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)", ip, r.URL.Query().Get("domain"), pk, r.URL.Query().Get("sid"), mode)
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
	bRows, _ := db.Query("SELECT ip, domain, pub_key, sid, mode FROM bridges")
	for bRows.Next() {
		var dIP, d, pk, sid, mode string; bRows.Scan(&dIP, &d, &pk, &sid, &mode)
		if mode == "tls" {
			links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TLS-%s]", uuid, d, d, name, d))
		} else {
            port := "443"
            if dIP == cfg.MasterIP || dIP == "127.0.0.1" { port = "4433" } // Локальный мост на 4433
			links = append(links, fmt.Sprintf("vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TCP-%s]", uuid, dIP, port, pk, sid, sni, name, d))
			links = append(links, fmt.Sprintf("vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=xhttp&path=%%2Fxtcp&sni=%s#%s-[xHTTP-%s]", uuid, dIP, port, pk, sid, sni, name, d))
		}
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
	http.HandleFunc("/api/register", authMw(handleRegister))
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
					msg.Text = "🧠 Master API v13.0"
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
	Users       []map[string]string `json:"users"`
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
	
	mode := "reality"
	pk, sid, tlsDomain := "", "", ""
	if len(p) >= 2 && p[0] == "tls" {
		mode = "tls"
		tlsDomain = p[1]
	} else if len(p) >= 2 {
		pk = p[0]
		sid = p[1]
	}

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

	inboundsJSON := ""
	if mode == "tls" {
		inboundsJSON = fmt.Sprintf(`[{"tag":"api-in","port":10085,"listen":"127.0.0.1","protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}},{"tag":"client-in","port":443,"protocol":"vless","settings":{"clients":%s,"decryption":"none","fallbacks":[{"dest":8080}]},"streamSettings":{"network":"tcp","security":"tls","tlsSettings":{"alpn":["http/1.1"],"certificates":[{"certificateFile":"/etc/letsencrypt/live/%s/fullchain.pem","keyFile":"/etc/letsencrypt/live/%s/privkey.pem"}]}}}]`, clientsJSON, tlsDomain, tlsDomain)
	} else {
		inboundsJSON = fmt.Sprintf(`[{"tag":"api-in","port":10085,"listen":"127.0.0.1","protocol":"dokodemo-door","settings":{"address":"127.0.0.1"}},{"tag":"client-in","port":443,"protocol":"vless","settings":{"clients":%s,"decryption":"none","fallbacks":[{"dest":80}]},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"show":false,"dest":"%s:443","serverNames":["%s"],"privateKey":"%s","shortIds":["%s"]}}},{"tag":"client-xh","port":8001,"listen":"127.0.0.1","protocol":"vless","settings":{"clients":%s,"decryption":"none"},"streamSettings":{"network":"xhttp","security":"none","xhttpSettings":{"path":"/xtcp","mode":"auto"}}}]`, clientsJSON, state.SNI, state.SNI, pk, sid, clientsJSON)
	}

	cfg := fmt.Sprintf(`{"log":{"loglevel":"warning"},"api":{"tag":"api","services":["HandlerService","StatsService"]},"stats":{},"policy":{"levels":{"0":{"statsUserUplink":true,"statsUserDownlink":true}}},"inbounds":%s,"outbounds":[%s,{"tag":"direct","protocol":"freedom"},{"tag":"block","protocol":"blackhole"}],"observatory":{"subjectSelector":[%s],"probeUrl":"https://www.google.com/generate_204","probeInterval":"1m","enableConcurrency":true},"routing":{"domainStrategy":"IPIfNonMatch","balancers":[{"tag":"eu-balancer","selector":[%s],"strategy":{"type":"leastPing"}}],"rules":[{"type":"field","inboundTag":["api-in"],"outboundTag":"api"},{"type":"field","inboundTag":["client-in","client-xh"],"balancerTag":"eu-balancer"},{"type":"field","ip":["geoip:private"],"outboundTag":"direct"}]}}`, inboundsJSON, strings.Trim(oStr, "[]"), sStr, sStr)

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

    cat <<EOF > /etc/systemd/system/vpn-master.service
[Unit]
Description=VPN Master API
[Service]
ExecStart=/usr/local/bin/vpn-master
Restart=always
WorkingDirectory=/etc/orchestrator[Install]
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
    RU_MODE="1" # По умолчанию Reality
    
    if [ "$TYPE" == "ru_remote" ]; then
        echo -e "\n🌉 ДОБАВЛЕНИЕ УДАЛЕННОГО RU-МОСТА"
        read -p "IP адрес сервера: " IP
        read -s -p "Root пароль от $IP: " PASS; echo ""
        
        echo "1) REALITY (Маскировка под чужой сайт, домен не нужен)"
        echo "2) Classic TLS (Требуется домен, ставится заглушка Nextcloud)"
        read -p "Режим работы: " RU_MODE
        
        if [ "$RU_MODE" == "2" ]; then
            read -p "Введи домен для моста: " DOMAIN
            read -p "Email для SSL (Let's Encrypt): " EMAIL
        else
            read -p "Домен для моста (просто название для ссылки): " DOMAIN
        fi
        
        echo "⏳ Копирование SSH-ключа на удаленный сервер..."
        sshpass -p "$PASS" ssh-copy-id -i /root/.ssh/vpn_cluster_key.pub -o StrictHostKeyChecking=no root@$IP >/dev/null 2>&1
        CMD_PREFIX="ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP bash -s"
        
    elif[ "$TYPE" == "ru_local" ]; then
        echo -e "\n🏠 ДОБАВЛЕНИЕ ЛОКАЛЬНОГО RU-МОСТА (На этом сервере)"
        echo "Внимание: Локальный мост будет работать только в режиме REALITY на порту 4433."
        DOMAIN=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)
        IP="127.0.0.1"
        CMD_PREFIX="bash -s"
        
    elif[ "$TYPE" == "eu" ]; then
        echo -e "\n🇪🇺 ДОБАВЛЕНИЕ EU-НОДЫ (+WARP)"
        read -p "IP адрес сервера: " IP
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
    
    RAW_OUT=$($CMD_PREFIX "$M_IP" "$C_TOK" "$B_UUID" "$M_DOM" "$TYPE" "$DOMAIN" "$RU_MODE" "$EMAIL" << 'EOF'
        MASTER_IP=$1; TOKEN=$2; BRIDGE_UUID=$3; MASTER_DOM=$4; TYPE=$5; DOMAIN=$6; RU_MODE=$7; EMAIL=$8
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl jq openssl ufw >/dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        if [[ "$TYPE" == "ru_remote" || "$TYPE" == "ru_local" ]]; then
            
            if [ "$RU_MODE" == "2" ]; then
                # Classic TLS mode setup
                apt-get install -yq nginx certbot python3-certbot-nginx >/dev/null 2>&1
                certbot certonly --standalone -d $DOMAIN -m $EMAIL --agree-tos -n >/dev/null 2>&1
                
                cat << 'HTML_EOF' > /var/www/html/index.html
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>Nextcloud</title><style>body{background-color:#0082c9;background-image:linear-gradient(40deg,#0082c9 0%,#004c8c 100%);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Oxygen-Sans,Ubuntu,Cantarell,"Helvetica Neue",sans-serif;color:#fff;height:100vh;margin:0;display:flex;align-items:center;justify-content:center;overflow:hidden}.nc-container{text-align:center;width:100%;max-width:320px;padding:20px}.nc-logo{margin-bottom:30px;display:inline-block}.nc-logo svg{width:110px;fill:#fff}.nc-form{background:#fff;border-radius:8px;padding:40px 30px;box-shadow:0 4px 10px rgba(0,0,0,0.1)}.input-group{margin-bottom:20px}input[type="text"],input[type="password"]{width:100%;padding:12px;border:1px solid #ddd;border-radius:4px;box-sizing:border-box;font-size:15px;color:#333;outline:none;transition:border-color 0.2s}input[type="text"]:focus,input[type="password"]:focus{border-color:#0082c9}.btn{background:#0082c9;color:#fff;border:none;border-radius:4px;padding:12px;width:100%;font-size:16px;cursor:pointer;font-weight:600;transition:background 0.2s}.btn:hover{background:#006098}.msg{color:#e9322d;font-size:14px;margin-bottom:15px;display:none;text-align:left}.footer{margin-top:40px;font-size:13px;color:rgba(255,255,255,0.7)}.footer a{color:rgba(255,255,255,0.8);text-decoration:none;font-weight:bold}.footer a:hover{text-decoration:underline}</style></head><body><div class="nc-container"><div class="nc-logo"><svg viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg"><circle cx="50" cy="50" r="35" fill="none" stroke="#fff" stroke-width="8"/><circle cx="28" cy="50" r="16" fill="#fff"/><circle cx="72" cy="50" r="16" fill="#fff"/><circle cx="50" cy="28" r="16" fill="#fff"/></svg></div><div class="nc-form"><div class="msg" id="error-msg">Wrong username or password.</div><form onsubmit="event.preventDefault(); document.getElementById('error-msg').style.display='block'; setTimeout(()=> { document.querySelectorAll('input').forEach(i=>i.value=''); document.getElementById('error-msg').style.display='none'; }, 2000);"><div class="input-group"><input type="text" placeholder="Username or email" required></div><div class="input-group"><input type="password" placeholder="Password" required></div><button type="submit" class="btn">Log in</button></form></div><div class="footer"><a href="#">Nextcloud</a> – a safe home for all your data</div></div></body></html>
HTML_EOF
                
                cat << 'NGINX_EOF' > /etc/nginx/sites-available/default
server { listen 8080 default_server; root /var/www/html; index index.html; }
NGINX_EOF
                systemctl restart nginx
                echo "tls|$DOMAIN" > /usr/local/etc/xray/agent_keys.txt
                
                curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=ru&ip=$(curl -s4 ifconfig.me)&domain=$DOMAIN&mode=tls" >/dev/null
                echo "NODE_DATA|ru|tls"
                
            else
                # Reality mode setup
                KEYS=$(xray x25519)
                PK=$(echo "$KEYS" | grep Private | awk '{print $3}')
                PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')
                SID=$(openssl rand -hex 4)
                echo "$PK|$SID" > /usr/local/etc/xray/agent_keys.txt
                
                IP=$(curl -s4 ifconfig.me)
                if[ "$TYPE" == "ru_local" ]; then IP="127.0.0.1"; fi
                
                curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=ru&ip=$IP&domain=$DOMAIN&pk=$PUB&sid=$SID&mode=reality" >/dev/null
                echo "NODE_DATA|ru|reality"
            fi
            
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
            ufw allow 443/tcp >/dev/null 2>&1
            ufw allow 4433/tcp >/dev/null 2>&1
            ufw --force enable >/dev/null 2>&1
            
        elif[ "$TYPE" == "eu" ]; then
            apt-get install -yq gpg lsb-release >/dev/null 2>&1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb[arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
            apt-get update -q >/dev/null 2>&1
            apt-get install -yq cloudflare-warp >/dev/null 2>&1
            warp-cli --accept-tos registration new >/dev/null 2>&1
            warp-cli --accept-tos mode proxy >/dev/null 2>&1
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
            warp-cli --accept-tos connect >/dev/null 2>&1
            
            KEYS=$(xray x25519)
            PK=$(echo "$KEYS" | grep Private | awk '{print $3}')
            PUB=$(echo "$KEYS" | grep Public | awk '{print $3}')
            SS_PASS=$(openssl rand -base64 16)
            XP=$(openssl rand -hex 6)
            
            cat <<XCFG > /usr/local/etc/xray/config.json
{"log":{"loglevel":"warning"},"inbounds":[{"port":5000,"protocol":"shadowsocks","settings":{"method":"2022-blake3-aes-128-gcm","password":"$SS_PASS","network":"tcp,udp"}},{"port":443,"protocol":"vless","settings":{"clients":[{"id":"$BRIDGE_UUID","flow":"xtls-rprx-vision"}],"decryption":"none"},"streamSettings":{"network":"tcp","security":"reality","realitySettings":{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"$PK","shortIds":[""]}}},{"port":4433,"protocol":"vless","settings":{"clients":[{"id":"$BRIDGE_UUID"}],"decryption":"none"},"streamSettings":{"network":"xhttp","security":"reality","xhttpSettings":{"path":"/$XP","mode":"auto"},"realitySettings":{"dest":"www.microsoft.com:443","serverNames":["www.microsoft.com"],"privateKey":"$PK","shortIds":[""]}}}],"outbounds":[{"protocol":"freedom","tag":"direct"},{"protocol":"socks","tag":"warp","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}},{"protocol":"blackhole","tag":"block"}],"routing":{"domainStrategy":"IPIfNonMatch","rules":[{"type":"field","domain":["geosite:google","geosite:openai","geosite:netflix"],"outboundTag":"warp"},{"type":"field","ip":["geoip:private"],"outboundTag":"block"}]}}
XCFG
            systemctl restart xray
            ufw allow 443/tcp >/dev/null 2>&1; ufw --force enable >/dev/null 2>&1
            
            curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=eu&ip=$(curl -s4 ifconfig.me)&pk=$PUB&ss=$SS_PASS&xp=$XP" >/dev/null
            echo "NODE_DATA|eu"
        fi
        
        if [ "$TYPE" != "ru_local" ]; then
            sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
            systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
        fi
EOF
)

    DATA=$(echo "$RAW_OUT" | grep "NODE_DATA")
    if [ -z "$DATA" ]; then
        echo "❌ Ошибка деплоя. Лог: $RAW_OUT"
    else
        echo "✅ Узел успешно развернут и защищен! Мастер подхватит его через 30 секунд."
    fi
}

# ==============================================================================
# 3. УДАЛЕНИЕ УЗЛОВ
# ==============================================================================
delete_node() {
    echo -e "\n🗑️ УДАЛЕНИЕ СЕРВЕРОВ ИЗ КЛАСТЕРА"
    echo "1) Удалить RU Мост"
    echo "2) Удалить EU Ноду"
    echo "0) Отмена"
    read -p "Выбор: " DEL_C
    
    if [ "$DEL_C" == "1" ]; then
        echo "Активные RU мосты:"
        sqlite3 /etc/orchestrator/core.db "SELECT ip, domain, mode FROM bridges"
        read -p "Введи IP моста для удаления: " DEL_IP
        sqlite3 /etc/orchestrator/core.db "DELETE FROM bridges WHERE ip='$DEL_IP'"
        echo "✅ Мост удален из БД. Агенты обновят маршруты."
    elif [ "$DEL_C" == "2" ]; then
        echo "Активные EU ноды:"
        sqlite3 /etc/orchestrator/core.db "SELECT ip FROM exits"
        read -p "Введи IP ноды для удаления: " DEL_IP
        sqlite3 /etc/orchestrator/core.db "DELETE FROM exits WHERE ip='$DEL_IP'"
        echo "✅ EU нода удалена из БД. Агенты исключат её из балансировщика."
    fi
}

# ==============================================================================
# MENU
# ==============================================================================
while true; do
    clear
    echo "🧠 VPN CLOUD NATIVE v13.0 (Ansible-way)"
    echo "---------------------------------------"
    if [ ! -f /usr/local/bin/vpn-master ]; then
        echo "1. 🛠 Установить Master API"
    else
        echo "2. 🏠 Добавить Локальный RU-Мост (127.0.0.1)"
        echo "3. 🌉 Добавить Удаленный RU-Мост (SSH)"
        echo "4. 🇪🇺 Добавить EU-Ноду (SSH)"
        echo "5. 🗑️ Удалить узел (RU/EU)"
    fi
    echo "---------------------------------------"
    echo "0. Выход"
    echo "---------------------------------------"
    read -p "Выбор: " C
    case $C in
        1) install_master ; read -p "Enter..." ;;
        2) deploy_node "ru_local" ; read -p "Enter..." ;;
        3) deploy_node "ru_remote" ; read -p "Enter..." ;;
        4) deploy_node "eu" ; read -p "Enter..." ;;
        5) delete_node ; read -p "Enter..." ;;
        0) exit 0 ;;
    esac
done
