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

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/ipv4-forwarding.conf
sysctl -w net.ipv4.ip_forward=1

PORTS=(500 854 859 864 878 880 890 891 894 903 908 928 934 939 942 943 945 946 955 968 987 988 1002 1010 1014 1018 1070 1074 1180 1387 1701 1843 2371 2408 2506 3138 3476 3581 3854 4177 4198 4233 4500 5279 5956 7103 7152 7156 7281 7559 8319 8742 8854 8886)

CHUNK_SIZE=15
for ((i=0; i<${#PORTS[@]}; i+=CHUNK_SIZE)); do
    CHUNK=("${PORTS[@]:i:CHUNK_SIZE}")
    PORTS_GROUP=$(IFS=,; echo "${CHUNK[*]}")

    iptables -t nat -A PREROUTING \
        -d ${SRC_IP} -p udp -m multiport --dports ${PORTS_GROUP} \
        -j DNAT --to-destination ${DST_IP} \
        -m comment --comment "${TAG}"

    iptables -t nat -A POSTROUTING \
        -p udp -d ${DST_IP} -m multiport --dports ${PORTS_GROUP} \
        -j MASQUERADE \
        -m comment --comment "${TAG}"

    iptables -A FORWARD -p udp -d ${DST_IP} -m multiport --dports ${PORTS_GROUP} -j ACCEPT -m comment --comment "${TAG}"
    iptables -A FORWARD -p udp -s ${DST_IP} -m multiport --sports ${PORTS_GROUP} -j ACCEPT -m comment --comment "${TAG}"
done

# Сохранение правил в зависимости от ОС
eval "$SAVE_CMD"

echo "Все правила добавлены!"