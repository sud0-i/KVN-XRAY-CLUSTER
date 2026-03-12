package main

import (
	"crypto/rand"
	"database/sql"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"strings"
	//"time"

	tgbotapi "github.com/go-telegram-bot-api/telegram-bot-api/v5"
	_ "modernc.org/sqlite"
)

var db *sql.DB
var cfg struct {
	Token, ChatID, Domain, ClusterToken, BridgeUUID, MasterIP string
}

func initDB() {
	var err error
	db, err = sql.Open("sqlite", "/etc/orchestrator/core.db?pragma=journal_mode(WAL)")
	if err != nil {
		log.Fatalf("Failed to open database: %v", err)
	}

	createQueries := []string{
		`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, name TEXT, traffic_up INT DEFAULT 0, traffic_down INT DEFAULT 0, expires_at DATETIME DEFAULT (datetime('now', '+30 days')), ip_limit INT DEFAULT 5, chat_id TEXT DEFAULT '')`,
		`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, ip_limit INT DEFAULT 5)`,
		`CREATE TABLE IF NOT EXISTS bridges (ip TEXT PRIMARY KEY, domain TEXT, pub_key TEXT, sid TEXT, mode TEXT, last_seen DATETIME)`,
		`CREATE TABLE IF NOT EXISTS exits (ip TEXT PRIMARY KEY, pub_key TEXT, ss_pass TEXT, xhttp_path TEXT, sni TEXT DEFAULT '', last_seen DATETIME)`,
		`CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, val TEXT)`,
	}

	for _, q := range createQueries {
		if _, err := db.Exec(q); err != nil {
			log.Fatalf("Failed to execute init query: %s\nError: %v", q, err)
		}
	}

	alterQueries := []string{
		`ALTER TABLE users ADD COLUMN expires_at DATETIME`,
		`ALTER TABLE users ADD COLUMN ip_limit INT DEFAULT 5`,
		`ALTER TABLE invites ADD COLUMN ip_limit INT DEFAULT 5`,
		`ALTER TABLE users ADD COLUMN chat_id TEXT DEFAULT ''`,
		`ALTER TABLE exits ADD COLUMN sni TEXT DEFAULT ''`,
		`ALTER TABLE exits ADD COLUMN last_seen DATETIME`,
	}
	for _, q := range alterQueries {
		_, err := db.Exec(q)
		if err != nil && !strings.Contains(err.Error(), "duplicate column name") {
			log.Printf("Migration warning: %v", err)
		}
	}

	db.Exec(`UPDATE users SET expires_at=datetime('now', '+30 days') WHERE expires_at IS NULL`)
	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('sni', 'www.microsoft.com')`)
	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('ru_sni', 'dzen.ru')`)
	db.Exec(`INSERT OR IGNORE INTO settings (key, val) VALUES ('warp_domains', '"geosite:google","geosite:openai","geosite:netflix","geosite:instagram","geosite:category-ru","domain:ru","domain:рф"')`)
}

func loadConfig() {
	data, err := os.ReadFile("/etc/orchestrator/config.env")
	if err != nil {
		log.Fatalf("Failed to read config.env: %v", err)
	}
	for _, l := range strings.Split(string(data), "\n") {
		parts := strings.SplitN(l, "=", 2)
		if len(parts) != 2 {
			continue
		}
		k, v := parts[0], strings.Trim(parts[1], `"`)
		switch k {
		case "TG_TOKEN":
			cfg.Token = v
		case "TG_CHAT_ID":
			cfg.ChatID = v
		case "SUB_DOMAIN":
			cfg.Domain = v
		case "CLUSTER_TOKEN":
			cfg.ClusterToken = v
		case "BRIDGE_UUID":
			cfg.BridgeUUID = v
		case "MASTER_IP":
			cfg.MasterIP = v
		}
	}
}

