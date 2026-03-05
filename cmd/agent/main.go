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