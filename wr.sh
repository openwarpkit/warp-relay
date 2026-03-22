#!/bin/bash

# Установка зависимостей
export DEBIAN_FRONTEND=noninteractive
if command -v apt &>/dev/null; then
    apt update -qq
    apt install -y -qq iptables curl netfilter-persistent
    SAVE_CMD="netfilter-persistent save"
elif command -v dnf &>/dev/null; then
    dnf install -y -q iptables curl iptables-services
    SAVE_CMD="service iptables save"
elif command -v yum &>/dev/null; then
    yum install -y -q iptables curl iptables-services
    SAVE_CMD="service iptables save"
elif command -v pacman &>/dev/null; then
    pacman -Syu --noconfirm iptables curl
    mkdir -p /etc/iptables
    SAVE_CMD="iptables-save > /etc/iptables/iptables.rules"
    if systemctl list-unit-files | grep -q iptables.service; then
        systemctl enable iptables --now 2>/dev/null || true
    fi
elif command -v apk &>/dev/null; then
    apk add --no-cache iptables curl
    mkdir -p /etc/iptables
    SAVE_CMD="iptables-save > /etc/iptables/rules.v4"
    mkdir -p /etc/local.d
    echo "iptables-restore < /etc/iptables/rules.v4" > /etc/local.d/iptables.start
    chmod +x /etc/local.d/iptables.start
    rc-update add local default 2>/dev/null || true
else
    echo "Не поддерживаемый менеджер пакетов. Пожалуйста, установите iptables и curl самостоятельно."
    exit 1
fi

TAG="WR_RULE"
RULES_FILE="/etc/iptables/rules.v4"
SYSCTL_FILE="/etc/sysctl.d/ipv4-forwarding.conf"

detect_ips() {
    SRC_IP=$(curl -4s ifconfig.me)
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

apply_rules() {
    echo "[*] Включаем ip_forward..."
    enable_forward

    echo "[*] Добавляем правила с тегом ${TAG}..."

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

    netfilter-persistent save

    echo "[✓] Правила добавлены."
}

rollback_rules() {
    echo "[!] Удаляем ВСЕ правила с тегом ${TAG}..."

    # Удаляем из nat
    iptables -t nat -S | grep "${TAG}" | sed 's/^-A/-D/' | while read rule; do
        iptables -t nat $rule
    done

    # Удаляем из filter
    iptables -S | grep "${TAG}" | sed 's/^-A/-D/' | while read rule; do
        iptables $rule
    done

    disable_forward

    iptables-save > ${RULES_FILE}

    echo "[✓] Откат выполнен."
}

show_rules() {
    echo "===== Правила Relay (${TAG}) ====="
    iptables -t nat -S | grep "${TAG}"
    iptables -S | grep "${TAG}"
}

custom_input() {
    read -p "Введите IP адрес Relay сервера: " SRC_IP
    read -p "Введите IP адрес Wireguard/WARP сервера: " DST_IP
    read -p "Введите порт Relay сервера [4500]: " SRC_PORT
    read -p "Введите порт Wireguard/WARP сервера [4500]: " DST_PORT

    SRC_PORT=${SRC_PORT:-4500}
    DST_PORT=${DST_PORT:-4500}
}

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
