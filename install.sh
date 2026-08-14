#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
PLAIN='\033[0m'

CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="$CONFIG_DIR/config.json"
CERT_DIR="$CONFIG_DIR/cert"
SECRETS_FILE="$CONFIG_DIR/.secrets"
FW_PORTS_FILE="$CONFIG_DIR/.fw_ports"
TMP_JSON="/tmp/sb_tmp.json"

trap 'rm -f $TMP_JSON' EXIT
trap 'rm -f $TMP_JSON; exit 1' INT TERM

if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
elif command -v apt-get >/dev/null 2>&1; then
    OS_TYPE="debian"
elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    OS_TYPE="centos"
else
    OS_TYPE="debian"
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须以 root 身份运行本脚本！${PLAIN}"
    exit 1
fi

GLOBAL_IP=""
GLOBAL_LATEST_VER=""

get_ip() {
    if [ -z "$GLOBAL_IP" ]; then
        GLOBAL_IP=$(curl -s ipv4.icanhazip.com)
    fi
    echo "$GLOBAL_IP"
}

get_latest_version() {
    if [ -z "$GLOBAL_LATEST_VER" ]; then
        local res=$(curl -s -m 2 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -n "$res" ]; then
            GLOBAL_LATEST_VER=${res#v}
        fi
    fi
    echo "$GLOBAL_LATEST_VER"
}

check_port() {
    local port=$1
    if command -v ss >/dev/null 2>&1; then
        ss -tuln | grep -qw ":${port}"
    elif command -v netstat >/dev/null 2>&1; then
        netstat -tuln | grep -qw ":${port}"
    else
        return 1
    fi
}

rand_port() {
    local port
    while true; do
        port=$(shuf -i 10000-65000 -n 1)
        if ! check_port "$port"; then
            echo "$port"
            break
        fi
    done
}

save_secret() {
    local key=$1
    local val=$2
    if grep -q "^${key}=" "$SECRETS_FILE" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}='${val}'|" "$SECRETS_FILE"
    else
        echo "${key}='${val}'" >> "$SECRETS_FILE"
    fi
}

load_secrets() {
    [ -f "$SECRETS_FILE" ] && source "$SECRETS_FILE"
}

open_fw_port() {
    local port=$1
    local proto=$2
    local success=0
    local fw_found=0

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        fw_found=1
        ufw allow ${port}/${proto} >/dev/null 2>&1 && success=1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        fw_found=1
        firewall-cmd --add-port=${port}/${proto} --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1 && success=1
    elif command -v iptables >/dev/null 2>&1; then
        fw_found=1
        if ! iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            if ! ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; then
                ip6tables -I INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1
            fi
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        fi
        success=1
    fi

    if [ "$fw_found" -eq 1 ] && [ "$success" -eq 1 ]; then
        echo "${port}/${proto}" >> "$FW_PORTS_FILE"
        local tmp_fw=$(mktemp)
        sort -u "$FW_PORTS_FILE" > "$tmp_fw" && mv "$tmp_fw" "$FW_PORTS_FILE"
    fi

    echo ""
    if [ "$fw_found" -eq 0 ]; then
        echo -e "${YELLOW}未发现防火墙 跳过${PLAIN}"
    else
        if [ "$success" -eq 1 ]; then
            echo -e "${GREEN}放行端口成功${PLAIN}"
            echo -e "${YELLOW}注:如你的VPS厂商/NAT VPS 有云端防火墙 请去云端后台放行对应端口或全部放行${PLAIN}"
        else
            echo -e "${RED}放行失败 请手动放行对应端口${PLAIN}"
        fi
    fi
    echo ""
}

close_fw_port() {
    local port=$1
    local proto=$2

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        ufw delete allow ${port}/${proto} >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --remove-port=${port}/${proto} --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1
        done
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -C INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1; do
                ip6tables -D INPUT -p ${proto} --dport ${port} -j ACCEPT >/dev/null 2>&1
            done
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        fi
    fi
}

remove_all_fw_rules() {
    if [ -f "$FW_PORTS_FILE" ]; then
        while IFS="/" read -r port proto; do
            if [ -n "$port" ] && [ -n "$proto" ]; then
                close_fw_port "$port" "$proto"
            fi
        done < "$FW_PORTS_FILE"
        rm -f "$FW_PORTS_FILE"
    fi
}

