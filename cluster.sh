#!/bin/bash
# ==============================================================================
# 🚀 VPN CLOUD NATIVE v17.0 (GitHub Release Edition)
# ==============================================================================

# ⚠️ ВПИШИ СЮДА СВОЙ РЕПОЗИТОРИЙ GITHUB:
REPO_URL="sud0-i/KVN-XRAY-CLUSTER"

export DEBIAN_FRONTEND=noninteractive
MASTER_IP=$(curl -s4 ifconfig.me)

install_deps() {
    echo "⏳ Проверка и установка пакетов ОС..."
    apt-get update -q >/dev/null 2>&1
    apt-get install -yq jq sqlite3 curl openssl nginx certbot python3-certbot-nginx ufw uuid-runtime fail2ban tar sshpass dnsutils iperf3 docker.io >/dev/null 2>&1
}

# (Здесь остаются старые функции без изменений: show_system_status, manage_mtproto, harden_system, create_backup, delete_node, verify_dns_propagation)
# ... [Для экономии места вставишь их из предыдущего скрипта] ...

update_cluster() {
    echo -e "\n🔄 БЕСШОВНОЕ ОБНОВЛЕНИЕ КЛАСТЕРА ИЗ GITHUB"
    
    echo "⏳ Скачиваю свежий релиз Мастера..."
    wget -q "https://github.com/${REPO_URL}/releases/latest/download/vpn-master" -O /tmp/vpn-master
    chmod +x /tmp/vpn-master
    mv /tmp/vpn-master /usr/local/bin/vpn-master
    systemctl restart vpn-master
    
    echo "⏳ Скачиваю свежий релиз Агента..."
    wget -q "https://github.com/${REPO_URL}/releases/latest/download/vpn-agent" -O /etc/orchestrator/bin/agent
    chmod +x /etc/orchestrator/bin/agent

    if [ -f /usr/local/bin/vpn-agent ]; then
        echo "⏳ Обновление локального моста..."
        systemctl stop vpn-agent
        cp /etc/orchestrator/bin/agent /usr/local/bin/vpn-agent
        systemctl start vpn-agent
    fi
    
    echo "⏳ Рассылка команды обновления на удаленные узлы..."
    for IP in $(sqlite3 /etc/orchestrator/core.db "SELECT ip FROM bridges WHERE ip != '127.0.0.1' AND ip != '$MASTER_IP' UNION SELECT ip FROM exits;"); do
        ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "systemctl stop vpn-agent && wget -q https://github.com/${REPO_URL}/releases/latest/download/vpn-agent -O /usr/local/bin/vpn-agent && chmod +x /usr/local/bin/vpn-agent && systemctl start vpn-agent" 2>/dev/null
        echo "✅ Узел $IP обновлен."
    done
    echo "🎉 Кластер успешно обновлен!"
}

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
        ssh-keygen -t ed25519 -f /root/.ssh/vpn_cluster_key -N "" -q
        chmod 600 /root/.ssh/vpn_cluster_key
    fi
    
    mkdir -p /etc/orchestrator/bin
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
    location / { return 404; }
}
EOF
    systemctl restart nginx

    echo "⏳ Скачивание бинарников из GitHub Releases..."
    wget -q "https://github.com/${REPO_URL}/releases/latest/download/vpn-master" -O /usr/local/bin/vpn-master
    wget -q "https://github.com/${REPO_URL}/releases/latest/download/vpn-agent" -O /etc/orchestrator/bin/agent
    chmod +x /usr/local/bin/vpn-master /etc/orchestrator/bin/agent

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
}

# Функция deploy_node остается прежней, но ВМЕСТО скачивания агента с мастера:
# wget -q https://$MASTER_DOM/download/agent -O /usr/local/bin/vpn-agent
# Она теперь качает его с гитхаба:
# wget -q https://github.com/${REPO_URL}/releases/latest/download/vpn-agent -O /usr/local/bin/vpn-agent