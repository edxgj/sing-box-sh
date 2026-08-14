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
TMP_JSON="/tmp/sb_tmp.json"

if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
else
    OS_TYPE="debian"
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须以 root 身份运行本脚本！${PLAIN}"
    exit 1
fi

if [[ "$0" != "/usr/local/bin/sb" ]]; then
    curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o /usr/local/bin/sb
    chmod +x /usr/local/bin/sb
    rm -f sb.sh install.sh 2>/dev/null
fi

rand_port() { shuf -i 10000-65000 -n 1; }

get_ip() { curl -s ipv4.icanhazip.com; }

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

init_base() {
    if ! command -v jq &> /dev/null || [ ! -f "/usr/local/bin/sing-box" ]; then
        echo -e "${CYAN}==> 正在准备环境与内核...${PLAIN}"
        if [ "$OS_TYPE" == "alpine" ]; then
            apk update >/dev/null 2>&1
            apk add curl wget jq tar openssl socat bash nano libc6-compat gcompat >/dev/null 2>&1
            rc-update add crond default >/dev/null 2>&1
            rc-service crond start >/dev/null 2>&1
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

        echo -e "${CYAN}==> 正在下载最新版 sing-box 内核...${PLAIN}"
        LATEST_TAG=$(curl -s "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        VERSION=${LATEST_TAG#v}
        wget -qO sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/${LATEST_TAG}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"
        tar -xzf sing-box.tar.gz
        mv sing-box-${VERSION}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
        chmod +x /usr/local/bin/sing-box
        rm -rf sing-box.tar.gz sing-box-${VERSION}-linux-${SB_ARCH}
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
    echo -e " 1) 申请新证书 (覆盖当前)"
    echo -e " 2) 手动强制续期"
    echo -e " 3) 查看证书与自动续期状态"
    echo -e " 0) 返回"
    echo ""
    read -p "请选择 [0-3]: " cert_idx

    load_secrets
    case "$cert_idx" in
        1)
            echo -e "${YELLOW}注意: 申请证书需要域名已成功解析到本机 IP！${PLAIN}"
            read -p "请输入你的域名 (如 node.domain.com): " NEW_DOMAIN
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
            echo -e "${GREEN}证书申请并安装完成！(acme.sh 已自动配置系统定时续期任务)${PLAIN}"
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
                    echo -e "${RED}警告: 未发现 acme.sh 自动续期定时任务 (若您使用的是自签名证书请忽略此警告)！${PLAIN}"
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
    
    echo -e "${YELLOW}当前节点协议需要 TLS 加密！${PLAIN}"
    read -p "是否申请真实域名证书? (y/n) [默认: y]: " apply_cert
    apply_cert=${apply_cert:-y}

    if [[ "$apply_cert" == "y" ]]; then
        echo -e "${CYAN}准备自动调用证书申请...${PLAIN}"
        read -p "请输入你的真实域名 (如 node.domain.com): " DOMAIN
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
        echo -e "${CYAN}已为您静默生成自签名证书...${PLAIN}"
        save_secret "CERT_TYPE" "self"
        
        openssl req -x509 -nodes -days 36500 -newkey rsa:2048 -keyout $CERT_DIR/private.key -out $CERT_DIR/fullchain.cer -subj "/CN=bing.com" >/dev/null 2>&1
        chmod -R 755 $CERT_DIR
    fi
}

