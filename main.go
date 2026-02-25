package main

import (
	"database/sql"
	"encoding/base64"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"time"

	_ "modernc.org/sqlite" // Pure Go драйвер SQLite (не требует CGO!)
)

var db *sql.DB

func initDB() {
	var err error
	// Открываем базу (создастся файл master_core.db)
	db, err = sql.Open("sqlite", "./master_core.db")
	if err != nil { log.Fatal(err) }

	// 1. Таблица Инфраструктуры (Наши серверы)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS nodes (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		role TEXT,             -- 'ru_bridge' или 'eu_exit'
		internal_ip TEXT,      -- 10.0.0.x (Tailscale для управления)
		public_ip TEXT,        -- Внешний IP
		public_domain TEXT,    -- SNI Домен
		status TEXT DEFAULT 'active' -- 'active' или 'dead'
	)`)
	if err != nil { log.Fatal(err) }

	// 2. Таблица Пользователей
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS users (
		uuid TEXT PRIMARY KEY,
		username TEXT,
		bytes_up INTEGER DEFAULT 0,
		bytes_down INTEGER DEFAULT 0,
		traffic_limit_gb INTEGER DEFAULT 0,
		expire_at DATETIME,
		max_ips INTEGER DEFAULT 3,   -- Лимит устройств (IP) за 24 часа
		status TEXT DEFAULT 'active' -- 'active', 'expired', 'banned'
	)`)
	if err != nil { log.Fatal(err) }

	// 3. Таблица учета IP-адресов (Анти-складчина)
	_, err = db.Exec(`CREATE TABLE IF NOT EXISTS user_ips (
		uuid TEXT,
		ip_address TEXT,
		last_seen DATETIME,
		PRIMARY KEY (uuid, ip_address)
	)`)
	if err != nil { log.Fatal(err) }
}

// Получаем реальный IP клиента (даже если он за Nginx или Cloudflare)
func getClientIP(r *http.Request) string {
	ip := r.Header.Get("X-Forwarded-For")
	if ip == "" { ip = r.Header.Get("X-Real-IP") }
	if ip == "" { ip, _, _ = net.SplitHostPort(r.RemoteAddr) }
	return strings.Split(ip, ",")[0]
}

// Обработчик подписок
func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	if len(uuid) != 36 {
		http.Error(w, "Invalid UUID", http.StatusBadRequest)
		return
	}

	clientIP := getClientIP(r)
	now := time.Now()

	// 1. Проверяем статус пользователя
	var username, status string
	var expireAt time.Time
	var maxIPs int
	err := db.QueryRow(`SELECT username, status, expire_at, max_ips FROM users WHERE uuid = ?`, uuid).Scan(&username, &status, &expireAt, &maxIPs)
	
	if err == sql.ErrNoRows {
		http.Error(w, "User not found", http.StatusNotFound)
		return
	}

	if status != "active" || (expireAt.Before(now) && !expireAt.IsZero()) {
		// Выдаем заглушку, если забанен или истек срок
		dummy := fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#❌_АККАУНТ_НЕАКТИВЕН", uuid)
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(dummy))))
		return
	}

	// 2. АНТИ-НАХЛЕБНИК (HWID / IP Tracking)
	// Обновляем время активности этого IP
	db.Exec(`INSERT INTO user_ips (uuid, ip_address, last_seen) VALUES (?, ?, ?) 
			 ON CONFLICT(uuid, ip_address) DO UPDATE SET last_seen = ?`, uuid, clientIP, now, now)

	// Очищаем старые IP (старше 24 часов)
	db.Exec(`DELETE FROM user_ips WHERE last_seen < ?`, now.Add(-24*time.Hour))

	// Считаем уникальные IP за сутки
	var ipCount int
	db.QueryRow(`SELECT COUNT(*) FROM user_ips WHERE uuid = ?`, uuid).Scan(&ipCount)

	if ipCount > maxIPs {
		// Превышен лимит устройств!
		dummy := fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_ПРЕВЫШЕН_ЛИМИТ_УСТРОЙСТВ_(%d_из_%d)", uuid, ipCount, maxIPs)
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(dummy))))
		return
	}

	// 3. ГЕНЕРАЦИЯ ДИНАМИЧЕСКИХ ССЫЛОК (Из живых RU-мостов)
	rows, err := db.Query(`SELECT public_ip, public_domain FROM nodes WHERE role = 'ru_bridge' AND status = 'active'`)
	if err != nil { log.Println(err) }
	defer rows.Close()

	var links []string
	for rows.Next() {
		var ip, domain string
		rows.Scan(&ip, &domain)

		// Стандартный линк (Надежный, для дома и обычного интернета)
		stdLink := fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=%s#🇷🇺_RU-Мост_(%s)", uuid, ip, domain, domain)
		links = append(links, stdLink)

		// Линк для обхода "Белых списков" (Вайтлистов) мобильных операторов
		// Используем популярный SNI (например, vk.com) и отключаем проверку сертификата (allowInsecure=1)
		wlLink := fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=vk.com&allowInsecure=1#🛡_Обход_Вайтлиста_(%s)", uuid, ip, domain)
		links = append(links, wlLink)
	}

	if len(links) == 0 {
		links = append(links, fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_НЕТ_ДОСТУПНЫХ_СЕРВЕРОВ", uuid))
	}

	// Отдаем клиенту финальный Base64
	finalData := strings.Join(links, "\n")
	w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(finalData))))
}