init_base() {
    if ! command -v jq &> /dev/null || [ ! -f "/usr/local/bin/sing-box" ]; then
        echo -e "${CYAN}==> 正在准备环境与内核...${PLAIN}"
        if [ "$OS_TYPE" == "alpine" ]; then
            apk update >/dev/null 2>&1
            apk add curl wget jq tar openssl socat bash nano libc6-compat gcompat >/dev/null 2>&1
            rc-update add crond default >/dev/null 2>&1
            rc-service crond start >/dev/null 2>&1
        elif [ "$OS_TYPE" == "centos" ]; then
            if command -v dnf >/dev/null 2>&1; then
                dnf install -y epel-release >/dev/null 2>&1
                dnf update -y >/dev/null 2>&1
                dnf install -y curl wget jq tar openssl socat cronie systemd nano >/dev/null 2>&1
            else
                yum install -y epel-release >/dev/null 2>&1
                yum update -y >/dev/null 2>&1
                yum install -y curl wget jq tar openssl socat cronie systemd nano >/dev/null 2>&1
            fi
            systemctl enable crond --now >/dev/null 2>&1
        else
            apt-get update -y >/dev/null 2>&1
            apt-get install -y curl wget jq tar openssl socat cron systemd nano >/dev/null 2>&1
        fi
        
        ARCH=$(uname -m)
        case "$ARCH" in
            x86_64) SB_ARCH="amd64" ;;
            aarch64|arm64) SB_ARCH="arm64" ;;
            *) echo -e "${RED}不支持的系统架构: ${ARCH}${PLAIN}"; exit 1 ;;
        esac

        echo -e "${CYAN}==> 正在获取最新版 sing-box 内核信息...${PLAIN}"
        VERSION=$(get_latest_version)
        
        if [ -z "$VERSION" ]; then
            echo -e "${RED}获取版本信息失败，请检查网络！${PLAIN}"
            exit 1
        fi

        echo -e "${CYAN}==> 发现最新版本 v${VERSION}，开始下载...${PLAIN}"
        wget --show-progress -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz" || wget -O sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
        
        tar -xzf sing-box.tar.gz
        mv sing-box-${VERSION}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
        chmod +x /usr/local/bin/sing-box
        rm -rf sing-box.tar.gz sing-box-${VERSION}-linux-${SB_ARCH}
        echo -e "${GREEN}==> 内核下载并解压完毕！${PLAIN}"
    fi

    mkdir -p $CONFIG_DIR $CERT_DIR
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"ip_is_private":true,"outbound":"block"}]}}' > $CONFIG_FILE
    else
        sed -i 's/"geoip":"private"/"ip_is_private":true/g' $CONFIG_FILE
        sed -i 's/"geoip": "private"/"ip_is_private": true/g' $CONFIG_FILE
    fi
}

cert_manage() {
    clear
    echo -e "选择: 证书管理\n"
    echo -e " 1) 申请新证书"
    echo -e " 2) 手动强制续期"
    echo -e " 3) 查看证书与自动续期状态"
    echo -e " 0) 返回"
    echo ""
    read -p "请选择 [0-3]: " cert_idx

    load_secrets
    case "$cert_idx" in
        1)
            echo -e "${YELLOW}注意: 申请证书需要域名已成功解析到本机 IP！${PLAIN}"
            read -p "请输入你的域名: " NEW_DOMAIN
            read -p "请输入 Cloudflare 邮箱: " NEW_CF_Email
            read -p "请输入 Cloudflare Global API Key: " NEW_CF_Key
            
            save_secret "DOMAIN" "$NEW_DOMAIN"
            save_secret "CERT_TYPE" "real"
            export CF_Key="${NEW_CF_Key}"
            export CF_Email="${NEW_CF_Email}"
            
            curl -sL https://get.acme.sh | sh
            ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
            ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${NEW_DOMAIN} --force
            
            if [ "$OS_TYPE" == "alpine" ]; then
                RELOAD_CMD="rc-service sing-box restart"
            else
                RELOAD_CMD="systemctl restart sing-box"
            fi
            ~/.acme.sh/acme.sh --installcert -d ${NEW_DOMAIN} --fullchainpath $CERT_DIR/fullchain.cer --keypath $CERT_DIR/private.key --reloadcmd "$RELOAD_CMD"
            chmod -R 755 $CERT_DIR
            echo -e "${GREEN}证书申请并安装完成！${PLAIN}"
            sleep 2
            ;;
        2)
            if [ -z "$DOMAIN" ] || [ ! -f "$CERT_DIR/fullchain.cer" ]; then
                echo -e "${RED}未找到已申请的证书记录，请先执行申请证书！${PLAIN}"
                sleep 2; return
            fi
            echo -e "${CYAN}正在强制续期证书: $DOMAIN ...${PLAIN}"
            ~/.acme.sh/acme.sh --renew -d ${DOMAIN} --force
            echo -e "${GREEN}手动续期执行完毕！${PLAIN}"
            sleep 2
            ;;
        3)
            echo -e "\n------------- 证书信息 -------------"
            if [ -f "$CERT_DIR/fullchain.cer" ]; then
                echo -e "绑定的域名\t: ${GREEN}${DOMAIN:-自签默认}${PLAIN}"
                echo -e "证书类型\t: ${GREEN}${CERT_TYPE:-unknown}${PLAIN}"
                echo -e "证书路径\t: ${GREEN}$CERT_DIR/fullchain.cer${PLAIN}"
                echo -e "私钥路径\t: ${GREEN}$CERT_DIR/private.key${PLAIN}"
                echo -e "\n------------- 自动续期 -------------"
                if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                    echo -e "${GREEN}acme.sh 自动续期定时任务已正常运行中！${PLAIN}"
                    crontab -l | grep "acme.sh"
                else
                    echo -e "${RED}警告: 未发现 acme.sh 自动续期定时任务！${PLAIN}"
                fi
            else
                echo -e "${YELLOW}当前未安装任何域名证书。${PLAIN}"
            fi
            echo -e "------------------------------------"
            read -p "按回车键返回菜单..."
            ;;
        0) return ;;
        *) echo "输入错误!"; sleep 1 ;;
    esac
}

