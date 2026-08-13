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

if [ -f /etc/alpine-release ]; then
    OS_TYPE="alpine"
else
    OS_TYPE="debian"
fi

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须以 root 身份运行本脚本！${PLAIN}"
    exit 1
fi

if [ ! -f "/usr/local/bin/sb" ] || ! cmp -s "$0" "/usr/local/bin/sb"; then
    cp "$0" /usr/local/bin/sb
    chmod +x /usr/local/bin/sb
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
        echo -e "${CYAN}==> 正在安装必要环境与内核...${PLAIN}"
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
        echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"geoip":"private","outbound":"block"}]}}' > $CONFIG_FILE
    fi
    
    load_secrets
    if [ -z "$GLOBAL_UUID" ]; then
        GLOBAL_UUID=$(/usr/local/bin/sing-box generate uuid)
        save_secret "GLOBAL_UUID" "$GLOBAL_UUID"
    fi
}

check_cert() {
    load_secrets
    if [ -f "$CERT_DIR/fullchain.cer" ] && [ -f "$CERT_DIR/private.key" ]; then return 0; fi
    
    echo -e "${YELLOW}此协议需要真实域名和SSL证书！${PLAIN}"
    read -p "请输入你的域名 (如 node.domain.com): " DOMAIN
    read -p "请输入 Cloudflare 邮箱: " CF_Email
    read -p "请输入 Cloudflare Global API Key: " CF_Key
    save_secret "DOMAIN" "$DOMAIN"

    export CF_Key="${CF_Key}"
    export CF_Email="${CF_Email}"
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${DOMAIN}
    
    if [ "$OS_TYPE" == "alpine" ]; then
        RELOAD_CMD="rc-service sing-box restart"
    else
        RELOAD_CMD="systemctl restart sing-box"
    fi
    ~/.acme.sh/acme.sh --installcert -d ${DOMAIN} --fullchainpath $CERT_DIR/fullchain.cer --keypath $CERT_DIR/private.key --reloadcmd "$RELOAD_CMD"
    chmod -R 755 $CERT_DIR
}

restart_service() {
    if ! /usr/local/bin/sing-box check -c $CONFIG_FILE >/dev/null 2>&1; then
        echo -e "${RED}配置文件校验失败，请检查！${PLAIN}"
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
        rc-service sing-box restart
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
        systemctl restart sing-box
    fi
    echo -e "${GREEN}服务已重启并生效！${PLAIN}"
}