restart_service() {
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

print_config_detail() {
    local TAG=$1
    local IP=$(get_ip)
    load_secrets
    
    local CONN_ADDR=$IP
    local INSECURE=1
    local INSECURE_TEXT="true"
    local SNI_URL=""
    
    if [ "$CERT_TYPE" == "real" ]; then
        CONN_ADDR=$DOMAIN
        INSECURE=0
        INSECURE_TEXT="false"
        SNI_URL="&sni=${DOMAIN}"
    fi
    
    local TYPE=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .type' $CONFIG_FILE)
    local PORT=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .listen_port' $CONFIG_FILE)
    
    echo -e "\n-------------- ${YELLOW}$TAG${PLAIN} -------------"
    echo -e "协议 (protocol)\t\t\t= $TYPE"
    
    case "$TYPE" in
        vless)
            local AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
            if [[ "$TAG" == *"reality"* ]]; then
                local SNI=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.server_name' $CONFIG_FILE)
                local SID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.reality.short_id[0]' $CONFIG_FILE)
                local PUB=$(eval echo \$REALITY_PUB_${PORT})
                echo -e "地址 (address)\t\t\t= $IP"
                echo -e "端口 (port)\t\t\t= $PORT"
                echo -e "用户ID (id)\t\t\t= $AUTH"
                echo -e "流控 (flow)\t\t\t= xtls-rprx-vision"
                echo -e "传输层安全 (TLS)\t\t= reality"
                echo -e "伪装域名 (sni)\t\t\t= $SNI"
                echo -e "公钥 (pbk)\t\t\t= $PUB"
                echo -e "ShortId (sid)\t\t\t= $SID"
                echo -e "------------- 链接 (URL) -------------"
                echo "vless://${AUTH}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
            elif [[ "$TAG" == *"argo"* ]]; then
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
                echo -e "------------- 链接 (URL) -------------"
                echo "vless://${AUTH}@${A_IP}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            local AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
            echo -e "地址 (address)\t\t\t= $CONN_ADDR"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $AUTH"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            if [ "$CERT_TYPE" == "real" ]; then
                echo -e "伪装域名 (sni)\t\t\t= $DOMAIN"
            fi
            echo -e "------------- 链接 (URL) -------------"
            echo "hysteria2://${AUTH}@${CONN_ADDR}:${PORT}?security=tls&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}"
            ;;
        tuic)
            local T_UUID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
            local T_PASS=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
            echo -e "地址 (address)\t\t\t= $CONN_ADDR"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "用户ID (id)\t\t\t= $T_UUID"
            echo -e "密码 (password)\t\t\t= $T_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            echo -e "拥塞控制算法 (congestion_control)= bbr"
            if [ "$CERT_TYPE" == "real" ]; then
                echo -e "伪装域名 (sni)\t\t\t= $DOMAIN"
            fi
            echo -e "------------- 链接 (URL) -------------"
            echo "tuic://${T_UUID}:${T_PASS}@${CONN_ADDR}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}"
            ;;
        anytls)
            local AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
            echo -e "地址 (address)\t\t\t= $CONN_ADDR"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $AUTH"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            if [ "$CERT_TYPE" == "real" ]; then
                echo -e "伪装域名 (sni)\t\t\t= $DOMAIN"
            fi
            echo -e "------------- 链接 (URL) -------------"
            echo "anytls://${AUTH}@${CONN_ADDR}:${PORT}?insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}"
            ;;
    esac
    if [ "$CERT_TYPE" != "real" ] && [[ "$TAG" != *"reality"* ]] && [[ "$TAG" != *"argo"* ]]; then
        echo -e "\n${YELLOW}警告! 您当前使用的是自签名证书，请确保客户端已开启「跳过证书验证」！${PLAIN}\n"
    fi
}

get_unique_tag() {
    local base_tag=$1
    local counter=2
    local final_tag=$base_tag
    while jq -e ".inbounds[] | select(.tag == \"$final_tag\")" "$CONFIG_FILE" >/dev/null 2>&1; do
        final_tag="${base_tag}-${counter}"
        ((counter++))
    done
    echo "$final_tag"
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
    
    # 严格的端口校验逻辑
    read -p "请输入监听端口 [默认随机: $DEF_PORT]: " PORT
    PORT=${PORT:-$DEF_PORT}
    if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
        echo -e "${RED}错误! 请输入正确的端口, 可选(1-65535)${PLAIN}"
        sleep 1; return
    fi
    echo -e "使用: ${GREEN}${PORT}${PLAIN}"
    
    HOST_NAME=$(hostname 2>/dev/null || echo "vps")
    HOST_NAME=$(echo "$HOST_NAME" | tr '[:upper:]' '[:lower:]')
    
    cp $CONFIG_FILE ${CONFIG_FILE}.bak
    
    case "$proto_idx" in
        1)
            read -p "请输入UUID(回车默认随机): " input_uuid
            UUID=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "UUID: ${GREEN}${UUID}${PLAIN}"
            
            TAG=$(get_unique_tag "vless-reality-${HOST_NAME}")
            read -p "伪装域名 [默认: apple.com]: " SNI
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
            read -p "请输入密码(回车默认随机): " input_pass
            PASS=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "密码: ${GREEN}${PASS}${PLAIN}"
            
            TAG=$(get_unique_tag "hysteria2-${HOST_NAME}")
            check_cert
            jq --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" \
            '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        3)
            read -p "请输入UUID(回车默认随机): " input_uuid
            UUID=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "UUID: ${GREEN}${UUID}${PLAIN}"
            
            read -p "请输入密码(回车默认随机): " input_pass
            PASS=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "密码: ${GREEN}${PASS}${PLAIN}"
            
            TAG=$(get_unique_tag "tuic-${HOST_NAME}")
            check_cert
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg tag "$TAG" \
            '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        4)
            read -p "请输入密码(回车默认随机): " input_pass
            PASS=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "密码: ${GREEN}${PASS}${PLAIN}"
            
            TAG=$(get_unique_tag "anytls-${HOST_NAME}")
            check_cert
            jq --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" \
            '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            ;;
        5)
            read -p "请输入UUID(回车默认随机): " input_uuid
            UUID=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
            echo -e "UUID: ${GREEN}${UUID}${PLAIN}"
            
            TAG=$(get_unique_tag "argo-ws-${HOST_NAME}")
            read -p "Argo 优选域名/IP [默认: icook.hk]: " ARGO_IP
            ARGO_IP=${ARGO_IP:-icook.hk}
            read -p "Argo 隧道域名: " ARGO_DOMAIN
            read -p "Cloudflare Tunnel Token: " ARGO_TOKEN
            save_secret "ARGO_IP_${PORT}" "$ARGO_IP"
            save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"localhost","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
            
            if ! command -v cloudflared &> /dev/null; then
                ARCH=$(uname -m)
                case "$ARCH" in
                    x86_64) CF_ARCH="amd64" ;;
                    aarch64|arm64) CF_ARCH="arm64" ;;
                    *) CF_ARCH="amd64" ;;
                esac
                curl -L -o /usr/local/bin/cloudflared "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}"
                chmod +x /usr/local/bin/cloudflared
            fi
            
            if [ "$OS_TYPE" == "alpine" ]; then
                cat > /etc/init.d/cloudflared << EOF