check_cert() {
    load_secrets
    if [ -f "$CERT_DIR/fullchain.cer" ] && [ -f "$CERT_DIR/private.key" ]; then return 0; fi
    
    echo -e "${YELLOW}当前节点协议强制需要使用 TLS 加密！${PLAIN}"
    read -p "是否申请真实域名证书? (y/n) [默认: y]: " apply_cert
    apply_cert=${apply_cert:-y}

    if [[ "$apply_cert" == "y" ]]; then
        echo -e "${CYAN}准备自动调用证书申请...${PLAIN}"
        read -p "请输入你的真实域名: " DOMAIN
        read -p "请输入 Cloudflare 邮箱: " CF_Email
        read -p "请输入 Cloudflare Global API Key: " CF_Key
        save_secret "DOMAIN" "$DOMAIN"
        save_secret "CERT_TYPE" "real"

        export CF_Key="${CF_Key}"
        export CF_Email="${CF_Email}"
        curl -sL https://get.acme.sh | sh
        ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
        ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${DOMAIN}
        
        if [ "$OS_TYPE" == "alpine" ]; then
            RELOAD_CMD="rc-service sing-box restart"
        else
            RELOAD_CMD="systemctl restart sing-box"
        fi
        ~/.acme.sh/acme.sh --installcert -d ${DOMAIN} --fullchainpath $CERT_DIR/fullchain.cer --keypath $CERT_DIR/private.key --reloadcmd "$RELOAD_CMD"
        chmod -R 755 $CERT_DIR
        echo -e "${GREEN}真实域名证书申请成功！${PLAIN}"
    else
        echo -e "${CYAN}准备生成自签名证书...${PLAIN}"
        read -p "请输入伪装域名 [默认: bing.com]: " DOMAIN
        DOMAIN=${DOMAIN:-bing.com}
        save_secret "DOMAIN" "$DOMAIN"
        save_secret "CERT_TYPE" "self"
        
        openssl req -x509 -nodes -days 36500 -newkey rsa:2048 -keyout $CERT_DIR/private.key -out $CERT_DIR/fullchain.cer -subj "/CN=${DOMAIN}" >/dev/null 2>&1
        chmod -R 755 $CERT_DIR
        echo -e "${GREEN}自签名证书生成完毕！${PLAIN}"
    fi
}

restart_service() {
    local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE)
    if [ "$INBOUND_COUNT" -eq 0 ]; then
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service sing-box stop >/dev/null 2>&1
        else
            systemctl stop sing-box >/dev/null 2>&1
        fi
        return 0
    fi

    if ! /usr/local/bin/sing-box check -c $CONFIG_FILE >/dev/null 2>&1; then
        echo -e "${RED}配置文件校验失败，请检查语法或端口冲突！${PLAIN}"
        /usr/local/bin/sing-box check -c $CONFIG_FILE
        return 1
    fi
    
    if [ "$OS_TYPE" == "alpine" ]; then
        cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/var/run/sing-box.pid"
depend() {
    need net
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        rc-service sing-box restart >/dev/null 2>&1
    else
        cat > /etc/systemd/system/sing-box.service << 'EOF'
[Unit]
Description=sing-box service
After=network.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable sing-box --now >/dev/null 2>&1
        systemctl restart sing-box >/dev/null 2>&1
    fi
    return 0
}

build_share_url() {
    local TAG=$1
    local IP=$2
    local CONN_ADDR=$IP
    local INSECURE=1
    local SNI_URL=""
    
    if [ "$CERT_TYPE" == "real" ]; then
        CONN_ADDR=$DOMAIN
        INSECURE=0
        SNI_URL="&sni=${DOMAIN}"
    fi
    
    local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
    local PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)
    
    case "$TYPE" in
        vless)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' $CONFIG_FILE)
            if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1; then
                local SNI=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.server_name' $CONFIG_FILE)
                local SID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.short_id[0]' $CONFIG_FILE)
                local PUB=$(eval echo \$REALITY_PUB_${PORT})
                echo "vless://${AUTH}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
            elif jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                local A_IP=$(eval echo \$ARGO_IP_${PORT})
                local A_DOM=$(eval echo \$ARGO_DOMAIN_${PORT})
                echo "vless://${AUTH}@${A_IP}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            echo "hysteria2://${AUTH}@${CONN_ADDR}:${PORT}?security=tls&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
            ;;
        tuic)
            local T_UUID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' $CONFIG_FILE)
            local T_PASS=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            echo "tuic://${T_UUID}:${T_PASS}@${CONN_ADDR}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
            ;;
        anytls)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            echo "anytls://${AUTH}@${CONN_ADDR}:${PORT}?insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
            ;;
    esac
}

print_config_detail() {
    local TAG=$1
    local IP=$(get_ip)
    load_secrets
    
    local CONN_ADDR=$IP
    local INSECURE_TEXT="true"
    if [ "$CERT_TYPE" == "real" ]; then
        CONN_ADDR=$DOMAIN
        INSECURE_TEXT="false"
    fi
    
    local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
    local PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)
    
    echo -e "\n-------------- ${YELLOW}$TAG${PLAIN} -------------"
    echo -e "协议 (protocol)\t\t\t= $TYPE"
    
    case "$TYPE" in
        vless)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' $CONFIG_FILE)
            if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1; then
                local SNI=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.server_name' $CONFIG_FILE)
                local SID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.short_id[0]' $CONFIG_FILE)
                local PUB=$(eval echo \$REALITY_PUB_${PORT})
                echo -e "地址 (address)\t\t\t= $IP"
                echo -e "端口 (port)\t\t\t= $PORT"
                echo -e "用户ID (id)\t\t\t= $AUTH"
                echo -e "流控 (flow)\t\t\t= xtls-rprx-vision"
                echo -e "传输层安全 (TLS)\t\t= reality"
                echo -e "伪装域名 (sni)\t\t\t= $SNI"
                echo -e "公钥 (pbk)\t\t\t= $PUB"
                echo -e "ShortId (sid)\t\t\t= $SID"
            elif jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                local A_IP=$(eval echo \$ARGO_IP_${PORT})
                local A_DOM=$(eval echo \$ARGO_DOMAIN_${PORT})
                echo -e "地址 (address)\t\t\t= $A_IP"
                echo -e "端口 (port)\t\t\t= 443"
                echo -e "用户ID (id)\t\t\t= $AUTH"
                echo -e "传输协议 (network)\t\t= ws"
                echo -e "传输层安全 (TLS)\t\t= tls"
                echo -e "伪装域名 (sni)\t\t\t= $A_DOM"
                echo -e "请求主机 (host)\t\t\t= $A_DOM"
                echo -e "路径 (path)\t\t\t= /argo"
            fi
            ;;
        hysteria2)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            echo -e "地址 (address)\t\t\t= $CONN_ADDR"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $AUTH"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ "$CERT_TYPE" == "real" ] && echo -e "伪装域名 (sni)\t\t\t= $DOMAIN"
            ;;
        tuic)
            local T_UUID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' $CONFIG_FILE)
            local T_PASS=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            echo -e "地址 (address)\t\t\t= $CONN_ADDR"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "用户ID (id)\t\t\t= $T_UUID"
            echo -e "密码 (password)\t\t\t= $T_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            echo -e "拥塞控制算法 (congestion_control)= bbr"
            [ "$CERT_TYPE" == "real" ] && echo -e "伪装域名 (sni)\t\t\t= $DOMAIN"
            ;;
        anytls)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            echo -e "地址 (address)\t\t\t= $CONN_ADDR"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $AUTH"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ "$CERT_TYPE" == "real" ] && echo -e "伪装域名 (sni)\t\t\t= $DOMAIN"
            ;;
    esac
    
    echo -e "------------- 链接 (URL) -------------"
    build_share_url "$TAG" "$IP"
    
    if [ "$CERT_TYPE" != "real" ] && ! jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1 && ! jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
        echo -e "\n${YELLOW}警告! 您当前使用的是自签名证书，请确保客户端已开启「跳过证书验证」！${PLAIN}\n"
    fi
}

