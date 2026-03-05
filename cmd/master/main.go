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