func main() {
	initDB()
	defer db.Close()

	http.HandleFunc("/sub/", handleSub)
	
	fmt.Println("👑 Master Node Core API запущен на порту 8080...")
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", nil))
}

package main

import (
	"bufio"
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
)

var db *sql.DB
var adminChatID int64

// --- 1. ИНИЦИАЛИЗАЦИЯ БАЗЫ ДАННЫХ ---
func initDB() {
	var err error
	db, err = sql.Open("sqlite", "/usr/local/etc/xray/master_core.db")
	if err != nil { log.Fatal(err) }

	db.Exec(`CREATE TABLE IF NOT EXISTS nodes (id INTEGER PRIMARY KEY AUTOINCREMENT, role TEXT, internal_ip TEXT, public_ip TEXT, public_domain TEXT, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS users (uuid TEXT PRIMARY KEY, username TEXT, chat_id INTEGER, traffic_limit_gb INTEGER DEFAULT 0, expire_at DATETIME, max_ips INTEGER DEFAULT 3, status TEXT DEFAULT 'active')`)
	db.Exec(`CREATE TABLE IF NOT EXISTS user_ips (uuid TEXT, ip_address TEXT, last_seen DATETIME, PRIMARY KEY (uuid, ip_address))`)
	db.Exec(`CREATE TABLE IF NOT EXISTS invites (code TEXT PRIMARY KEY, target_name TEXT, created_at DATETIME)`)
}

// --- 2. HTTP СЕРВЕР (ВЫДАЧА ПОДПИСОК) ---
func getClientIP(r *http.Request) string {
	ip := r.Header.Get("X-Forwarded-For")
	if ip == "" { ip = r.Header.Get("X-Real-IP") }
	if ip == "" { ip, _, _ = net.SplitHostPort(r.RemoteAddr) }
	return strings.Split(ip, ",")[0]
}