get_unique_tag() {
    local base_tag=$1
    local counter=2
    local final_tag=$base_tag
    while jq -e --arg tag "$final_tag" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; do
        final_tag="${base_tag}-${counter}"
        ((counter++))
    done
    echo "$final_tag"
}

select_inbound() {
    TAGS=($(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' $CONFIG_FILE))
    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "${RED}未添加节点配置！${PLAIN}"
        sleep 2
        return 1
    fi
    for i in "${!TAGS[@]}"; do
        echo -e " $((i + 1))) ${CYAN}${TAGS[$i]}${PLAIN}"
    done
    echo -e " 0) 返回"
    echo ""
    read -p "请选择 [0-${#TAGS[@]}]: " idx
    if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return 1; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -gt "${#TAGS[@]}" ]; then echo "输入错误!"; sleep 1; return 1; fi
    ((idx--))
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return 1; fi
    return 0
}

add_config() {
    clear
    echo -e "请选择协议:\n"
    echo -e " 1) VLESS-REALITY"
    echo -e " 2) Hysteria2"
    echo -e " 3) TUIC v5"
    echo -e " 4) AnyTLS"
    echo -e " 5) VLESS-WS (Argo)"
    echo -e " 0) 返回\n"
    read -p "请选择 [0-5]: " proto_idx

    case "$proto_idx" in
        1|2|3|4|5) ;;
        0) return ;;
        *) echo "输入错误"; sleep 1; return ;;
    esac

    load_secrets
    DEF_PORT=$(rand_port)
    
    read -p "请输入监听端口 [默认: $DEF_PORT]: " PORT
    PORT=${PORT:-$DEF_PORT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}错误! 请输入正确的端口, 可选(1-65535)${PLAIN}"
        sleep 1; return
    fi
    
    if check_port "$PORT"; then
        echo -e "${RED}错误! 端口 ${PORT} 已被占用，请重新选择！${PLAIN}"
        sleep 2; return
    fi
    
    echo -e "使用: ${GREEN}${PORT}${PLAIN}"
    
    HOST_NAME=$(hostname 2>/dev/null || echo "vps")
    HOST_NAME=$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')
    
    cp $CONFIG_FILE ${CONFIG_FILE}.bak
    
    case "$proto_idx" in
        1)
            read -p "请输入UUID [默认随机]: " input_uuid
            UUID=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "UUID: ${GREEN}${UUID}${PLAIN}"
            
            DEF_TAG="vless-reality-${HOST_NAME}"
            read -p "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            TAG=$(get_unique_tag "${input_tag:-$DEF_TAG}")
            
            read -p "请输入伪装域名 [默认: apple.com]: " SNI
            SNI=${SNI:-apple.com}
            KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
            PK=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
            PUB=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
            SID=$(/usr/local/bin/sing-box generate rand --hex 8)
            save_secret "REALITY_PUB_${PORT}" "$PUB"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg pk "$PK" --arg sid "$SID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        2)
            read -p "请输入密码 [默认随机]: " input_pass
            PASS=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "密码: ${GREEN}${PASS}${PLAIN}"
            
            DEF_TAG="hysteria2-${HOST_NAME}"
            read -p "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            TAG=$(get_unique_tag "${input_tag:-$DEF_TAG}")
            
            check_cert
            jq --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" \
            '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        3)
            read -p "请输入UUID [默认随机]: " input_uuid
            UUID=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "UUID: ${GREEN}${UUID}${PLAIN}"
            
            read -p "请输入密码 [默认随机]: " input_pass
            PASS=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "密码: ${GREEN}${PASS}${PLAIN}"
            
            DEF_TAG="tuic-${HOST_NAME}"
            read -p "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            TAG=$(get_unique_tag "${input_tag:-$DEF_TAG}")
            
            check_cert
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg tag "$TAG" \
            '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        4)
            read -p "请输入密码 [默认随机]: " input_pass
            PASS=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "密码: ${GREEN}${PASS}${PLAIN}"
            
            DEF_TAG="anytls-${HOST_NAME}"
            read -p "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            TAG=$(get_unique_tag "${input_tag:-$DEF_TAG}")
            
            check_cert
            jq --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" \
            '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h2","http/1.1"],"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        5)
            read -p "请输入UUID [默认随机]: " input_uuid
            UUID=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "UUID: ${GREEN}${UUID}${PLAIN}"
            
            DEF_TAG="argo-ws-${HOST_NAME}"
            read -p "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            TAG=$(get_unique_tag "${input_tag:-$DEF_TAG}")
            
            read -p "请输入 Argo 优选域名/IP [默认: icook.hk]: " ARGO_IP
            ARGO_IP=${ARGO_IP:-icook.hk}
            read -p "请输入 Argo 隧道域名: " ARGO_DOMAIN
            read -p "请输入 Cloudflare Tunnel Token: " ARGO_TOKEN
            save_secret "ARGO_IP_${PORT}" "$ARGO_IP"
            save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"127.0.0.1","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            
            if ! command -v cloudflared &> /dev/null; then
                ARCH=$(uname -m)
                case "$ARCH" in
                    x86_64) CF_ARCH="amd64" ;;
                    aarch64|arm64) CF_ARCH="arm64" ;;
                    *) CF_ARCH="amd64" ;;
                esac
                echo -e "${CYAN}正在下载 cloudflared 组件，请稍候...${PLAIN}"
                wget --show-progress -qO /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" || curl -L -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
                chmod +x /usr/local/bin/cloudflared
            fi
            
            if [ "$OS_TYPE" == "alpine" ]; then
                cat > /etc/init.d/cloudflared-${TAG} << EOF
