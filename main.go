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

// --- 1. ИНИЦИАЛИЗАЦИЯ БАЗЫ ДАННЫХ ---
func initDB() {
	var err error
	// Файл БД будет лежать рядом с бинарником или в /etc/master-core/
	db, err = sql.Open("sqlite", "/root/master_core.db")
	if err != nil { log.Fatal(err) }

	db.Exec(`CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT, internal_ip TEXT, public_ip TEXT, public_domain TEXT, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, username TEXT, chat_id INTEGER, traffic_limit_gb INTEGER DEFAULT 0, expire_at DATETIME, max_ips INTEGER DEFAULT 3, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS user_ips (uuid TEXT, ip_address TEXT, last_seen DATETIME, PRIMARY KEY (uuid, ip_address))`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, target_name TEXT, created_at DATETIME)`)
}

// --- 2. ВЕБ-СЕРВЕР (ПОДПИСКИ И ЛИМИТЫ) ---
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

	// Анти-складчина
	db.Exec(`INSERT INTO user_ips (uuid, ip_address, last_seen) VALUES (?, ?, ?) ON CONFLICT(uuid, ip_address) DO UPDATE SET last_seen = ?`, uuid, clientIP, now, now)
	db.Exec(`DELETE FROM user_ips WHERE last_seen < ?`, now.Add(-24*time.Hour))
	
	var ipCount int
	db.QueryRow(`SELECT COUNT(*) FROM user_ips WHERE uuid = ?`, uuid).Scan(&ipCount)
	if ipCount > maxIPs {
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_ПРЕВЫШЕН_ЛИМИТ_УСТРОЙСТВ_(%d_из_%d)", uuid, ipCount, maxIPs)))))
		return
	}

	// Генерация ссылок из живых нод
	rows, _ := db.Query(`SELECT public_ip, public_domain FROM nodes WHERE role = 'ru_bridge' AND status = 'active'`)
	defer rows.Close()
	var links []string
	for rows.Next() {
		var ip, domain string
		rows.Scan(&ip, &domain)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=%s#🇷🇺_RU-Мост_(%s)", uuid, ip, domain, domain))
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=vk.com&allowInsecure=1#🛡_Обход_Вайтлиста", uuid, ip))
	}
	
	if len(links) == 0 {
		links = append(links, fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_НЕТ_ДОСТУПНЫХ_СЕРВЕРОВ", uuid))
	}
	
	w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
}

func startHTTPServer() {
	http.HandleFunc("/sub/", handleSub)
	log.Println("🌍 HTTP-сервер подписок запущен на порту 8080...")
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", nil))
}

// --- 3. gRPC УПРАВЛЕНИЕ УЗЛАМИ (HOT RELOAD) ---
func addClientToNode(nodeIP, uuid, email string) error {
	conn, err := grpc.Dial(nodeIP+":10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil { return err }
	defer conn.Close()

	client := proxymancommand.NewHandlerServiceClient(conn)
	vlessAccount := &vless.Account{Id: uuid, Flow: "xtls-rprx-vision"}
	accountExt, err := serial.ToTypedMessage(vlessAccount)
	if err != nil { return err }

	user := &protocol.User{Level: 0, Email: email, Account: accountExt}
	op := &proxymancommand.AddUserOperation{User: user}
	opExt, err := serial.ToTypedMessage(op)
	if err != nil { return err }

	req := &proxymancommand.AlterInboundRequest{Tag: "client-in", Operation: opExt}
	_, err = client.AlterInbound(context.Background(), req)
	return err
}

// --- 4. ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ---
func genInviteCode() string {
	b := make([]byte, 4); rand.Read(b)
	return "INV-" + strings.ToUpper(hex.EncodeToString(b))
}

func genUUID() string {
	b := make([]byte, 16); rand.Read(b)
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// --- 5. ОСНОВНОЙ ПРОЦЕСС (ТЕЛЕГРАМ БОТ) ---
func main() {
	initDB()
	defer db.Close()

	// Загрузка конфига
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

	if token == "" { log.Fatal("❌ Токен Telegram не найден. Настройте /root/.vpn_tg.conf") }

	// Запускаем веб-сервер в фоне
	go startHTTPServer()

	bot, err := tgbotapi.NewBotAPI(token)
	if err != nil { log.Panic(err) }
	log.Printf("🤖 Бот авторизован как %s", bot.Self.UserName)

	u := tgbotapi.NewUpdate(0)
	u.Timeout = 60
	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		if update.Message == nil { continue }
		chatID := update.Message.Chat.ID
		text := update.Message.Text
		isAdmin := chatID == adminChatID

		// Админ: Создание инвайта
		if isAdmin && text == "/invite" {
			code := genInviteCode()
			db.Exec(`INSERT INTO invites (code, target_name, created_at) VALUES (?, ?, ?)`, code, "NewUser", time.Now())
			bot.Send(tgbotapi.NewMessage(chatID, "✅ Инвайт создан: `"+code+"`\n\nДля активации юзер должен отправить боту команду:\n`/start "+code+"`"))
			continue
		}

		// Юзер: Активация инвайта
		if strings.HasPrefix(text, "/start INV-") {
			code := strings.TrimSpace(strings.TrimPrefix(text, "/start "))
			var targetName string
			err := db.QueryRow(`SELECT target_name FROM invites WHERE code = ?`, code).Scan(&targetName)
			
			if err == sql.ErrNoRows {
				bot.Send(tgbotapi.NewMessage(chatID, "❌ Код недействителен или уже использован."))
				continue
			}

			newUUID := genUUID()
			db.Exec(`INSERT INTO users (uuid, username, chat_id) VALUES (?, ?, ?)`, newUUID, targetName, chatID)
			db.Exec(`DELETE FROM invites WHERE code = ?`, code)

			// Пуш на все рабочие мосты
			rows, _ := db.Query(`SELECT internal_ip FROM nodes WHERE status = 'active'`)
			successCount := 0
			for rows.Next() {
				var nodeIP string
				rows.Scan(&nodeIP)
				if err := addClientToNode(nodeIP, newUUID, targetName); err != nil {
					log.Printf("⚠️ Ошибка gRPC пуша на ноду %s: %v", nodeIP, err)
				} else {
					successCount++
				}
			}
			rows.Close()

			bot.Send(tgbotapi.NewMessage(chatID, fmt.Sprintf("✅ Профиль создан!\nУспешно синхронизировано с узлами: %d\n\n🌍 Ваша подписка (добавьте в приложение):\n`https://sub.ваша-сеть.com/sub/%s`", successCount, newUUID)))
		}
	}
}
