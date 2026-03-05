#!/bin/bash
# ==============================================================================
# 🚀 VPN CLOUD NATIVE v17.0 FINAL (Safe JSON, Limits, Regex, MTProto, Timeouts)
# ==============================================================================

export DEBIAN_FRONTEND=noninteractive
export PATH=$PATH:/usr/local/go/bin
MASTER_IP=$(curl -s4 ifconfig.me)

install_deps() {
    echo "⏳ Проверка и установка пакетов ОС..."
    apt-get update -q >/dev/null 2>&1
    apt-get install -yq jq sqlite3 curl openssl git build-essential nginx certbot python3-certbot-nginx ufw uuid-runtime fail2ban tar sshpass dnsutils iperf3 docker.io >/dev/null 2>&1
    
    if ! command -v go &> /dev/null; then
        echo "⏳ Установка компилятора Go..."
        wget -q https://go.dev/dl/go1.24.0.linux-amd64.tar.gz
        rm -rf /usr/local/go && tar -C /usr/local -xzf go1.24.0.linux-amd64.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "export PATH=\$PATH:/usr/local/go/bin" >> /root/.profile
    fi
}

show_system_status() {
    local CPU=$(top -bn1 | grep load | awk '{printf "%.2f", $(NF-2)}')
    local RAM=$(free -m | awk 'NR==2{printf "%s/%sMB (%.2f%%)", $3,$2,$3*100/$2 }')
    local NGINX_STAT=$(systemctl is-active nginx 2>/dev/null)
    local MASTER_STAT=$(systemctl is-active vpn-master 2>/dev/null)
    
    [[ "$MASTER_STAT" == "active" ]] && MASTER_STAT="🟢 Активен" || MASTER_STAT="🔴 Отключен"
    [[ "$NGINX_STAT" == "active" ]] && NGINX_STAT="🟢 Активен" || NGINX_STAT="🔴 Отключен"

    echo "📊 Сервер: CPU: $CPU | RAM: $RAM"
    echo "⚙️ Службы: Master API: $MASTER_STAT | Nginx: $NGINX_STAT"
    echo "---------------------------------------------------------"
}

manage_mtproto() {
    echo -e "\n✈️ УПРАВЛЕНИЕ MTPROTO PROXY (Telegram)"
    echo "1) 🚀 Установить / Показать ссылку"
    echo "2) 🛑 Удалить прокси"
    echo "0) ↩️ Назад"
    read -p "Выбор: " M_ACT

    if [ "$M_ACT" == "1" ]; then
        echo "⏳ Настройка MTProto Proxy (FakeTLS)..."
        if ! docker ps | grep -q mtproto-vpn; then
            SECRET=$(docker run --rm nineseconds/mtg:2 generate-secret tls -c google.com)
            docker run -d --name mtproto-vpn --restart unless-stopped -p 8443:3128 nineseconds/mtg:2 simple-run -n 1.1.1.1 $SECRET >/dev/null 2>&1
            ufw allow 8443/tcp >/dev/null 2>&1
        else
            SECRET=$(docker inspect mtproto-vpn | grep -o 'simple-run -n 1.1.1.1 .*"' | cut -d' ' -f4 | tr -d '"')
        fi
        MY_IP=$(curl -s4 ifconfig.me)
        echo -e "\n✅ MTProto Прокси активен! Ссылка для подключения:\n"
        echo "tg://proxy?server=$MY_IP&port=8443&secret=$SECRET"
        echo ""
    elif [ "$M_ACT" == "2" ]; then
        docker rm -f mtproto-vpn >/dev/null 2>&1
        ufw delete allow 8443/tcp >/dev/null 2>&1
        echo "✅ MTProto прокси удален."
    fi
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

# ==============================================================================
# 1. КОМПИЛЯЦИЯ И ОБНОВЛЕНИЕ КЛАСТЕРА (Safe JSON)
# ==============================================================================
compile_code() {
    mkdir -p /usr/src/vpn-cluster && cd /usr/src/vpn-cluster

    # =========================================================================
    # MASTER GO CODE
    # =========================================================================
    cat << 'MASTER_EOF' > master.go
package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	_ "modernc.org/sqlite"
)

var db *sql.DB
var cfg struct{ Token, ChatID, Domain, ClusterToken, BridgeUUID, MasterIP string }

func initDB() {
	db, _ = sql.Open("sqlite", "/etc/orchestrator/core.db?_pragma=journal_mode(WAL)")
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, name TEXT, traffic_up INT DEFAULT 0, traffic_down INT DEFAULT 0, expires_at DATETIME DEFAULT (datetime('now', '+30 days')), ip_limit INT DEFAULT 5, chat_id TEXT DEFAULT '')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, ip_limit INT DEFAULT 5)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS bridges (ip TEXT PRIMARY KEY, domain TEXT, pub_key TEXT, sid TEXT, mode TEXT, last_seen DATETIME)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS exits (ip TEXT PRIMARY KEY, pub_key TEXT, ss_pass TEXT, xhttp_path TEXT, sni TEXT DEFAULT '', last_seen DATETIME)`)
	db.Exec(`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, val TEXT)`)
	
	db.Exec(`ALTER TABLE users ADD COLUMN expires_at DATETIME`)
	db.Exec(`UPDATE users SET expires_at=datetime('now', '+30 days') WHERE expires_at IS NULL`)
	
	db.Exec(`ALTER TABLE users ADD COLUMN ip_limit INT DEFAULT 5`)
	db.Exec(`ALTER TABLE invites ADD COLUMN ip_limit INT DEFAULT 5`)
	db.Exec(`ALTER TABLE users ADD COLUMN chat_id TEXT DEFAULT ''`)
	db.Exec(`ALTER TABLE exits ADD COLUMN sni TEXT DEFAULT ''`)
	db.Exec(`ALTER TABLE exits ADD COLUMN last_seen DATETIME`)

	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('sni', 'www.microsoft.com')`)
	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('warp_domains', '"geosite:google","geosite:openai","geosite:netflix","geosite:instagram","geosite:category-ru","domain:ru","domain:рф"')`)
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
	nodeIP := r.Header.Get("X-Real-IP")
	if nodeIP == "" || nodeIP == "::1" { nodeIP = "127.0.0.1" }
	db.Exec("UPDATE bridges SET last_seen=CURRENT_TIMESTAMP WHERE ip=?", nodeIP)
	db.Exec("UPDATE exits SET last_seen=CURRENT_TIMESTAMP WHERE ip=?", nodeIP)

	var sni, warp string
	db.QueryRow("SELECT val FROM settings WHERE key='sni'").Scan(&sni)
	db.QueryRow("SELECT val FROM settings WHERE key='warp_domains'").Scan(&warp)

	users := []map[string]interface{}{}
	uRows, _ := db.Query("SELECT uuid, name, IFNULL(ip_limit, 5) FROM users WHERE expires_at > CURRENT_TIMESTAMP OR expires_at IS NULL")
	for uRows.Next() {
		var u, n string; var lim int; uRows.Scan(&u, &n, &lim)
		users = append(users, map[string]interface{}{"uuid": u, "email": n, "ip_limit": lim})
	}
	uRows.Close()

	exits := []map[string]string{}
	eRows, _ := db.Query("SELECT ip, pub_key, ss_pass, xhttp_path, sni FROM exits")
	for eRows.Next() {
		var ip, pk, ss, xp string; var nodeSNI sql.NullString
		eRows.Scan(&ip, &pk, &ss, &xp, &nodeSNI)
		finalSNI := sni; if nodeSNI.Valid && nodeSNI.String != "" { finalSNI = nodeSNI.String }
		exits = append(exits, map[string]string{"ip": ip, "pub_key": pk, "ss_pass": ss, "xhttp_path": xp, "sni": finalSNI})
	}
	eRows.Close()

	json.NewEncoder(w).Encode(map[string]interface{}{"bridge_uuid": cfg.BridgeUUID, "sni": sni, "warp_domains": warp, "users": users, "exits": exits})
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	var stats []map[string]interface{}
	json.NewDecoder(r.Body).Decode(&stats)
	for _, s := range stats { db.Exec("UPDATE users SET traffic_up=traffic_up+?, traffic_down=traffic_down+? WHERE name=?", int64(s["up"].(float64)), int64(s["down"].(float64)), s["email"].(string)) }
	w.WriteHeader(200)
}

func handleBan(w http.ResponseWriter, r *http.Request) {
	email := r.URL.Query().Get("email")
	if email != "" {
		db.Exec("UPDATE users SET expires_at=datetime('now', '-1 days') WHERE name=?", email)
		if cfg.Token != "" {
			bot, _ := tgbotapi.NewBotAPI(cfg.Token)
			msg := tgbotapi.NewMessageToChannel(cfg.ChatID, fmt.Sprintf("🚨 <b>Сработал Анти-фрод!</b>\nПользователь <code>%s</code> заблокирован за использование с большего числа IP, чем разрешено лимитом.", email))
			msg.ParseMode = "HTML"; bot.Send(msg)
		}
	}
	w.WriteHeader(200)
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	typ, ip, pk := r.URL.Query().Get("type"), r.URL.Query().Get("ip"), r.URL.Query().Get("pk")
	if typ == "eu" { db.Exec("INSERT OR REPLACE INTO exits (ip, pub_key, ss_pass, xhttp_path, last_seen) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)", ip, pk, r.URL.Query().Get("ss"), r.URL.Query().Get("xp"))
	} else if typ == "ru" { mode := r.URL.Query().Get("mode"); if mode == "" { mode = "reality" }; db.Exec("INSERT OR REPLACE INTO bridges (ip, domain, pub_key, sid, mode, last_seen) VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)", ip, r.URL.Query().Get("domain"), pk, r.URL.Query().Get("sid"), mode) }
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
		if mode == "tls" { links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TLS-%s]", uuid, d, d, name, d))
		} else {
			port := "443"; if dIP == cfg.MasterIP || dIP == "127.0.0.1" { port = "4433" }
			links = append(links, fmt.Sprintf("vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TCP-%s]", uuid, dIP, port, pk, sid, sni, name, d))
			links = append(links, fmt.Sprintf("vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=xhttp&path=%%2Fxtcp&sni=%s#%s-[xHTTP-%s]", uuid, dIP, port, pk, sid, sni, name, d))
		}
	}
	bRows.Close()
	if isHTML {
		u := "https://" + cfg.Domain + "/sub/" + uuid
		h := fmt.Sprintf(`<!DOCTYPE html><html><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>VPN Setup</title><script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script><style>body{background:#121212;color:#e0e0e0;font-family:sans-serif;text-align:center;padding:20px}.card{background:#1e1e1e;padding:30px;border-radius:16px;max-width:400px;margin:auto}.btn{display:block;padding:14px;margin-bottom:12px;border-radius:12px;text-decoration:none;font-weight:bold}.btn-ios{background:#007AFF;color:#fff}.btn-android{background:#3DDC84;color:#000}#qr{margin:20px auto;background:#fff;padding:10px;border-radius:8px;display:inline-block}.raw-link{background:#111;padding:10px;border-radius:8px;font-family:monospace;font-size:12px;word-break:break-all}</style></head><body><div class="card"><h2>Привет, %s!</h2><div id="qr"></div><a href="v2raytun://import/%s" class="btn btn-ios">🍏 Подключить iOS / Mac</a><a href="hiddify://install-config?url=%s" class="btn btn-android">🤖 Подключить Android</a><p>Прямая ссылка:</p><div class="raw-link">%s</div></div><script>new QRCode(document.getElementById("qr"), "%s");</script></body></html>`, name, u, u, u, u)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(h))
	} else { w.Header().Set("Content-Type", "text/plain; charset=utf-8"); w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n"))))) }
}

