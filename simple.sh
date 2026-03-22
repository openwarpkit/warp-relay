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

export TAG="WR_RULE"
export SRC_IP=$(curl -4s ifconfig.me)
export DST_IP=$(getent ahostsv4 engage.cloudflareclient.com | awk '{print $1; exit}')
export SRC_PORT=4500
export DST_PORT=4500

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/ipv4-forwarding.conf
sysctl -w net.ipv4.ip_forward=1

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

netfilter-persistent save
