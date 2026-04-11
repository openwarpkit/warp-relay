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

echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo DEBIAN_FRONTEND=noninteractive apt install -y iptables-persistent

iptables-save > /etc/iptables/rules.v4

echo "Все правила добавлены!"