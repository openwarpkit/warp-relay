#!/bin/bash
set -e

TAG="WR_RULE"
RULES_FILE="/etc/iptables/rules.v4"
SYSCTL_FILE="/etc/sysctl.d/ipv4-forwarding.conf"
# NFT
FIREWALL_TYPE=""
NFT_CONF="/etc/nftables.conf"

check_nftables() {
    command -v nft >/dev/null 2>&1 || return 1
    nft add table ip test 2>/dev/null && nft delete table ip test 2>/dev/null
    return $?
}

detect_firewall() {
    if check_nftables; then
        FIREWALL_TYPE="nftables"
        echo "[*] Обнаружен nftables, будет использоваться nftables"
        return 0
    elif command -v iptables >/dev/null 2>&1; then
        FIREWALL_TYPE="iptables"
        echo "[*] Обнаружен iptables, будет использоваться iptables"
        return 0
    else
        echo "[!] Не найден ни nftables, ни iptables. Будет выполнена установка..."
        return 1
    fi
}

install_dependencies() {
    if detect_firewall; then
        if command -v apt &>/dev/null; then
            export DEBIAN_FRONTEND=noninteractive
            apt update -qq
            apt install -y -qq curl
            if [ "$FIREWALL_TYPE" = "iptables" ]; then
                apt install -y -qq netfilter-persistent
                SAVE_CMD="netfilter-persistent save"
            fi
        elif command -v dnf &>/dev/null; then
            dnf install -y -q curl
            if [ "$FIREWALL_TYPE" = "iptables" ]; then
                dnf install -y -q iptables-services
                SAVE_CMD="service iptables save"
            fi
        elif command -v yum &>/dev/null; then
            yum install -y -q curl
            if [ "$FIREWALL_TYPE" = "iptables" ]; then
                yum install -y -q iptables-services
                SAVE_CMD="service iptables save"
            fi
        elif command -v pacman &>/dev/null; then
            pacman -Syu --noconfirm curl
            if [ "$FIREWALL_TYPE" = "iptables" ]; then
                mkdir -p /etc/iptables
                SAVE_CMD="iptables-save > /etc/iptables/iptables.rules"
            fi
        elif command -v apk &>/dev/null; then
            apk add --no-cache curl
            if [ "$FIREWALL_TYPE" = "iptables" ]; then
                mkdir -p /etc/iptables
                SAVE_CMD="iptables-save > /etc/iptables/rules.v4"
            fi
        fi

        if [ -n "${SAVE_CMD:-}" ]; then
            export SAVE_CMD
        fi
        return 0
    fi

    if command -v apt &>/dev/null; then
        export DEBIAN_FRONTEND=noninteractive
        apt update -qq
        apt install -y -qq nftables curl
        if check_nftables; then
            FIREWALL_TYPE="nftables"
            echo "[*] Установлен nftables"
        else
            apt install -y -qq iptables netfilter-persistent
            FIREWALL_TYPE="iptables"
            SAVE_CMD="netfilter-persistent save"
            export SAVE_CMD
        fi
    elif command -v dnf &>/dev/null; then
        dnf install -y -q nftables curl
        if check_nftables; then
            FIREWALL_TYPE="nftables"
        else
            dnf install -y -q iptables iptables-services curl
            FIREWALL_TYPE="iptables"
            SAVE_CMD="service iptables save"
            export SAVE_CMD
        fi
    elif command -v yum &>/dev/null; then
        yum install -y -q nftables curl
        if check_nftables; then
            FIREWALL_TYPE="nftables"
        else
            yum install -y -q iptables iptables-services curl
            FIREWALL_TYPE="iptables"
            SAVE_CMD="service iptables save"
            export SAVE_CMD
        fi
    elif command -v pacman &>/dev/null; then
        pacman -Syu --noconfirm nftables curl
        if check_nftables; then
            FIREWALL_TYPE="nftables"
        else
            pacman -Syu --noconfirm iptables curl
            mkdir -p /etc/iptables
            FIREWALL_TYPE="iptables"
            SAVE_CMD="iptables-save > /etc/iptables/iptables.rules"
            export SAVE_CMD
        fi
    elif command -v apk &>/dev/null; then
        apk add --no-cache nftables curl
        if check_nftables; then
            FIREWALL_TYPE="nftables"
        else
            apk add --no-cache iptables curl
            mkdir -p /etc/iptables
            FIREWALL_TYPE="iptables"
            SAVE_CMD="iptables-save > /etc/iptables/rules.v4"
            export SAVE_CMD
        fi
    else
        echo "Не поддерживаемый менеджер пакетов. Пожалуйста, установите iptables или nftables и curl самостоятельно."
        exit 1
    fi

    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        echo "[*] Используется nftables"
        if [ ! -f "$NFT_CONF" ]; then
            echo '#!/usr/sbin/nft -f' > "$NFT_CONF"
            echo 'flush ruleset' >> "$NFT_CONF"
        fi
        if command -v systemctl >/dev/null 2>&1; then
            systemctl enable nftables 2>/dev/null || true
            systemctl start nftables 2>/dev/null || true
        elif command -v rc-update >/dev/null 2>&1; then
            rc-update add nftables default 2>/dev/null || true
        fi
    else
        echo "[*] Используется iptables"
    fi
}