func monitorNodes(bot *tgbotapi.BotAPI) {
	for {
		time.Sleep(2 * time.Minute)
		rows, _ := db.Query("SELECT ip FROM bridges WHERE ip != '127.0.0.1' AND last_seen < datetime('now', '-3 minute') UNION SELECT ip FROM exits WHERE ip != '127.0.0.1' AND last_seen < datetime('now', '-3 minute')")
		for rows.Next() {
			var ip string; rows.Scan(&ip)
			msg := tgbotapi.NewMessageToChannel(cfg.ChatID, fmt.Sprintf("🔴 <b>АЛЕРТ!</b> Узел <code>%s</code> не выходит на связь более 3 минут.", ip))
			msg.ParseMode = "HTML"; bot.Send(msg)
		}
		rows.Close()
	}
}

func main() {
	loadConfig(); initDB()
	http.HandleFunc("/api/sync", authMw(handleSync))
	http.HandleFunc("/api/stats", authMw(handleStats))
	http.HandleFunc("/api/ban", authMw(handleBan))
	http.HandleFunc("/api/register", authMw(handleRegister))
	http.HandleFunc("/sub/", handleSub)
	http.Handle("/download/", http.StripPrefix("/download/", http.FileServer(http.Dir("/etc/orchestrator/bin"))))
	go http.ListenAndServe("127.0.0.1:8080", nil)

	if cfg.Token != "" {
		bot, _ := tgbotapi.NewBotAPI(cfg.Token)
		go monitorNodes(bot)
		
		u := tgbotapi.NewUpdate(0); u.Timeout = 60
		updates := bot.GetUpdatesChan(u)
		
		mainKB := tgbotapi.NewReplyKeyboard(
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📊 Статус"), tgbotapi.NewKeyboardButton("👥 Юзеры")),
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🎫 Инвайты"), tgbotapi.NewKeyboardButton("⚙️ Управление кластером")),
		)

		userKB := tgbotapi.NewReplyKeyboard(
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🌍 Моя ссылка"), tgbotapi.NewKeyboardButton("📊 Мой статус")),
		)

		for update := range updates {
			if update.CallbackQuery != nil {
				data := update.CallbackQuery.Data
				chatID := update.CallbackQuery.Message.Chat.ID
				
				if strings.HasPrefix(data, "del_inv:") {
					code := strings.TrimPrefix(data, "del_inv:")
					db.Exec("DELETE FROM invites WHERE code=?", code)
					bot.Request(tgbotapi.NewCallbackWithAlert(update.CallbackQuery.ID, "✅ Инвайт удален!"))
				} else if strings.HasPrefix(data, "new_inv_") {
					limit := 5
					if data == "new_inv_0" { limit = 0 }
					b := make([]byte, 4); rand.Read(b); code := "INV-" + strings.ToUpper(hex.EncodeToString(b))
					db.Exec("INSERT INTO invites (code, ip_limit) VALUES (?, ?)", code, limit)
					limTxt := "5 устройств"; if limit == 0 { limTxt = "Безлимит" }
					msg := tgbotapi.NewMessage(chatID, fmt.Sprintf("✅ <b>Новый Инвайт (%s):</b> <code>%s</code>\n🔗 Перешли юзеру:\nhttps://t.me/%s?start=%s", limTxt, code, bot.Self.UserName, code))
					msg.ParseMode = "HTML"; bot.Send(msg)
					bot.Request(tgbotapi.NewCallback(update.CallbackQuery.ID, "Создано!"))
				} else if data == "backup" {
					exec.Command("sqlite3", "/etc/orchestrator/core.db", ".backup '/tmp/backup.db'").Run()
					doc := tgbotapi.NewDocument(chatID, tgbotapi.FilePath("/tmp/backup.db"))
					bot.Send(doc); os.Remove("/tmp/backup.db")
					bot.Request(tgbotapi.NewCallback(update.CallbackQuery.ID, "Отправлено!"))
				} else if data == "reboot" {
					bot.Send(tgbotapi.NewMessage(chatID, "⏳ Перезагружаю Xray на всех узлах..."))
					ips, _ := db.Query("SELECT ip FROM bridges UNION SELECT ip FROM exits")
					for ips.Next() {
						var ip string; ips.Scan(&ip)
						if ip != "127.0.0.1" && ip != cfg.MasterIP { exec.Command("ssh", "-i", "/root/.ssh/vpn_cluster_key", "-o", "StrictHostKeyChecking=no", "root@"+ip, "systemctl restart xray").Run() }
					}
					ips.Close()
					bot.Send(tgbotapi.NewMessage(chatID, "✅ Кластер перезагружен."))
					bot.Request(tgbotapi.NewCallback(update.CallbackQuery.ID, "Готово!"))
				} else if strings.HasPrefix(data, "del_usr:") {
					uuid := strings.TrimPrefix(data, "del_usr:")
					db.Exec("DELETE FROM users WHERE uuid=?", uuid)
					bot.Request(tgbotapi.NewDeleteMessage(chatID, update.CallbackQuery.Message.MessageID))
					bot.Send(tgbotapi.NewMessage(chatID, "✅ Пользователь удален. Агенты отключат его через 30с."))
					bot.Request(tgbotapi.NewCallback(update.CallbackQuery.ID, "Удалено!"))
				} else if strings.HasPrefix(data, "add_30d:") {
					uuid := strings.TrimPrefix(data, "add_30d:")
					db.Exec("UPDATE users SET expires_at=datetime(COALESCE(expires_at, 'now'), '+30 days') WHERE uuid=?", uuid)
					bot.Request(tgbotapi.NewCallbackWithAlert(update.CallbackQuery.ID, "✅ Время успешно продлено на 30 дней!"))
				}
				continue
			}

			if update.Message == nil { continue }
			txt := update.Message.Text; chatID := update.Message.Chat.ID
			
			isAdmin := fmt.Sprintf("%d", chatID) == cfg.ChatID
			
			var userUUID, userName string
			err := db.QueryRow("SELECT uuid, name FROM users WHERE chat_id=?", fmt.Sprintf("%d", chatID)).Scan(&userUUID, &userName)
			isUser := (err == nil && userUUID != "")

			// --- ЛОГИКА АДМИНА ---
			if isAdmin {
				msg := tgbotapi.NewMessage(chatID, "")
				if txt == "/start" || txt == "/menu" {
					msg.Text = "🧠 Master API v17.0 Final"; msg.ReplyMarkup = mainKB
				} else if txt == "📊 Статус" {
					var bC, eC int
					db.QueryRow("SELECT COUNT(*) FROM bridges WHERE last_seen > datetime('now', '-5 minute')").Scan(&bC)
					db.QueryRow("SELECT COUNT(*) FROM exits").Scan(&eC)
					var sni, warp string
					db.QueryRow("SELECT val FROM settings WHERE key='sni'").Scan(&sni)
					db.QueryRow("SELECT val FROM settings WHERE key='warp_domains'").Scan(&warp)
					msg.Text = fmt.Sprintf("🌐 <b>Инфраструктура:</b>\n\n🇷🇺 Активных мостов: <b>%d</b>\n🇪🇺 EU-нод: <b>%d</b>\n\n🎭 SNI: <code>%s</code>\n🚀 WARP: <code>%s</code>", bC, eC, sni, warp)
					msg.ParseMode = "HTML"
				} else if txt == "🎫 Инвайты" {
					rows, _ := db.Query("SELECT code, IFNULL(ip_limit, 5) FROM invites")
					var btns [][]tgbotapi.InlineKeyboardButton
					count := 0
					for rows.Next() {
						count++
						var c string; var l int; rows.Scan(&c, &l)
						btns = append(btns, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(fmt.Sprintf("❌ Уд. %s (Lim: %d)", c, l), "del_inv:"+c)))
					}
					rows.Close()
					btns = append(btns, tgbotapi.NewInlineKeyboardRow(
						tgbotapi.NewInlineKeyboardButtonData("➕ Инвайт (5 IP)", "new_inv_5"),
						tgbotapi.NewInlineKeyboardButtonData("➕ Инвайт (Безлимит)", "new_inv_0"),
					))
					msg.Text = fmt.Sprintf("🎫 <b>Активные инвайты:</b> %d шт.\nНажми кнопку ниже, чтобы создать новый.", count)
					msg.ParseMode = "HTML"
					msg.ReplyMarkup = tgbotapi.InlineKeyboardMarkup{InlineKeyboard: btns}
				} else if txt == "👥 Юзеры" {
					rows, err := db.Query("SELECT uuid, name, traffic_down, expires_at, IFNULL(ip_limit, 5) FROM users")
					if err != nil {
						msg.Text = "❌ Ошибка чтения БД: " + err.Error()
					} else {
						count := 0
						for rows.Next() { 
							count++
							var id, n string; var d sql.NullInt64; var exp sql.NullString; var lim int
							rows.Scan(&id, &n, &d, &exp, &lim)
							
							down := int64(0); if d.Valid { down = d.Int64 }
							expStr := "Безлимит"; if exp.Valid && exp.String != "" { expStr = exp.String }
							limStr := "Безлимит"; if lim > 0 { limStr = fmt.Sprintf("%d IP", lim) }
							
							uMsg := tgbotapi.NewMessage(chatID, fmt.Sprintf("👤 <b>%s</b> (%s)\n🔽 %.2f GB | ⏳ До: %s\n🔗 <code>https://%s/sub/%s.html</code>", n, limStr, float64(down)/1073741824, expStr, cfg.Domain, id))
							uMsg.ParseMode = "HTML"
							uMsg.ReplyMarkup = tgbotapi.NewInlineKeyboardMarkup(
								tgbotapi.NewInlineKeyboardRow(
									tgbotapi.NewInlineKeyboardButtonData("⏳ +30 дней", "add_30d:"+id),
									tgbotapi.NewInlineKeyboardButtonData("❌ Удалить", "del_usr:"+id),
								),
							)
							bot.Send(uMsg)
						}
						rows.Close()
						if count == 0 { msg.Text = "🤷‍♂️ Пока нет ни одного пользователя." }
					}
				} else if txt == "⚙️ Управление кластером" {
					msg.Text = "🛠 Настройки и обслуживание:"
					msg.ReplyMarkup = tgbotapi.NewInlineKeyboardMarkup(
						tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData("📦 Бекап БД", "backup")),
						tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData("🔄 Ребутнуть узлы", "reboot")),
					)
				}
				if msg.Text != "" { bot.Send(msg) }
			}

			// --- ЛОГИКА ОБЫЧНОГО ЮЗЕРА ---
			if isUser && !isAdmin {
				msg := tgbotapi.NewMessage(chatID, "")
				if txt == "/start" || txt == "/menu" {
					msg.Text = "👋 Привет, " + userName + "!\nИспользуй кнопки ниже."
					msg.ReplyMarkup = userKB
				} else if txt == "🌍 Моя ссылка" {
					msg.Text = fmt.Sprintf("🔗 <b>Твоя ссылка:</b>\n<code>https://%s/sub/%s.html</code>", cfg.Domain, userUUID)
					msg.ParseMode = "HTML"
				} else if txt == "📊 Мой статус" {
					var d, u sql.NullInt64; var exp sql.NullString
					db.QueryRow("SELECT traffic_down, traffic_up, expires_at FROM users WHERE uuid=?", userUUID).Scan(&d, &u, &exp)
					down := int64(0); if d.Valid { down = d.Int64 }
					up := int64(0); if u.Valid { up = u.Int64 }
					expStr := "Безлимит"; if exp.Valid && exp.String != "" { expStr = exp.String }
					
					msg.Text = fmt.Sprintf("📊 <b>Твоя статистика:</b>\n🔽 Скачано: %.2f GB\n🔼 Загружено: %.2f GB\n⏳ До: %s", float64(down)/1073741824, float64(up)/1073741824, expStr)
					msg.ParseMode = "HTML"
				}
				if msg.Text != "" { bot.Send(msg) }
			}
			
			// --- РЕГИСТРАЦИЯ ПО ИНВАЙТУ ---
			if strings.HasPrefix(txt, "/start INV-") {
				code := strings.TrimPrefix(txt, "/start ")
				var lim int
				if db.QueryRow("SELECT IFNULL(ip_limit, 5) FROM invites WHERE code=?", code).Scan(&lim) == nil {
					b := make([]byte, 16); rand.Read(b); b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80
					uuid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
					
					name := update.Message.From.UserName
					if name == "" { name = update.Message.From.FirstName } 
					name = strings.ReplaceAll(name, " ", "_") 
					if name == "" { name = fmt.Sprintf("user_%d", chatID) }
					
					db.Exec("INSERT INTO users (uuid, name, chat_id, ip_limit) VALUES (?, ?, ?, ?)", uuid, name, fmt.Sprintf("%d", chatID), lim)
					db.Exec("DELETE FROM invites WHERE code=?", code)
					
					msg := tgbotapi.NewMessage(chatID, fmt.Sprintf("✅ Профиль создан! Тебе дано 30 дней.\n\n👇 Ссылка:\nhttps://%s/sub/%s.html", cfg.Domain, uuid))
					if !isAdmin { msg.ReplyMarkup = userKB }
					bot.Send(msg)
				}
			}
		}
	} else { select {} }
}
MASTER_EOF

    # =========================================================================
    # AGENT GO CODE (Safe JSON + Safe Limits Regex + Timeouts)
    # =========================================================================
    cat << 'AGENT_EOF' > agent.go