#!/sbin/openrc-run
name="cloudflared"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate run --token ${ARGO_TOKEN}"
command_background=true
pidfile="/var/run/cloudflared.pid"
depend() {
    need net
}
EOF
                chmod +x /etc/init.d/cloudflared
                rc-update add cloudflared default >/dev/null 2>&1
                rc-service cloudflared restart
            else
                cloudflared service uninstall 2>/dev/null
                cloudflared service install "${ARGO_TOKEN}"
            fi
            ;;
    esac
    
    if ! restart_service; then
        echo -e "${RED}节点添加失败，已为您还原配置！${PLAIN}"
        mv ${CONFIG_FILE}.bak $CONFIG_FILE
        sleep 2
        return
    fi
    
    print_config_detail "$TAG"
    read -p "按回车键返回菜单..."
}

list_inbounds() {
    TAGS=($(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' $CONFIG_FILE))
    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "${RED}当前没有发现任何配置！${PLAIN}"
        return 1
    fi
    echo "当前配置列表:"
    for i in "${!TAGS[@]}"; do
        echo -e " $(($i + 1))) ${CYAN}${TAGS[$i]}${PLAIN}"
    done
    return 0
}

modify_config() {
    clear
    echo -e "选择: 更改配置\n"
    list_inbounds || { sleep 2; return; }
    echo ""
    read -p "请选择要更改的配置序号 (输入 0 返回): " idx
    if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then echo "输入错误!"; sleep 1; return; fi
    let idx--
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return; fi

    TYPE=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .type' $CONFIG_FILE)
    OLD_PORT=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .listen_port' $CONFIG_FILE)

    echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"
    
    if [ "$TYPE" == "vless" ]; then
        echo -e " 1) 更改 UUID"
        echo -e " 2) 更改端口"
        echo -e " 0) 返回"
        read -p "请选择 [0-2]: " mod_idx
        if [ "$mod_idx" == "1" ]; then action="uuid"
        elif [ "$mod_idx" == "2" ]; then action="port"
        else return; fi
    elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "anytls" ]]; then
        echo -e " 1) 更改密码"
        echo -e " 2) 更改端口"
        echo -e " 0) 返回"
        read -p "请选择 [0-2]: " mod_idx
        if [ "$mod_idx" == "1" ]; then action="pass"
        elif [ "$mod_idx" == "2" ]; then action="port"
        else return; fi
    elif [ "$TYPE" == "tuic" ]; then
        echo -e " 1) 更改 UUID"
        echo -e " 2) 更改密码"
        echo -e " 3) 更改端口"
        echo -e " 0) 返回"
        read -p "请选择 [0-3]: " mod_idx
        if [ "$mod_idx" == "1" ]; then action="uuid"
        elif [ "$mod_idx" == "2" ]; then action="pass"
        elif [ "$mod_idx" == "3" ]; then action="port"
        else return; fi
    else
        echo "未知的协议类型"
        sleep 1; return
    fi

    cp $CONFIG_FILE ${CONFIG_FILE}.bak

    if [ "$action" == "uuid" ]; then
        read -p "请输入UUID(回车默认随机): " input_uuid
        NEW_AUTH=${input_uuid:-$(/usr/local/bin/sing-box generate uuid)}
        echo -e "UUID: ${GREEN}${NEW_AUTH}${PLAIN}"
        jq '(.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid) = "'$NEW_AUTH'"' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}节点 $TAG 的 UUID 已更新！${PLAIN}"
        sleep 2
    elif [ "$action" == "pass" ]; then
        read -p "请输入密码(回车默认随机): " input_pass
        NEW_AUTH=${input_pass:-$(/usr/local/bin/sing-box generate uuid)}
        echo -e "密码: ${GREEN}${NEW_AUTH}${PLAIN}"
        jq '(.inbounds[] | select(.tag=="'$TAG'") | .users[0].password) = "'$NEW_AUTH'"' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}节点 $TAG 的密码已更新！${PLAIN}"
        sleep 2
    elif [ "$action" == "port" ]; then
        NEW_PORT=$(rand_port)
        read -p "请输入新端口 [默认随机: $NEW_PORT]: " input_port
        NEW_PORT=${input_port:-$NEW_PORT}
        if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
            echo -e "${RED}输入错误!${PLAIN}"; sleep 1; return
        fi
        
        jq '(.inbounds[] | select(.tag=="'$TAG'") | .listen_port) = '$NEW_PORT'' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
        
        load_secrets
        if [[ "$TAG" == *"reality"* ]]; then
            PUB=$(eval echo \$REALITY_PUB_${OLD_PORT})
            save_secret "REALITY_PUB_${NEW_PORT}" "$PUB"
        elif [[ "$TAG" == *"argo"* ]]; then
            A_IP=$(eval echo \$ARGO_IP_${OLD_PORT})
            A_DOM=$(eval echo \$ARGO_DOMAIN_${OLD_PORT})
            save_secret "ARGO_IP_${NEW_PORT}" "$A_IP"
            save_secret "ARGO_DOMAIN_${NEW_PORT}" "$A_DOM"
        fi
        
        if ! restart_service; then mv ${CONFIG_FILE}.bak $CONFIG_FILE; return; fi
        echo -e "${GREEN}端口已更改为: $NEW_PORT${PLAIN}"
        echo -e "${GREEN}节点 $TAG 的配置已生效！${PLAIN}"
        sleep 2
    fi
}

