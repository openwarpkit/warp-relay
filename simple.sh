#!/bin/bash
set -e

TAG="WR_RULE"
SRC_PORT=4500
DST_PORT=4500
DST_IP=$(getent ahostsv4 engage.cloudflareclient.com | awk '{print $1; exit}')
SRC_IP=$(curl -4s --max-time 3 ifconfig.me 2>/dev/null ||
         curl -4s --max-time 3 icanhazip.com 2>/dev/null ||
         curl -4s --max-time 3 api.ipify.org 2>/dev/null)
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

enable_ip_forwarding() {
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/ipv4-forwarding.conf
    sysctl -w net.ipv4.ip_forward=1
}

# IPT
clean_iptables_rules() {
    iptables -t nat -S | grep "${TAG}" | sed 's/^-A/-D/' | while read -r rule; do
        eval iptables -t nat "$rule" 2>/dev/null || true
    done
    iptables -S | grep "${TAG}" | sed 's/^-A/-D/' | while read -r rule; do
        eval iptables "$rule" 2>/dev/null || true
    done
}

apply_iptables_rules() {
    clean_iptables_rules
    iptables -t nat -A PREROUTING \
        -d ${SRC_IP} -p udp --dport ${SRC_PORT} \
        -j DNAT --to-destination ${DST_IP}:${DST_PORT} \
        -m comment --comment "${TAG}"

    iptables -t nat -A POSTROUTING \
        -p udp -d ${DST_IP} --dport ${DST_PORT} \
        -j MASQUERADE \
        -m comment --comment "${TAG}"

    iptables -A FORWARD -p udp -d ${DST_IP} --dport ${DST_PORT} -j ACCEPT -m comment --comment "${TAG}"
    iptables -A FORWARD -p udp -s ${DST_IP} --sport ${DST_PORT} -j ACCEPT -m comment --comment "${TAG}"
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
    nft add chain ip filter forward { type filter hook forward priority filter \; } 2>/dev/null || true

    nft add rule ip nat prerouting ip daddr $SRC_IP udp dport $SRC_PORT dnat to $DST_IP:$DST_PORT comment \"$TAG\"
    nft add rule ip nat postrouting ip daddr $DST_IP udp dport $DST_PORT masquerade comment \"$TAG\"
    nft add rule ip filter forward ip daddr $DST_IP udp dport $DST_PORT accept comment \"$TAG\"
    nft add rule ip filter forward ip saddr $DST_IP udp sport $DST_PORT accept comment \"$TAG\"
}

save_nftables_rules() {
    nft list ruleset > "$NFT_CONF"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl restart nftables 2>/dev/null || true
    fi
}

main() {
    install_dependencies
    enable_ip_forwarding

    if [ "$FIREWALL_TYPE" = "nftables" ]; then
        apply_nftables_rules
        save_nftables_rules
    else
        apply_iptables_rules
        save_iptables_rules
    fi
    echo "Все правила добавлены!"
}

main