package main

import (
	"bufio"
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
	"sync"
	"regexp"

	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
	proxyman "github.com/xtls/xray-core/app/proxyman/command"
	stats "github.com/xtls/xray-core/app/stats/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
)

var (
	masterURL, token, role, lastHash string
	knownUsers = make(map[string]string)
	userLimits = make(map[string]int) // Хранит лимит для каждого email (0 = безлимит)
	limitsMu   sync.RWMutex
)

type State struct {
	BridgeUUID  string                   `json:"bridge_uuid"`
	SNI         string                   `json:"sni"`
	WarpDomains string                   `json:"warp_domains"`
	Users       []map[string]interface{} `json:"users"`
	Exits       []map[string]string      `json:"exits"`
}

func syncWithMaster() {
	client := &http.Client{Timeout: 5 * time.Second} // Защита от зависания
	req, _ := http.NewRequest("GET", masterURL+"/api/sync", nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Node-IP", "PING")
	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != 200 { return }
	defer resp.Body.Close()

	var state State; json.NewDecoder(resp.Body).Decode(&state)
	eJSON, _ := json.Marshal(state.Exits)
	cHash := fmt.Sprintf("%x", sha256.Sum256([]byte(string(eJSON)+state.SNI+state.WarpDomains)))
	
	// Обновляем лимиты пользователей
	newLimits := make(map[string]int)
	for _, u := range state.Users {
		email := u["email"].(string)
		if limit, ok := u["ip_limit"].(float64); ok { newLimits[email] = int(limit) } else { newLimits[email] = 5 }
	}
	limitsMu.Lock()
	userLimits = newLimits
	limitsMu.Unlock()

	if cHash != lastHash {
		if role == "eu" { buildEUConfigSafe(state) } else { buildRUConfigSafe(state) }
		lastHash = cHash
		knownUsers = make(map[string]string)
		for _, u := range state.Users { knownUsers[u["uuid"].(string)] = u["email"].(string) }
		return
	}

	if role == "ru" {
		newKnown := make(map[string]string)
		for _, u := range state.Users {
			id, mail := u["uuid"].(string), u["email"].(string)
			newKnown[id] = mail
			if _, ok := knownUsers[id]; !ok { alterUserXray(id, mail, false) }
		}
		for uuid, email := range knownUsers {
			if _, ok := newKnown[uuid]; !ok { alterUserXray(uuid, email, true) }
		}
		knownUsers = newKnown
	}
}

// SAFE EU JSON GENERATOR
func buildEUConfigSafe(state State) {
	keys, err := ioutil.ReadFile("/usr/local/etc/xray/agent_keys.txt")
	if err != nil { return } // Защита от паники
	p := strings.Split(strings.TrimSpace(string(keys)), "|")
	if len(p) < 3 { return }
	pk, ss, xp := p[0], p[1], p[2]

	mySNI := state.SNI
	for _, e := range state.Exits {
		if e["xhttp_path"] == xp && e["sni"] != "" { mySNI = e["sni"]; break }
	}

	var parsedWarpDomains []string
	for _, d := range strings.Split(state.WarpDomains, ",") { parsedWarpDomains = append(parsedWarpDomains, strings.Trim(d, "\" ")) }

	config := map[string]interface{}{
		"log": map[string]interface{}{"loglevel": "warning"},
		"inbounds": []map[string]interface{}{
			{"port": 5000, "protocol": "shadowsocks", "settings": map[string]interface{}{"method": "2022-blake3-aes-128-gcm", "password": ss, "network": "tcp,udp"}},
			{
				"port": 443, "protocol": "vless",
				"settings": map[string]interface{}{"clients": []map[string]interface{}{{"id": state.BridgeUUID, "flow": "xtls-rprx-vision"}}, "decryption": "none"},
				"streamSettings": map[string]interface{}{"network": "tcp", "security": "reality", "realitySettings": map[string]interface{}{"dest": fmt.Sprintf("%s:443", mySNI), "serverNames": []string{mySNI}, "privateKey": pk, "shortIds": []string{""}}},
			},
			{
				"port": 4433, "protocol": "vless",
				"settings": map[string]interface{}{"clients": []map[string]interface{}{{"id": state.BridgeUUID}}, "decryption": "none"},
				"streamSettings": map[string]interface{}{"network": "xhttp", "security": "reality", "xhttpSettings": map[string]interface{}{"path": "/" + xp, "mode": "auto"}, "realitySettings": map[string]interface{}{"dest": fmt.Sprintf("%s:443", mySNI), "serverNames": []string{mySNI}, "privateKey": pk, "shortIds": []string{""}}},
			},
		},
		"outbounds": []map[string]interface{}{
			{"protocol": "freedom", "tag": "direct"},
			{"protocol": "socks", "tag": "warp", "settings": map[string]interface{}{"servers": []map[string]interface{}{{"address": "127.0.0.1", "port": 40000}}}},
			{"protocol": "blackhole", "tag": "block"},
		},
		"routing": map[string]interface{}{
			"domainStrategy": "IPIfNonMatch",
			"rules": []map[string]interface{}{
				{"type": "field", "domain": parsedWarpDomains, "outboundTag": "warp"},
				{"type": "field", "ip": []string{"geoip:private"}, "outboundTag": "block"},
			},
		},
	}
	jsonData, _ := json.MarshalIndent(config, "", "  ")
	ioutil.WriteFile("/usr/local/etc/xray/config.json", jsonData, 0644)
	exec.Command("systemctl", "restart", "xray").Run()
}

// SAFE RU JSON GENERATOR
func buildRUConfigSafe(state State) {
	keys, err := ioutil.ReadFile("/usr/local/etc/xray/agent_keys.txt")
	if err != nil { return }
	p := strings.Split(strings.TrimSpace(string(keys)), "|")
	mode, pk, sid, tlsDomain := "reality", "", "", ""
	if len(p) >= 2 && p[0] == "tls" { mode, tlsDomain = "tls", p[1] } else if len(p) >= 2 { pk, sid = p[0], p[1] }

	var clients []map[string]interface{}; var xhClients []map[string]interface{}
	for _, u := range state.Users {
		clients = append(clients, map[string]interface{}{"id": u["uuid"], "email": u["email"], "flow": "xtls-rprx-vision"})
		xhClients = append(xhClients, map[string]interface{}{"id": u["uuid"], "email": u["email"]})
	}

	var outbounds []map[string]interface{}; var balancers []string
	for _, e := range state.Exits {
		ip, pub, ss, xp, nodeSNI := e["ip"], e["pub_key"], e["ss_pass"], e["xhttp_path"], e["sni"]
		if nodeSNI == "" { nodeSNI = state.SNI }

		outbounds = append(outbounds, map[string]interface{}{
			"tag": fmt.Sprintf("eu-tcp-%s", ip), "protocol": "vless",
			"settings": map[string]interface{}{"vnext": []map[string]interface{}{{"address": ip, "port": 443, "users": []map[string]interface{}{{"id": state.BridgeUUID, "flow": "xtls-rprx-vision", "encryption": "none"}}}}},
			"streamSettings": map[string]interface{}{"network": "tcp", "security": "reality", "realitySettings": map[string]interface{}{"serverName": nodeSNI, "publicKey": pub, "fingerprint": "chrome"}},
		})
		outbounds = append(outbounds, map[string]interface{}{
			"tag": fmt.Sprintf("eu-xh-%s", ip), "protocol": "vless",
			"settings": map[string]interface{}{"vnext": []map[string]interface{}{{"address": ip, "port": 4433, "users": []map[string]interface{}{{"id": state.BridgeUUID, "encryption": "none"}}}}},
			"streamSettings": map[string]interface{}{"network": "xhttp", "security": "reality", "xhttpSettings": map[string]interface{}{"path": "/" + xp, "mode": "auto"}, "realitySettings": map[string]interface{}{"serverName": nodeSNI, "publicKey": pub, "fingerprint": "chrome"}},
		})
		outbounds = append(outbounds, map[string]interface{}{
			"tag": fmt.Sprintf("eu-ss-%s", ip), "protocol": "shadowsocks",
			"settings": map[string]interface{}{"servers": []map[string]interface{}{{"address": ip, "port": 5000, "method": "2022-blake3-aes-128-gcm", "password": ss}}},
		})
		balancers = append(balancers, fmt.Sprintf("eu-tcp-%s", ip), fmt.Sprintf("eu-xh-%s", ip), fmt.Sprintf("eu-ss-%s", ip))
	}

	outbounds = append(outbounds, map[string]interface{}{"tag": "direct", "protocol": "freedom"}, map[string]interface{}{"tag": "block", "protocol": "blackhole"})

	var inbounds []map[string]interface{}
	inbounds = append(inbounds, map[string]interface{}{"tag": "api-in", "port": 10085, "listen": "127.0.0.1", "protocol": "dokodemo-door", "settings": map[string]interface{}{"address": "127.0.0.1"}})

	if mode == "tls" {
		inbounds = append(inbounds, map[string]interface{}{
			"tag": "client-in", "port": 443, "protocol": "vless",
			"settings": map[string]interface{}{"clients": clients, "decryption": "none", "fallbacks": []map[string]interface{}{{"dest": 8081}}},
			"streamSettings": map[string]interface{}{"network": "tcp", "security": "tls", "tlsSettings": map[string]interface{}{"alpn": []string{"http/1.1"}, "certificates": []map[string]interface{}{{"certificateFile": fmt.Sprintf("/etc/letsencrypt/live/%s/fullchain.pem", tlsDomain), "keyFile": fmt.Sprintf("/etc/letsencrypt/live/%s/privkey.pem", tlsDomain)}}}},
		})
	} else {
		inbounds = append(inbounds, map[string]interface{}{
			"tag": "client-in", "port": 443, "protocol": "vless",
			"settings": map[string]interface{}{"clients": clients, "decryption": "none", "fallbacks": []map[string]interface{}{{"dest": 80}}},
			"streamSettings": map[string]interface{}{"network": "tcp", "security": "reality", "realitySettings": map[string]interface{}{"show": false, "dest": fmt.Sprintf("%s:443", state.SNI), "serverNames": []string{state.SNI}, "privateKey": pk, "shortIds": []string{sid}}},
		})
		inbounds = append(inbounds, map[string]interface{}{
			"tag": "client-xh", "port": 8001, "listen": "127.0.0.1", "protocol": "vless",
			"settings": map[string]interface{}{"clients": xhClients, "decryption": "none"},
			"streamSettings": map[string]interface{}{"network": "xhttp", "security": "none", "xhttpSettings": map[string]interface{}{"path": "/xtcp", "mode": "auto"}},
		})
	}

	config := map[string]interface{}{
		"log": map[string]interface{}{"loglevel": "warning", "access": "/var/log/xray/access.log"},
		"api": map[string]interface{}{"tag": "api", "services": []string{"HandlerService", "StatsService"}},
		"stats": map[string]interface{}{},
		"policy": map[string]interface{}{"levels": map[string]interface{}{"0": map[string]interface{}{"statsUserUplink": true, "statsUserDownlink": true}}},
		"inbounds": inbounds, "outbounds": outbounds,
		"observatory": map[string]interface{}{"subjectSelector": balancers, "probeUrl": "https://www.google.com/generate_204", "probeInterval": "1m", "enableConcurrency": true},
		"routing": map[string]interface{}{
			"domainStrategy": "IPIfNonMatch",
			"balancers": []map[string]interface{}{{"tag": "eu-balancer", "selector": balancers, "strategy": map[string]interface{}{"type": "leastPing"}}},
			"rules": []map[string]interface{}{
				{"type": "field", "inboundTag": []string{"api-in"}, "outboundTag": "api"},
				{"type": "field", "inboundTag": []string{"client-in", "client-xh"}, "balancerTag": "eu-balancer"},
				{"type": "field", "ip": []string{"geoip:private"}, "outboundTag": "direct"},
			},
		},
	}

	if len(balancers) == 0 {
		config["routing"].(map[string]interface{})["balancers"] = []interface{}{}
		config["observatory"].(map[string]interface{})["subjectSelector"] = []interface{}{}
		config["routing"].(map[string]interface{})["rules"] = []map[string]interface{}{
			{"type": "field", "inboundTag": []string{"api-in"}, "outboundTag": "api"},
			{"type": "field", "inboundTag": []string{"client-in", "client-xh"}, "outboundTag": "direct"},
			{"type": "field", "ip": []string{"geoip:private"}, "outboundTag": "direct"},
		}
	}

	jsonData, _ := json.MarshalIndent(config, "", "  ")
	ioutil.WriteFile("/usr/local/etc/xray/config.json", jsonData, 0644)
	exec.Command("systemctl", "restart", "xray").Run()
}

// АНТИ-НАХЛЕБНИК: БЕЗОПАСНЫЙ ПАРСИНГ ЛОГОВ (Regex)
func monitorIPLimits() {
	if role != "ru" { return }
	activeIPs := make(map[string]map[string]time.Time)
	
	emailRegex := regexp.MustCompile(`email:\s*([^ ]+)`)
	ipRegex := regexp.MustCompile(`from\s+([0-9\.]+):`)
	
	go func() {
		time.Sleep(5 * time.Second)
		file, err := os.Open("/var/log/xray/access.log"); if err != nil { return }
		file.Seek(0, 2); reader := bufio.NewReader(file)
		for {
			line, err := reader.ReadString('\n')
			if err == nil && strings.Contains(line, "accepted") {
				eMatch := emailRegex.FindStringSubmatch(line)
				iMatch := ipRegex.FindStringSubmatch(line)
				if len(eMatch) > 1 && len(iMatch) > 1 {
					email := strings.TrimSpace(eMatch[1])
					ip := strings.TrimSpace(iMatch[1])
					if activeIPs[email] == nil { activeIPs[email] = make(map[string]time.Time) }
					activeIPs[email][ip] = time.Now()
				}
			} else { time.Sleep(500 * time.Millisecond) }
		}
	}()

	go func() {
		for {
			time.Sleep(1 * time.Minute); now := time.Now()
			for email, ips := range activeIPs {
				// Очистка старых IP
				for ip, lastSeen := range ips { if now.Sub(lastSeen) > 5*time.Minute { delete(ips, ip) } }
				
				limitsMu.RLock()
				limit := userLimits[email]
				limitsMu.RUnlock()

				// Если limit == 0 (безлимит), пропускаем блокировку
				if limit > 0 && len(ips) > limit {
					uuid := knownUsers[email]
					alterUserXray(uuid, email, true)
					http.Get(fmt.Sprintf("%s/api/ban?email=%s", masterURL, email)) // Отправка сигнала Мастеру
					delete(activeIPs, email)
				}
			}
		}
	}()
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
	if role == "eu" { return }
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
		client := &http.Client{Timeout: 10 * time.Second} // ЗАЩИТА ОТ ЗАВИСАНИЯ
		req, _ := http.NewRequest("POST", masterURL+"/api/stats", bytes.NewBuffer(b))
		req.Header.Set("Authorization", "Bearer "+token)
		client.Do(req)
	}
}