func authMw(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer "+cfg.ClusterToken {
			http.Error(w, "Unauthorized", http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

func handleSync(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	nodeIP := r.Header.Get("X-Real-IP")
	if nodeIP == "" || nodeIP == "::1" {
		nodeIP = "127.0.0.1"
	}

	db.ExecContext(ctx, "UPDATE bridges SET last_seen=CURRENT_TIMESTAMP WHERE ip=?", nodeIP)
	db.ExecContext(ctx, "UPDATE exits SET last_seen=CURRENT_TIMESTAMP WHERE ip=?", nodeIP)

	var sni, ru_sni, warp string
	db.QueryRowContext(ctx, "SELECT val FROM settings WHERE key='sni'").Scan(&sni)
	db.QueryRowContext(ctx, "SELECT val FROM settings WHERE key='ru_sni'").Scan(&ru_sni)
	db.QueryRowContext(ctx, "SELECT val FROM settings WHERE key='warp_domains'").Scan(&warp)

	users := []map[string]interface{}{}
	uRows, err := db.QueryContext(ctx, "SELECT uuid, name, IFNULL(ip_limit, 5) FROM users WHERE expires_at > CURRENT_TIMESTAMP OR expires_at IS NULL")
	if err != nil {
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}
	defer uRows.Close()

	for uRows.Next() {
		var u, n string
		var lim int
		uRows.Scan(&u, &n, &lim)
		users = append(users, map[string]interface{}{"uuid": u, "email": n, "ip_limit": lim})
	}

	exits := []map[string]string{}
	eRows, err := db.QueryContext(ctx, "SELECT ip, pub_key, ss_pass, xhttp_path, sni FROM exits")
	if err != nil {
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}
	defer eRows.Close()

	for eRows.Next() {
		var ip, pk, ss, xp string
		var nodeSNI sql.NullString
		eRows.Scan(&ip, &pk, &ss, &xp, &nodeSNI)
		finalSNI := sni
		if nodeSNI.Valid && nodeSNI.String != "" {
			finalSNI = nodeSNI.String
		}
		exits = append(exits, map[string]string{"ip": ip, "pub_key": pk, "ss_pass": ss, "xhttp_path": xp, "sni": finalSNI})
	}

	w.Header().Set("Content-Type", "application/json")
	if err := json.NewEncoder(w).Encode(map[string]interface{}{
		"bridge_uuid":  cfg.BridgeUUID,
		"sni":          sni,
		"ru_sni":       ru_sni,
		"warp_domains": warp,
		"users":        users,
		"exits":        exits,
	}); err != nil {
		log.Println("Error encoding sync response:", err)
	}
}

func handleStats(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	var stats []map[string]interface{}
	if err := json.NewDecoder(r.Body).Decode(&stats); err != nil {
		http.Error(w, "Invalid JSON", http.StatusBadRequest)
		return
	}

	stmt, err := db.PrepareContext(ctx, "UPDATE users SET traffic_up=traffic_up+?, traffic_down=traffic_down+? WHERE name=?")
	if err != nil {
		log.Println("Failed to prepare stats query:", err)
		http.Error(w, "Internal Error", http.StatusInternalServerError)
		return
	}
	defer stmt.Close()

	for _, s := range stats {
		up, _ := s["up"].(float64)
		down, _ := s["down"].(float64)
		email, _ := s["email"].(string)

		if _, err := stmt.ExecContext(ctx, int64(up), int64(down), email); err != nil {
			log.Printf("Failed to update stats for user %s: %v", email, err)
		}
	}
	w.WriteHeader(http.StatusOK)
}

func handleBan(w http.ResponseWriter, r *http.Request) {
	email := r.URL.Query().Get("email")
	if email != "" {
		db.ExecContext(r.Context(), "UPDATE users SET expires_at=datetime('now', '-1 days') WHERE name=?", email)
		if cfg.Token != "" {
			bot, err := tgbotapi.NewBotAPI(cfg.Token)
			if err == nil {
				msg := tgbotapi.NewMessageToChannel(cfg.ChatID, fmt.Sprintf("🚨 Сработал Анти-фрод!\nПользователь %s заблокирован за использование с большего числа IP, чем разрешено лимитом.", email))
				bot.Send(msg)
			}
		}
	}
	w.WriteHeader(http.StatusOK)
}

func handleRegister(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	query := r.URL.Query()
	typ := query.Get("type")
	ip := query.Get("ip")
	pk := query.Get("pk")

	if typ == "eu" {
		ss := query.Get("ss")
		xp := query.Get("xp")
		db.ExecContext(ctx, "INSERT OR REPLACE INTO exits (ip, pub_key, ss_pass, xhttp_path, last_seen) VALUES (?, ?, ?, ?, CURRENT_TIMESTAMP)", ip, pk, ss, xp)
	} else if typ == "ru" {
		mode := query.Get("mode")
		if mode == "" { mode = "reality" }
		domain := query.Get("domain")
		sid := query.Get("sid")
		db.ExecContext(ctx, "INSERT OR REPLACE INTO bridges (ip, domain, pub_key, sid, mode, last_seen) VALUES (?, ?, ?, ?, ?, CURRENT_TIMESTAMP)", ip, domain, pk, sid, mode)
	}
	w.WriteHeader(http.StatusOK)
}

func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	isHTML := strings.HasSuffix(uuid, ".html")
	uuid = strings.TrimSuffix(uuid, ".html")

	var name string
	if err := db.QueryRowContext(r.Context(), "SELECT name FROM users WHERE uuid=?", uuid).Scan(&name); err != nil {
		http.Error(w, "Not found", http.StatusNotFound)
		return
	}

	var sni string
	db.QueryRowContext(r.Context(), "SELECT val FROM settings WHERE key='sni'").Scan(&sni)

	var links []string
	bRows, err := db.QueryContext(r.Context(), "SELECT ip, domain, pub_key, sid, mode FROM bridges")
	if err != nil {
		http.Error(w, "Database error", http.StatusInternalServerError)
		return
	}
	defer bRows.Close()

	for bRows.Next() {
		var dIP, d, pk, sid, mode string
		bRows.Scan(&dIP, &d, &pk, &sid, &mode)
		if mode == "tls" {
			links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TLS-%s]", uuid, d, d, name, d))
		} else {
			port := "443"
			if dIP == cfg.MasterIP || dIP == "127.0.0.1" {
				port = "4433"
			}
			links = append(links, fmt.Sprintf("vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s#%s-[TCP-%s]", uuid, dIP, port, pk, sid, sni, name, d))
			links = append(links, fmt.Sprintf("vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&sid=%s&fp=chrome&type=xhttp&path=%%2Fxtcp&sni=%s#%s-[xHTTP-%s]", uuid, dIP, port, pk, sid, sni, name, d))
		}
	}

	if isHTML {
		u := "https://" + cfg.Domain + "/sub/" + uuid
		
		// Обрати внимание: все символы % в CSS (например, width: 100%) удвоены до %%, 
		// чтобы компилятор Go не воспринял их как переменные!
		htmlTemplate := `<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Настройка VPN</title>
    <script src="https://cdnjs.cloudflare.com/ajax/libs/qrcodejs/1.0.0/qrcode.min.js"></script>
    <style>
        body { background: #121212; color: #e0e0e0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; display: flex; flex-direction: column; align-items: center; min-height: 100vh; margin: 0; padding: 20px; text-align: center; }
        .card { background: #1e1e1e; padding: 30px; border-radius: 16px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); max-width: 400px; width: 100%%; box-sizing: border-box; }
        h2 { font-size: 24px; margin-top: 0; margin-bottom: 20px; color: #ffffff; }
        .step-title { font-weight: bold; color: #888; font-size: 12px; text-transform: uppercase; letter-spacing: 1px; margin-bottom: 10px; display: block; text-align: left; }
        .apps { background: #2a2a2a; padding: 15px; border-radius: 12px; margin-bottom: 25px; text-align: left; font-size: 14px; border: 1px solid #333; }
        .apps a { color: #4da6ff; text-decoration: none; display: block; margin-bottom: 10px; font-weight: 500; }
        .apps a:last-child { margin-bottom: 0; }
        .apps a:hover { text-decoration: underline; }
        .btn { display: block; width: 100%%; padding: 14px; margin-bottom: 12px; border-radius: 12px; text-decoration: none; font-weight: bold; font-size: 15px; box-sizing: border-box; transition: transform 0.1s; border: none; cursor: pointer; }
        .btn:active { transform: scale(0.98); }
        .btn-ios { background: #007AFF; color: white; }
        .btn-android { background: #3DDC84; color: #000; }
        .btn-win { background: #00A4EF; color: white; }
        #qr { margin: 10px auto 20px; background: #fff; padding: 15px; border-radius: 12px; display: inline-block; }
        .raw-link { background: #111; padding: 15px; border-radius: 12px; font-family: monospace; font-size: 12px; color: #4da6ff; word-break: break-all; margin-top: 5px; cursor: pointer; border: 1px solid #333; }
    </style>
</head>
<body>
    <div class="card">
        <h2>🔑 Привет, %s!</h2>
        
        <div class="apps">
            <span class="step-title">Шаг 1. Установи клиент:</span>
            <a href="https://apps.apple.com/us/app/v2raytun/id6476628951">🍏 iOS / macOS — V2rayTun</a>
            <a href="https://play.google.com/store/apps/details?id=com.v2raytun.android">🤖 Android — V2rayTun</a>
            <a href="https://github.com/hiddify/hiddify-next/releases/latest">💻 Windows / Linux — Hiddify Next</a>
        </div>

        <span class="step-title" style="text-align: center;">Шаг 2. Подключи профиль:</span>
        <a href="v2raytun://import/%s" class="btn btn-ios">🚀 Подключить в V2rayTun</a>
        <a href="hiddify://install-config?url=%s" class="btn btn-android">🤖 Подключить в Hiddify</a>
        <a href="v2box://install-sub?url=%s" class="btn btn-win">📦 Подключить в V2Box</a>

        <div id="qr"></div>

        <span class="step-title" style="text-align: center;">Для ручной настройки (нажми, чтобы скопировать):</span>
        <div class="raw-link" onclick="navigator.clipboard.writeText(this.innerText); alert('Ссылка скопирована!');">%s</div>
    </div>
    <script>new QRCode(document.getElementById("qr"), {text: "%s", width: 160, height: 160, colorDark : "#000000", colorLight : "#ffffff", correctLevel : QRCode.CorrectLevel.L});</script>
</body>
</html>`

		h := fmt.Sprintf(htmlTemplate, name, u, u, u, u, u)
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(h))
	} else {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
	}
}

