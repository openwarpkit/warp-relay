#!/bin/bash

export DEBIAN_FRONTEND=noninteractive
apt update -qq
apt install -y -qq iptables curl netfilter-persistent

export TAG="WR_RULE_MASQUE"
export SRC_IP=$(curl -4s ifconfig.me)
export DST_IP="162.159.198.2"

echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/ipv4-forwarding.conf
sysctl -w net.ipv4.ip_forward=1

PORTS=(443 500 1701 4500 4443 8443 8095)
PORTS_GROUP=$(IFS=,; echo "${PORTS[*]}")

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

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent

iptables-save > /etc/iptables/rules.v4

echo "Все правила MASQUE добавлены!"