func main() {
	flag.StringVar(&masterURL, "master", "", ""); flag.StringVar(&token, "token", "", ""); flag.StringVar(&role, "role", "ru", ""); flag.Parse()
	monitorIPLimits()
	for { syncWithMaster(); sendStats(); time.Sleep(30 * time.Second) }
}
AGENT_EOF

    echo "⏳ Компиляция Мастера и Агента v17.0 Final..."
    go mod init vpn-core >/dev/null 2>&1
    go get github.com/go-telegram-bot-api/telegram-bot-api/v5 modernc.org/sqlite >/dev/null 2>&1
    go get github.com/xtls/xray-core@latest >/dev/null 2>&1
    go get google.golang.org/grpc >/dev/null 2>&1
    go mod tidy >/dev/null 2>&1
    
    go build -ldflags="-s -w" -o /usr/local/bin/vpn-master master.go
    mkdir -p /etc/orchestrator/bin
    CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /etc/orchestrator/bin/agent agent.go
}

update_cluster() {
    echo -e "\n🔄 БЕСШОВНОЕ ОБНОВЛЕНИЕ КЛАСТЕРА"
    compile_code
    
    echo "⏳ Перезапуск локального Мастера..."
    systemctl restart vpn-master
    
    if [ -f /usr/local/bin/vpn-agent ]; then
        echo "⏳ Обновление локального моста..."
        systemctl stop vpn-agent
        cp /etc/orchestrator/bin/agent /usr/local/bin/vpn-agent
        systemctl start vpn-agent
    fi
    
    echo "⏳ Обновление удаленных RU-мостов..."
    for IP in $(sqlite3 /etc/orchestrator/core.db "SELECT ip FROM bridges WHERE ip != '127.0.0.1' AND ip != '$MASTER_IP';"); do
        ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "systemctl stop vpn-agent" 2>/dev/null
        if scp -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no /etc/orchestrator/bin/agent root@$IP:/usr/local/bin/vpn-agent 2>/dev/null; then
            ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "systemctl start vpn-agent" 2>/dev/null
            echo "✅ Мост $IP обновлен."
        else
            echo "❌ Ошибка обновления моста $IP."
        fi
    done

    echo "⏳ Обновление EU-нод..."
    for IP in $(sqlite3 /etc/orchestrator/core.db "SELECT ip FROM exits;"); do
        ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "systemctl stop vpn-agent" 2>/dev/null
        if scp -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no /etc/orchestrator/bin/agent root@$IP:/usr/local/bin/vpn-agent 2>/dev/null; then
            ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "systemctl start vpn-agent" 2>/dev/null
            echo "✅ Нода $IP обновлена."
        else
            echo "❌ Ошибка обновления ноды $IP."
        fi
    done
    echo "✅ Кластер успешно обновлен!"
}