#!/sbin/openrc-run
name="cloudflared-${TAG}"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --protocol http2 run --token ${ARGO_TOKEN}"
command_background=true
pidfile="/var/run/cloudflared-${TAG}.pid"
depend() {
    need net
}
EOF
                chmod +x /etc/init.d/cloudflared-${TAG}
                rc-update add cloudflared-${TAG} default >/dev/null 2>&1
                rc-service cloudflared-${TAG} restart >/dev/null 2>&1
            else
                cat > /etc/systemd/system/cloudflared-${TAG}.service << EOF
[Unit]
Description=cloudflared tunnel for ${TAG}
After=network.target

[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token ${ARGO_TOKEN}
Restart=on-failure
RestartSec=10s

[Install]
WantedBy=multi-user.target
EOF
                systemctl daemon-reload >/dev/null 2>&1
                systemctl enable cloudflared-${TAG} --now >/dev/null 2>&1
            fi
            ;;
    esac
    
    if ! restart_service; then
        echo -e "${RED}节点添加失败，已为您还原配置！${PLAIN}"
        mv ${CONFIG_FILE}.bak $CONFIG_FILE
        sleep 2
        return
    fi
    
    local f_proto=""
    if [ "$proto_idx" == "1" ] || [ "$proto_idx" == "4" ]; then
        f_proto="tcp"
    elif [ "$proto_idx" == "2" ] || [ "$proto_idx" == "3" ]; then
        f_proto="udp"
    fi
    
    if [ -n "$f_proto" ]; then
        echo ""
        read -p "是否自动放行端口？(y/n) [默认: y]: " auto_fw
        auto_fw=${auto_fw:-y}
        if [[ "$auto_fw" == "y" || "$auto_fw" == "Y" ]]; then
            open_fw_port "$PORT" "$f_proto"
        fi
    fi
    
    print_config_detail "$TAG"
    read -p "按回车键返回菜单..."
}