del_config() {
    clear
    echo -e "选择: 删除配置\n"
    list_inbounds || { sleep 2; return; }
    echo ""
    read -p "请选择要删除的配置序号 (输入 0 返回): " idx
    if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then echo "输入错误!"; sleep 1; return; fi
    let idx--
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return; fi
    
    jq 'del(.inbounds[] | select(.tag == "'$TAG'"))' $CONFIG_FILE > $TMP_JSON && mv $TMP_JSON $CONFIG_FILE
    if [[ "$TAG" == *"argo"* ]]; then
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service cloudflared stop 2>/dev/null
            rc-update del cloudflared default 2>/dev/null
            rm -f /etc/init.d/cloudflared
        else
            cloudflared service uninstall 2>/dev/null
        fi
    fi
    restart_service
    echo -e "${GREEN}配置 $TAG 已删除！${PLAIN}"
    sleep 2
}

view_single_config() {
    clear
    echo -e "选择: 单协议链接\n"
    list_inbounds || { sleep 2; return; }
    echo ""
    read -p "请选择要查看的配置序号 (输入 0 返回): " idx
    if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return; fi
    if ! [[ "$idx" =~ ^[0-9]+$ ]]; then echo "输入错误!"; sleep 1; return; fi
    let idx--
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return; fi
    
    print_config_detail "$TAG"
    read -p "按回车键返回菜单..."
}