detect_ips() {
    SRC_IP=$(curl -4s --max-time 3 ifconfig.me 2>/dev/null ||
             curl -4s --max-time 3 icanhazip.com 2>/dev/null ||
             curl -4s --max-time 3 api.ipify.org 2>/dev/null)
    DST_IP=$(getent ahostsv4 engage.cloudflareclient.com | awk '{print $1; exit}')
}

enable_forward() {
    echo "net.ipv4.ip_forward=1" > ${SYSCTL_FILE}
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
}

disable_forward() {
    echo "net.ipv4.ip_forward=0" > ${SYSCTL_FILE}
    sysctl -w net.ipv4.ip_forward=0 >/dev/null
}

# IPT
apply_iptables_rules() {
    iptables -t nat -A PREROUTING \
        -d ${SRC_IP} -p udp --dport ${SRC_PORT} \
        -m comment --comment "${TAG}" \
        -j DNAT --to-destination ${DST_IP}:${DST_PORT}

    iptables -t nat -A POSTROUTING \
        -p udp -d ${DST_IP} --dport ${DST_PORT} \
        -m comment --comment "${TAG}" \
        -j MASQUERADE

    iptables -A FORWARD \
        -p udp -d ${DST_IP} --dport ${DST_PORT} \
        -m comment --comment "${TAG}" \
        -j ACCEPT

    iptables -A FORWARD \
        -p udp -s ${DST_IP} --sport ${DST_PORT} \
        -m comment --comment "${TAG}" \
        -j ACCEPT
}

rollback_iptables_rules() {
    echo "[!] Удаляем ВСЕ правила iptables с тегом ${TAG}..."
    iptables -t nat -S | grep "${TAG}" | sed 's/^-A/-D/' | while read -r rule; do
        eval iptables -t nat "$rule" 2>/dev/null || true
    done
    iptables -S | grep "${TAG}" | sed 's/^-A/-D/' | while read -r rule; do
        eval iptables "$rule" 2>/dev/null || true
    done
}

show_iptables_rules() {
    echo "===== Правила Relay (${TAG}) ====="
    iptables -t nat -S | grep "${TAG}"
    iptables -S | grep "${TAG}"
}

save_iptables_rules() {
    if [ -n "$SAVE_CMD" ]; then
        eval "$SAVE_CMD"
    fi
}

# NFT
clean_nftables_rules() {
    for table in nat filter; do
        for chain in prerouting postrouting forward; do
            nft -a list chain ip "$table" "$chain" 2>/dev/null | \
                grep -B1 "comment \"$TAG\"" | \
                grep -o 'handle [0-9]*' | \
                awk '{print $2}' | \
                while read -r handle; do
                    if [[ "$handle" =~ ^[0-9]+$ ]]; then
                        nft delete rule ip "$table" "$chain" handle "$handle" 2>/dev/null || true
                    fi
                done
        done
    done
}