func handleSub(w http.ResponseWriter, r *http.Request) {
	uuid := strings.TrimPrefix(r.URL.Path, "/sub/")
	if len(uuid) != 36 { http.Error(w, "Invalid", http.StatusBadRequest); return }

	clientIP := getClientIP(r)
	now := time.Now()

	var status string
	var maxIPs int
	err := db.QueryRow(`SELECT status, max_ips FROM users WHERE uuid = ?`, uuid).Scan(&status, &maxIPs)
	if err == sql.ErrNoRows || status != "active" {
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#❌_АККАУНТ_НЕАКТИВЕН", uuid)))))
		return
	}

	// Анти-складчина (HWID)
	db.Exec(`INSERT INTO user_ips (uuid, ip_address, last_seen) VALUES (?, ?, ?) ON CONFLICT(uuid, ip_address) DO UPDATE SET last_seen = ?`, uuid, clientIP, now, now)
	db.Exec(`DELETE FROM user_ips WHERE last_seen < ?`, now.Add(-24*time.Hour))
	var ipCount int
	db.QueryRow(`SELECT COUNT(*) FROM user_ips WHERE uuid = ?`, uuid).Scan(&ipCount)
	if ipCount > maxIPs {
		w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(fmt.Sprintf("vless://%s@127.0.0.1:443?security=none#⚠️_ПРЕВЫШЕН_ЛИМИТ_УСТРОЙСТВ", uuid)))))
		return
	}

	// Генерация ссылок из базы
	rows, _ := db.Query(`SELECT public_ip, public_domain FROM nodes WHERE role = 'ru_bridge' AND status = 'active'`)
	defer rows.Close()
	var links []string
	for rows.Next() {
		var ip, domain string
		rows.Scan(&ip, &domain)
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=%s#🇷🇺_RU_(%s)", uuid, ip, domain, domain))
		links = append(links, fmt.Sprintf("vless://%s@%s:443?security=tls&encryption=none&type=tcp&flow=xtls-rprx-vision&fp=chrome&sni=vk.com&allowInsecure=1#🛡_Обход_Вайтлиста", uuid, ip))
	}
	w.Write([]byte(base64.StdEncoding.EncodeToString([]byte(strings.Join(links, "\n")))))
}

// Запуск HTTP в фоне
func startHTTPServer() {
	http.HandleFunc("/sub/", handleSub)
	log.Fatal(http.ListenAndServe("127.0.0.1:8080", nil))
}

// --- 3. TELEGRAM БОТ ---
func genInviteCode() string {
	b := make([]byte, 4); rand.Read(b)
	return "INV-" + strings.ToUpper(hex.EncodeToString(b))
}

func main() {
	initDB()
	defer db.Close()

	// Читаем конфиг токена
	var token string
	file, _ := os.Open("/root/.vpn_tg.conf")
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "TG_TOKEN=") { token = strings.Trim(strings.TrimPrefix(line, "TG_TOKEN="), "\"") }
		if strings.HasPrefix(line, "TG_CHAT_ID=") { adminChatID, _ = strconv.ParseInt(strings.Trim(strings.TrimPrefix(line, "TG_CHAT_ID="), "\""), 10, 64) }
	}
	file.Close()

	// ЗАПУСКАЕМ ВЕБ-СЕРВЕР ПАРАЛЛЕЛЬНО!
	go startHTTPServer()

	bot, err := tgbotapi.NewBotAPI(token)
	if err != nil { log.Panic(err) }

	u := tgbotapi.NewUpdate(0)
	u.Timeout = 60
	updates := bot.GetUpdatesChan(u)

	for update := range updates {
		if update.Message == nil { continue }
		chatID := update.Message.Chat.ID
		text := update.Message.Text
		isAdmin := chatID == adminChatID

		// Простая логика Админа (создание инвайта в базу SQLite)
		if isAdmin && text == "/invite" {
			code := genInviteCode()
			db.Exec(`INSERT INTO invites (code, target_name, created_at) VALUES (?, ?, ?)`, code, "NewUser", time.Now())
			bot.Send(tgbotapi.NewMessage(chatID, "✅ Инвайт создан: "+code))
			continue
		}

		// Логика Юзера (Активация инвайта)
		if strings.HasPrefix(text, "/start INV-") {
			code := strings.TrimSpace(strings.TrimPrefix(text, "/start "))
			var targetName string
			err := db.QueryRow(`SELECT target_name FROM invites WHERE code = ?`, code).Scan(&targetName)
			
			if err == sql.ErrNoRows {
				bot.Send(tgbotapi.NewMessage(chatID, "❌ Код недействителен."))
				continue
			}

			// Генерируем UUID и записываем в БД
			newUUID := "a1b2c3d4-e5f6-7890-1234-abcdef123456" // Позже заменим на реальную генерацию и пуш в gRPC
			db.Exec(`INSERT INTO users (uuid, username, chat_id) VALUES (?, ?, ?)`, newUUID, targetName, chatID)
			db.Exec(`DELETE FROM invites WHERE code = ?`, code) // Сжигаем инвайт

			bot.Send(tgbotapi.NewMessage(chatID, "✅ Профиль создан! Твоя подписка:\nhttps://sub.tvoy-domen.com/sub/"+newUUID))
		}
	}
}