show_all_links() {
    clear
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "🚀【 聚合节点 】节点信息如下：\n"
    echo -e "分享链接"
    TAGS=($(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' $CONFIG_FILE))
    IP=$(get_ip)
    load_secrets
    
    local CONN_ADDR=$IP
    local INSECURE=1
    local SNI_URL=""
    if [ "$CERT_TYPE" == "real" ]; then
        CONN_ADDR=$DOMAIN
        INSECURE=0
        SNI_URL="&sni=${DOMAIN}"
    fi
    
    for TAG in "${TAGS[@]}"; do
        TYPE=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .type' $CONFIG_FILE)
        PORT=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .listen_port' $CONFIG_FILE)
        case "$TYPE" in
            vless)
                AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
                if [[ "$TAG" == *"reality"* ]]; then
                    SNI=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.server_name' $CONFIG_FILE)
                    SID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.reality.short_id[0]' $CONFIG_FILE)
                    PUB=$(eval echo \$REALITY_PUB_${PORT})
                    echo "vless://${AUTH}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
                elif [[ "$TAG" == *"argo"* ]]; then
                    A_IP=$(eval echo \$ARGO_IP_${PORT})
                    A_DOM=$(eval echo \$ARGO_DOMAIN_${PORT})
                    echo "vless://${AUTH}@${A_IP}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
                fi
                ;;
            hysteria2)
                AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
                echo "hysteria2://${AUTH}@${CONN_ADDR}:${PORT}?security=tls&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
                ;;
            tuic)
                T_UUID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
                T_PASS=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
                echo "tuic://${T_UUID}:${T_PASS}@${CONN_ADDR}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
                ;;
            anytls)
                AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
                echo "anytls://${AUTH}@${CONN_ADDR}:${PORT}?insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
                ;;
        esac
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
           if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box start; else systemctl start sing-box; fi
           echo -e "${GREEN}已启动${PLAIN}"; sleep 1 ;;
        2) 
           if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop; else systemctl stop sing-box; fi
           echo -e "${GREEN}已停止${PLAIN}"; sleep 1 ;;
        3) restart_service; echo -e "${GREEN}已重启${PLAIN}"; sleep 1 ;;
        0) return ;;
        *) echo "输入错误!"; sleep 1 ;;
    esac
}

update_kernel() {
    clear
    echo -e "${CYAN}正在检查并更新 sing-box 内核...${PLAIN}\n"
    rm -f /usr/local/bin/sing-box
    init_base
    if [ -f "/usr/local/bin/sing-box" ]; then
        restart_service
        NEW_VER=$(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        echo -e "\n${GREEN}内核更新成功！当前版本: ${NEW_VER}${PLAIN}"
    else
        echo -e "\n${RED}内核更新失败，请检查网络！${PLAIN}"
    fi
    read -p "按回车键返回菜单..."
}

uninstall_all() {
    read -p "确认卸载并删除所有已创建的节点配置吗? (y/n): " un
    if [[ "$un" == "y" ]]; then
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service sing-box stop 2>/dev/null
            rc-service cloudflared stop 2>/dev/null
            rc-update del sing-box default 2>/dev/null
            rc-update del cloudflared default 2>/dev/null
            rm -f /etc/init.d/sing-box /etc/init.d/cloudflared
        else
            systemctl stop sing-box cloudflared 2>/dev/null
            systemctl disable sing-box cloudflared 2>/dev/null
            rm -rf /etc/systemd/system/sing-box.service
            cloudflared service uninstall 2>/dev/null
            systemctl daemon-reload
        fi
        
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then
            $HOME/.acme.sh/acme.sh --uninstall
            rm -rf $HOME/.acme.sh
        fi
        
        # 彻底清空应用和配置文件夹
        rm -rf /usr/local/bin/sing-box /usr/local/bin/cloudflared /usr/local/bin/sb /etc/sing-box
        rm -f /var/run/sing-box.pid /var/run/cloudflared.pid $TMP_JSON
        echo -e "${GREEN}已彻底卸载，并完全清理了所有节点配置与相关残留文件！${PLAIN}"
        exit 0
    fi
}

menu() {
    init_base
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
        
        echo -e "------------- sing-box 综合管理脚本 -------------"
        echo -e "sing-box ${VER:-未安装}: ${ST_COLOR}${SB_STATUS}${PLAIN}"
        echo -e ""
        echo -e " 1) 添加配置"
        echo -e " 2) 更改配置"
        echo -e " 3) 删除配置"
        echo -e " 4) 查看配置"
        echo -e " 5) 证书管理"
        echo -e " 6) 运行管理"
        echo -e " 7) 更新内核"
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
            7) update_kernel ;;
            8) uninstall_all ;;
            0) exit 0 ;;
            *) echo "输入错误!"; sleep 1 ;;
        esac
    done
}

menu