//func monitorNodes(bot *tgbotapi.BotAPI) {
//	for {
//		time.Sleep(2 * time.Minute)
//		rows, err := db.Query("SELECT ip FROM bridges WHERE ip != '127.0.0.1' AND last_seen < datetime('now', '-3 minute') UNION SELECT ip FROM exits WHERE ip != '127.0.0.1' AND last_seen < datetime('now', '-3 minute')")
//		if err != nil {
//			log.Println("Node monitor DB error:", err)
//			continue
//		}
//
//		for rows.Next() {
//			var ip string
//			rows.Scan(&ip)
//			msg := tgbotapi.NewMessageToChannel(cfg.ChatID, fmt.Sprintf("🔴 АЛЕРТ! Узел %s не выходит на связь более 3 минут.", ip))
//			bot.Send(msg)
//		}
//		rows.Close()
//	}
//}

func main() {
	loadConfig()
	initDB()

	http.HandleFunc("/api/sync", authMw(handleSync))
	http.HandleFunc("/api/stats", authMw(handleStats))
	http.HandleFunc("/api/ban", authMw(handleBan))
	http.HandleFunc("/api/register", authMw(handleRegister))
	http.HandleFunc("/sub/", handleSub)
	http.Handle("/download/", http.StripPrefix("/download/", http.FileServer(http.Dir("/etc/orchestrator/bin"))))

	go func() {
		log.Println("Master API server starting on :8080")
		if err := http.ListenAndServe("127.0.0.1:8080", nil); err != nil {
			log.Fatalf("HTTP server failed: %v", err)
		}
	}()

	if cfg.Token != "" {
		bot, err := tgbotapi.NewBotAPI(cfg.Token)
		if err != nil {
			log.Printf("Failed to initialize Telegram bot: %v", err)
			select {}
		}

		//go monitorNodes(bot)

		u := tgbotapi.NewUpdate(0)
		u.Timeout = 60
		updates := bot.GetUpdatesChan(u)

		mainKB := tgbotapi.NewReplyKeyboard(
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("📊 Статус"), tgbotapi.NewKeyboardButton("👥 Юзеры")),
			tgbotapi.NewKeyboardButtonRow(tgbotapi.NewKeyboardButton("🎫 Инвайты"), tgbotapi.NewKeyboardButton("⚙ Управление кластером")),
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
				} else if strings.HasPrefix(data, "new_inv") {
					limit := 5
					if data == "new_inv_0" {
						limit = 0
					}
					b := make([]byte, 4)
					rand.Read(b)
					code := "INV-" + strings.ToUpper(hex.EncodeToString(b))
					db.Exec("INSERT INTO invites (code, ip_limit) VALUES (?, ?)", code, limit)

					limTxt := "5 устройств"
					if limit == 0 {
						limTxt = "Безлимит"
					}
					msg := tgbotapi.NewMessage(chatID, fmt.Sprintf("✅ Новый Инвайт (%s): %s\n🔗 Перешли юзеру:\nhttps://t.me/%s?start=%s", limTxt, code, bot.Self.UserName, code))
					bot.Send(msg)
					bot.Request(tgbotapi.NewCallback(update.CallbackQuery.ID, "Создано!"))
				} else if data == "backup" {
					exec.Command("sqlite3", "/etc/orchestrator/core.db", ".backup '/tmp/backup.db'").Run()
					doc := tgbotapi.NewDocument(chatID, tgbotapi.FilePath("/tmp/backup.db"))
					bot.Send(doc)
					os.Remove("/tmp/backup.db")
					bot.Request(tgbotapi.NewCallback(update.CallbackQuery.ID, "Отправлено!"))
				} else if data == "reboot" {
					bot.Send(tgbotapi.NewMessage(chatID, "⏳ Перезагружаю Xray на всех узлах..."))
					ips, err := db.Query("SELECT ip FROM bridges UNION SELECT ip FROM exits")
					if err == nil {
						for ips.Next() {
							var ip string
							ips.Scan(&ip)
							if ip != "127.0.0.1" && ip != cfg.MasterIP {
								exec.Command("ssh", "-i", "/root/.ssh/vpn_cluster_key", "-o", "StrictHostKeyChecking=no", "root@"+ip, "systemctl restart xray").Run()
							}
						}
						ips.Close()
					}
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

			if update.Message == nil {
				continue
			}

			txt := update.Message.Text
			chatID := update.Message.Chat.ID
			isAdmin := fmt.Sprintf("%d", chatID) == cfg.ChatID

			var userUUID, userName string
			err := db.QueryRow("SELECT uuid, name FROM users WHERE chat_id=?", fmt.Sprintf("%d", chatID)).Scan(&userUUID, &userName)
			isUser := (err == nil && userUUID != "")

			if isAdmin {
				msg := tgbotapi.NewMessage(chatID, "")
				if txt == "/start" || txt == "/menu" {
					msg.Text = "🧠 Master API v17.0 Final"
					msg.ReplyMarkup = mainKB
				} else if txt == "📊 Статус" {
					var bC, eC int
					db.QueryRow("SELECT COUNT(*) FROM bridges WHERE last_seen > datetime('now', '-5 minute')").Scan(&bC)
					db.QueryRow("SELECT COUNT(*) FROM exits").Scan(&eC)
					var sni, warp string
					db.QueryRow("SELECT val FROM settings WHERE key='sni'").Scan(&sni)
					db.QueryRow("SELECT val FROM settings WHERE key='warp_domains'").Scan(&warp)

					msg.Text = fmt.Sprintf("🌐 Инфраструктура:\n\n🇷🇺 Активных мостов: %d\n🇪🇺 EU-нод: %d\n\n🎭 SNI: %s\n🚀 WARP: %s", bC, eC, sni, warp)
				} else if txt == "🎫 Инвайты" {
					rows, err := db.Query("SELECT code, IFNULL(ip_limit, 5) FROM invites")
					var btns [][]tgbotapi.InlineKeyboardButton
					count := 0
					if err == nil {
						for rows.Next() {
							count++
							var c string
							var l int
							rows.Scan(&c, &l)
							btns = append(btns, tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData(fmt.Sprintf("❌ Уд. %s (Lim: %d)", c, l), "del_inv:"+c)))
						}
						rows.Close()
					}
					btns = append(btns, tgbotapi.NewInlineKeyboardRow(
						tgbotapi.NewInlineKeyboardButtonData("➕ Инвайт (5 IP)", "new_inv_5"),
						tgbotapi.NewInlineKeyboardButtonData("➕ Инвайт (Безлимит)", "new_inv_0"),
					))
					msg.Text = fmt.Sprintf("🎫 Активные инвайты: %d шт.\nНажми кнопку ниже, чтобы создать новый.", count)
					msg.ReplyMarkup = tgbotapi.InlineKeyboardMarkup{InlineKeyboard: btns}
				} else if txt == "👥 Юзеры" {
					rows, err := db.Query("SELECT uuid, name, traffic_down, expires_at, IFNULL(ip_limit, 5) FROM users")
					if err != nil {
						msg.Text = "❌ Ошибка чтения БД: " + err.Error()
					} else {
						count := 0
						for rows.Next() {
							count++
							var id, n string
							var d sql.NullInt64
							var exp sql.NullString
							var lim int
							rows.Scan(&id, &n, &d, &exp, &lim)

							down := int64(0)
							if d.Valid {
								down = d.Int64
							}
							expStr := "Безлимит"
							if exp.Valid && exp.String != "" {
								expStr = exp.String
							}
							limStr := "Безлимит"
							if lim > 0 {
								limStr = fmt.Sprintf("%d IP", lim)
							}

							uMsg := tgbotapi.NewMessage(chatID, fmt.Sprintf("👤 %s (%s)\n🔽 %.2f GB | ⏳ До: %s\n🔗 https://%s/sub/%s.html", n, limStr, float64(down)/1073741824, expStr, cfg.Domain, id))
							uMsg.ReplyMarkup = tgbotapi.NewInlineKeyboardMarkup(
								tgbotapi.NewInlineKeyboardRow(
									tgbotapi.NewInlineKeyboardButtonData("⏳ +30 дней", "add_30d:"+id),
									tgbotapi.NewInlineKeyboardButtonData("❌ Удалить", "del_usr:"+id),
								),
							)
							bot.Send(uMsg)
						}
						rows.Close()
						if count == 0 {
							msg.Text = "🤷‍♂️ Пока нет ни одного пользователя."
						}
					}
				} else if txt == "⚙ Управление кластером" {
					msg.Text = "🛠 Настройки и обслуживание:"
					msg.ReplyMarkup = tgbotapi.NewInlineKeyboardMarkup(
						tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData("📦 Бекап БД", "backup")),
						tgbotapi.NewInlineKeyboardRow(tgbotapi.NewInlineKeyboardButtonData("🔄 Ребутнуть узлы", "reboot")),
					)
				}
				if msg.Text != "" {
					bot.Send(msg)
				}
			}

			if isUser && !isAdmin {
				msg := tgbotapi.NewMessage(chatID, "")
				if txt == "/start" || txt == "/menu" {
					msg.Text = "👋 Привет, " + userName + "!\nИспользуй кнопки ниже."
					msg.ReplyMarkup = userKB
				} else if txt == "🌍 Моя ссылка" {
					msg.Text = fmt.Sprintf("🔗 Твоя ссылка:\nhttps://%s/sub/%s.html", cfg.Domain, userUUID)
				} else if txt == "📊 Мой статус" {
					var d, u sql.NullInt64
					var exp sql.NullString
					db.QueryRow("SELECT traffic_down, traffic_up, expires_at FROM users WHERE uuid=?", userUUID).Scan(&d, &u, &exp)

					down := int64(0)
					if d.Valid {
						down = d.Int64
					}
					up := int64(0)
					if u.Valid {
						up = u.Int64
					}
					expStr := "Безлимит"
					if exp.Valid && exp.String != "" {
						expStr = exp.String
					}
					msg.Text = fmt.Sprintf("📊 Твоя статистика:\n🔽 Скачано: %.2f GB\n🔼 Загружено: %.2f GB\n⏳ До: %s", float64(down)/1073741824, float64(up)/1073741824, expStr)
				}
				if msg.Text != "" {
					bot.Send(msg)
				}
			}

			if strings.HasPrefix(txt, "/start INV-") {
				code := strings.TrimPrefix(txt, "/start ")
				var lim int
				if db.QueryRow("SELECT IFNULL(ip_limit, 5) FROM invites WHERE code=?", code).Scan(&lim) == nil {
					b := make([]byte, 16)
					rand.Read(b)
					b[6] = (b[6] & 0x0f) | 0x40
					b[8] = (b[8] & 0x3f) | 0x80
					uuid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])

					name := update.Message.From.UserName
					if name == "" {
						name = update.Message.From.FirstName
					}
					name = strings.ReplaceAll(name, " ", "")
					if name == "" {
						name = fmt.Sprintf("user%d", chatID)
					}

					if lim == 0 {
						db.Exec("INSERT INTO users (uuid, name, chat_id, ip_limit, expires_at) VALUES (?, ?, ?, ?, NULL)", uuid, name, fmt.Sprintf("%d", chatID), lim)
					} else {
						db.Exec("INSERT INTO users (uuid, name, chat_id, ip_limit) VALUES (?, ?, ?, ?)", uuid, name, fmt.Sprintf("%d", chatID), lim)
					}

					db.Exec("DELETE FROM invites WHERE code=?", code)

					msgText := fmt.Sprintf("✅ Профиль создан! Тебе дано 30 дней.\n\n👇 Ссылка:\nhttps://%s/sub/%s.html", cfg.Domain, uuid)
					if lim == 0 {
						msgText = fmt.Sprintf("✅ Профиль создан! Доступ безлимитный.\n\n👇 Ссылка:\nhttps://%s/sub/%s.html", cfg.Domain, uuid)
					}
					
					msg := tgbotapi.NewMessage(chatID, msgText)
					if !isAdmin {
						msg.ReplyMarkup = userKB
					}
					bot.Send(msg)
				}
			}
		}
	} else {
		select {}
	}
}