add_config() {
    clear
    echo -e "请选择协议:\n"
    echo -e " 1) VLESS-REALITY"
    echo -e " 2) Hysteria2"
    echo -e " 3) TUIC v5"
    echo -e " 4) AnyTLS"
    echo -e " 5) VLESS-WS (Argo)\n"
    read -p "请选择 [1-5]: " proto_idx

    load_secrets
    PORT=$(rand_port)
    UUID=$GLOBAL_UUID
    
    case "$proto_idx" in
        1)
            TAG="VLESS-REALITY-$PORT"
            read -p "伪装域名 [默认: apple.com]: " SNI
            SNI=${SNI:-apple.com}
            KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
            PK=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
            PUB=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
            SID=$(/usr/local/bin/sing-box generate rand --hex 8)
            save_secret "REALITY_PUB_${PORT}" "$PUB"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg pk "$PK" --arg sid "$SID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"flow":"xtls-rpxr-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            ;;
        2)
            TAG="Hysteria2-$PORT"
            check_cert
            jq --argjson p "$PORT" --arg pass "$UUID" --arg domain "$DOMAIN" --arg tag "$TAG" \
            '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$domain,"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            ;;
        3)
            TAG="TUIC-$PORT"
            check_cert
            jq --argjson p "$PORT" --arg pass "$UUID" --arg domain "$DOMAIN" --arg tag "$TAG" \
            '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$pass,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"server_name":$domain,"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            ;;
        4)
            TAG="AnyTLS-$PORT"
            check_cert
            jq --argjson p "$PORT" --arg pass "$UUID" --arg domain "$DOMAIN" --arg tag "$TAG" \
            '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"server_name":$domain,"certificate_path":"/etc/sing-box/cert/fullchain.cer","key_path":"/etc/sing-box/cert/private.key"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            ;;
        5)
            TAG="Argo-WS-$PORT"
            read -p "Argo 优选域名/IP [默认: icook.hk]: " ARGO_IP
            ARGO_IP=${ARGO_IP:-icook.hk}
            read -p "Argo 隧道域名: " ARGO_DOMAIN
            read -p "Cloudflare Tunnel Token: " ARGO_TOKEN
            save_secret "ARGO_IP_${PORT}" "$ARGO_IP"
            save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"localhost","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
            
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
        *) echo "输入错误"; sleep 1; return ;;
    esac
    
    restart_service
    echo -e "${GREEN}已添加配置: ${TAG}${PLAIN}"
    sleep 2
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
    read -p "请选择要更改的配置序号: " idx
    let idx--
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return; fi

    TYPE=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .type' $CONFIG_FILE)
    OLD_PORT=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .listen_port' $CONFIG_FILE)

    echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"
    echo -e " 1) 随机生成新的 UUID/密码"
    echo -e " 2) 自定义输入 UUID/密码"
    echo -e " 3) 更改端口"
    echo -e " 0) 返回"
    echo ""
    read -p "请选择 [0-3]: " mod_idx

    if [ "$mod_idx" == "1" ]; then
        NEW_AUTH=$(/usr/local/bin/sing-box generate uuid)
        echo -e "已生成新凭据: ${GREEN}$NEW_AUTH${PLAIN}"
    elif [ "$mod_idx" == "2" ]; then
        read -p "请输入新的 UUID 或 密码: " NEW_AUTH
        if [ -z "$NEW_AUTH" ]; then echo "输入不能为空!"; sleep 1; return; fi
    elif [ "$mod_idx" == "3" ]; then
        NEW_PORT=$(rand_port)
        read -p "请输入新端口 [默认: $NEW_PORT]: " input_port
        NEW_PORT=${input_port:-$NEW_PORT}
        
        jq '(.inbounds[] | select(.tag=="'$TAG'") | .listen_port) = '$NEW_PORT'' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        
        load_secrets
        if [[ "$TAG" == *"REALITY"* ]]; then
            PUB=$(eval echo \$REALITY_PUB_${OLD_PORT})
            save_secret "REALITY_PUB_${NEW_PORT}" "$PUB"
        elif [[ "$TAG" == *"Argo"* ]]; then
            A_IP=$(eval echo \$ARGO_IP_${OLD_PORT})
            A_DOM=$(eval echo \$ARGO_DOMAIN_${OLD_PORT})
            save_secret "ARGO_IP_${NEW_PORT}" "$A_IP"
            save_secret "ARGO_DOMAIN_${NEW_PORT}" "$A_DOM"
        fi
        
        NEW_TAG=$(echo "$TAG" | sed "s/-$OLD_PORT/-$NEW_PORT/")
        jq '(.inbounds[] | select(.tag=="'$TAG'") | .tag) = "'$NEW_TAG'"' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
        TAG=$NEW_TAG
        echo -e "${GREEN}端口已更改为: $NEW_PORT${PLAIN}"
    else
        return
    fi

    if [ "$mod_idx" == "1" ] || [ "$mod_idx" == "2" ]; then
        case "$TYPE" in
            vless)
                jq '(.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid) = "'$NEW_AUTH'"' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
                ;;
            hysteria2|anytls)
                jq '(.inbounds[] | select(.tag=="'$TAG'") | .users[0].password) = "'$NEW_AUTH'"' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
                ;;
            tuic)
                jq '(.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid) = "'$NEW_AUTH'" | (.inbounds[] | select(.tag=="'$TAG'") | .users[0].password) = "'$NEW_AUTH'"' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
                ;;
        esac
        echo -e "${GREEN}凭据已成功更新！${PLAIN}"
    fi

    restart_service
    echo -e "${GREEN}节点 $TAG 的配置已生效！${PLAIN}"
    sleep 2
}