# ==============================================================================
# 2. ИНТЕРАКТИВНАЯ УСТАНОВКА МАСТЕРА И МОСТА
# ==============================================================================
install_master() {
    install_deps
    echo -e "\n🧠 УСТАНОВКА ЦЕНТРА УПРАВЛЕНИЯ"
    
    read -p "🤖 Telegram Bot Token: " TG_TOKEN
    read -p "🆔 Telegram Admin ID: " TG_CHAT_ID
    read -p "🌐 Домен Мастера (sub.master.com): " SUB_DOMAIN
    
    verify_dns_propagation "$SUB_DOMAIN"
    
    read -p "✉️ Email для SSL (Let's Encrypt): " SSL_EMAIL
    
    CLUSTER_TOKEN=$(openssl rand -hex 16)
    BRIDGE_UUID=$(uuidgen)
    
    if [ ! -f /root/.ssh/vpn_cluster_key ]; then
        echo "🔑 Генерация SSH-ключей кластера..."
        ssh-keygen -t ed25519 -f /root/.ssh/vpn_cluster_key -N "" -q
        chmod 600 /root/.ssh/vpn_cluster_key
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
server { listen 80; server_name _; return 301 https://\$host\$request_uri; }
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
    compile_code

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
    echo "✅ Мастер успешно установлен и запущен!"
    
    echo "---------------------------------------------------------"
    read -p "Установить локальный RU-мост на этом же сервере прямо сейчас? (y/n): " SETUP_LOCAL
    if [[ "$SETUP_LOCAL" == "y" || "$SETUP_LOCAL" == "Y" ]]; then
        deploy_node "ru_local"
    fi
}

# ==============================================================================
# 3. РАЗВЕРТЫВАНИЕ УЗЛОВ
# ==============================================================================
deploy_node() {
    TYPE=$1
    if [ "$TYPE" == "ru_local" ]; then
        echo -e "\n🏠 ДОБАВЛЕНИЕ ЛОКАЛЬНОГО RU-МОСТА (Classic TLS на 443 порту)"
        DOMAIN=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)
        TOKEN=$(grep CLUSTER_TOKEN /etc/orchestrator/config.env | cut -d'"' -f2)
        
        echo "⏳ Настройка Nginx и заглушки..."
        cat << 'EOF' > /etc/nginx/sites-available/default
server { listen 80; server_name _; return 301 https://$host$request_uri; }
server {
    listen 127.0.0.1:8081;
    root /var/www/html;
    index index.html;
    location /sub/ { proxy_pass http://127.0.0.1:8080/sub/; proxy_set_header X-Real-IP $remote_addr; }
    location /api/ { proxy_pass http://127.0.0.1:8080/api/; proxy_set_header X-Real-IP $remote_addr; }
    location /download/ { proxy_pass http://127.0.0.1:8080/download/; }
}
EOF
        mkdir -p /var/www/html
        cat << 'HTML_EOF' > /var/www/html/index.html
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Nextcloud</title><style>body{background-color:#0082c9;background-image:linear-gradient(40deg,#0082c9 0%,#004c8c 100%);font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.form{background:#fff;padding:40px;border-radius:8px;width:300px;text-align:center;box-shadow:0 4px 10px rgba(0,0,0,0.1)}.form input{width:100%;padding:12px;margin:10px 0;border:1px solid #ddd;border-radius:4px;box-sizing:border-box}.form button{width:100%;padding:12px;background:#0082c9;color:#fff;border:none;border-radius:4px;cursor:pointer;font-weight:bold;margin-top:10px}</style></head><body><div class="form"><h2 style="color:#333;margin-top:0">Nextcloud</h2><input type="text" placeholder="Username or email"><input type="password" placeholder="Password"><button>Log in</button></div></body></html>
HTML_EOF
        systemctl restart nginx

        echo "⏳ Установка Xray..."
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
		mkdir -p /var/log/xray && chmod 777 /var/log/xray
        sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service
        systemctl daemon-reload

        echo "⏳ Настройка Агента..."
        sed -i 's/"dest":8080/"dest":8081/g' /usr/src/vpn-cluster/agent.go
        cd /usr/src/vpn-cluster && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags="-s -w" -o /etc/orchestrator/bin/agent agent.go
        cp /etc/orchestrator/bin/agent /usr/local/bin/vpn-agent
        
        echo "tls|$DOMAIN" > /usr/local/etc/xray/agent_keys.txt
        curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8080/api/register?type=ru&ip=127.0.0.1&domain=$DOMAIN&mode=tls" >/dev/null

        cat <<SVC > /etc/systemd/system/vpn-agent.service
[Unit]
Description=VPN Agent
[Service]
ExecStart=/usr/local/bin/vpn-agent -master http://127.0.0.1:8080 -token $TOKEN -role ru
Restart=always
[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload && systemctl enable vpn-agent && systemctl restart vpn-agent
        sleep 2; systemctl restart xray
        echo "✅ Локальный мост успешно установлен!"
        return
    fi

    RU_MODE="1"
    if [ "$TYPE" == "ru_remote" ]; then
        echo -e "\n🌉 ДОБАВЛЕНИЕ УДАЛЕННОГО RU-МОСТА"
        read -p "IP адрес сервера: " IP
        read -s -p "Root пароль от $IP: " PASS; echo ""
        echo "1) REALITY (Маскировка под чужой сайт, домен не нужен)"
        echo "2) Classic TLS (Требуется домен, ставится заглушка Nextcloud)"
        read -p "Режим работы: " RU_MODE
        if [ "$RU_MODE" == "2" ]; then
            read -p "Введи домен для моста: " DOMAIN
            verify_dns_propagation "$DOMAIN"
            read -p "Email для SSL (Let's Encrypt): " EMAIL
        else
            read -p "Домен для моста (просто название для ссылки): " DOMAIN
        fi
    elif [ "$TYPE" == "eu" ]; then
        echo -e "\n🇪🇺 ДОБАВЛЕНИЕ EU-НОДЫ (+WARP)"
        read -p "IP адрес сервера: " IP
        read -s -p "Root пароль от $IP: " PASS; echo ""
    fi

    echo "⏳ Копирование SSH-ключа на удаленный сервер (Безопасно)..."
    export SSHPASS="$PASS"
    sshpass -e ssh-copy-id -i /root/.ssh/vpn_cluster_key.pub -o StrictHostKeyChecking=no root@$IP >/dev/null 2>&1
    CMD_PREFIX="ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP bash -s"

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
		mkdir -p /var/log/xray && chmod 777 /var/log/xray
        
        ufw allow 22/tcp >/dev/null 2>&1

        if [ "$TYPE" == "ru_remote" ]; then
            if [ "$RU_MODE" == "2" ]; then
                apt-get install -yq nginx certbot python3-certbot-nginx >/dev/null 2>&1
                certbot certonly --standalone -d $DOMAIN -m $EMAIL --agree-tos -n >/dev/null 2>&1
                cat << 'HTML_EOF' > /var/www/html/index.html
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8"><title>Nextcloud</title><style>body{background-color:#0082c9;background-image:linear-gradient(40deg,#0082c9 0%,#004c8c 100%);font-family:sans-serif;display:flex;align-items:center;justify-content:center;height:100vh;margin:0}.form{background:#fff;padding:40px;border-radius:8px;width:300px;text-align:center;box-shadow:0 4px 10px rgba(0,0,0,0.1)}.form input{width:100%;padding:12px;margin:10px 0;border:1px solid #ddd;border-radius:4px;box-sizing:border-box}.form button{width:100%;padding:12px;background:#0082c9;color:#fff;border:none;border-radius:4px;cursor:pointer;font-weight:bold;margin-top:10px}</style></head><body><div class="form"><h2 style="color:#333;margin-top:0">Nextcloud</h2><input type="text" placeholder="Username or email"><input type="password" placeholder="Password"><button>Log in</button></div></body></html>
HTML_EOF
                cat << 'NGINX_EOF' > /etc/nginx/sites-available/default
server { listen 8080 default_server; root /var/www/html; index index.html; }
NGINX_EOF
                systemctl restart nginx
                echo "tls|$DOMAIN" > /usr/local/etc/xray/agent_keys.txt
                curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=ru&ip=$(curl -s4 ifconfig.me)&domain=$DOMAIN&mode=tls" >/dev/null
                echo "NODE_DATA|ru|tls"
            else
                KEYS=$(/usr/local/bin/xray x25519)
                PK=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
                PUB=$(echo "$KEYS" | grep -iE "Public|Password" | awk '{print $NF}')
                SID=$(openssl rand -hex 4)
                echo "$PK|$SID" > /usr/local/etc/xray/agent_keys.txt
                curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=ru&ip=$(curl -s4 ifconfig.me)&domain=$DOMAIN&pk=$PUB&sid=$SID&mode=reality" >/dev/null
                echo "NODE_DATA|ru|reality"
            fi
            
            wget -q https://$MASTER_DOM/download/agent -O /usr/local/bin/vpn-agent
            chmod +x /usr/local/bin/vpn-agent
            cat <<SVC > /etc/systemd/system/vpn-agent.service
[Unit]
Description=VPN Agent
[Service]
ExecStart=/usr/local/bin/vpn-agent -master https://$MASTER_DOM -token $TOKEN -role ru
Restart=always
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload && systemctl enable vpn-agent && systemctl restart vpn-agent
            ufw allow 443/tcp >/dev/null 2>&1
            ufw allow 4433/tcp >/dev/null 2>&1
            ufw --force enable >/dev/null 2>&1
            
        elif [ "$TYPE" == "eu" ]; then
            apt-get install -yq gpg lsb-release >/dev/null 2>&1
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            echo "deb[arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
            apt-get update -q >/dev/null 2>&1
            apt-get install -yq cloudflare-warp >/dev/null 2>&1
            warp-cli --accept-tos registration new >/dev/null 2>&1
            warp-cli --accept-tos mode proxy >/dev/null 2>&1
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
            warp-cli --accept-tos connect >/dev/null 2>&1
            
            KEYS=$(/usr/local/bin/xray x25519)
            PK=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
            PUB=$(echo "$KEYS" | grep -iE "Public|Password" | awk '{print $NF}')
            SS_PASS=$(openssl rand -base64 16)
            XP=$(openssl rand -hex 6)
            
            echo "$PK|$SS_PASS|$XP" > /usr/local/etc/xray/agent_keys.txt
            
            wget -q https://$MASTER_DOM/download/agent -O /usr/local/bin/vpn-agent
            chmod +x /usr/local/bin/vpn-agent
            cat <<SVC > /etc/systemd/system/vpn-agent.service
[Unit]
Description=VPN Agent (EU)
[Service]
ExecStart=/usr/local/bin/vpn-agent -master https://$MASTER_DOM -token $TOKEN -role eu
Restart=always
[Install]
WantedBy=multi-user.target
SVC
            systemctl daemon-reload && systemctl enable vpn-agent && systemctl restart vpn-agent
            
            ufw allow 443/tcp >/dev/null 2>&1
            ufw allow 4433/tcp >/dev/null 2>&1
            ufw allow 5000/tcp >/dev/null 2>&1
            ufw --force enable >/dev/null 2>&1
            
            curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=eu&ip=$(curl -s4 ifconfig.me)&pk=$PUB&ss=$SS_PASS&xp=$XP" >/dev/null
            echo "NODE_DATA|eu"
        fi
        sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/g' /etc/ssh/sshd_config
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null
EOF
)
    DATA=$(echo "$RAW_OUT" | grep "NODE_DATA")
    if [ -z "$DATA" ]; then echo "❌ Ошибка деплоя. Лог: $RAW_OUT"
    else echo "✅ Узел успешно развернут! Мастер подхватит его через 30 секунд."; fi
}

# ==============================================================================
# УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ
# ==============================================================================
manage_users_cli() {
    while true; do
        clear
        echo "========================================================="
        echo "👥 УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ"
        echo "========================================================="
        sqlite3 /etc/orchestrator/core.db "SELECT name, traffic_down, IFNULL(ip_limit, 5), uuid FROM users;" | awk -F'|' '{l="Безлимит"; if($3>0){l=$3" IP"} printf "👤 %-15s | Lim: %-8s | 🔽 %.2f GB | ID: %s\n", $1, l, $2/1073741824, $4}'
        if [ $(sqlite3 /etc/orchestrator/core.db "SELECT COUNT(*) FROM users;") -eq 0 ]; then echo "Пусто. Нет активных пользователей."; fi
        echo "---------------------------------------------------------"
        echo "1) ➕ Добавить пользователя"
        echo "2) ➖ Удалить пользователя"
        echo "3) 🔗 Показать ссылку пользователя"
        echo "0) ↩️ Назад"
        read -p "Выбор: " U_OPT
        
        case $U_OPT in
            1)
                read -p "Имя (без пробелов, англ): " U_NAME
                echo "1) Лимит 5 IP (По умолчанию)"
                echo "2) Безлимитный аккаунт"
                read -p "Тип аккаунта: " L_TYPE
                LIMIT=5
                if [ "$L_TYPE" == "2" ]; then LIMIT=0; fi
                U_UUID=$(uuidgen)
                sqlite3 /etc/orchestrator/core.db "INSERT INTO users (uuid, name, expires_at, ip_limit) VALUES ('$U_UUID', '$U_NAME', datetime('now', '+30 days'), $LIMIT);"
                DOMAIN=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)
                echo "✅ Пользователь добавлен в БД!"
                echo "🔗 Ссылка: https://$DOMAIN/sub/$U_UUID.html"
                read -p "Нажми Enter..." ;;
            2)
                read -p "Введи точное Имя пользователя для удаления: " DEL_NAME
                sqlite3 /etc/orchestrator/core.db "DELETE FROM users WHERE name='$DEL_NAME';"
                echo "✅ Пользователь удален из БД!"
                read -p "Нажми Enter..." ;;
            3)
                read -p "Введи Имя пользователя: " GET_NAME
                U_UUID=$(sqlite3 /etc/orchestrator/core.db "SELECT uuid FROM users WHERE name='$GET_NAME';")
                if [ -n "$U_UUID" ]; then
                    DOMAIN=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)
                    echo "🔗 Ссылка: https://$DOMAIN/sub/$U_UUID.html"
                else
                    echo "❌ Пользователь не найден."
                fi
                read -p "Нажми Enter..." ;;
            0) return ;;
        esac
    done
}

