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

TMP_JSON=$(mktemp)
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

ARCH=$(uname -m)
case "$ARCH" in
    x86_64) SB_ARCH="amd64" ;;
    aarch64|arm64) SB_ARCH="arm64" ;;
    *) echo -e "${RED}错误: 不支持的系统架构 ${ARCH}！${PLAIN}"; exit 1 ;;
esac

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}错误: 必须以 root 身份运行本脚本！${PLAIN}"
    exit 1
fi

GLOBAL_IP=""
GLOBAL_LATEST_VER=""

get_ip() {
    if [ -z "$GLOBAL_IP" ]; then
        local ip
        ip=$(curl -s -m 5 https://ipv4.icanhazip.com)
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            GLOBAL_IP="$ip"
        else
            ip=$(curl -s -m 5 https://ipv6.icanhazip.com)
            if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                GLOBAL_IP="$ip"
            fi
        fi
    fi
    echo "$GLOBAL_IP"
}

get_latest_version() {
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    local CACHE_FILE="$CONFIG_DIR/.version_cache"
    [ -f "$CACHE_FILE" ] && chmod 600 "$CACHE_FILE" 2>/dev/null
    
    local CACHE_TTL=3600
    local NOW=$(date +%s)

    if [ -z "$GLOBAL_LATEST_VER" ]; then
        if [ -f "$CACHE_FILE" ]; then
            local CACHE_TIME=$(head -n 1 "$CACHE_FILE" 2>/dev/null)
            local CACHE_VER=$(tail -n 1 "$CACHE_FILE" 2>/dev/null)
            if [[ "$CACHE_TIME" =~ ^[0-9]+$ ]] && [ $((NOW - CACHE_TIME)) -le $CACHE_TTL ] && [ -n "$CACHE_VER" ]; then
                GLOBAL_LATEST_VER="$CACHE_VER"
                echo "$GLOBAL_LATEST_VER"
                return
            fi
        fi

        local res=$(curl -s -m 5 "https://api.github.com/repos/SagerNet/sing-box/releases/latest" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
        if [ -n "$res" ]; then
            GLOBAL_LATEST_VER=${res#v}
            echo "$NOW" > "$CACHE_FILE"
            echo "$GLOBAL_LATEST_VER" >> "$CACHE_FILE"
            chmod 600 "$CACHE_FILE" 2>/dev/null
        fi
    fi
    echo "$GLOBAL_LATEST_VER"
}

check_port() {
    local port=$1
    local proto=${2:-both}
    local ss_arg="-tuln"
    [ "$proto" == "tcp" ] && ss_arg="-tln"
    [ "$proto" == "udp" ] && ss_arg="-uln"
    
    if command -v ss >/dev/null 2>&1; then
        ss $ss_arg | awk '{print $4}' | grep -qE ":${port}$"
    elif command -v netstat >/dev/null 2>&1; then
        netstat $ss_arg | awk '{print $4}' | grep -qE ":${port}$"
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

url_encode() {
    jq -rn --arg s "$1" '$s|@uri'
}

wrap_ipv6() {
    local ip=$1
    if [[ "$ip" == *":"* ]]; then
        echo "[$ip]"
    else
        echo "$ip"
    fi
}

save_secret() {
    local key=$1
    local val=$2
    val=${val//\'/}
    touch "$SECRETS_FILE"
    grep -v "^${key}=" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp"
    echo "${key}='${val}'" >> "${SECRETS_FILE}.tmp"
    mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
}

remove_secret() {
    local key_prefix=$1
    if [ -f "$SECRETS_FILE" ]; then
        grep -v "^${key_prefix}=" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp"
        mv "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
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
        if ! iptables -C INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            if ! ip6tables -C INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; then
                ip6tables -I INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1
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
        echo -e "${GREEN}放行端口 ${port}/${proto} 成功${PLAIN}" >&2
    elif [ "$fw_found" -eq 0 ]; then
        echo -e "${YELLOW}未检测到系统内置防火墙工具，请确保云服务商后台和本机系统放行了 ${port} 端口！${PLAIN}" >&2
    fi
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
        while iptables -C INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1
        done
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -C INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; do
                ip6tables -D INPUT -p ${proto} --dport ${port} -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1
            done
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null 2>&1; then
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

migrate_certs() {
    load_secrets
    if [ -f "$CERT_DIR/fullchain.cer" ]; then
        if [ "$CERT_TYPE" == "real" ]; then
            mv "$CERT_DIR/fullchain.cer" "$CERT_DIR/real.cer" 2>/dev/null
            mv "$CERT_DIR/private.key" "$CERT_DIR/real.key" 2>/dev/null
            sed -i 's|fullchain.cer|real.cer|g' $CONFIG_FILE
            sed -i 's|private.key|real.key|g' $CONFIG_FILE
            save_secret "REAL_DOMAIN" "$DOMAIN"
        else
            mv "$CERT_DIR/fullchain.cer" "$CERT_DIR/self.cer" 2>/dev/null
            mv "$CERT_DIR/private.key" "$CERT_DIR/self.key" 2>/dev/null
            sed -i 's|fullchain.cer|self.cer|g' $CONFIG_FILE
            sed -i 's|private.key|self.key|g' $CONFIG_FILE
            save_secret "SELF_DOMAIN" "$DOMAIN"
        fi
        sed -i '/CERT_TYPE=/d' "$SECRETS_FILE"
        sed -i '/DOMAIN=/d' "$SECRETS_FILE"
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
        
        echo -e "${CYAN}==> 正在获取最新版 sing-box 内核信息...${PLAIN}"
        VERSION=$(get_latest_version)
        
        if [ -z "$VERSION" ]; then
            echo -e "${YELLOW}获取版本信息失败！${PLAIN}"
            read -p "请手动输入要安装的 sing-box 版本号 (例如 1.10.1): " VERSION
            if [ -z "$VERSION" ]; then
                echo -e "${RED}未输入版本号，安装终止。${PLAIN}"
                exit 1
            fi
        fi

        echo -e "${CYAN}==> 开始下载 v${VERSION} 内核...${PLAIN}"
        
        local INIT_TMP=$(mktemp -d)
        if wget --show-progress -qO $INIT_TMP/sing-box.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${VERSION}/sing-box-${VERSION}-linux-${SB_ARCH}.tar.gz"; then
            if tar -xzf $INIT_TMP/sing-box.tar.gz -C $INIT_TMP; then
                mv -f $INIT_TMP/sing-box-${VERSION}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
                chmod +x /usr/local/bin/sing-box
                echo -e "${GREEN}==> 内核下载并解压完毕！${PLAIN}"
            else
                echo -e "${RED}解压失败！${PLAIN}"
                exit 1
            fi
        else
            echo -e "${RED}下载内核失败！请检查网络。${PLAIN}"
            exit 1
        fi
        rm -rf $INIT_TMP
    fi

    mkdir -p $CONFIG_DIR $CERT_DIR || return 1
    
    if [ ! -f "$CONFIG_FILE" ]; then
        echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"ip_is_private":true,"outbound":"block"}]}}' > $CONFIG_FILE
    else
        sed -i 's/"geoip":"private"/"ip_is_private":true/g' $CONFIG_FILE
        sed -i 's/"geoip": "private"/"ip_is_private": true/g' $CONFIG_FILE
    fi
    migrate_certs
}

restart_service() {
    local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE 2>/dev/null)
    if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then
        if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop >/dev/null 2>&1; else systemctl stop sing-box >/dev/null 2>&1; fi
        return 0
    fi

    if ! /usr/local/bin/sing-box check -c $CONFIG_FILE; then return 1; fi
    
    if [ "$OS_TYPE" == "alpine" ]; then
        cat > /etc/init.d/sing-box << 'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/var/run/sing-box.pid"
rc_ulimit="-n 65535"
depend() { need net; }
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        rc-service sing-box restart >/dev/null 2>&1
        sleep 1
        if ! rc-service sing-box status 2>/dev/null | grep -q 'started'; then return 1; fi
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
        sleep 1
        if [ "$(systemctl is-active sing-box 2>/dev/null)" != "active" ]; then return 1; fi
    fi
    return 0
}

get_domain() {
    local prompt="$1"
    local default="$2"
    local allow_colon="${3:-false}"
    local pattern='^[a-zA-Z0-9.-]+$'
    [ "$allow_colon" == "true" ] && pattern='^[a-zA-Z0-9:.-]+$'
    
    local val
    while true; do
        read -p "$prompt [默认: $default]: " val >&2
        val=${val:-$default}
        if [[ "$val" =~ $pattern ]] && [[ "$val" =~ [a-zA-Z0-9] ]]; then
            break
        else
            if [ "$allow_colon" == "true" ]; then
                echo -e "${RED}错误：格式不正确！必须包含字母或数字，且不得包含空格或特殊符号。${PLAIN}" >&2
            else
                echo -e "${RED}错误：格式不正确！纯域名不支持冒号，且必须包含字母或数字。${PLAIN}" >&2
            fi
        fi
    done
    echo "$val"
}

apply_real_cert() {
    local NEW_DOMAIN=$(get_domain "请输入解析到本机的域名" "")
    save_secret "REAL_DOMAIN" "$NEW_DOMAIN"
    echo -e "\n请选择验证方式:"
    echo -e " 1) 80端口独立申请 (Standalone) - 需确保服务器80端口开放且未被占用"
    echo -e " 2) Cloudflare DNS API - 推荐，适合各类环境"
    local v_mode
    while true; do
        read -p "请选择 [1-2]: " v_mode
        if [[ "$v_mode" == "1" || "$v_mode" == "2" ]]; then break; fi
    done

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        curl -sL https://get.acme.sh | sh
    fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1

    if [ "$v_mode" == "1" ]; then
        open_fw_port 80 tcp >/dev/null
        if ! ~/.acme.sh/acme.sh --issue -d ${NEW_DOMAIN} --standalone; then
            echo -e "${RED}申请失败！请检查域名解析和 80 端口是否连通。${PLAIN}"
            return 1
        fi
    else
        local NEW_CF_Key=""
        while true; do
            read -s -p "请输入 Cloudflare Global API Key: " NEW_CF_Key >&2
            echo "" >&2
            if [[ "$NEW_CF_Key" =~ ^[A-Za-z0-9]+$ ]]; then break; fi
            echo -e "${RED}错误：API Key 格式不正确！${PLAIN}" >&2
        done
        
        local NEW_CF_Email=""
        while true; do
            read -p "请输入 Cloudflare 邮箱: " NEW_CF_Email >&2
            if [[ "$NEW_CF_Email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
            echo -e "${RED}错误：邮箱格式不正确，请重新输入！${PLAIN}" >&2
        done
        
        if ! CF_Key="${NEW_CF_Key}" CF_Email="${NEW_CF_Email}" ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${NEW_DOMAIN}; then
            echo -e "${RED}申请失败！请检查 CF API 是否正确。${PLAIN}"
            return 1
        fi
    fi
    
    if [ "$OS_TYPE" == "alpine" ]; then
        RELOAD_CMD="rc-service sing-box restart"
    else
        RELOAD_CMD="systemctl restart sing-box"
    fi
    
    if ! ~/.acme.sh/acme.sh --installcert -d ${NEW_DOMAIN} \
        --fullchainpath $CERT_DIR/real.cer \
        --keypath $CERT_DIR/real.key \
        --reloadcmd "$RELOAD_CMD"; then
        echo -e "${RED}证书部署至目标目录失败！请检查系统权限或 acme.sh 报错信息。${PLAIN}"
        return 1
    fi
    
    chmod 644 $CERT_DIR/*.cer 2>/dev/null
    chmod 600 $CERT_DIR/*.key 2>/dev/null
    echo -e "${GREEN}真实域名证书申请并安装完成！${PLAIN}"
    return 0
}

generate_self_cert() {
    if ! command -v openssl >/dev/null 2>&1; then
        echo -e "${RED}系统缺少 openssl，正在尝试安装...${PLAIN}"
        if [ "$OS_TYPE" == "alpine" ]; then apk add openssl; elif [ "$OS_TYPE" == "centos" ]; then yum install -y openssl || dnf install -y openssl; else apt-get install -y openssl; fi
        if ! command -v openssl >/dev/null 2>&1; then
            echo -e "${RED}openssl 自动安装失败，请手动安装后重试！${PLAIN}"
            return 1
        fi
    fi

    local NEW_DOMAIN=$(get_domain "请输入伪装域名" "bing.com")
    save_secret "SELF_DOMAIN" "$NEW_DOMAIN"
    
    echo -e "${CYAN}正在生成自签名证书...${PLAIN}"
    if ! ( umask 077; openssl req -x509 -nodes -days 36500 -newkey rsa:2048 \
        -keyout $CERT_DIR/self.key -out $CERT_DIR/self.cer -subj "/CN=${NEW_DOMAIN}" ); then
        echo -e "${RED}生成自签名证书失败！请查看上方报错信息。${PLAIN}"
        rm -f $CERT_DIR/self.key $CERT_DIR/self.cer
        return 1
    fi
    
    chmod 644 $CERT_DIR/*.cer 2>/dev/null
    chmod 600 $CERT_DIR/*.key 2>/dev/null
    echo -e "${GREEN}自签名证书生成完毕！${PLAIN}"
    return 0
}

cert_manage() {
    while true; do
        clear
        echo -e "选择: 证书管理中心\n"
        echo -e " 1) 重新申请真实域名证书"
        echo -e " 2) 重新生成自签名证书"
        echo -e " 3) 查看证书与自动续期状态"
        echo -e " 0) 返回\n"
        
        load_secrets
        read -p "请选择 [0-3]: " cert_idx
        case "$cert_idx" in
            1) apply_real_cert; read -p "按回车键返回..." ;;
            2) generate_self_cert; read -p "按回车键返回..." ;;
            3)
                echo -e "\n------------- 真实域名证书 -------------"
                if [ -s "$CERT_DIR/real.cer" ]; then
                    echo -e "绑定的域名\t: ${GREEN}${REAL_DOMAIN}${PLAIN}"
                    echo -e "证书路径\t: ${GREEN}$CERT_DIR/real.cer${PLAIN}"
                    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                        echo -e "${GREEN}acme.sh 自动续期已运行中！${PLAIN}"
                    else
                        echo -e "${RED}警告: 未发现自动续期任务！${PLAIN}"
                    fi
                else
                    echo -e "${YELLOW}当前未安装真实域名证书。${PLAIN}"
                fi
                echo -e "\n------------- 自签名证书 -------------"
                if [ -s "$CERT_DIR/self.cer" ]; then
                    echo -e "伪装域名\t: ${GREEN}${SELF_DOMAIN}${PLAIN}"
                    echo -e "证书路径\t: ${GREEN}$CERT_DIR/self.cer${PLAIN}"
                else
                    echo -e "${YELLOW}当前未生成自签证书。${PLAIN}"
                fi
                echo -e "------------------------------------"
                read -p "按回车键返回..."
                ;;
            0) return ;;
            *) echo -e "${RED}输入错误，请重新选择!${PLAIN}"; sleep 1 ;;
        esac
    done
}

prompt_cert_type() {
    echo -e "\n请选择该节点使用的证书类型:"
    echo -e " 1) 真实域名证书"
    echo -e " 2) 自签名证书"
    local c_idx
    while true; do
        read -p "请选择 [1-2]: " c_idx
        case "$c_idx" in
            1)
                if [ ! -s "$CERT_DIR/real.cer" ] || [ ! -s "$CERT_DIR/real.key" ]; then
                    echo -e "${YELLOW}未检测到有效真实域名证书，需要先申请...${PLAIN}"
                    if ! apply_real_cert; then return 1; fi
                fi
                SEL_CERT="$CERT_DIR/real.cer"
                SEL_KEY="$CERT_DIR/real.key"
                break ;;
            2)
                if [ ! -s "$CERT_DIR/self.cer" ] || [ ! -s "$CERT_DIR/self.key" ]; then
                    echo -e "${YELLOW}未检测到有效自签证书，需要先生成...${PLAIN}"
                    if ! generate_self_cert; then return 1; fi
                fi
                SEL_CERT="$CERT_DIR/self.cer"
                SEL_KEY="$CERT_DIR/self.key"
                break ;;
            *) echo -e "${RED}输入错误！${PLAIN}" ;;
        esac
    done
    return 0
}

get_uuid() {
    local val
    while true; do
        read -p "请输入UUID [默认随机]: " val >&2
        val=${val:-$(/usr/local/bin/sing-box generate uuid)}
        if [[ "$val" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            break
        else
            echo -e "${RED}错误：输入的格式不规范！必须是标准 UUIDv4 格式。${PLAIN}" >&2
        fi
    done
    echo -e "UUID: ${GREEN}${val}${PLAIN}" >&2
    echo "$val"
}

get_pass() {
    local val
    while true; do
        read -p "请输入密码(支持特殊符号,会自动安全编码) [默认随机]: " val >&2
        val=${val:-$(/usr/local/bin/sing-box generate rand --hex 16)}
        if [[ "$val" =~ [^[:space:]] ]]; then
            break
        else
            echo -e "${RED}错误：密码不能全为空白字符！${PLAIN}" >&2
        fi
    done
    echo -e "密码: ${GREEN}${val}${PLAIN}" >&2
    echo "$val"
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

build_share_url() {
    local TAG=$1
    local IP=$2
    load_secrets
    
    local CONN_ADDR=$IP
    local INSECURE=1
    local SNI_URL=""
    
    local CERT_PATH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.certificate_path // empty' $CONFIG_FILE)
    if [[ "$CERT_PATH" == *"/real.cer" ]]; then
        CONN_ADDR=$REAL_DOMAIN
        INSECURE=0
        SNI_URL="&sni=${REAL_DOMAIN}"
    elif [[ "$CERT_PATH" == *"/self.cer" ]]; then
        SNI_URL="&sni=${SELF_DOMAIN:-bing.com}"
    fi
    
    local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
    local PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)
    
    local IP_URI=$(wrap_ipv6 "$IP")
    local CONN_ADDR_URI=$(wrap_ipv6 "$CONN_ADDR")
    
    case "$TYPE" in
        vless)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' $CONFIG_FILE)
            if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1; then
                if [ -z "$IP" ]; then echo -e "${RED}[获取公网IP异常，无法生成 VLESS-REALITY 链接]${PLAIN}"; return; fi
                local SNI=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.server_name' $CONFIG_FILE)
                local SID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.short_id[0]' $CONFIG_FILE)
                local var_name="REALITY_PUB_${PORT}"
                local PUB="${!var_name}"
                echo "vless://${AUTH}@${IP_URI}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
            elif jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                local var_ip="ARGO_IP_${PORT}"
                local var_dom="ARGO_DOMAIN_${PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                if [ -z "$A_IP" ]; then echo -e "${RED}[无法读取 Argo IP，无法生成链接]${PLAIN}"; return; fi
                local A_IP_URI=$(wrap_ipv6 "$A_IP")
                echo "vless://${AUTH}@${A_IP_URI}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 Hysteria2 链接]${PLAIN}"; return; fi
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password // empty' $CONFIG_FILE)
            local AUTH_ENC=$(url_encode "$AUTH")
            echo "hysteria2://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?security=tls&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
            ;;
        tuic)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 TUIC 链接]${PLAIN}"; return; fi
            local T_UUID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid // empty' $CONFIG_FILE)
            local T_PASS=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password // empty' $CONFIG_FILE)
            local T_UUID_ENC=$(url_encode "$T_UUID")
            local T_PASS_ENC=$(url_encode "$T_PASS")
            echo "tuic://${T_UUID_ENC}:${T_PASS_ENC}@${CONN_ADDR_URI}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
            ;;
        anytls)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 AnyTLS 链接]${PLAIN}"; return; fi
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password // empty' $CONFIG_FILE)
            local AUTH_ENC=$(url_encode "$AUTH")
            echo "anytls://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?insecure=${INSECURE}&allowInsecure=${INSECURE}${SNI_URL}#${TAG}" 
            ;;
    esac
}

print_config_detail() {
    local TAG=$1
    local IP=$(get_ip)
    load_secrets
    
    local CERT_PATH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.certificate_path // empty' $CONFIG_FILE)
    local CONN_ADDR=$IP
    local INSECURE_TEXT="true"
    local SNI_VAL=""
    if [[ "$CERT_PATH" == *"/real.cer" ]]; then
        CONN_ADDR=$REAL_DOMAIN
        INSECURE_TEXT="false"
        SNI_VAL=$REAL_DOMAIN
    elif [[ "$CERT_PATH" == *"/self.cer" ]]; then
        SNI_VAL=${SELF_DOMAIN:-bing.com}
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
                local var_name="REALITY_PUB_${PORT}"
                local PUB="${!var_name}"
                local IP_DISP=$(wrap_ipv6 "$IP")
                echo -e "地址 (address)\t\t\t= ${IP_DISP:-[获取公网IP失败]}"
                echo -e "端口 (port)\t\t\t= $PORT"
                echo -e "用户ID (id)\t\t\t= $AUTH"
                echo -e "流控 (flow)\t\t\t= xtls-rprx-vision"
                echo -e "传输层安全 (TLS)\t\t= reality"
                echo -e "伪装域名 (sni)\t\t\t= $SNI"
                echo -e "公钥 (pbk)\t\t\t= $PUB"
                echo -e "ShortId (sid)\t\t\t= $SID"
            elif jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                local var_ip="ARGO_IP_${PORT}"
                local var_dom="ARGO_DOMAIN_${PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                local A_IP_DISP=$(wrap_ipv6 "$A_IP")
                echo -e "地址 (address)\t\t\t= $A_IP_DISP"
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
            local CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $AUTH"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        tuic)
            local T_UUID=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].uuid' $CONFIG_FILE)
            local T_PASS=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            local CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "用户ID (id)\t\t\t= $T_UUID"
            echo -e "密码 (password)\t\t\t= $T_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            echo -e "拥塞控制算法 (congestion_control)= bbr"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        anytls)
            local AUTH=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .users[0].password' $CONFIG_FILE)
            local CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $AUTH"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
    esac
    
    echo -e "------------- 链接 (URL) -------------"
    build_share_url "$TAG" "$IP"
    
    if [ "$INSECURE_TEXT" == "true" ] && ! jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1 && ! jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
        echo -e "\n${YELLOW}警告! 此节点使用自签名证书，请确保客户端已开启「跳过证书验证」！${PLAIN}\n"
    fi
}

select_inbound() {
    local old_IFS=$IFS
    IFS=$'\n'
    TAGS=($(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' "$CONFIG_FILE"))
    IFS=$old_IFS
    
    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "${RED}未添加节点配置！${PLAIN}"
        read -p "按回车键返回上一级..."
        return 1
    fi
    for i in "${!TAGS[@]}"; do
        echo -e " $((i + 1))) ${CYAN}${TAGS[$i]}${PLAIN}"
    done
    echo -e " 0) 返回\n"
    
    while true; do
        read -p "请选择 [0-${#TAGS[@]}]: " idx
        if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return 1; fi
        if ! [[ "$idx" =~ ^[0-9]+$ ]] || [ "$idx" -gt "${#TAGS[@]}" ]; then 
            echo -e "${RED}输入错误，请重新选择！${PLAIN}"
            continue
        fi
        ((idx--))
        TAG=${TAGS[$idx]}
        return 0
    done
}

add_config() {
    clear
    echo -e "请选择协议:\n"
    echo -e " 1) VLESS-REALITY"
    echo -e " 2) Hysteria2"
    echo -e " 3) TUIC"
    echo -e " 4) AnyTLS"
    echo -e " 5) VLESS-Argo"
    echo -e " 0) 返回\n"
    
    local proto_idx
    while true; do
        read -p "请选择 [0-5]: " proto_idx
        if [[ "$proto_idx" =~ ^[0-5]$ ]]; then break; fi
        echo -e "${RED}输入错误，请重新选择！${PLAIN}"
    done
    [ "$proto_idx" == "0" ] && return

    load_secrets
    local DEF_PORT=$(rand_port)
    local PORT
    
    local f_proto=""
    if [[ "$proto_idx" == "1" || "$proto_idx" == "4" ]]; then f_proto="tcp"
    elif [[ "$proto_idx" == "2" || "$proto_idx" == "3" ]]; then f_proto="udp"
    fi

    while true; do
        read -p "请输入监听端口 [默认: $DEF_PORT]: " PORT
        PORT=${PORT:-$DEF_PORT}
        if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
            echo -e "${RED}端口必须为 1-65535 之间的数字${PLAIN}"; continue
        fi
        if check_port "$PORT" "$f_proto"; then
            echo -e "${RED}错误! 端口 ${PORT} 已被占用！${PLAIN}"; continue
        fi
        break
    done
    echo -e "使用: ${GREEN}${PORT}${PLAIN}"
    
    local raw_hostname=$(hostname 2>/dev/null || echo "vps")
    local HOST_NAME=$(echo "$raw_hostname" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
    [ -z "$HOST_NAME" ] && HOST_NAME="vps"
    
    local DEF_TAG=""
    case "$proto_idx" in
        1) DEF_TAG="vless-reality" ;;
        2) DEF_TAG="hysteria2" ;;
        3) DEF_TAG="tuic" ;;
        4) DEF_TAG="anytls" ;;
        5) DEF_TAG="vless-argo" ;;
    esac
    DEF_TAG="${DEF_TAG}-${HOST_NAME}"
    
    local input_tag
    while true; do
        read -p "请输入节点名称 [默认: $DEF_TAG]: " input_tag
        input_tag=${input_tag:-$DEF_TAG}
        input_tag=${input_tag// /-}
        if [[ "$input_tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
            break
        else
            echo -e "${RED}错误：节点名称仅限字母、数字、短横线和下划线！${PLAIN}" >&2
        fi
    done
    local TAG=$(get_unique_tag "$input_tag")
    
    cp $CONFIG_FILE ${CONFIG_FILE}.bak
    local IS_ARGO=0

    case "$proto_idx" in
        1)
            local UUID=$(get_uuid)
            local SNI=$(get_domain "请输入伪装域名" "apple.com")
            local KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
            local PK=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
            local PUB=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
            local SID=$(/usr/local/bin/sing-box generate rand --hex 8)
            save_secret "REALITY_PUB_${PORT}" "$PUB"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg pk "$PK" --arg sid "$SID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            ;;
        2)
            local PASS=$(get_pass)
            if ! prompt_cert_type; then rm -f ${CONFIG_FILE}.bak; return; fi
            jq --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" \
            '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            ;;
        3)
            local UUID=$(get_uuid)
            local PASS=$(get_pass)
            if ! prompt_cert_type; then rm -f ${CONFIG_FILE}.bak; return; fi
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" \
            '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            ;;
        4)
            local PASS=$(get_pass)
            if ! prompt_cert_type; then rm -f ${CONFIG_FILE}.bak; return; fi
            jq --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" \
            '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h2","http/1.1"],"certificate_path":$cert,"key_path":$key}}]' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            ;;
        5)
            IS_ARGO=1
            local UUID=$(get_uuid)
            local ARGO_IP=$(get_domain "请输入 Argo 优选域名/IP" "saas.sin.fan" "true")
            local ARGO_DOMAIN=$(get_domain "请输入 Argo 隧道域名" "example.com")
            
            local ARGO_TOKEN=""
            while true; do
                read -s -p "请输入 Cloudflare Tunnel Token: " ARGO_TOKEN >&2
                echo "" >&2
                if [[ "$ARGO_TOKEN" =~ ^[A-Za-z0-9+/=._-]+$ ]]; then break; fi
                echo -e "${RED}错误：Token 格式不正确或为空！${PLAIN}" >&2
            done
            
            save_secret "ARGO_IP_${PORT}" "$ARGO_IP"
            save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN"
            
            jq --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG" \
            '.inbounds += [{"type":"vless","tag":$tag,"listen":"127.0.0.1","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            
            if ! command -v cloudflared &> /dev/null; then
                echo -e "${CYAN}正在下载 cloudflared 组件...${PLAIN}"
                local TMP_CF=$(mktemp)
                local cf_arch="amd64"
                [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && cf_arch="arm64"
                if wget --show-progress -qO $TMP_CF "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" || curl -sL -o $TMP_CF "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}"; then
                    mv $TMP_CF /usr/local/bin/cloudflared
                    chmod +x /usr/local/bin/cloudflared
                else
                    echo -e "${RED}下载 cloudflared 失败！${PLAIN}"
                    rm -f $TMP_CF
                fi
            fi
            
            if [ "$OS_TYPE" == "alpine" ]; then
                cat > "/etc/init.d/cloudflared-${TAG}" << 'EOF'
#!/sbin/openrc-run
name="cloudflared-@@SB_TAG@@"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --protocol http2 run --token @@SB_TOKEN@@"
command_background=true
pidfile="/var/run/cloudflared-@@SB_TAG@@.pid"
depend() { need net; }
EOF
                sed -i "s|@@SB_TAG@@|${TAG}|g" "/etc/init.d/cloudflared-${TAG}"
                sed -i "s|@@SB_TOKEN@@|${ARGO_TOKEN}|g" "/etc/init.d/cloudflared-${TAG}"
                chmod +x "/etc/init.d/cloudflared-${TAG}"
                rc-update add "cloudflared-${TAG}" default >/dev/null 2>&1
                rc-service "cloudflared-${TAG}" restart >/dev/null 2>&1
            else
                cat > "/etc/systemd/system/cloudflared-${TAG}.service" << 'EOF'
[Unit]
Description=cloudflared tunnel for @@SB_TAG@@
After=network.target
[Service]
ExecStart=/usr/local/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token @@SB_TOKEN@@
Restart=on-failure
RestartSec=10s
[Install]
WantedBy=multi-user.target
EOF
                sed -i "s|@@SB_TAG@@|${TAG}|g" "/etc/systemd/system/cloudflared-${TAG}.service"
                sed -i "s|@@SB_TOKEN@@|${ARGO_TOKEN}|g" "/etc/systemd/system/cloudflared-${TAG}.service"
                systemctl daemon-reload >/dev/null 2>&1
                systemctl enable "cloudflared-${TAG}" --now >/dev/null 2>&1
            fi
            ;;
    esac
    
    if ! restart_service; then
        echo -e "${RED}节点添加失败(校验报错)，已为您还原配置！${PLAIN}"
        mv ${CONFIG_FILE}.bak $CONFIG_FILE
        remove_secret "REALITY_PUB_${PORT}"
        remove_secret "ARGO_IP_${PORT}"
        remove_secret "ARGO_DOMAIN_${PORT}"
        if [ "$IS_ARGO" -eq 1 ]; then
            if [ "$OS_TYPE" == "alpine" ]; then
                rc-service "cloudflared-${TAG}" stop >/dev/null 2>&1
                rc-update del "cloudflared-${TAG}" default >/dev/null 2>&1
                rm -f "/etc/init.d/cloudflared-${TAG}"
            else
                systemctl stop "cloudflared-${TAG}" >/dev/null 2>&1
                systemctl disable "cloudflared-${TAG}" >/dev/null 2>&1
                rm -f "/etc/systemd/system/cloudflared-${TAG}.service"
                systemctl daemon-reload >/dev/null 2>&1
            fi
        fi
        read -p "按回车键返回上一级..."
        return
    fi
    
    rm -f ${CONFIG_FILE}.bak
    
    if [ -n "$f_proto" ]; then
        echo ""
        read -p "是否自动放行端口？(y/n) [默认: y]: " auto_fw
        if [[ "${auto_fw:-y}" == "y" || "${auto_fw:-y}" == "Y" ]]; then
            open_fw_port "$PORT" "$f_proto"
        fi
    fi
    
    print_config_detail "$TAG"
    read -p "按回车键返回上一级..."
}

modify_config() {
    while true; do
        clear
        echo -e "选择: 更改节点配置\n"
        select_inbound || return

        local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
        local OLD_PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)
        echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"
        
        local action=""
        if [ "$TYPE" == "vless" ]; then
            echo -e " 1) 更改 UUID"
            echo -e " 2) 更改端口"
            echo -e " 3) 更改节点名称"
            echo -e " 0) 返回"
            while true; do
                read -p "请选择 [0-3]: " mod_idx
                case "$mod_idx" in 1) action="uuid"; break ;; 2) action="port"; break ;; 3) action="tag"; break ;; 0) break ;; *) echo -e "${RED}错误!${PLAIN}" ;; esac
            done
        elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "anytls" || "$TYPE" == "tuic" ]]; then
            echo -e " 1) 更改主密钥/密码"
            echo -e " 2) 更改端口"
            echo -e " 3) 更改节点名称"
            echo -e " 4) 更改证书类型 (真实/自签)"
            echo -e " 0) 返回"
            while true; do
                read -p "请选择 [0-4]: " mod_idx
                case "$mod_idx" in 1) action="pass"; break ;; 2) action="port"; break ;; 3) action="tag"; break ;; 4) action="cert"; break ;; 0) break ;; *) echo -e "${RED}错误!${PLAIN}" ;; esac
            done
        else
            echo "不支持修改的协议类型"; read -p "按回车键返回..."; continue
        fi

        [ "$mod_idx" == "0" ] && continue
        cp $CONFIG_FILE ${CONFIG_FILE}.bak

        if [ "$action" == "uuid" ] || [ "$action" == "pass" ]; then
            local NEW_AUTH
            if [ "$action" == "uuid" ]; then NEW_AUTH=$(get_uuid); else NEW_AUTH=$(get_pass); fi
            
            if [ "$action" == "uuid" ]; then
                jq --arg tag "$TAG" --arg auth "$NEW_AUTH" '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $auth' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            else
                jq --arg tag "$TAG" --arg auth "$NEW_AUTH" '(.inbounds[] | select(.tag==$tag) | .users[0].password) = $auth' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            fi
            
            if ! restart_service; then 
                echo -e "${RED}操作失败，已还原配置！${PLAIN}"; mv ${CONFIG_FILE}.bak $CONFIG_FILE
            else
                echo -e "${GREEN}节点秘钥已更新！${PLAIN}"; rm -f ${CONFIG_FILE}.bak
            fi
            read -p "按回车键返回上一级..."
            
        elif [ "$action" == "cert" ]; then
            if prompt_cert_type; then
                jq --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" \
                '(.inbounds[] | select(.tag==$tag) | .tls.certificate_path) = $cert | (.inbounds[] | select(.tag==$tag) | .tls.key_path) = $key' \
                $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
                
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"; mv ${CONFIG_FILE}.bak $CONFIG_FILE
                else
                    echo -e "${GREEN}节点 $TAG 的证书已更新！${PLAIN}"; rm -f ${CONFIG_FILE}.bak
                fi
            else
                rm -f ${CONFIG_FILE}.bak
            fi
            read -p "按回车键返回上一级..."
            
        elif [ "$action" == "port" ]; then
            local f_proto=""
            local IS_ARGO=0
            if [[ "$TYPE" == "vless" && "$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type // empty' $CONFIG_FILE)" != "ws" ]]; then f_proto="tcp"
            elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"
            elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"
            fi

            local NEW_PORT
            while true; do
                read -p "请输入新端口 [默认随机]: " NEW_PORT
                NEW_PORT=${NEW_PORT:-$(rand_port)}
                if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then echo -e "${RED}错误输入!${PLAIN}"; continue; fi
                if check_port "$NEW_PORT" "$f_proto"; then echo -e "${RED}端口占用!${PLAIN}"; continue; fi
                break
            done
            
            jq --arg tag "$TAG" --argjson p "$NEW_PORT" '(.inbounds[] | select(.tag==$tag) | .listen_port) = $p' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            
            load_secrets
            if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1; then
                local var_pub="REALITY_PUB_${OLD_PORT}"
                local PUB="${!var_pub}"
                [ -n "$PUB" ] && save_secret "REALITY_PUB_${NEW_PORT}" "$PUB"
            elif jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                IS_ARGO=1
                local var_ip="ARGO_IP_${OLD_PORT}"
                local var_dom="ARGO_DOMAIN_${OLD_PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                [ -n "$A_IP" ] && save_secret "ARGO_IP_${NEW_PORT}" "$A_IP"
                [ -n "$A_DOM" ] && save_secret "ARGO_DOMAIN_${NEW_PORT}" "$A_DOM"
            fi
            
            if ! restart_service; then 
                echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                mv ${CONFIG_FILE}.bak $CONFIG_FILE
                remove_secret "REALITY_PUB_${NEW_PORT}"
                remove_secret "ARGO_IP_${NEW_PORT}"
                remove_secret "ARGO_DOMAIN_${NEW_PORT}"
            else
                remove_secret "REALITY_PUB_${OLD_PORT}"
                remove_secret "ARGO_IP_${OLD_PORT}"
                remove_secret "ARGO_DOMAIN_${OLD_PORT}"
                rm -f ${CONFIG_FILE}.bak
                
                echo -e "${GREEN}端口已更改为: $NEW_PORT${PLAIN}"
                
                if [ -n "$f_proto" ]; then
                    close_fw_port "$OLD_PORT" "$f_proto"
                    sed -i "\\|^${OLD_PORT}/${f_proto}\$|d" "$FW_PORTS_FILE" 2>/dev/null
                    read -p "是否自动放行新端口？(y/n) [默认: y]: " auto_fw
                    if [[ "${auto_fw:-y}" == "y" || "${auto_fw:-y}" == "Y" ]]; then open_fw_port "$NEW_PORT" "$f_proto"; fi
                fi
                
                if [ "$IS_ARGO" -eq 1 ]; then
                    echo -e "\n${YELLOW}【重要警告】: 您修改了 Argo 节点的本地端口！\n请务必前往 Cloudflare Zero Trust 后台，将对应 Tunnel 的 Public Hostname (Ingress) 映射目标端口同步更改为 localhost:${NEW_PORT}，否则节点将无法连接！${PLAIN}\n"
                fi
            fi
            read -p "按回车键返回上一级..."
            
        elif [ "$action" == "tag" ]; then
            local NEW_TAG=""
            while true; do
                read -p "请输入新的节点名称: " NEW_TAG
                NEW_TAG=${NEW_TAG// /-}
                if [ -z "$NEW_TAG" ]; then echo -e "${RED}不能为空!${PLAIN}"; continue; fi
                if ! [[ "$NEW_TAG" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo -e "${RED}错误：节点名称仅限字母、数字、短横线和下划线！${PLAIN}"; continue; fi
                if jq -e --arg tag "$NEW_TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then echo -e "${RED}名称已存在！${PLAIN}"; continue; fi
                break
            done
            
            local IS_ARGO=0
            if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then IS_ARGO=1; fi
            
            jq --arg tag "$TAG" --arg newtag "$NEW_TAG" '(.inbounds[] | select(.tag==$tag) | .tag) = $newtag' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
            
            if ! restart_service; then 
                echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                mv ${CONFIG_FILE}.bak $CONFIG_FILE
            else
                if [ "$IS_ARGO" -eq 1 ]; then
                    if [ "$OS_TYPE" == "alpine" ]; then
                        rc-service "cloudflared-${TAG}" stop >/dev/null 2>&1
                        rc-update del "cloudflared-${TAG}" default >/dev/null 2>&1
                        mv "/etc/init.d/cloudflared-${TAG}" "/etc/init.d/cloudflared-${NEW_TAG}"
                        sed -i "s|name=\"cloudflared-${TAG}\"|name=\"cloudflared-${NEW_TAG}\"|g" "/etc/init.d/cloudflared-${NEW_TAG}"
                        sed -i "s|cloudflared-${TAG}\.pid|cloudflared-${NEW_TAG}\.pid|g" "/etc/init.d/cloudflared-${NEW_TAG}"
                        rc-update add "cloudflared-${NEW_TAG}" default >/dev/null 2>&1
                        rc-service "cloudflared-${NEW_TAG}" start >/dev/null 2>&1
                    else
                        systemctl stop "cloudflared-${TAG}" >/dev/null 2>&1
                        systemctl disable "cloudflared-${TAG}" >/dev/null 2>&1
                        mv "/etc/systemd/system/cloudflared-${TAG}.service" "/etc/systemd/system/cloudflared-${NEW_TAG}.service"
                        sed -i "s|tunnel for ${TAG}|tunnel for ${NEW_TAG}|g" "/etc/systemd/system/cloudflared-${NEW_TAG}.service"
                        systemctl daemon-reload >/dev/null 2>&1
                        systemctl enable "cloudflared-${NEW_TAG}" --now >/dev/null 2>&1
                    fi
                fi
                echo -e "${GREEN}节点名称已成功更改为: $NEW_TAG${PLAIN}"
                rm -f ${CONFIG_FILE}.bak
            fi
            read -p "按回车键返回上一级..."
        fi
    done
}

del_config() {
    while true; do
        clear
        echo -e "选择: 删除节点配置\n"
        select_inbound || return
        
        local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
        local PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)

        cp $CONFIG_FILE ${CONFIG_FILE}.bak
        jq --arg tag "$TAG" 'del(.inbounds[] | select(.tag == $tag))' $CONFIG_FILE > $TMP_JSON && [ -s $TMP_JSON ] && mv $TMP_JSON $CONFIG_FILE
        
        if ! restart_service; then
            echo -e "${RED}删除失败：配置还原，内核未能正常重启！${PLAIN}"
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
            read -p "按回车键返回上一级..."
            continue
        fi
        
        rm -f ${CONFIG_FILE}.bak
        
        local IS_ARGO=0
        if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then IS_ARGO=1; fi
        
        local f_proto=""
        if [[ "$TYPE" == "vless" && "$IS_ARGO" -eq 0 ]]; then f_proto="tcp"
        elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"
        elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"
        fi

        if [ -n "$f_proto" ]; then
            close_fw_port "$PORT" "$f_proto"
            sed -i "\\|^${PORT}/${f_proto}\$|d" "$FW_PORTS_FILE" 2>/dev/null
        fi
        
        if [ "$IS_ARGO" -eq 1 ]; then
            if [ "$OS_TYPE" == "alpine" ]; then
                rc-service "cloudflared-${TAG}" stop >/dev/null 2>&1
                rc-update del "cloudflared-${TAG}" default >/dev/null 2>&1
                rm -f "/etc/init.d/cloudflared-${TAG}"
            else
                systemctl stop "cloudflared-${TAG}" >/dev/null 2>&1
                systemctl disable "cloudflared-${TAG}" >/dev/null 2>&1
                rm -f "/etc/systemd/system/cloudflared-${TAG}.service"
                systemctl daemon-reload >/dev/null 2>&1
            fi
        fi
        
        remove_secret "REALITY_PUB_${PORT}"
        remove_secret "ARGO_IP_${PORT}"
        remove_secret "ARGO_DOMAIN_${PORT}"
        
        local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE)
        if [ "$INBOUND_COUNT" -eq 0 ]; then
            echo -e "${GREEN}配置 $TAG 已删除！检测到已无节点，内核已自动停止。${PLAIN}"
        else
            echo -e "${GREEN}配置 $TAG 已删除！${PLAIN}"
        fi
        read -p "按回车键返回上一级..."
    done
}

view_single_config() {
    while true; do
        clear
        echo -e "选择: 单协议链接\n"
        select_inbound || return
        print_config_detail "$TAG"
        read -p "按回车键返回上一级..."
    done
}

show_all_links() {
    clear
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    echo -e "🚀【 聚合节点 】节点信息如下：\n"
    
    local old_IFS=$IFS
    IFS=$'\n'
    TAGS=($(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' "$CONFIG_FILE"))
    IFS=$old_IFS
    
    if [ ${#TAGS[@]} -eq 0 ]; then
        echo -e "${RED}未添加节点配置！${PLAIN}"
    else
        IP=$(get_ip)
        for TAG in "${TAGS[@]}"; do build_share_url "$TAG" "$IP"; done
    fi
    echo -e "~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~"
    read -p "按回车键返回上一级..."
}

view_config() {
    while true; do
        clear
        echo -e "选择: 查看节点配置\n"
        echo -e " 1) 单协议链接"
        echo -e " 2) 聚合链接"
        echo -e " 0) 返回\n"
        while true; do
            read -p "请选择 [0-2]: " v_idx
            case "$v_idx" in 1) view_single_config; break ;; 2) show_all_links; break ;; 0) return ;; *) echo -e "${RED}输入错误!${PLAIN}" ;; esac
        done
    done
}

run_manage() {
    while true; do
        clear
        echo -e "选择: 运行管理\n"
        echo " 1) 启动"
        echo " 2) 停止"
        echo " 3) 重启"
        echo " 0) 返回\n"
        while true; do
            read -p "请选择 [0-3]: " run_idx
            case "$run_idx" in
                1|3) 
                   local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE 2>/dev/null)
                   if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then echo -e "${RED}未添加节点配置！${PLAIN}"; read -p "按回车..."; break; fi
                   if [ "$run_idx" == "1" ]; then
                       if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box start; else systemctl start sing-box; fi
                       echo -e "${GREEN}已启动${PLAIN}"
                   else
                       restart_service; echo -e "${GREEN}已重启${PLAIN}"
                   fi
                   read -p "按回车键返回上一级..."; break ;;
                2) 
                   if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop; else systemctl stop sing-box; fi
                   echo -e "${GREEN}已停止${PLAIN}"; read -p "按回车键返回上一级..."; break ;;
                0) return ;;
                *) echo -e "${RED}输入错误!${PLAIN}" ;;
            esac
        done
    done
}

update_manage() {
    while true; do
        clear
        echo -e "${CYAN}正在检查更新，请稍候...${PLAIN}"
        local CUR_VER="未安装"
        if [ -f "/usr/local/bin/sing-box" ]; then CUR_VER=$(/usr/local/bin/sing-box version 2>/dev/null | head -n 1 | awk '{print $3}'); fi
        local NEW_VER=$(get_latest_version)
        local SB_UPDATE_TEXT="更新 sing-box 内核"
        if [ -n "$NEW_VER" ]; then
            if [ "$CUR_VER" != "$NEW_VER" ]; then SB_UPDATE_TEXT="更新 sing-box 内核 ${GREEN}[发现新版: v${NEW_VER}]${PLAIN}"
            else SB_UPDATE_TEXT="更新 sing-box 内核 ${YELLOW}[已是最新: v${CUR_VER}]${PLAIN}"
            fi
        fi

        clear
        echo -e "选择: 检查更新\n"
        echo -e " 1) ${SB_UPDATE_TEXT}"
        echo -e " 2) 更新脚本"
        echo -e " 0) 返回\n"
        while true; do
            read -p "请选择 [0-2]: " up_idx
            case "$up_idx" in
                1)
                    if [ -z "$NEW_VER" ]; then echo -e "${RED}获取最新版本失败！API 受限或网络超时。${PLAIN}"; read -p "按回车..."; break; fi
                    if [ "$CUR_VER" == "$NEW_VER" ]; then echo -e "\n${GREEN}当前已是最新，无需更新！${PLAIN}"; read -p "按回车..."; break; fi
                    
                    echo -e "\n${YELLOW}即将更新内核至 v${NEW_VER}...${PLAIN}"
                    local UP_TMP=$(mktemp -d)
                    if wget --show-progress -qO $UP_TMP/sb.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${NEW_VER}/sing-box-${NEW_VER}-linux-${SB_ARCH}.tar.gz"; then
                        if tar -xzf $UP_TMP/sb.tar.gz -C $UP_TMP; then
                            if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop >/dev/null 2>&1; else systemctl stop sing-box >/dev/null 2>&1; fi
                            rm -f /usr/local/bin/sing-box
                            mv $UP_TMP/sing-box-${NEW_VER}-linux-${SB_ARCH}/sing-box /usr/local/bin/sing-box
                            chmod +x /usr/local/bin/sing-box
                            restart_service
                            GLOBAL_LATEST_VER="$NEW_VER"
                            echo -e "\n${GREEN}内核更新成功！当前版本: v${NEW_VER}${PLAIN}"
                        else
                            echo -e "\n${RED}解压失败，已安全回退并保留原内核。${PLAIN}"
                        fi
                    else
                        echo -e "\n${RED}下载失败，已安全回退并保留原内核。请检查网络。${PLAIN}"
                    fi
                    rm -rf $UP_TMP
                    read -p "按回车键返回上一级..."; break ;;
                2)
                    echo -e "\n${CYAN}正在拉取最新脚本代码...${PLAIN}"
                    local SCRIPT_UP_TMP=$(mktemp)
                    if curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o "$SCRIPT_UP_TMP" && [ -s "$SCRIPT_UP_TMP" ]; then
                        mv "$SCRIPT_UP_TMP" /usr/local/bin/sb
                        chmod +x /usr/local/bin/sb
                        echo -e "${GREEN}脚本代码更新成功！请重新运行 sb 命令。${PLAIN}"
                        exit 0
                    else
                        echo -e "${RED}下载脚本失败，网络异常！更新中止。${PLAIN}"
                        rm -f "$SCRIPT_UP_TMP"
                    fi
                    ;;
                0) return ;;
                *) echo -e "${RED}输入错误!${PLAIN}" ;;
            esac
        done
    done
}

uninstall_all() {
    read -p "确认卸载脚本、sing-box和所有节点配置吗？(y/n): " un
    if [[ "$un" == "y" ]]; then
        remove_all_fw_rules
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service sing-box stop >/dev/null 2>&1
            rc-update del sing-box default >/dev/null 2>&1
            rm -f /etc/init.d/sing-box
            for f in /etc/init.d/cloudflared-*; do
                if [ -f "$f" ]; then svc=$(basename "$f"); rc-service "$svc" stop >/dev/null 2>&1; rc-update del "$svc" default >/dev/null 2>&1; rm -f "$f"; fi
            done
        else
            systemctl stop sing-box >/dev/null 2>&1
            systemctl disable sing-box >/dev/null 2>&1
            rm -f /etc/systemd/system/sing-box.service
            for f in /etc/systemd/system/cloudflared-*.service; do
                if [ -f "$f" ]; then svc=$(basename "$f"); systemctl stop "$svc" >/dev/null 2>&1; systemctl disable "$svc" >/dev/null 2>&1; rm -f "$f"; fi
            done
            systemctl daemon-reload >/dev/null 2>&1
        fi
        
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then
            load_secrets
            if [ -n "$REAL_DOMAIN" ]; then
                $HOME/.acme.sh/acme.sh --remove -d "$REAL_DOMAIN" >/dev/null 2>&1
            fi
        fi
        
        rm -rf /usr/local/bin/sing-box /usr/local/bin/cloudflared /usr/local/bin/sb /etc/sing-box
        echo -e "${GREEN}已彻底卸载！系统已恢复原状。${PLAIN}"
    fi
}

menu() {
    init_base || { echo -e "${RED}系统环境初始化失败，无法继续运行！${PLAIN}"; exit 1; }
    local LATEST_VER_CACHE=$(get_latest_version)
    GLOBAL_LATEST_VER="$LATEST_VER_CACHE"
    
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
        if [ -n "$VER" ]; then
            if [ -n "$GLOBAL_LATEST_VER" ] && [ "$VER" != "$GLOBAL_LATEST_VER" ]; then VER_SHOW="${VER} ${YELLOW}[新版: ${GLOBAL_LATEST_VER}]${PLAIN}"
            else VER_SHOW="${VER}"
            fi
        else
            VER_SHOW="未安装"
        fi
        
        echo -e "------------- sing-box 管理脚本 -------------"
        echo -e "sing-box ${VER_SHOW}: ${ST_COLOR}${SB_STATUS}${PLAIN}\n"
        echo -e " 1) 添加节点配置"
        echo -e " 2) 更改节点"
        echo -e " 3) 删除节点"
        echo -e " 4) 查看节点"
        echo -e " 5) 证书管理"
        echo -e " 6) 运行管理"
        echo -e " 7) 更新"
        echo -e " 8) 卸载"
        echo -e " 0) 退出\n"
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
        echo -e " 4. 退出\n"
        read -p "请选择 [1-4]: " pre_choice
        case "$pre_choice" in
            1)
                echo -e "${CYAN}正在拉取最新脚本代码...${PLAIN}"
                SCRIPT_TMP=$(mktemp)
                if curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o "$SCRIPT_TMP" && [ -s "$SCRIPT_TMP" ]; then
                    mv "$SCRIPT_TMP" /usr/local/bin/sb
                    chmod +x /usr/local/bin/sb
                    echo -e "${GREEN}脚本代码更新成功！请执行 sb 命令进入面板。${PLAIN}"
                    exit 0
                else
                    echo -e "${RED}下载脚本失败，网络异常！${PLAIN}"
                    rm -f "$SCRIPT_TMP"
                    exit 1
                fi
                ;;
            2) uninstall_all; exit 0 ;;
            3) ;;
            *) exit 0 ;;
        esac
    else
        echo -e "${CYAN}==> 正在将管理脚本写入到全局环境...${PLAIN}"
        SCRIPT_TMP=$(mktemp)
        if curl -sL "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" -o "$SCRIPT_TMP" && [ -s "$SCRIPT_TMP" ]; then
            mv "$SCRIPT_TMP" /usr/local/bin/sb
            chmod +x /usr/local/bin/sb
            rm -f sb.sh install.sh 2>/dev/null
            echo -e "\n${GREEN}==> 脚本安装完成！以后可随时输入 ${YELLOW}sb${GREEN} 快捷调用本面板。${PLAIN}"
            sleep 2
        else
            echo -e "${RED}初始化脚本下载失败，请检查网络！${PLAIN}"
            rm -f "$SCRIPT_TMP"
            exit 1
        fi
    fi
fi

menu