del_config() {
    clear
    echo -e "选择: 删除配置\n"
    list_inbounds || { sleep 2; return; }
    echo ""
    read -p "请选择要删除的配置序号: " idx
    let idx--
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return; fi
    
    jq 'del(.inbounds[] | select(.tag == "'$TAG'"))' $CONFIG_FILE > tmp.json && mv tmp.json $CONFIG_FILE
    if [[ "$TAG" == *"Argo"* ]]; then
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
    read -p "请选择要查看的配置序号: " idx
    let idx--
    TAG=${TAGS[$idx]}
    if [ -z "$TAG" ]; then echo "输入错误!"; sleep 1; return; fi
    
    IP=$(get_ip)
    load_secrets
    TYPE=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .type' $CONFIG_FILE)
    PORT=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .listen_port' $CONFIG_FILE)
    
    echo -e "\n-------------- ${YELLOW}$TAG${PLAIN} -------------"
    echo "协议 (protocol)       = $TYPE"
    if [[ "$TAG" == *"Argo"* ]]; then
        echo "监听地址 (listen)     = localhost"
    fi
    echo "监听端口 (port)       = $PORT"
    
    echo -e "------------- 链接 (URL) -------------"
    case "$TYPE" in
        vless)
            AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
            if [[ "$TAG" == *"REALITY"* ]]; then
                SNI=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.server_name' $CONFIG_FILE)
                SID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.reality.short_id[0]' $CONFIG_FILE)
                PUB=$(eval echo \$REALITY_PUB_${PORT})
                echo "vless://${AUTH}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
            elif [[ "$TAG" == *"Argo"* ]]; then
                A_IP=$(eval echo \$ARGO_IP_${PORT})
                A_DOM=$(eval echo \$ARGO_DOMAIN_${PORT})
                echo "vless://${AUTH}@${A_IP}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
            echo "hysteria2://${AUTH}@${DOMAIN}:${PORT}?security=tls&alpn=h3&insecure=0&allowInsecure=0&sni=${DOMAIN}#${TAG}"
            ;;
        tuic)
            T_UUID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
            T_PASS=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
            echo "tuic://${T_UUID}:${T_PASS}@${DOMAIN}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}&insecure=0&allowInsecure=0#${TAG}"
            ;;
        anytls)
            AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
            echo "anytls://${AUTH}@${DOMAIN}:${PORT}?sni=${DOMAIN}&allowInsecure=0&insecure=0#${TAG}"
            ;;
    esac
    echo -e "------------- END -------------"
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
    for TAG in "${TAGS[@]}"; do
        TYPE=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .type' $CONFIG_FILE)
        PORT=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .listen_port' $CONFIG_FILE)
        case "$TYPE" in
            vless)
                AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
                if [[ "$TAG" == *"REALITY"* ]]; then
                    SNI=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.server_name' $CONFIG_FILE)
                    SID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .tls.reality.short_id[0]' $CONFIG_FILE)
                    PUB=$(eval echo \$REALITY_PUB_${PORT})
                    echo "vless://${AUTH}@${IP}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
                elif [[ "$TAG" == *"Argo"* ]]; then
                    A_IP=$(eval echo \$ARGO_IP_${PORT})
                    A_DOM=$(eval echo \$ARGO_DOMAIN_${PORT})
                    echo "vless://${AUTH}@${A_IP}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
                fi
                ;;
            hysteria2)
                AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
                echo "hysteria2://${AUTH}@${DOMAIN}:${PORT}?security=tls&alpn=h3&insecure=0&allowInsecure=0&sni=${DOMAIN}#${TAG}" 
                ;;
            tuic)
                T_UUID=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].uuid' $CONFIG_FILE)
                T_PASS=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
                echo "tuic://${T_UUID}:${T_PASS}@${DOMAIN}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&sni=${DOMAIN}&insecure=0&allowInsecure=0#${TAG}" 
                ;;
            anytls)
                AUTH=$(jq -r '.inbounds[] | select(.tag=="'$TAG'") | .users[0].password' $CONFIG_FILE)
                echo "anytls://${AUTH}@${DOMAIN}:${PORT}?sni=${DOMAIN}&allowInsecure=0&insecure=0#${TAG}" 
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
    echo "1) 启动"
    echo "2) 停止"
    echo "3) 重启"
    read -p "请选择 [1-3]: " run_idx
    case "$run_idx" in
        1) 
           if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box start; else systemctl start sing-box; fi
           echo "已启动"; sleep 1 ;;
        2) 
           if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop; else systemctl stop sing-box; fi
           echo "已停止"; sleep 1 ;;
        3) restart_service; sleep 1 ;;
    esac
}

uninstall_all() {
    read -p "确认卸载? (y/n): " un
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
        
        rm -rf /usr/local/bin/sing-box /usr/local/bin/cloudflared /usr/local/bin/sb $CONFIG_DIR
        echo -e "${GREEN}已彻底卸载！${PLAIN}"
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
        VER=$(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $3}')
        
        echo -e "------------- sing-box 综合管理脚本 -------------"
        echo -e "sing-box ${VER:-未安装}: ${ST_COLOR}${SB_STATUS}${PLAIN}"
        echo -e ""
        echo -e " 1) 添加配置"
        echo -e " 2) 更改配置"
        echo -e " 3) 删除配置"
        echo -e " 4) 查看配置"
        echo -e " 5) 运行管理"
        echo -e " 6) 更新内核"
        echo -e " 7) 卸载"
        echo -e " 0) 退出"
        echo -e ""
        read -p "请选择 [0-7]: " choice

        case "$choice" in
            1) add_config ;;
            2) modify_config ;;
            3) del_config ;;
            4) view_config ;;
            5) run_manage ;;
            6) 
               echo "正在更新内核..."
               rm -f /usr/local/bin/sing-box
               init_base
               restart_service
               sleep 2
               ;;
            7) uninstall_all ;;
            0) exit 0 ;;
            *) echo "输入错误!"; sleep 1 ;;
        esac
    done
}

menu
