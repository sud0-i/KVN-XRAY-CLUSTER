#!/bin/bash
# ==============================================================================
# 🚀 VPN CLOUD NATIVE v17.0 FINAL (GitHub Release Edition)
# ==============================================================================

# ⚠️ УБЕДИСЬ, ЧТО ЗДЕСЬ УКАЗАН ТВОЙ РЕПОЗИТОРИЙ GITHUB:
REPO_URL="sud0-i/KVN-XRAY-CLUSTER"

export DEBIAN_FRONTEND=noninteractive
MASTER_IP=$(curl -s4 ifconfig.me)

install_deps() {
    echo "⏳ Проверка и установка пакетов ОС..."
    apt-get update -q >/dev/null 2>&1
    apt-get install -yq jq sqlite3 curl openssl nginx certbot python3-certbot-nginx ufw uuid-runtime fail2ban tar sshpass dnsutils iperf3 docker.io >/dev/null 2>&1
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
        if ! docker ps -a | grep -q mtproto-vpn; then
            SECRET=$(docker run --rm nineseconds/mtg:1 generate-secret tls -c "google.com")
            docker run -d --name mtproto-vpn --restart always -p 8443:3128 nineseconds/mtg:1 run -b 0.0.0.0:3128 $SECRET >/dev/null 2>&1
            ufw allow 8443/tcp >/dev/null 2>&1
            echo "$SECRET" > /etc/orchestrator/mtg_secret.txt
        else
            SECRET=$(cat /etc/orchestrator/mtg_secret.txt 2>/dev/null)
        fi
        MY_IP=$(curl -s4 ifconfig.me)
        echo -e "\n✅ MTProto Прокси активен! Ссылка для подключения:\n"
        echo "tg://proxy?server=$MY_IP&port=8443&secret=$SECRET"
        echo ""
    elif [ "$M_ACT" == "2" ]; then
        docker rm -f mtproto-vpn >/dev/null 2>&1
        ufw delete allow 8443/tcp >/dev/null 2>&1
        rm -f /etc/orchestrator/mtg_secret.txt
        echo "✅ MTProto прокси удален."
    fi
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

harden_system() {
    echo "⏳ Настройка безопасности и SWAP..."
    if [ ! -f /swapfile ]; then
        fallocate -l 2G /swapfile; chmod 600 /swapfile; mkswap /swapfile >/dev/null; swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    systemctl enable fail2ban >/dev/null 2>&1; systemctl start fail2ban >/dev/null 2>&1
    echo "✅ Безопасность усилена (SWAP 2GB, Fail2Ban)."
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

create_backup() {
    echo -e "\n📦 СОЗДАНИЕ ЗАШИФРОВАННОГО БЕКАПА"
    TG_TOKEN=$(grep TG_TOKEN /etc/orchestrator/config.env 2>/dev/null | cut -d'"' -f2)
    TG_CHAT_ID=$(grep TG_CHAT_ID /etc/orchestrator/config.env 2>/dev/null | cut -d'"' -f2)
    if [ -z "$TG_TOKEN" ]; then echo "❌ Токен не найден. Сначала установи Мастер."; return; fi
    
    read -s -p "🔐 Придумай пароль для шифрования архива: " B_PASS1; echo ""
    read -s -p "🔁 Повтори пароль: " B_PASS2; echo ""
    if [ "$B_PASS1" != "$B_PASS2" ]; then echo "❌ Пароли не совпадают!"; return; fi
    
    echo "⏳ Сбор файлов и шифрование..."
    sqlite3 /etc/orchestrator/core.db ".backup '/tmp/core_backup.db'"
    
    # Упаковываем базу, конфиг кластера, SSH-ключи и конфиги Nginx
    tar -czf /tmp/backup.tar.gz -C / tmp/core_backup.db etc/orchestrator/config.env root/.ssh/vpn_cluster_key root/.ssh/vpn_cluster_key.pub etc/letsencrypt etc/nginx/sites-available/default 2>/dev/null
    
    # Шифруем (AES-256-CBC)
    openssl enc -aes-256-cbc -pbkdf2 -salt -in /tmp/backup.tar.gz -out /tmp/cluster_backup.enc -pass pass:"$B_PASS1" 2>/dev/null
    
    echo "⏳ Отправка в Telegram..."
    curl -s -F document=@"/tmp/cluster_backup.enc" -F chat_id="$TG_CHAT_ID" -F caption="📦 Зашифрованный бекап кластера (AES-256)" "https://api.telegram.org/bot$TG_TOKEN/sendDocument" >/dev/null
    
    rm -f /tmp/core_backup.db /tmp/backup.tar.gz /tmp/cluster_backup.enc
    echo "✅ Бекап успешно отправлен в Telegram!"
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

restore_backup() {
    echo -e "\n♻️ ПОЛНОЕ ВОССТАНОВЛЕНИЕ КЛАСТЕРА ИЗ БЕКАПА"
    read -p "Укажи путь к зашифрованному архиву (например, /root/cluster_backup.enc): " B_FILE
    if [ ! -f "$B_FILE" ]; then echo "❌ Файл не найден!"; return; fi
    
    read -s -p "🔐 Введи пароль от архива: " B_PASS; echo ""
    
    echo "⏳ 1/6 Установка базовых зависимостей..."
    install_deps
    
    echo "⏳ 2/6 Расшифровка архива..."
    if ! openssl enc -aes-256-cbc -pbkdf2 -d -in "$B_FILE" -out /tmp/restored.tar.gz -pass pass:"$B_PASS" 2>/dev/null; then
        echo "❌ Ошибка расшифровки! Неверный пароль или поврежден файл."
        return
    fi
    
    echo "⏳ 3/6 Остановка служб и распаковка..."
    systemctl stop vpn-master vpn-agent nginx xray 2>/dev/null
    
    tar -xzf /tmp/restored.tar.gz -C /
    mkdir -p /etc/orchestrator
    mv /tmp/core_backup.db /etc/orchestrator/core.db
    rm -f /tmp/restored.tar.gz
    
    # Исправляем права на SSH-ключи
    chmod 600 /root/.ssh/vpn_cluster_key 2>/dev/null
    
    # Обновляем IP-адрес Мастера в конфиге на новый
    MY_IP=$(curl -s4 ifconfig.me)
    sed -i "s/MASTER_IP=\".*\"/MASTER_IP=\"$MY_IP\"/" /etc/orchestrator/config.env
    
    echo "⏳ 4/6 Загрузка бинарников ядра и агента..."
    # Качаем Мастера
    curl -sSL -f "https://github.com/${REPO_URL}/releases/latest/download/vpn-master" -o /usr/local/bin/vpn-master
    chmod +x /usr/local/bin/vpn-master
    
    # Качаем Агента для будущих нод
    mkdir -p /etc/orchestrator/bin
    curl -sSL -f "https://github.com/${REPO_URL}/releases/latest/download/vpn-agent" -o /etc/orchestrator/bin/agent
    chmod +x /etc/orchestrator/bin/agent
        
    cat <<EOF > /etc/systemd/system/vpn-master.service
[Unit]
Description=VPN Master API
After=network.target

[Service]
ExecStart=/usr/local/bin/vpn-master
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    fi
    
    OLD_DOMAIN=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)
    echo "---------------------------------------------------------"
    echo "📂 В бекапе найден домен управления: $OLD_DOMAIN"
    echo "1) ✅ Оставить этот домен (восстановить как было)"
    echo "2) 🔄 ПЕРЕЕХАТЬ НА НОВЫЙ ДОМЕН (если старый забанен)"
    echo "---------------------------------------------------------"
    read -p "Твой выбор (1-2): " D_CHOICE
    
    echo "⏳ 5/6 Настройка сети и доменов..."
    if [ "$D_CHOICE" == "2" ]; then
        read -p "Введи НОВЫЙ домен (напр. new.sudoi.ru): " NEW_DOMAIN
        read -p "Email для SSL (Let's Encrypt): " SSL_EMAIL
        
        certbot certonly --standalone -d "$NEW_DOMAIN" -m "$SSL_EMAIL" --agree-tos -n
        
        sed -i "s/SUB_DOMAIN=\"$OLD_DOMAIN\"/SUB_DOMAIN=\"$NEW_DOMAIN\"/" /etc/orchestrator/config.env
        sed -i "s/$OLD_DOMAIN/$NEW_DOMAIN/g" /etc/nginx/sites-available/default
        sqlite3 /etc/orchestrator/core.db "UPDATE bridges SET domain='$NEW_DOMAIN' WHERE domain='$OLD_DOMAIN';"
        
        echo "⏳ Переключение удаленных нод на новый домен..."
        for IP in $(sqlite3 /etc/orchestrator/core.db "SELECT ip FROM bridges WHERE ip != '127.0.0.1' UNION SELECT ip FROM exits;"); do
            ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "sed -i 's/$OLD_DOMAIN/$NEW_DOMAIN/g' /etc/systemd/system/vpn-agent.service && systemctl daemon-reload && systemctl restart vpn-agent" 2>/dev/null
            echo "   ✅ Нода $IP переключена."
        done
    fi
    
    # Включаем Nginx
    [ ! -f /etc/nginx/sites-enabled/default ] && ln -s /etc/nginx/sites-available/default /etc/nginx/sites-enabled/ 2>/dev/null
    
    echo "⏳ 6/6 Запуск ядра кластера..."
    systemctl restart nginx vpn-master 2>/dev/null
    
    echo "🎉 МАСТЕР УСПЕШНО ВОССТАНОВЛЕН!"
    
    # Если на сервере еще нет локального моста, предлагаем его поставить
    if [ ! -f /usr/local/bin/vpn-agent ]; then
        echo "---------------------------------------------------------"
        read -p "🚀 Установить Локальный RU-Мост на этот сервер прямо сейчас? (y/n): " INST_LOCAL
        if [ "$INST_LOCAL" == "y" ]; then
            deploy_node "ru_local"
        fi
    fi
    
    read -n 1 -s -r -p "Нажми любую клавишу..."
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
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

verify_dns_propagation() {
    local DOM_TO_CHECK=$1
    local REAL_IP=$(curl -s4 ifconfig.me)
    echo -e "\n🌍 Проверка DNS: привязка $DOM_TO_CHECK к $REAL_IP..."
    
    while true; do
        local RESOLVED_IP=$(dig +short "$DOM_TO_CHECK" | tail -n1)
        if [ "$RESOLVED_IP" == "$REAL_IP" ]; then
            echo "✅ Отлично! DNS-записи обновлены, домен указывает на этот сервер."
            return 0
        fi
        
        echo "⚠️ ВНИМАНИЕ: Домен $DOM_TO_CHECK сейчас указывает на IP: ${RESOLVED_IP:-"Нет записи (пусто)"}"
        echo "👉 Зайди в панель регистратора домена и измени A-запись на: $REAL_IP"
        echo "---------------------------------------------------------"
        echo "1) 🔄 Проверить DNS еще раз (нажми после смены записи)"
        echo "2) ⏭️ Пропустить проверку (Например, если домен за Cloudflare Proxy)"
        read -p "Твой выбор (1-2): " DNS_CHOICE
        
        if [ "$DNS_CHOICE" == "2" ]; then
            echo "⚠️ Проверка пропущена. Убедись, что клиенты и Let's Encrypt смогут достучаться!"
            return 0
        fi
        sleep 2
    done
}

update_xray_core() {
    echo -e "\n🔄 ОБНОВЛЕНИЕ XRAY-CORE (Zero-Downtime)"
    echo "⏳ Обновление на Мастере / Локальном мосте..."
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
    systemctl restart xray 2>/dev/null

    echo "⏳ Рассылка команды обновления на удаленные узлы..."
    local IPS=$(sqlite3 /etc/orchestrator/core.db "SELECT ip FROM bridges WHERE ip != '127.0.0.1' UNION SELECT ip FROM exits;")
    for IP in $IPS; do
        echo "   🚀 Обновляю ядро на $IP..."
        ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP 'bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1 && systemctl restart xray' < /dev/null
    done
    echo "✅ Все ядра Xray в кластере успешно обновлены до последней версии!"
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

manage_warp_cli() {
    echo -e "\n🚀 НАСТРОЙКА МАРШРУТИЗАЦИИ WARP (Cloudflare)"
    echo "Текущие домены WARP:"
    sqlite3 /etc/orchestrator/core.db "SELECT val FROM settings WHERE key='warp_domains';"
    echo "---------------------------------------------------------"
    echo "1) 🌍 Вернуть стандартные домены (Google, ChatGPT, Meta, RU и др.)"
    echo "2) 🚫 Отключить WARP (весь трафик пойдет напрямую с EU-IP)"
    echo "3) ✏️ Задать свои домены вручную"
    echo "0) Отмена"
    read -p "Выбор: " W_C
    if [ "$W_C" == "1" ]; then
        sqlite3 /etc/orchestrator/core.db "UPDATE settings SET val='\"geosite:google\",\"geosite:openai\",\"geosite:netflix\",\"geosite:instagram\",\"geosite:category-ru\",\"domain:ru\",\"domain:рф\"' WHERE key='warp_domains';"
        echo "✅ Домены WARP восстановлены."
    elif [ "$W_C" == "2" ]; then
        sqlite3 /etc/orchestrator/core.db "UPDATE settings SET val='' WHERE key='warp_domains';"
        echo "✅ WARP отключен. Весь трафик идет напрямую."
    elif [ "$W_C" == "3" ]; then
        echo "Введи домены через запятую (например: \"geosite:google\",\"domain:ipinfo.io\"):"
        read -p "> " NEW_WARP
        sqlite3 /etc/orchestrator/core.db "UPDATE settings SET val='$NEW_WARP' WHERE key='warp_domains';"
        echo "✅ Домены WARP обновлены!"
    fi
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

change_sni_cli() {
    echo -e "\n🎭 СМЕНА SNI (Маскировки)"
    echo "1) Изменить ГЛОБАЛЬНЫЙ SNI (по умолчанию)"
    echo "2) Изменить SNI для КОНКРЕТНОЙ EU-ноды"
    read -p "Выбор: " SNI_OPT

    if [ "$SNI_OPT" == "1" ]; then
        read -p "Новый глобальный SNI (напр. www.samsung.com): " NEW_SNI
        sqlite3 /etc/orchestrator/core.db "UPDATE settings SET val='$NEW_SNI' WHERE key='sni';"
        echo "✅ Глобальный SNI обновлен!"
    elif [ "$SNI_OPT" == "2" ]; then
        sqlite3 /etc/orchestrator/core.db "SELECT ip, sni FROM exits;" | awk -F'|' '{printf "🌍 IP: %-15s | Текущий кастомный SNI: %s\n", $1, $2}'
        read -p "Введи IP ноды: " NODE_IP
        read -p "Новый SNI для этой ноды: " NEW_SNI
        sqlite3 /etc/orchestrator/core.db "UPDATE exits SET sni='$NEW_SNI' WHERE ip='$NODE_IP';"
        echo "✅ SNI для $NODE_IP обновлен!"
    fi
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

setup_ssh_notify() {
    echo -e "\n🔔 НАСТРОЙКА УВЕДОМЛЕНИЙ ОБ SSH-ВХОДАХ"
    local TG_TOKEN=$(grep TG_TOKEN /etc/orchestrator/config.env 2>/dev/null | cut -d'"' -f2)
    local TG_CHAT_ID=$(grep TG_CHAT_ID /etc/orchestrator/config.env 2>/dev/null | cut -d'"' -f2)
    
    if [ -z "$TG_TOKEN" ]; then
        echo "⚠️ Сначала установите Мастер, чтобы задать Токен и Chat ID."
        read -n 1 -s -r -p "Нажми любую клавишу..."
        return
    fi

    cat <<EOF > /etc/profile.d/tg_ssh_notify.sh
#!/bin/bash
if [ -n "\$SSH_CLIENT" ]; then
    IP=\$(echo "\$SSH_CLIENT" | awk '{print \$1}')
    HOSTNAME=\$(hostname)
    MSG="🚨 *ВНИМАНИЕ! Вход по SSH*%0A%0A🖥 *Сервер:* \$HOSTNAME%0A👤 *Пользователь:* \$USER%0A🌐 *IP адрес:* \$IP%0A⏰ *Время:* \$(date '+%Y-%m-%d %H:%M:%S')"
    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" -d chat_id="${TG_CHAT_ID}" -d text="\$MSG" -d parse_mode="Markdown" >/dev/null 2>&1 &
fi
EOF
    chmod +x /etc/profile.d/tg_ssh_notify.sh
    echo "✅ Уведомления включены! Теперь бот будет присылать алерт при каждом входе."
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

toggle_autostart() {
    echo -e "\n⚙️ НАСТРОЙКА АВТОЗАПУСКА ПРИ ВХОДЕ ПО SSH"
    local BASHRC="$HOME/.bashrc"
    local SCRIPT_PATH=$(readlink -f "$0")
    local MARKER="# VPN_BRIDGE_AUTOSTART"
    local AUTOSTART_LINE="[[ \$- == *i* ]] && bash \"$SCRIPT_PATH\" $MARKER"

    if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
        grep -v "$MARKER" "$BASHRC" > "${BASHRC}.tmp" && mv "${BASHRC}.tmp" "$BASHRC"
        echo "🔴 Автозапуск ОТКЛЮЧЕН. При входе по SSH будет открываться обычная консоль."
    else
        echo "$AUTOSTART_LINE" >> "$BASHRC"
        echo "🟢 Автозапуск ВКЛЮЧЕН. Меню будет появляться сразу при подключении к серверу."
    fi
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

show_logs() {
    echo "📜 ПРОСМОТР ЛОГОВ (Последние 30 строк)"
    echo "1) Мастер (vpn-master)"
    echo "2) Агент (vpn-agent)"
    echo "3) Nginx (Веб-сервер)"
    echo "4) Xray (Ядро)"
    read -p "Выбор: " L_C
    echo "---------------------------------------------------------"
    case $L_C in
        1) journalctl -u vpn-master -n 30 --no-pager ;;
        2) journalctl -u vpn-agent -n 30 --no-pager ;;
        3) tail -n 30 /var/log/nginx/error.log 2>/dev/null || echo "Ошибок Nginx нет." ;;
        4) journalctl -u xray -n 30 --no-pager ;;
        *) echo "Отмена." ;;
    esac
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

speedtest_bridge() {
    echo -e "\n⚡ ЗАМЕР СКОРОСТИ МЕЖДУ RU И EU (iperf3)"
    local IPS=$(sqlite3 /etc/orchestrator/core.db "SELECT ip FROM exits;" 2>/dev/null)
    if [ -z "$IPS" ]; then echo "❌ Нет подключенных EU-серверов в БД."; read -n 1 -s -r -p "Нажми любую клавишу..."; return; fi
    
    apt-get install -yq iperf3 >/dev/null 2>&1

    for IP in $IPS; do
        echo "---------------------------------------------------------"
        echo "🌐 Настраиваю EU-ноду ($IP) для теста..."
        ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "apt-get install -yq iperf3 >/dev/null 2>&1 && ufw allow 5201/tcp >/dev/null 2>&1 && killall iperf3 2>/dev/null; iperf3 -s -D" < /dev/null
        
        echo "🚀 Тест 1/2: Скачивание (EU -> RU)..."
        iperf3 -c "$IP" -O 1 -t 5 -R | grep -E "sender|receiver"
        
        echo "🚀 Тест 2/2: Загрузка (RU -> EU)..."
        iperf3 -c "$IP" -O 1 -t 5 | grep -E "sender|receiver"
        
        echo "🧹 Уборка на EU-ноде..."
        ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP "killall iperf3 2>/dev/null && ufw delete allow 5201/tcp >/dev/null 2>&1" < /dev/null
    done
    read -n 1 -s -r -p "Нажми любую клавишу..."
}

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
                
                U_UUID=$(uuidgen)
                if [ "$L_TYPE" == "2" ]; then
                    LIMIT=0
                    sqlite3 /etc/orchestrator/core.db "INSERT INTO users (uuid, name, expires_at, ip_limit) VALUES ('$U_UUID', '$U_NAME', NULL, $LIMIT);"
                else
                    LIMIT=5
                    sqlite3 /etc/orchestrator/core.db "INSERT INTO users (uuid, name, expires_at, ip_limit) VALUES ('$U_UUID', '$U_NAME', datetime('now', '+30 days'), $LIMIT);"
                fi
                
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
    read -n 1 -s -r -p "Нажми любую клавишу..."
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
    
    echo "---------------------------------------------------------"
    read -p "Установить локальный RU-мост на этом же сервере прямо сейчас? (y/n): " SETUP_LOCAL
    if [[ "$SETUP_LOCAL" == "y" || "$SETUP_LOCAL" == "Y" ]]; then
        deploy_node "ru_local"
    fi
}

deploy_node() {
    TYPE=$1
    if [ "$TYPE" == "ru_local" ]; then
        echo -e "\n🏠 ДОБАВЛЕНИЕ ЛОКАЛЬНОГО RU-МОСТА"
        DOMAIN=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)
        TOKEN=$(grep CLUSTER_TOKEN /etc/orchestrator/config.env | cut -d'"' -f2)
        
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

        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        mkdir -p /usr/local/etc/xray /var/log/xray && chmod 777 /var/log/xray
        sed -i 's/User=nobody/User=root/g' /etc/systemd/system/xray.service
        systemctl daemon-reload

        cp /etc/orchestrator/bin/agent /usr/local/bin/vpn-agent
        echo "tls|$DOMAIN|none" > /usr/local/etc/xray/agent_keys.txt
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
        echo "✅ Локальный мост установлен!"
        return
    fi

    # Секция для удаленных нод
    read -p "IP адрес сервера: " IP
    read -s -p "Root пароль от $IP: " PASS; echo ""
    
    if [ "$TYPE" == "ru_remote" ]; then
        echo "1) REALITY | 2) Classic TLS"
        read -p "Режим: " RU_MODE
        [ "$RU_MODE" == "2" ] && { read -p "Домен: " DOMAIN; verify_dns_propagation "$DOMAIN"; read -p "Email: " EMAIL; } || read -p "Название домена: " DOMAIN
    fi

    export SSHPASS="$PASS"
    sshpass -e ssh-copy-id -i /root/.ssh/vpn_cluster_key.pub -o StrictHostKeyChecking=no root@$IP >/dev/null 2>&1
    CMD_PREFIX="ssh -i /root/.ssh/vpn_cluster_key -o StrictHostKeyChecking=no root@$IP bash -s"

    M_IP=$(curl -s4 ifconfig.me)
    C_TOK=$(grep CLUSTER_TOKEN /etc/orchestrator/config.env | cut -d'"' -f2)
    B_UUID=$(grep BRIDGE_UUID /etc/orchestrator/config.env | cut -d'"' -f2)
    M_DOM=$(grep SUB_DOMAIN /etc/orchestrator/config.env | cut -d'"' -f2)

    RAW_OUT=$($CMD_PREFIX "$M_IP" "$C_TOK" "$B_UUID" "$M_DOM" "$TYPE" "$DOMAIN" "$RU_MODE" "$EMAIL" "$REPO_URL" << 'EOF'
        MASTER_IP=$1; TOKEN=$2; BRIDGE_UUID=$3; MASTER_DOM=$4; TYPE=$5; DOMAIN=$6; RU_MODE=$7; EMAIL=$8; GITHUB_REPO=$9
        
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -q >/dev/null 2>&1
        apt-get install -yq curl jq openssl ufw gnupg >/dev/null 2>&1
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1
        
        # Исправлено: принудительное создание папок
        mkdir -p /usr/local/etc/xray /var/log/xray
        chmod 777 /var/log/xray
        
        ufw allow 22/tcp >/dev/null 2>&1

        if [ "$TYPE" == "ru_remote" ]; then
            if [ "$RU_MODE" == "2" ]; then
                apt-get install -yq nginx certbot python3-certbot-nginx >/dev/null 2>&1
                certbot certonly --standalone -d $DOMAIN -m $EMAIL --agree-tos -n >/dev/null 2>&1
                systemctl restart nginx
                echo "tls|$DOMAIN|none" > /usr/local/etc/xray/agent_keys.txt
                curl -s -H "Authorization: Bearer $TOKEN" "https://$MASTER_DOM/api/register?type=ru&ip=$(curl -s4 ifconfig.me)&domain=$DOMAIN&mode=tls" >/dev/null
            else
                KEYS=$(/usr/local/bin/xray x25519)
                PK=$(echo "$KEYS" | grep -i "Private" | awk '{print $NF}')
                PUB=$(echo "$KEYS" | grep -iE "Public|Password" | head -n 1 | awk '{print $NF}')
                SID=$(openssl rand -hex 4)
                echo "$PK|$SID|none" > /usr/local/etc/xray/agent_keys.txt
                curl -s -G -H "Authorization: Bearer $TOKEN" \
                    --data-urlencode "type=ru" \
                    --data-urlencode "ip=$(curl -s4 ifconfig.me)" \
                    --data-urlencode "pk=$PUB" \
                    --data-urlencode "sid=$SID" \
                    --data-urlencode "mode=reality" \
                    "https://$MASTER_DOM/api/register" >/dev/null
            fi
        elif [ "$TYPE" == "eu" ]; then
            # 1. Устанавливаем WARP-CLI и зависимости
            apt-get update -y
            apt-get install -y gnupg curl
            curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
            source /etc/os-release
            echo "deb [arch=amd64 signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ ${VERSION_CODENAME} main" > /etc/apt/sources.list.d/cloudflare-client.list
            apt-get update -q && apt-get install -yq cloudflare-warp >/dev/null 2>&1
            
            warp-cli --accept-tos registration new >/dev/null 2>&1
            warp-cli --accept-tos mode proxy >/dev/null 2>&1
            warp-cli --accept-tos proxy port 40000 >/dev/null 2>&1
            warp-cli --accept-tos connect >/dev/null 2>&1

            # 2. Генерируем ключи Xray
            KEYS=$(/usr/local/bin/xray x25519)
            PRV=$(echo "$KEYS" | grep -i "PrivateKey" | awk '{print $NF}')
            PUB=$(echo "$KEYS" | grep -iE "Public|Password" | head -n 1 | awk '{print $NF}')
            SS_PASS=$(openssl rand -base64 16)
            XHTTP_PATH=$(openssl rand -hex 6)

            # 3. Сохраняем ключи для локального агента
            echo "$PRV|$SS_PASS|$XHTTP_PATH" > /usr/local/etc/xray/agent_keys.txt

            # 4. Регистрируем ноду в базе Мастера по API
            curl -s -G -H "Authorization: Bearer $TOKEN" \
                --data-urlencode "type=eu" \
                --data-urlencode "ip=$(curl -s4 ifconfig.me)" \
                --data-urlencode "pk=$PUB" \
                --data-urlencode "ss=$SS_PASS" \
                --data-urlencode "xp=$XHTTP_PATH" \
                "https://$MASTER_DOM/api/register" >/dev/null
        fi
        
        wget --no-check-certificate -q "https://$MASTER_DOM/download/agent" -O /usr/local/bin/vpn-agent
        chmod +x /usr/local/bin/vpn-agent
        cat <<SVC > /etc/systemd/system/vpn-agent.service
[Unit]
Description=VPN Agent
[Service]
ExecStart=/usr/local/bin/vpn-agent -master https://$MASTER_DOM -token $TOKEN -role ${TYPE:0:2}
Restart=always
[Install]
WantedBy=multi-user.target
SVC
        systemctl daemon-reload && systemctl enable vpn-agent && systemctl restart vpn-agent
        ufw allow 443/tcp >/dev/null 2>&1
        ufw allow 4433/tcp >/dev/null 2>&1
        ufw allow 5000/tcp >/dev/null 2>&1
        ufw --force enable >/dev/null 2>&1
        echo "NODE_DATA|$TYPE"
EOF
)
    echo "$RAW_OUT" | grep -q "NODE_DATA" && echo "✅ Готово!" || echo "❌ Ошибка: $RAW_OUT"
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
        echo "13. ♻️ Восстановить из бекапа"
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
        echo "11. 🔔 Включить SSH-алерты в Telegram"
        echo "12. 📦 Сделать полный бекап в Telegram"
        echo "13. ♻️ Восстановить из бекапа"
        echo "14. 🔄 Обновить Мастера и Агентов"
        echo "15. 🔄 Обновить Ядро Xray"
        echo "16. 🎭 Сменить SNI"
        echo "17. 🚀 Сменить домены WARP"
        echo "18. ⚙️ Автозапуск меню при входе"
    fi
    echo "0. 🚪 Выход"
    echo "#########################################################"
    read -p "Выбор: " C
    case $C in
        1) install_master ;;
        2) deploy_node "ru_local" ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        3) deploy_node "ru_remote" ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        4) deploy_node "eu" ; read -n 1 -s -r -p "Нажми любую клавишу..." ;;
        5) delete_node ;;
        6) manage_users_cli ;;
        7) speedtest_bridge ;;
        8) show_logs ;;
        9) harden_system ;;
        10) manage_mtproto ;;
        11) setup_ssh_notify ;;
        12) create_backup ;;
        13) restore_backup ;;
        14) update_cluster ;;
        15) update_xray_core ;;
        16) change_sni_cli ;;
        17) manage_warp_cli ;;
        18) toggle_autostart ;;
        0) exit 0 ;;
    esac
done