modify_config() {
    clear
    echo -e "选择: 更改配置\n"
    select_inbound || return

    local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
    local OLD_PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)

    echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"
    
    if [ "$TYPE" == "vless" ]; then
        echo -e " 1) 更改 UUID"
        echo -e " 2) 更改端口"
        echo -e " 3) 更改节点名称"
        echo -e " 0) 返回"
        read -p "请选择 [0-3]: " mod_idx
        case "$mod_idx" in
            1) action="uuid" ;;
            2) action="port" ;;
            3) action="tag" ;;
            0) return ;;
            *) echo "输入错误!"; sleep 1; return ;;
        esac
    elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "anytls" ]]; then
        echo -e " 1) 更改密码"
        echo -e " 2) 更改端口"
        echo -e " 3) 更改节点名称"
        echo -e " 0) 返回"
        read -p "请选择 [0-3]: " mod_idx
        case "$mod_idx" in
            1) action="pass" ;;
            2) action="port" ;;
            3) action="tag" ;;
            0) return ;;
            *) echo "输入错误!"; sleep 1; return ;;
        esac
    elif [ "$TYPE" == "tuic" ]; then
        echo -e " 1) 更改 UUID"
        echo -e " 2) 更改密码"
        echo -e " 3) 更改端口"
        echo -e " 4) 更改节点名称"
        echo -e " 0) 返回"
        read -p "请选择 [0-4]: " mod_idx
        case "$mod_idx" in
            1) action="uuid" ;;
            2) action="pass" ;;
            3) action="port" ;;
            4) action="tag" ;;
            0) return ;;
            *) echo "输入错误!"; sleep 1; return ;;
        esac
    else
        echo "未知的协议类型"
        sleep 1; return
    fi

    cp $CONFIG_FILE ${CONFIG_FILE}.bak

    if [ "$action" == "uuid" ]; then
        read -p "请输入UUID [默认随机]: " input_uuid
        NEW_AUTH=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
        echo -e "UUID: ${GREEN}${NEW_AUTH}${PLAIN}"
        jq --arg tag "$TAG" --arg auth "$NEW_AUTH" '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $auth' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}节点 $TAG 的 UUID 已更新！${PLAIN}"
        sleep 2
    elif [ "$action" == "pass" ]; then
        read -p "请输入密码 [默认随机]: " input_pass
        NEW_AUTH=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
        echo -e "密码: ${GREEN}${NEW_AUTH}${PLAIN}"
        jq --arg tag "$TAG" --arg auth "$NEW_AUTH" '(.inbounds[] | select(.tag==$tag) | .users[0].password) = $auth' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}节点 $TAG 的密码已更新！${PLAIN}"
        sleep 2
    elif [ "$action" == "port" ]; then
        NEW_PORT=$(rand_port)
        read -p "请输入新端口 [默认: $NEW_PORT]: " input_port
        NEW_PORT=${input_port:-$NEW_PORT}
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
            echo -e "${RED}输入错误!${PLAIN}"; sleep 1; return
        fi
        
        if check_port "$NEW_PORT"; then
            echo -e "${RED}错误! 端口 ${NEW_PORT} 已被占用，请重新选择！${PLAIN}"
            sleep 2; return
        fi
        
        local f_proto=""
        if [ "$TYPE" == "vless" ] && ! jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
            f_proto="tcp"
        elif [ "$TYPE" == "hysteria2" ] || [ "$TYPE" == "tuic" ]; then
            f_proto="udp"
        elif [ "$TYPE" == "anytls" ]; then
            f_proto="tcp"
        fi

        if [ -n "$f_proto" ]; then
            close_fw_port "$OLD_PORT" "$f_proto"
            sed -i "|^${OLD_PORT}/${f_proto}$|d" "$FW_PORTS_FILE" 2>/dev/null
        fi
        
        jq --arg tag "$TAG" --argjson p "$NEW_PORT" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $p' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        
        load_secrets
        if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1; then
            PUB=$(eval echo \$REALITY_PUB_${OLD_PORT})
            save_secret "REALITY_PUB_${NEW_PORT}" "$PUB"
        elif jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
            A_IP=$(eval echo \$ARGO_IP_${OLD_PORT})
            A_DOM=$(eval echo \$ARGO_DOMAIN_${OLD_PORT})
            save_secret "ARGO_IP_${NEW_PORT}" "$A_IP"
            save_secret "ARGO_DOMAIN_${NEW_PORT}" "$A_DOM"
        fi
        
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}端口已更改为: $NEW_PORT${PLAIN}"
        
        if [ -n "$f_proto" ]; then
            echo ""
            read -p "是否自动放行新端口？(y/n) [默认: y]: " auto_fw
            auto_fw=${auto_fw:-y}
            if [[ "$auto_fw" == "y" || "$auto_fw" == "Y" ]]; then
                open_fw_port "$NEW_PORT" "$f_proto"
            fi
            read -p "按回车键继续..."
        else
            sleep 2
        fi
        
        echo -e "${GREEN}节点 $TAG 的配置已生效！${PLAIN}"
        sleep 2
    elif [ "$action" == "tag" ]; then
        read -p "请输入新的节点名称: " NEW_TAG
        if [ -z "$NEW_TAG" ]; then
            echo -e "${RED}输入不能为空!${PLAIN}"
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
            sleep 1; return
        fi
        if jq -e --arg tag "$NEW_TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${RED}该节点名称已存在，请换一个名称！${PLAIN}"
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
            sleep 1; return
        fi
        
        local IS_ARGO=0
        if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
            IS_ARGO=1
        fi
        
        if [ "$IS_ARGO" -eq 1 ]; then
            if [ "$OS_TYPE" == "alpine" ]; then
                rc-service cloudflared-${TAG} stop >/dev/null 2>&1
                rc-update del cloudflared-${TAG} default >/dev/null 2>&1
                mv /etc/init.d/cloudflared-${TAG} /etc/init.d/cloudflared-${NEW_TAG}
                sed -i "s/name=\"cloudflared-${TAG}\"/name=\"cloudflared-${NEW_TAG}\"/g" /etc/init.d/cloudflared-${NEW_TAG}
                sed -i "s/cloudflared-${TAG}\.pid/cloudflared-${NEW_TAG}\.pid/g" /etc/init.d/cloudflared-${NEW_TAG}
                rc-update add cloudflared-${NEW_TAG} default >/dev/null 2>&1
                rc-service cloudflared-${NEW_TAG} start >/dev/null 2>&1
            else
                systemctl stop cloudflared-${TAG} >/dev/null 2>&1
                systemctl disable cloudflared-${TAG} >/dev/null 2>&1
                mv /etc/systemd/system/cloudflared-${TAG}.service /etc/systemd/system/cloudflared-${NEW_TAG}.service
                sed -i "s/tunnel for ${TAG}/tunnel for ${NEW_TAG}/g" /etc/systemd/system/cloudflared-${NEW_TAG}.service
                systemctl daemon-reload >/dev/null 2>&1
                systemctl enable cloudflared-${NEW_TAG} --now >/dev/null 2>&1
            fi
        fi

        jq --arg tag "$TAG" --arg newtag "$NEW_TAG" '(.inbounds[] | select(.tag==$tag) | .tag) = $newtag' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}节点名称已成功更改为: $NEW_TAG${PLAIN}"
        sleep 2
    fi
}