harden_system() {
    echo "⏳ Настройка безопасности и SWAP..."
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    systemctl enable fail2ban >/dev/null 2>&1; systemctl start fail2ban >/dev/null 2>&1
    echo "✅ Безопасность усилена (SWAP 2GB, Fail2Ban)."
}

create_backup() {
    TG_TOKEN=$(grep TG_TOKEN /etc/orchestrator/config.env 2>/dev/null | cut -d'"' -f2)
    TG_CHAT_ID=$(grep TG_CHAT_ID /etc/orchestrator/config.env 2>/dev/null | cut -d'"' -f2)
    if [ -z "$TG_TOKEN" ]; then echo "❌ Токен не найден. Сначала установи Мастер."; return; fi
    echo "⏳ Создание бекапа..."
    sqlite3 /etc/orchestrator/core.db ".backup '/tmp/core_backup.db'"
    tar -czf /tmp/backup.tar.gz -C /tmp core_backup.db
    curl -s -F document=@"/tmp/backup.tar.gz" -F chat_id="$TG_CHAT_ID" -F caption="📦 Бекап БД Кластера v17.0 Final" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" >/dev/null
    rm -f /tmp/core_backup.db /tmp/backup.tar.gz
    echo "✅ Бекап отправлен в Telegram!"
}

