package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"

	proxyman "github.com/xtls/xray-core/app/proxyman/command"
	stats "github.com/xtls/xray-core/app/stats/command"
	"github.com/xtls/xray-core/common/protocol"
	"github.com/xtls/xray-core/common/serial"
	"github.com/xtls/xray-core/proxy/vless"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"
)

var (
	masterURL, token, role, lastHash string
	knownUsers                       = make(map[string]string)
	userLimits                       = make(map[string]int) // Хранит лимит для каждого email (0 = безлимит)
	limitsMu                         sync.RWMutex

	activeIPs   = make(map[string]map[string]time.Time)
	activeIPsMu sync.Mutex // Мьютекс для защиты activeIPs от состояния гонки
)

type State struct {
	BridgeUUID  string                   `json:"bridge_uuid"`
	SNI         string                   `json:"sni"`
	WarpDomains string                   `json:"warp_domains"`
	Users       []map[string]interface{} `json:"users"`
	Exits       []map[string]string      `json:"exits"`
}

func syncWithMaster() {
	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", masterURL+"/api/sync", nil)
	if err != nil {
		log.Println("Error creating sync request:", err)
		return
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("X-Node-IP", "PING")

	resp, err := client.Do(req)
	if err != nil || resp.StatusCode != 200 {
		return
	}
	defer resp.Body.Close()

	var state State
	if err := json.NewDecoder(resp.Body).Decode(&state); err != nil {
		log.Println("Error decoding state:", err)
		return
	}

	eJSON, _ := json.Marshal(state.Exits)
	cHash := fmt.Sprintf("%x", sha256.Sum256([]byte(string(eJSON)+state.SNI+state.WarpDomains)))

	newLimits := make(map[string]int)
	for _, u := range state.Users {
		email := u["email"].(string)
		if limit, ok := u["ip_limit"].(float64); ok {
			newLimits[email] = int(limit)
		} else {
			newLimits[email] = 5
		}
	}

	limitsMu.Lock()
	userLimits = newLimits
	limitsMu.Unlock()

	if cHash != lastHash {
		if role == "eu" {
			buildEUConfigSafe(state)
		} else {
			buildRUConfigSafe(state)
		}
		lastHash = cHash
		knownUsers = make(map[string]string)
		for _, u := range state.Users {
			knownUsers[u["uuid"].(string)] = u["email"].(string)
		}
		return
	}

	if role == "ru" {
		newKnown := make(map[string]string)
		for _, u := range state.Users {
			id, mail := u["uuid"].(string), u["email"].(string)
			newKnown[id] = mail
			if _, ok := knownUsers[id]; !ok {
				alterUserXray(id, mail, false)
			}
		}
		for uuid, email := range knownUsers {
			if _, ok := newKnown[uuid]; !ok {
				alterUserXray(uuid, email, true)
			}
		}
		knownUsers = newKnown
	}
}

func buildEUConfigSafe(state State) {
	keys, err := os.ReadFile("/usr/local/etc/xray/agent_keys.txt")
	if err != nil {
		log.Println("Failed to read agent keys:", err)
		return
	}

	p := strings.Split(strings.TrimSpace(string(keys)), "|")
	if len(p) < 3 {
		log.Println("Invalid keys format")
		return
	}
	pk, ss, xp := p[0], p[1], p[2]

	mySNI := state.SNI
	for _, e := range state.Exits {
		if e["xhttp_path"] == xp && e["sni"] != "" {
			mySNI = e["sni"]
			break
		}
	}

	var parsedWarpDomains []string
	for _, d := range strings.Split(state.WarpDomains, ",") {
		parsedWarpDomains = append(parsedWarpDomains, strings.Trim(d, `"`))
	}

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
	if err := os.WriteFile("/usr/local/etc/xray/config.json", jsonData, 0644); err != nil {
		log.Println("Failed to write EU config:", err)
		return
	}
	if err := exec.Command("systemctl", "restart", "xray").Run(); err != nil {
		log.Println("Failed to restart xray:", err)
	}
}

func buildRUConfigSafe(state State) {
	keys, err := os.ReadFile("/usr/local/etc/xray/agent_keys.txt")
	if err != nil {
		log.Println("Failed to read agent keys:", err)
		return
	}

	p := strings.Split(strings.TrimSpace(string(keys)), "|")
	mode, pk, sid, tlsDomain := "reality", "", "", ""
	if len(p) >= 2 && p[0] == "tls" {
		mode, tlsDomain = "tls", p[1]
	} else if len(p) >= 2 {
		pk, sid = p[0], p[1]
	}

	var clients []map[string]interface{}
	var xhClients []map[string]interface{}
	for _, u := range state.Users {
		clients = append(clients, map[string]interface{}{"id": u["uuid"], "email": u["email"], "flow": "xtls-rprx-vision"})
		xhClients = append(xhClients, map[string]interface{}{"id": u["uuid"], "email": u["email"]})
	}

	var outbounds []map[string]interface{}
	var balancers []string
	for _, e := range state.Exits {
		ip, pub, ss, xp, nodeSNI := e["ip"], e["pub_key"], e["ss_pass"], e["xhttp_path"], e["sni"]
		if nodeSNI == "" {
			nodeSNI = state.SNI
		}
		outbounds = append(outbounds, map[string]interface{}{
			"tag":      fmt.Sprintf("eu-tcp-%s", ip),
			"protocol": "vless",
			"settings": map[string]interface{}{"vnext": []map[string]interface{}{{"address": ip, "port": 443, "users": []map[string]interface{}{{"id": state.BridgeUUID, "flow": "xtls-rprx-vision", "encryption": "none"}}}}},
			"streamSettings": map[string]interface{}{"network": "tcp", "security": "reality", "realitySettings": map[string]interface{}{"serverName": nodeSNI, "publicKey": pub, "fingerprint": "chrome"}},
		})
		outbounds = append(outbounds, map[string]interface{}{
			"tag":      fmt.Sprintf("eu-xh-%s", ip),
			"protocol": "vless",
			"settings": map[string]interface{}{"vnext": []map[string]interface{}{{"address": ip, "port": 4433, "users": []map[string]interface{}{{"id": state.BridgeUUID, "encryption": "none"}}}}},
			"streamSettings": map[string]interface{}{"network": "xhttp", "security": "reality", "xhttpSettings": map[string]interface{}{"path": "/" + xp, "mode": "auto"}, "realitySettings": map[string]interface{}{"serverName": nodeSNI, "publicKey": pub, "fingerprint": "chrome"}},
		})
		outbounds = append(outbounds, map[string]interface{}{
			"tag":      fmt.Sprintf("eu-ss-%s", ip),
			"protocol": "shadowsocks",
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
		"inbounds":  inbounds,
		"outbounds": outbounds,
		"observatory": map[string]interface{}{"subjectSelector": balancers, "probeUrl": "https://www.google.com/generate_204", "probeInterval": "1m", "enableConcurrency": true},
		"routing": map[string]interface{}{
			"domainStrategy": "IPIfNonMatch",
			"balancers":      []map[string]interface{}{{"tag": "eu-balancer", "selector": balancers, "strategy": map[string]interface{}{"type": "leastPing"}}},
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
	if err := os.WriteFile("/usr/local/etc/xray/config.json", jsonData, 0644); err != nil {
		log.Println("Failed to write RU config:", err)
		return
	}
	if err := exec.Command("systemctl", "restart", "xray").Run(); err != nil {
		log.Println("Failed to restart xray:", err)
	}
}

func monitorIPLimits() {
	if role != "ru" {
		return
	}

	emailRegex := regexp.MustCompile(`email:\s*([^ ]+)`)
	ipRegex := regexp.MustCompile(`from\s+([0-9\.]+):`)

	go func() {
		time.Sleep(5 * time.Second)
		logPath := "/var/log/xray/access.log"
		var file *os.File
		var reader *bufio.Reader
		var err error

		openLog := func() {
			for {
				file, err = os.Open(logPath)
				if err == nil {
					file.Seek(0, io.SeekEnd)
					reader = bufio.NewReader(file)
					return
				}
				time.Sleep(5 * time.Second)
			}
		}

		openLog()

		for {
			line, err := reader.ReadString('\n')
			if err != nil {
				if err == io.EOF {
					info, statErr := os.Stat(logPath)
					if statErr == nil {
						currentPos, _ := file.Seek(0, io.SeekCurrent)
						if info.Size() < currentPos {
							file.Close()
							openLog()
							continue
						}
					}
					time.Sleep(500 * time.Millisecond)
					continue
				}
				file.Close()
				openLog()
				continue
			}

			if strings.Contains(line, "accepted") {
				eMatch := emailRegex.FindStringSubmatch(line)
				iMatch := ipRegex.FindStringSubmatch(line)
				if len(eMatch) > 1 && len(iMatch) > 1 {
					email := strings.TrimSpace(eMatch[1])
					ip := strings.TrimSpace(iMatch[1])

					activeIPsMu.Lock()
					if activeIPs[email] == nil {
						activeIPs[email] = make(map[string]time.Time)
					}
					activeIPs[email][ip] = time.Now()
					activeIPsMu.Unlock()
				}
			}
		}
	}()

	go func() {
		for {
			time.Sleep(1 * time.Minute)
			now := time.Now()

			activeIPsMu.Lock()
			for email, ips := range activeIPs {
				for ip, lastSeen := range ips {
					if now.Sub(lastSeen) > 5*time.Minute {
						delete(ips, ip)
					}
				}

				limitsMu.RLock()
				limit := userLimits[email]
				limitsMu.RUnlock()

				if limit > 0 && len(ips) > limit {
					uuid := knownUsers[email]

					go func(u, e string) {
						alterUserXray(u, e, true)
						http.Get(fmt.Sprintf("%s/api/ban?email=%s", masterURL, e))
					}(uuid, email)

					delete(activeIPs, email)
				}
			}
			activeIPsMu.Unlock()
		}
	}()
}

func alterUserXray(uuid, email string, remove bool) {
	conn, err := grpc.NewClient("127.0.0.1:10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Println("Failed to connect to gRPC:", err)
		return
	}
	defer conn.Close()

	c := proxyman.NewHandlerServiceClient(conn)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if remove {
		_, err = c.AlterInbound(ctx, &proxyman.AlterInboundRequest{Tag: "client-in", Operation: serial.ToTypedMessage(&proxyman.RemoveUserOperation{Email: email})})
		if err != nil {
			log.Println("AlterInbound remove client-in error:", err)
		}

		_, err = c.AlterInbound(ctx, &proxyman.AlterInboundRequest{Tag: "client-xh", Operation: serial.ToTypedMessage(&proxyman.RemoveUserOperation{Email: email})})
		if err != nil {
			log.Println("AlterInbound remove client-xh error:", err)
		}
	} else {
		_, err = c.AlterInbound(ctx, &proxyman.AlterInboundRequest{Tag: "client-in", Operation: serial.ToTypedMessage(&proxyman.AddUserOperation{User: &protocol.User{Level: 0, Email: email, Account: serial.ToTypedMessage(&vless.Account{Id: uuid, Flow: "xtls-rprx-vision"})}})})
		if err != nil {
			log.Println("AlterInbound add client-in error:", err)
		}

		_, err = c.AlterInbound(ctx, &proxyman.AlterInboundRequest{Tag: "client-xh", Operation: serial.ToTypedMessage(&proxyman.AddUserOperation{User: &protocol.User{Level: 0, Email: email, Account: serial.ToTypedMessage(&vless.Account{Id: uuid})}})})
		if err != nil {
			log.Println("AlterInbound add client-xh error:", err)
		}
	}
}

func sendStats() {
	if role == "eu" {
		return
	}

	conn, err := grpc.NewClient("127.0.0.1:10085", grpc.WithTransportCredentials(insecure.NewCredentials()))
	if err != nil {
		log.Println("Failed to connect to gRPC for stats:", err)
		return
	}
	defer conn.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	resp, err := stats.NewStatsServiceClient(conn).QueryStats(ctx, &stats.QueryStatsRequest{Pattern: "user>>>", Reset: true})
	if err != nil {
		log.Println("QueryStats error:", err)
		return
	}

	aggr := make(map[string]map[string]int64)
	for _, s := range resp.Stat {
		p := strings.Split(s.Name, ">>>")
		if len(p) == 4 {
			e, t, v := p[1], p[3], s.Value
			if aggr[e] == nil {
				aggr[e] = make(map[string]int64)
			}
			if t == "downlink" {
				aggr[e]["down"] += v
			} else {
				aggr[e]["up"] += v
			}
		}
	}

	var pl []map[string]interface{}
	for e, d := range aggr {
		pl = append(pl, map[string]interface{}{"email": e, "up": d["up"], "down": d["down"]})
	}

	if len(pl) > 0 {
		b, _ := json.Marshal(pl)
		client := &http.Client{Timeout: 10 * time.Second}
		req, err := http.NewRequest("POST", masterURL+"/api/stats", bytes.NewBuffer(b))
		if err != nil {
			log.Println("Failed to create stats request:", err)
			return
		}
		req.Header.Set("Authorization", "Bearer "+token)

		httpResp, err := client.Do(req)
		if err != nil {
			log.Println("Failed to send stats:", err)
			return
		}
		httpResp.Body.Close()
	}
}

func main() {
	flag.StringVar(&masterURL, "master", "", "")
	flag.StringVar(&token, "token", "", "")
	flag.StringVar(&role, "role", "ru", "")
	flag.Parse()

	monitorIPLimits()

	for {
		syncWithMaster()
		sendStats()
		time.Sleep(30 * time.Second)
	}
}