del_config() {
    clear
    echo -e "选择: 删除配置\n"
    select_inbound || return
    
    local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
    local PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)

    local f_proto=""
    if [ "$TYPE" == "vless" ] && ! jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
        f_proto="tcp"
    elif [ "$TYPE" == "hysteria2" ] || [ "$TYPE" == "tuic" ]; then
        f_proto="udp"
    elif [ "$TYPE" == "anytls" ]; then
        f_proto="tcp"
    fi

    if [ -n "$f_proto" ]; then
        close_fw_port "$PORT" "$f_proto"
        sed -i "|^${PORT}/${f_proto}$|d" "$FW_PORTS_FILE" 2>/dev/null
    fi
    
    local IS_ARGO=0
    if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
        IS_ARGO=1
    fi
    
    jq --arg tag "$TAG" 'del(.inbounds[] | select(.tag == $tag))' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
    
    if [ "$IS_ARGO" -eq 1 ]; then
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service cloudflared-${TAG} stop >/dev/null 2>&1
            rc-update del cloudflared-${TAG} default >/dev/null 2>&1
            rm -f /etc/init.d/cloudflared-${TAG}
        else
            systemctl stop cloudflared-${TAG} >/dev/null 2>&1
            systemctl disable cloudflared-${TAG} >/dev/null 2>&1
            rm -f /etc/systemd/system/cloudflared-${TAG}.service
            systemctl daemon-reload >/dev/null 2>&1
        fi
    fi
    
    restart_service
    
    local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE)
    if [ "$INBOUND_COUNT" -eq 0 ]; then
        echo -e "${GREEN}配置 $TAG 已删除！检测到当前已无节点配置，内核已自动停止运行。${PLAIN}"
    else
        echo -e "${GREEN}配置 $TAG 已删除！${PLAIN}"
    fi
    sleep 2
}

view_single_config() {
    clear
    echo -e "选择: 单协议链接\n"
    select_inbound || return
    print_config_detail "$TAG"
    read -p "按回车键返回菜单..."
}

show_all_links() {
    clear
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "🚀【 聚合节点 】节点信息如下：\n"
    echo -e "分享链接"
    TAGS=($(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' $CONFIG_FILE))
    
    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "\n${RED}未添加节点配置！${PLAIN}"
        echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
        sleep 2
        return
    fi
    
    IP=$(get_ip)
    for TAG in "${TAGS[@]}"; do
        build_share_url "$TAG" "$IP"
    done
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    read -p "按回车键返回菜单..."
}

view_config() {
    clear
    echo -e "选择: 查看配置\n"
    echo -e " 1) 单协议链接"
    echo -e " 2) 聚合链接"
    echo -e " 0) 返回"
    echo ""
    read -p "请选择 [0-2]: " v_idx
    case "$v_idx" in
        1) view_single_config ;;
        2) show_all_links ;;
        0) return ;;
        *) echo "输入错误!"; sleep 1 ;;
    esac
}

run_manage() {
    clear
    echo -e "选择: 运行管理\n"
    echo " 1) 启动"
    echo " 2) 停止"
    echo " 3) 重启"
    echo " 0) 返回"
    echo ""
    read -p "请选择 [0-3]: " run_idx
    case "$run_idx" in
        1) 
           local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE 2>/dev/null)
           if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then
               echo -e "${RED}未添加节点配置！请先添加配置。${PLAIN}"; sleep 2; return
           fi
           if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box start; else systemctl start sing-box; fi
           echo -e "${GREEN}已启动${PLAIN}"; sleep 1 ;;
        2) 
           if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop; else systemctl stop sing-box; fi
           echo -e "${GREEN}已停止${PLAIN}"; sleep 1 ;;
        3) 
           local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE 2>/dev/null)
           if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then
               echo -e "${RED}未添加节点配置！请先添加配置。${PLAIN}"; sleep 2; return
           fi
           restart_service; echo -e "${GREEN}已重启${PLAIN}"; sleep 1 ;;
        0) return ;;
        *) echo "输入错误!"; sleep 1 ;;
    esac
}

update_manage() {
    clear
    echo -e "${CYAN}正在检查 sing-box 内核新版本，请稍候...${PLAIN}"
    
    local CUR_VER="未安装"
    if [ -f "/usr/local/bin/sing-box" ]; then
        CUR_VER=$(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
    fi
    
    local NEW_VER=$(get_latest_version)
    
    local SB_UPDATE_TEXT="更新 sing-box 内核"
    if [ -n "$NEW_VER" ]; then
        if [ "$CUR_VER" != "$NEW_VER" ]; then
            SB_UPDATE_TEXT="更新 sing-box 内核 ${GREEN}[发现新版: v${NEW_VER}]${PLAIN}"
        else
            SB_UPDATE_TEXT="更新 sing-box 内核 ${YELLOW}[已是最新: v${CUR_VER}]${PLAIN}"
        fi
    fi

    clear
    echo -e "选择: 更新\n"
    echo -e " 1) ${SB_UPDATE_TEXT}"
    echo -e " 2) 更新脚本"
    echo -e " 0) 返回\n"
    read -p "请选择 [0-2]: " up_idx
    
    case "$up_idx" in
        1)
            if [ -z "$NEW_VER" ]; then
                echo -e "${RED}获取最新版本信息失败，请检查网络！${PLAIN}"
                sleep 2; return
            fi
            if [ "$CUR_VER" == "$NEW_VER" ]; then
                echo -e "\n${GREEN}当前已是最新版本 v${CUR_VER}，无需更新！${PLAIN}"
                sleep 2; return
            fi
            
            echo -e "\n${YELLOW}即将更新内核至 v${NEW_VER}...${PLAIN}"
            rm -f /usr/local/bin/sing-box
            init_base
            if [ -f "/usr/local/bin/sing-box" ]; then
                restart_service
                GLOBAL_LATEST_VER="$NEW_VER"
                echo -e "\n${GREEN}内核更新成功！当前版本: v${NEW_VER}${PLAIN}"
            else
                echo -e "\n${RED}内核更新失败，请检查网络！${PLAIN}"
            fi
            read -p "按回车键返回菜单..."
            ;;
        2)
            echo -e "\n${CYAN}正在拉取最新脚本代码...${PLAIN}"
            curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o /usr/local/bin/sb
            chmod +x /usr/local/bin/sb
            echo -e "${GREEN}脚本代码更新成功！请重新运行 sb 命令进入面板。${PLAIN}"
            exit 0
            ;;
        0) return ;;
        *) echo "输入错误!"; sleep 1 ;;
    esac
}