apply_nftables_rules() {
    clean_nftables_rules
    nft add table ip nat 2>/dev/null || true
    nft add table ip filter 2>/dev/null || true

    nft add chain ip nat prerouting { type nat hook prerouting priority -100 \; } 2>/dev/null || true
    nft add chain ip nat postrouting { type nat hook postrouting priority 100 \; } 2>/dev/null || true
nft add chain ip filter forward { type filter hook forward priority filter \; policy accept \; } 2>/dev/null || true

    nft add rule ip nat prerouting ip daddr $SRC_IP udp dport $SRC_PORT dnat to $DST_IP:$DST_PORT comment \"$TAG\"
    nft add rule ip nat postrouting ip daddr $DST_IP udp dport $DST_PORT masquerade comment \"$TAG\"
    nft add rule ip filter forward ip daddr $DST_IP udp dport $DST_PORT accept comment \"$TAG\"
    nft add rule ip filter forward ip saddr $DST_IP udp sport $DST_PORT accept comment \"$TAG\"
}

rollback_nftables_rules() {
    echo "[!] Удаляем ВСЕ правила nftables с тегом ${TAG}..."
    for table in nat filter; do
        for chain in prerouting postrouting forward; do
            nft -a list chain ip $table $chain 2>/dev/null | grep -B1 "comment \"$TAG\"" | grep -o 'handle [0-9]*' | awk '{print $2}' | while read handle; do
                nft delete rule ip $table $chain handle $handle 2>/dev/null
            done
        done
    done
}

show_nftables_rules() {
    echo "===== Правила Relay (${TAG}) ====="
    nft list ruleset | grep -A2 -B1 "comment \"$TAG\""
}

save_nftables_rules() {
    nft list ruleset > "$NFT_CONF"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart nftables 2>/dev/null || true
    fi
}

apply_rules() {
    enable_ip_forwarding
    echo "[*] Добавляем правила с тегом ${TAG}..."
    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        apply_nftables_rules
    else
        apply_iptables_rules
    fi
    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        save_nftables_rules
    else
        save_iptables_rules
    fi
    echo "[✓] Правила добавлены."
}

rollback_rules() {
    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        rollback_nftables_rules
    else
        rollback_iptables_rules
    fi
    disable_ip_forwarding
    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        save_nftables_rules
    else
        save_iptables_rules
    fi
    echo "[✓] Откат выполнен."
}

show_rules() {
    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        show_nftables_rules
    else
        show_iptables_rules
    fi
}

custom_input() {
    read -p "Введите IP адрес Relay сервера: " SRC_IP
    read -p "Введите IP адрес Wireguard/WARP сервера: " DST_IP
    read -p "Введите порт Relay сервера [4500]: " SRC_PORT
    read -p "Введите порт Wireguard/WARP сервера [4500]: " DST_PORT

    SRC_PORT=${SRC_PORT:-4500}
    DST_PORT=${DST_PORT:-4500}
}

install_dependencies

while true; do
    echo ""
    echo "===== Wireguard/WARP RELAY MENU ====="
    echo "1) Автонастройка (Cloudflare UDP 4500)"
    echo "2) Ввести параметры вручную"
    echo "3) Показать Relay правила файрволла"
    echo "4) Откат изменений (удаление)"
    echo "5) Выход"
    echo "=========================="

    read -p "Выберите пункт: " choice

    case $choice in
        1)
            detect_ips
            SRC_PORT=4500
            DST_PORT=4500
            echo "SRC_IP=${SRC_IP}"
            echo "DST_IP=${DST_IP}"
            apply_rules
            ;;
        2)
            custom_input
            apply_rules
            ;;
        3)
            show_rules
            ;;
        4)
            rollback_rules
            ;;
        5)
            exit 0
            ;;
        *)
            echo "Неверный выбор"
            ;;
    esac
done