// Добавляем новые импорты в блок import:
import (
	"context"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	proxymancommand "github.com/xtls/xray-core/app/proxyman/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
)

// --- 4. gRPC УПРАВЛЕНИЕ XRAY (Горячая замена) ---

// Функция внедрения пользователя в работающий мост
func addClientToNode(nodeIP, uuid, email string) error {
	// Подключаемся к API моста по внутреннему IP (Tailscale)
	conn, err := grpc.Dial(nodeIP+":10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil { return err }
	defer conn.Close()

	client := proxymancommand.NewHandlerServiceClient(conn)

	// Формируем профиль пользователя VLESS (Vision)
	vlessAccount := &vless.Account{
		Id:   uuid,
		Flow: "xtls-rprx-vision",
	}

	accountExt, err := serial.ToTypedMessage(vlessAccount)
	if err != nil { return err }

	user := &protocol.User{
		Level:   0,
		Email:   email, // Email используется в Xray как уникальный идентификатор (логин)
		Account: accountExt,
	}

	// Команда: "Добавить пользователя"
	op := &proxymancommand.AddUserOperation{
		User: user,
	}

	opExt, err := serial.ToTypedMessage(op)
	if err != nil { return err }

	// Отправляем команду во входящий поток с тегом "client-in"
	req := &proxymancommand.AlterInboundRequest{
		Tag:       "client-in", 
		Operation: opExt,
	}

	_, err = client.AlterInbound(context.Background(), req)
	return err
}

// Функция мгновенного отключения пользователя (например, при бане)
func removeClientFromNode(nodeIP, email string) error {
	conn, err := grpc.Dial(nodeIP+":10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil { return err }
	defer conn.Close()

	client := proxymancommand.NewHandlerServiceClient(conn)

	// Команда: "Удалить пользователя по Email"
	op := &proxymancommand.RemoveUserOperation{
		Email: email,
	}

	opExt, err := serial.ToTypedMessage(op)
	if err != nil { return err }

	req := &proxymancommand.AlterInboundRequest{
		Tag:       "client-in",
		Operation: opExt,
	}

	_, err = client.AlterInbound(context.Background(), req)
	return err
}

// 1. Генерируем реальный UUID
newUUID := runShell("/usr/local/bin/xray uuid") // Или используем Go-библиотеку google/uuid
newUUID = strings.TrimSpace(newUUID)

// 2. Записываем юзера в нашу SQLite базу
db.Exec(`INSERT INTO users (uuid, username, chat_id) VALUES (?, ?, ?)`, newUUID, targetName, chatID)

// 3. МАГИЯ КЛАСТЕРА: Пушим юзера на все живые рабочие мосты
rows, _ := db.Query(`SELECT internal_ip FROM nodes WHERE status = 'active'`)
defer rows.Close()

for rows.Next() {
	var nodeIP string
	rows.Scan(&nodeIP)
	
	// Внедряем "на горячую"
	err := addClientToNode(nodeIP, newUUID, targetName)
	if err != nil {
		log.Printf("⚠️ Ошибка пуша юзера %s на ноду %s: %v\n", targetName, nodeIP, err)
		// Здесь можно написать логику Retry (повтора) или алерт админу
	} else {
		log.Printf("✅ Юзер %s успешно добавлен на мост %s\n", targetName, nodeIP)
	}
}

// 4. Отправляем юзеру ссылку на его личную страницу (которую отдаст наш HTTP-сервер)
bot.Send(tgbotapi.NewMessage(chatID, "✅ Профиль создан! Твоя подписка:\nhttps://sub.твоя-сеть.com/sub/"+newUUID))

cd /usr/src/vpn-bot
# Инициализируем модуль
go mod init master-core
# Скачиваем библиотеки gRPC и Xray-core
go get google.golang.org/grpc
go get github.com/xtls/xray-core/app/proxyman/command
go get github.com/xtls/xray-core/common/protocol
go get github.com/xtls/xray-core/proxy/vless
# Подчищаем зависимости
go mod tidy
# Собираем монолит
go build -ldflags="-s -w" -o /usr/local/bin/master-core main.go