uninstall_all() {
    read -p "确认卸载脚本,sing-box和删除所有节点配置吗？(y/n): " un
    if [[ "$un" == "y" ]]; then
        remove_all_fw_rules
        
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service sing-box stop >/dev/null 2>&1
            rc-update del sing-box default >/dev/null 2>&1
            rm -f /etc/init.d/sing-box
            for f in /etc/init.d/cloudflared-*; do
                if [ -f "$f" ]; then
                    svc=$(basename "$f")
                    rc-service "$svc" stop >/dev/null 2>&1
                    rc-update del "$svc" default >/dev/null 2>&1
                    rm -f "$f"
                fi
            done
        else
            systemctl stop sing-box >/dev/null 2>&1
            systemctl disable sing-box >/dev/null 2>&1
            rm -f /etc/systemd/system/sing-box.service
            for f in /etc/systemd/system/cloudflared-*.service; do
                if [ -f "$f" ]; then
                    svc=$(basename "$f")
                    systemctl stop "$svc" >/dev/null 2>&1
                    systemctl disable "$svc" >/dev/null 2>&1
                    rm -f "$f"
                fi
            done
            systemctl daemon-reload >/dev/null 2>&1
        fi
        
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then
            $HOME/.acme.sh/acme.sh --uninstall >/dev/null 2>&1
            rm -rf $HOME/.acme.sh
        fi
        crontab -l 2>/dev/null | grep -v "acme.sh" | crontab - 2>/dev/null
        
        rm -rf /usr/local/bin/sing-box /usr/local/bin/cloudflared /usr/local/bin/sb /etc/sing-box
        echo -e "${GREEN}已彻底卸载！系统已恢复原状。${PLAIN}"
    fi
}

menu() {
    init_base
    local LATEST_VER_CACHE=$(get_latest_version)

    while true; do
        clear
        if [ "$OS_TYPE" == "alpine" ]; then
            SB_STATUS=$(rc-service sing-box status 2>/dev/null | grep -o 'started')
            [ "$SB_STATUS" == "started" ] && SB_STATUS="active" || SB_STATUS="stopped"
        else
            SB_STATUS=$(systemctl is-active sing-box 2>/dev/null)
        fi
        [ "$SB_STATUS" == "active" ] && ST_COLOR=$GREEN || ST_COLOR=$RED
        
        VER=$(sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        
        if [ -n "$VER" ]; then
            if [ -n "$GLOBAL_LATEST_VER" ] && [ "$VER" != "$GLOBAL_LATEST_VER" ]; then
                VER_SHOW="${VER} ${YELLOW}[新版: ${GLOBAL_LATEST_VER}]${PLAIN}"
            else
                VER_SHOW="${VER}"
            fi
        else
            VER_SHOW="未安装"
        fi
        
        echo -e "------------- sing-box 管理脚本 -------------"
        echo -e "sing-box ${VER_SHOW}: ${ST_COLOR}${SB_STATUS}${PLAIN}"
        echo -e ""
        echo -e " 1) 添加配置"
        echo -e " 2) 更改配置"
        echo -e " 3) 删除配置"
        echo -e " 4) 查看配置"
        echo -e " 5) 证书管理"
        echo -e " 6) 运行管理"
        echo -e " 7) 更新"
        echo -e " 8) 卸载"
        echo -e " 0) 退出"
        echo -e ""
        read -p "请选择 [0-8]: " choice

        case "$choice" in
            1) add_config ;;
            2) modify_config ;;
            3) del_config ;;
            4) view_config ;;
            5) cert_manage ;;
            6) run_manage ;;
            7) update_manage ;;
            8) uninstall_all; exit 0 ;;
            0) exit 0 ;;
            *) echo "输入错误!"; sleep 1 ;;
        esac
    done
}

if [[ "$0" != "/usr/local/bin/sb" ]] && [[ "$0" != "sb" ]] && [[ "$0" != *"/sb" ]]; then
    if [ -f "/usr/local/bin/sb" ]; then
        clear
        echo -e "${GREEN}检测到 sing-box 管理脚本已经安装！${PLAIN}\n"
        echo -e " 1. 更新覆盖脚本"
        echo -e " 2. 卸载脚本"
        echo -e " 3. 进入面板"
        echo -e " 4. 退出"
        echo ""
        read -p "请选择 [1-4]: " pre_choice
        case "$pre_choice" in
            1)
                echo -e "${CYAN}正在拉取最新脚本代码...${PLAIN}"
                curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o /usr/local/bin/sb
                chmod +x /usr/local/bin/sb
                echo -e "${GREEN}脚本代码更新成功！请执行 sb 命令进入面板。${PLAIN}"
                exit 0
                ;;
            2)
                uninstall_all
                exit 0
                ;;
            3)
                ;;
            *)
                exit 0
                ;;
        esac
    else
        echo -e "${CYAN}==> 正在将管理脚本写入到全局环境...${PLAIN}"
        curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o /usr/local/bin/sb
        chmod +x /usr/local/bin/sb
        rm -f sb.sh install.sh 2>/dev/null
        
        echo -e "\n${GREEN}==> 脚本安装完成！以后可随时输入 ${YELLOW}sb${GREEN} 快捷调用本面板。${PLAIN}"
        sleep 2
    fi
fi

menu