delete_node() {
    echo -e "\n🗑️ УДАЛЕНИЕ СЕРВЕРОВ ИЗ КЛАСТЕРА"
    echo "1) Удалить RU Мост"
    echo "2) Удалить EU Ноду"
    echo "0) Отмена"
    read -p "Выбор: " DEL_C
    if [ "$DEL_C" == "1" ]; then
        sqlite3 /etc/orchestrator/core.db "SELECT ip, domain, mode FROM bridges"
        read -p "Введи IP моста: " DEL_IP
        sqlite3 /etc/orchestrator/core.db "DELETE FROM bridges WHERE ip='$DEL_IP'"
        echo "✅ Мост удален из БД."
    elif [ "$DEL_C" == "2" ]; then
        sqlite3 /etc/orchestrator/core.db "SELECT ip FROM exits"
        read -p "Введи IP ноды: " DEL_IP
        sqlite3 /etc/orchestrator/core.db "DELETE FROM exits WHERE ip='$DEL_IP'"
        echo "✅ EU нода удалена из БД."
    fi
}

# ==============================================================================
# MENU
# ==============================================================================
while true; do
    clear
    echo "#########################################################"
    echo "🚀 VPN CLOUD NATIVE v17.0 FINAL | Master Control Panel"
    echo "#########################################################"
    show_system_status
    
    if [ ! -f /usr/local/bin/vpn-master ]; then
        echo "1. 🛠 Установить Master API"
    else
        echo "🔹 ИНФРАСТРУКТУРА"
        echo "2. 🏠 Добавить Локальный RU-Мост"
        echo "3. 🌉 Добавить Удаленный RU-Мост"
        echo "4. 🇪🇺 Добавить EU-Ноду (+WARP)"
        echo "5. 🗑️ Удалить узел из кластера"
        
        echo -e "\n🔹 УПРАВЛЕНИЕ И ДИАГНОСТИКА"
        echo "6. 👥 Управление пользователями"
        echo "7. ⚡ Speedtest: Замер скорости"
        echo "8. 📜 Просмотр логов"
        
        echo -e "\n🔹 БЕЗОПАСНОСТЬ И ОБСЛУЖИВАНИЕ"
        echo "9.  🛡️ Усилить безопасность (SWAP, Fail2ban)"
        echo "10. ✈️ Telegram MTProto Прокси"
        echo "11. ⚙️ Автозапуск меню при входе"
        echo "12. 📦 Сделать полный бекап в Telegram"
        echo "13. 🔄 Обновить Мастера и Агентов"
		echo "14. 🔄 Обновить Ядро Xray"
		echo "15. 🎭 Сменить SNI"
		echo "16. 🚀 Сменить домены WARP"
    fi
    echo "0. 🚪 Выход"
    echo "#########################################################"
    read -p "Выбор: " C
    case $C in
        1) install_master ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        2) deploy_node "ru_local" ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        3) deploy_node "ru_remote" ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        4) deploy_node "eu" ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        5) delete_node ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        6) manage_users_cli ;;
        7) speedtest_bridge ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        8) show_logs ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        9) harden_system ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        10) manage_mtproto ;;
        11) toggle_autostart ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        12) create_backup ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        13) update_cluster ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
		14) update_xray_core ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        15) change_sni_cli ;;
		16) manage_warp_cli ;;
        0) exit 0 ;;
    esac
done
