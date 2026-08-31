#!/bin/bash

umask 077

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

trap 'rm -f "${CONFIG_FILE}".tmp.* /usr/local/bin/.sb.* 2>/dev/null' EXIT
trap 'rm -f "${CONFIG_FILE}".tmp.* /usr/local/bin/.sb.* 2>/dev/null; exit 1' INT TERM

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
KERNEL_REINSTALLED=0

pause() {
    while read -r -t 0.1; do :; done
    echo ""
    read -r -p "按回车键继续..."
}

get_ip() {
    if [ -z "$GLOBAL_IP" ]; then
        mkdir -p "$CONFIG_DIR" 2>/dev/null
        local IP_CACHE="$CONFIG_DIR/.ip_cache"
        local IP_TTL=300
        if [ -f "$IP_CACHE" ]; then
            local c_time c_ip
            c_time=$(head -n 1 "$IP_CACHE" 2>/dev/null)
            c_ip=$(tail -n 1 "$IP_CACHE" 2>/dev/null)
            if [[ "$c_time" =~ ^[0-9]+$ ]] && [ $(( $(date +%s) - c_time )) -le $IP_TTL ] && [ -n "$c_ip" ]; then
                GLOBAL_IP="$c_ip"
                echo "$GLOBAL_IP"
                return
            fi
        fi

        local ip
        ip=$(http_get https://ipv4.icanhazip.com)
        if [[ "$ip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
            GLOBAL_IP="$ip"
        else
            ip=$(http_get https://ipv6.icanhazip.com)
            if [[ "$ip" == *:* && "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
                GLOBAL_IP="$ip"
            fi
        fi

        if [ -n "$GLOBAL_IP" ]; then
            { echo "$(date +%s)"; echo "$GLOBAL_IP"; } > "$IP_CACHE" 2>/dev/null
            chmod 600 "$IP_CACHE" 2>/dev/null
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

        local res
        res=$(http_get "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
              | grep '"tag_name":' \
              | sed -E 's/.*"tag_name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' \
              | head -n 1)
        if [[ "$res" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
            GLOBAL_LATEST_VER=${res#v}
            echo "$NOW" > "$CACHE_FILE"
            echo "$GLOBAL_LATEST_VER" >> "$CACHE_FILE"
            chmod 600 "$CACHE_FILE" 2>/dev/null
        fi
    fi
    echo "$GLOBAL_LATEST_VER"
}

JQ_DNS_LOCAL='.dns.servers |= (. // []) |
  if (.dns.servers | map(select(.tag == "dns-local")) | length == 0) then
    .dns.servers += [{"tag": "dns-local", "type": "local"}]
  else . end'

sb_ge_112() {
    local ver
    ver=$( ( /usr/local/bin/sing-box version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
    [ -z "$ver" ] && return 1
    local major=$(echo "$ver" | cut -d. -f1)
    local minor=$(echo "$ver" | cut -d. -f2)
    [[ "$major" =~ ^[0-9]+$ ]] && [[ "$minor" =~ ^[0-9]+$ ]] || return 1
    [ "$major" -gt 1 ] && return 0
    { [ "$major" -eq 1 ] && [ "$minor" -ge 12 ]; } && return 0
    return 1
}

check_port() {
    local port=$1
    local proto=${2:-both}
    local ss_arg="-tuln"
    [ "$proto" == "tcp" ] && ss_arg="-tln"
    [ "$proto" == "udp" ] && ss_arg="-uln"
    
    local pat="[^[:space:]]:${port}([[:space:]]|\$)"
    if command -v ss >/dev/null 2>&1; then
        ss $ss_arg 2>/dev/null | tail -n +2 | grep -qE "$pat"
    elif command -v netstat >/dev/null 2>&1; then
        netstat $ss_arg 2>/dev/null | grep -qE "$pat"
    else
        return 1
    fi
}

rand_port() {
    local port
    while true; do
        port=$(( ( (RANDOM << 15) | RANDOM ) % 55001 + 10000 ))
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
    mv -f "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
}

remove_secret() {
    local key_prefix=$1
    if [ -f "$SECRETS_FILE" ]; then
        grep -v "^${key_prefix}=" "$SECRETS_FILE" > "${SECRETS_FILE}.tmp"
        mv -f "${SECRETS_FILE}.tmp" "$SECRETS_FILE"
    fi
}

load_secrets() {
    [ -f "$SECRETS_FILE" ] && source "$SECRETS_FILE"
    return 0
}

apply_jq_config() {
    local jq_filter="$1"
    shift
    local tmp
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    if jq "$@" "$jq_filter" "$CONFIG_FILE" > "$tmp" && [ -s "$tmp" ]; then
        mv -f "$tmp" "$CONFIG_FILE"
        return 0
    else
        rm -f "$tmp"
        echo -e "${RED}配置生成失败，请检查 jq 表达式或联系维护者！${PLAIN}" >&2
        return 1
    fi
}

http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -sL -m 10 "$url" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -T 10 -qO - "$url" 2>/dev/null && return 0
    fi
    return 1
}

fetch_script() {
    local t
    t=$(mktemp /usr/local/bin/.sb.XXXXXX) || return 1
    if fetch_url "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" "$t" \
       && [ -s "$t" ] && head -n 1 "$t" | grep -q '^#!/bin/bash'; then
        chmod 755 "$t"
        mv -f "$t" /usr/local/bin/sb
        return 0
    fi
    rm -f "$t"
    return 1
}

cleanup_node_secrets() {
    local port="$1" type="$2" is_argo="${3:-0}"
    if [ "$is_argo" -eq 1 ]; then
        remove_secret "ARGO_IP_${port}"
        remove_secret "ARGO_DOMAIN_${port}"
    elif [ "$type" == "vless" ]; then
        remove_secret "REALITY_PUB_${port}"
    fi
}

open_fw_port() {
    local port=$1
    local proto=$2
    local success=0
    local fw_found=0

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        fw_found=1
        ufw allow ${port}/${proto} comment 'sb-sh' >/dev/null 2>&1 || ufw allow ${port}/${proto} >/dev/null 2>&1
        [ $? -eq 0 ] && success=1
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
            apply_jq_config '(.inbounds[] | select(.tls.certificate_path? != null) | .tls.certificate_path) |= sub("fullchain.cer"; "real.cer") | (.inbounds[] | select(.tls.key_path? != null) | .tls.key_path) |= sub("private.key"; "real.key")' >/dev/null 2>&1
            save_secret "REAL_DOMAIN" "$DOMAIN"
        else
            mv "$CERT_DIR/fullchain.cer" "$CERT_DIR/self.cer" 2>/dev/null
            mv "$CERT_DIR/private.key" "$CERT_DIR/self.key" 2>/dev/null
            apply_jq_config '(.inbounds[] | select(.tls.certificate_path? != null) | .tls.certificate_path) |= sub("fullchain.cer"; "self.cer") | (.inbounds[] | select(.tls.key_path? != null) | .tls.key_path) |= sub("private.key"; "self.key")' >/dev/null 2>&1
            save_secret "SELF_DOMAIN" "$DOMAIN"
        fi
        sed -i '/^CERT_TYPE=/d; /^DOMAIN=/d' "$SECRETS_FILE"
    fi
}

kernel_ok() {
    [ -x /usr/local/bin/sing-box ] || return 1
    local ver
    ver=$( ( /usr/local/bin/sing-box version ) 2>/dev/null ) || return 1
    echo "$ver" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+' || return 1
    return 0
}

fetch_url() {
    local url="$1" out="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 2 --connect-timeout 15 -o "$out" "$url" && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        if wget --help 2>&1 | grep -q -- '--show-progress'; then
            wget --show-progress -qO "$out" "$url" && return 0
        else
            wget -O "$out" "$url" && return 0
        fi
    fi
    return 1
}

install_kernel() {
    local ver="$1"
    local mode="${2:-restart}"
    [ -z "$ver" ] && return 1

    local tmp
    tmp=$(mktemp -d) || return 1
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz"

    echo -e "${CYAN}==> 正在下载 sing-box v${ver} (${SB_ARCH})...${PLAIN}"
    if ! fetch_url "$url" "$tmp/sb.tar.gz"; then
        echo -e "${RED}下载失败，已保留原内核。请检查网络。${PLAIN}"
        rm -rf "$tmp"; return 1
    fi
    if ! tar -xzf "$tmp/sb.tar.gz" -C "$tmp" 2>/dev/null; then
        echo -e "${RED}解压失败，已保留原内核。${PLAIN}"
        rm -rf "$tmp"; return 1
    fi
    local newbin="$tmp/sing-box-${ver}-linux-${SB_ARCH}/sing-box"
    if [ ! -s "$newbin" ]; then
        echo -e "${RED}压缩包内未找到内核文件，已保留原内核。${PLAIN}"
        rm -rf "$tmp"; return 1
    fi

    [ -s /usr/local/bin/sing-box ] && cp -f /usr/local/bin/sing-box "$tmp/sing-box.old" 2>/dev/null

    if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop >/dev/null 2>&1; else systemctl stop sing-box >/dev/null 2>&1; fi
    if ! mv -f "$newbin" /usr/local/bin/sing-box; then
        echo -e "${RED}写入 /usr/local/bin/sing-box 失败！${PLAIN}"
        rm -rf "$tmp"; return 1
    fi
    chmod +x /usr/local/bin/sing-box
    chown 0:0 /usr/local/bin/sing-box 2>/dev/null

    if ! kernel_ok; then
        echo -e "${RED}新内核 v${ver} 无法执行(可能缺少运行库或架构不匹配)。${PLAIN}"
        if [ -s "$tmp/sing-box.old" ]; then
            mv -f "$tmp/sing-box.old" /usr/local/bin/sing-box
            chmod +x /usr/local/bin/sing-box
            chown 0:0 /usr/local/bin/sing-box 2>/dev/null
            echo -e "${YELLOW}已回滚到原内核。${PLAIN}"
        fi
        rm -rf "$tmp"; return 1
    fi

    if [ "$mode" == "norestart" ]; then
        echo -e "${GREEN}==> 内核 v${ver} 安装完毕！${PLAIN}"
        rm -rf "$tmp"; return 0
    fi

    if restart_service; then
        echo -e "${GREEN}==> 内核已覆盖为 v${ver}，服务运行正常。${PLAIN}"
        rm -rf "$tmp"; return 0
    fi

    if [ -s "$tmp/sing-box.old" ]; then
        mv -f "$tmp/sing-box.old" /usr/local/bin/sing-box
        chmod +x /usr/local/bin/sing-box
        restart_service
        echo -e "${RED}v${ver} 启动失败(配置可能不被新版接受)，已回滚到原内核。${PLAIN}"
        echo -e "${YELLOW}可执行 sing-box check -c ${CONFIG_FILE} 查看具体报错。${PLAIN}"
    else
        echo -e "${RED}v${ver} 启动失败，且旧内核备份不可用！请手动排查。${PLAIN}"
    fi
    rm -rf "$tmp"
    return 1
}

ensure_deps() {
    local miss=()
    local c
    for c in "$@"; do
        command -v "$c" >/dev/null 2>&1 || miss+=("$c")
    done
    [ ${#miss[@]} -eq 0 ] && return 0

    echo -e "${CYAN}==> 缺少依赖: ${miss[*]}，正在自动安装...${PLAIN}"
    local pkgs=()
    for c in "${miss[@]}"; do
        case "$c" in
            crontab) [ "$OS_TYPE" == "alpine" ] && pkgs+=(dcron) || { [ "$OS_TYPE" == "centos" ] && pkgs+=(cronie) || pkgs+=(cron); } ;;
            ss)      pkgs+=(iproute2) ;;
            *)       pkgs+=("$c") ;;
        esac
    done

    if [ "$OS_TYPE" == "alpine" ]; then
        apk update >/dev/null 2>&1
        apk add "${pkgs[@]}" >/dev/null 2>&1
    elif [ "$OS_TYPE" == "centos" ]; then
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y epel-release >/dev/null 2>&1
            dnf install -y "${pkgs[@]}" >/dev/null 2>&1
        else
            yum install -y epel-release >/dev/null 2>&1
            yum install -y "${pkgs[@]}" >/dev/null 2>&1
        fi
    else
        apt-get update -y >/dev/null 2>&1
        apt-get install -y "${pkgs[@]}" >/dev/null 2>&1
    fi

    local still=()
    for c in "${miss[@]}"; do
        command -v "$c" >/dev/null 2>&1 || still+=("$c")
    done
    if [ ${#still[@]} -gt 0 ]; then
        echo -e "${RED}以下依赖安装失败: ${still[*]}${PLAIN}"
        echo -e "${YELLOW}请手动安装后重试。${PLAIN}"
        return 1
    fi
    echo -e "${GREEN}==> 依赖安装完毕。${PLAIN}"
    return 0
}

init_base() {
    ensure_deps curl wget jq tar openssl socat ss crontab || return 1

    if [ "$OS_TYPE" == "alpine" ]; then
        if [ ! -e /lib/ld-linux-x86-64.so.2 ] && [ ! -e /lib64/ld-linux-x86-64.so.2 ] \
           && [ ! -e /lib/ld-linux-aarch64.so.1 ] && [ ! -e /lib64/ld-linux-aarch64.so.1 ]; then
            echo -e "${CYAN}==> 正在安装 glibc 兼容层(sing-box 官方二进制需要)...${PLAIN}"
            apk add libc6-compat gcompat >/dev/null 2>&1
        fi
        rc-update add crond default >/dev/null 2>&1
        rc-service crond start >/dev/null 2>&1
    elif [ "$OS_TYPE" == "centos" ]; then
        systemctl enable crond --now >/dev/null 2>&1
    fi

    if ! kernel_ok; then
        echo -e "${CYAN}==> 正在获取最新版 sing-box 内核信息...${PLAIN}"
        local VERSION
        VERSION=$(get_latest_version)

        if [ -z "$VERSION" ]; then
            echo -e "${YELLOW}获取版本信息失败！${PLAIN}"
            read -p "请手动输入要安装的 sing-box 版本号 (例如 1.10.1): " VERSION
            if [ -z "$VERSION" ]; then
                echo -e "${RED}未输入版本号，安装终止。${PLAIN}"
                return 1
            fi
        fi
        echo -e "${CYAN}==> 开始下载 v${VERSION} 内核...${PLAIN}"
        install_kernel "$VERSION" norestart || return 1
        KERNEL_REINSTALLED=1
    fi


    mkdir -p $CONFIG_DIR $CERT_DIR || return 1
    
    if [ -f "$CONFIG_FILE" ]; then
        if ! jq -e '.inbounds | type == "array"' "$CONFIG_FILE" >/dev/null 2>&1; then
            echo -e "${RED}检测到 $CONFIG_FILE 已损坏（非法 JSON 或缺少 inbounds 数组）！${PLAIN}"
            read -p "是否重建为空白配置？原文件会被备份，但现有节点将丢失。(y/n) [默认: n]: " rebuild
            if [[ "${rebuild:-n}" != "y" && "${rebuild:-n}" != "Y" ]]; then
                echo -e "${YELLOW}已取消，未做任何修改。请手动修复该文件后再运行本脚本。${PLAIN}"
                return 1
            fi
            local broken_bak="${CONFIG_FILE}.broken.$(date +%Y%m%d%H%M%S)"
            if mv "$CONFIG_FILE" "$broken_bak" 2>/dev/null; then
                echo -e "${YELLOW}原文件已备份为: ${broken_bak}${PLAIN}"
            fi
        fi
    fi
    
    if [ ! -f "$CONFIG_FILE" ]; then
        if sb_ge_112; then
            echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"rules":[{"ip_is_private":true,"action":"reject"}]}}' > $CONFIG_FILE
        else
            echo '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"}],"route":{"rules":[{"ip_is_private":true,"outbound":"block"}]}}' > $CONFIG_FILE
        fi
    else
        apply_jq_config '(.route.rules[] | select(has("geoip") and .geoip == "private")) |= (del(.geoip) | .ip_is_private = true)' >/dev/null 2>&1
        
        if ! jq -e '.outbounds? // [] | map(select(.tag=="direct")) | length > 0' "$CONFIG_FILE" >/dev/null 2>&1; then
            apply_jq_config '.outbounds = ((.outbounds // []) + [{"type":"direct","tag":"direct"}])' >/dev/null 2>&1
        fi
        
        if sb_ge_112; then
            if grep -q '"block"' $CONFIG_FILE; then
                apply_jq_config '(.route.rules[]? | select(.outbound=="block")) |= (del(.outbound) | .action="reject") | .outbounds |= map(select(.type!="block"))' >/dev/null 2>&1
            fi
            
            if grep -q '"domain_strategy"' $CONFIG_FILE || grep -q '"domain_resolver"' $CONFIG_FILE; then
                apply_jq_config "
                  $JQ_DNS_LOCAL |
                  (.outbounds[] | select(has(\"domain_strategy\"))) |= (.domain_resolver = {\"server\": \"dns-local\", \"strategy\": .domain_strategy} | del(.domain_strategy)) |
                  (.outbounds[] | select(has(\"domain_resolver\"))) |= (if .domain_resolver.server == null or .domain_resolver.server == \"\" then .domain_resolver.server = \"dns-local\" else . end)
                " >/dev/null 2>&1
            fi
        fi
    fi
    migrate_certs

    if [ "${KERNEL_REINSTALLED:-0}" -eq 1 ]; then
        local n
        n=$(jq '.inbounds | length' "$CONFIG_FILE" 2>/dev/null)
        if [ -n "$n" ] && [ "$n" -gt 0 ]; then
            echo -e "${CYAN}==> 检测到已有节点，正在用新内核重启服务...${PLAIN}"
            if restart_service; then
                echo -e "${GREEN}==> 服务已恢复运行。${PLAIN}"
            else
                echo -e "${RED}==> 服务启动失败！请用 [6) 运行管理] 查看，或执行:${PLAIN}"
                echo -e "${YELLOW}    sing-box check -c ${CONFIG_FILE}${PLAIN}"
            fi
        fi
    fi
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
        sleep 2
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
        sleep 2
        if [ "$(systemctl is-active sing-box 2>/dev/null)" != "active" ]; then
            sleep 2
            [ "$(systemctl is-active sing-box 2>/dev/null)" != "active" ] && return 1
        fi
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

    local reuse=0
    local had_prior=0
    if [ -f ~/.acme.sh/acme.sh ]; then
        local dconf=$(~/.acme.sh/acme.sh --info -d "${NEW_DOMAIN}" 2>/dev/null | sed -n 's/^DOMAIN_CONF=//p')
        local exist_cer=""
        if [ -n "$dconf" ]; then
            local ddir="${dconf%/*}"
            for c in "$ddir/fullchain.cer" "$ddir/${NEW_DOMAIN}.cer"; do
                [ -s "$c" ] && { exist_cer="$c"; break; }
            done
        fi
        [ -n "$exist_cer" ] && had_prior=1
        if [ -n "$exist_cer" ]; then
            local left_days=""
            if command -v openssl >/dev/null 2>&1; then
                local end_ts=$(date -d "$(openssl x509 -in "$exist_cer" -noout -enddate 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null)
                [ -n "$end_ts" ] && left_days=$(( (end_ts - $(date +%s)) / 86400 ))
            fi
            if [ -n "$left_days" ] && [ "$left_days" -gt 7 ]; then
                echo -e "\n${GREEN}检测到 ${NEW_DOMAIN} 已有有效证书，剩余 ${left_days} 天。${PLAIN}"
                echo -e "${YELLOW}Let's Encrypt 对同一域名限制 168 小时内最多签发 5 次，建议直接复用。${PLAIN}"
                read -p "是否复用现有证书？(y/n) [默认: y]: " ru
                [[ "${ru:-y}" == "y" || "${ru:-y}" == "Y" ]] && reuse=1
            fi
        fi
    fi

    if [ "$reuse" -eq 0 ]; then
    echo -e "\n请选择验证方式:"
    echo -e " 1) 80端口独立申请 - 需确保服务器80端口开放且未被占用"
    echo -e " 2) Cloudflare DNS API - 推荐，适合各类环境"
    local v_mode
    while true; do
        read -p "请选择 [1-2]: " v_mode
        if [[ "$v_mode" == "1" || "$v_mode" == "2" ]]; then break; fi
    done

    if [ ! -f ~/.acme.sh/acme.sh ]; then
        if command -v curl >/dev/null 2>&1; then
            curl -sL https://get.acme.sh | sh
        elif command -v wget >/dev/null 2>&1; then
            wget -qO - https://get.acme.sh | sh
        fi
        if [ ! -f ~/.acme.sh/acme.sh ]; then
            echo -e "${RED}acme.sh 安装失败！请检查网络后重试。${PLAIN}"
            return 1
        fi
    fi
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1

    if [ "$v_mode" == "1" ]; then
        open_fw_port 80 tcp >/dev/null
        local issue_ok=1
        if ! ~/.acme.sh/acme.sh --issue -d ${NEW_DOMAIN} --standalone --force; then
            issue_ok=0
        fi
        close_fw_port 80 tcp
        sed -i "\\|^80/tcp\$|d" "$FW_PORTS_FILE" 2>/dev/null
        if [ "$issue_ok" -eq 0 ]; then
            echo -e "${RED}申请失败！请检查域名解析和 80 端口是否连通。${PLAIN}"
            return 1
        fi
    else
        local NEW_CF_Key=""
        while true; do
            read -p "请输入 Cloudflare Global API Key: " NEW_CF_Key >&2
            if [[ "$NEW_CF_Key" =~ ^[A-Za-z0-9]+$ ]]; then break; fi
            echo -e "${RED}错误：API Key 格式不正确！${PLAIN}" >&2
        done
        
        local NEW_CF_Email=""
        while true; do
            read -p "请输入 Cloudflare 邮箱: " NEW_CF_Email >&2
            if [[ "$NEW_CF_Email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
            echo -e "${RED}错误：邮箱格式不正确，请重新输入！${PLAIN}" >&2
        done
        
        if ! CF_Key="${NEW_CF_Key}" CF_Email="${NEW_CF_Email}" ~/.acme.sh/acme.sh --issue --dns dns_cf -d ${NEW_DOMAIN} --force; then
            echo -e "${RED}申请失败！请检查 CF API 是否正确，或该域名已达 Let's Encrypt 签发频率上限。${PLAIN}"
            return 1
        fi
    fi
    fi
    
    if [ "$OS_TYPE" == "alpine" ]; then
        local RELOAD_CMD="rc-service sing-box restart >/dev/null 2>&1 || true"
    else
        local RELOAD_CMD="systemctl restart sing-box >/dev/null 2>&1 || true"
    fi
    
    ~/.acme.sh/acme.sh --installcert -d ${NEW_DOMAIN} \
        --fullchainpath $CERT_DIR/real.cer \
        --keypath $CERT_DIR/real.key \
        --reloadcmd "$RELOAD_CMD"
    
    if [ ! -s "$CERT_DIR/real.cer" ] || [ ! -s "$CERT_DIR/real.key" ]; then
        echo -e "${RED}证书部署至目标目录失败！请检查系统权限或 acme.sh 报错信息。${PLAIN}"
        return 1
    fi
    
    chmod 644 $CERT_DIR/*.cer 2>/dev/null
    chmod 600 $CERT_DIR/*.key 2>/dev/null
    save_secret "REAL_DOMAIN" "$NEW_DOMAIN"
    if [ "$had_prior" -eq 1 ]; then
        save_secret "REAL_CERT_OWNED" "0"
    else
        save_secret "REAL_CERT_OWNED" "1"
    fi
    echo -e "${GREEN}域名证书申请并安装完成！${PLAIN}"
    return 0
}

generate_self_cert() {
    ensure_deps openssl || return 1

    local NEW_DOMAIN=$(get_domain "请输入伪装域名" "bing.com")
    
    echo -e "${CYAN}正在生成自签证书...${PLAIN}"
    if ! ( umask 077; openssl req -x509 -nodes -days 36500 -newkey rsa:2048 \
        -keyout $CERT_DIR/self.key -out $CERT_DIR/self.cer -subj "/CN=${NEW_DOMAIN}" ); then
        echo -e "${RED}生成自签证书失败！请查看上方报错信息。${PLAIN}"
        rm -f $CERT_DIR/self.key $CERT_DIR/self.cer
        return 1
    fi
    save_secret "SELF_DOMAIN" "$NEW_DOMAIN"
    
    chmod 644 $CERT_DIR/*.cer 2>/dev/null
    chmod 600 $CERT_DIR/*.key 2>/dev/null
    echo -e "${GREEN}自签证书生成完毕！${PLAIN}"
    return 0
}

cert_manage() {
    while true; do
        clear
        echo -e "选择: 证书管理\n"
        echo -e " 1) 重新申请域名证书"
        echo -e " 2) 重新生成自签证书"
        echo -e " 3) 查看证书与自动续期状态"
        echo -e " 0) 返回\n"
        
        load_secrets
        read -p "请选择 [0-3]: " cert_idx
        case "$cert_idx" in
            1) apply_real_cert; pause ;;
            2) generate_self_cert; pause ;;
            3)
                echo -e "\n------------- 域名证书 -------------"
                if [ -s "$CERT_DIR/real.cer" ]; then
                    echo -e "绑定的域名\t: ${GREEN}${REAL_DOMAIN}${PLAIN}"
                    echo -e "证书路径\t: ${GREEN}$CERT_DIR/real.cer${PLAIN}"
                    if crontab -l 2>/dev/null | grep -q "acme.sh"; then
                        echo -e "${GREEN}acme.sh 自动续期已运行中！${PLAIN}"
                    else
                        echo -e "${RED}警告: 未发现自动续期任务！${PLAIN}"
                    fi
                else
                    echo -e "${YELLOW}当前未安装域名证书。${PLAIN}"
                fi
                echo -e "\n------------- 自签证书 -------------"
                if [ -s "$CERT_DIR/self.cer" ]; then
                    echo -e "伪装域名\t: ${GREEN}${SELF_DOMAIN}${PLAIN}"
                    echo -e "证书路径\t: ${GREEN}$CERT_DIR/self.cer${PLAIN}"
                else
                    echo -e "${YELLOW}当前未生成自签证书。${PLAIN}"
                fi
                echo -e "------------------------------------"
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}输入错误，请重新选择!${PLAIN}"; sleep 1 ;;
        esac
    done
}

prompt_cert_type() {
    echo -e "\n请选择该节点使用的证书类型:"
    echo -e " 1) 域名证书"
    echo -e " 2) 自签证书"
    local c_idx
    while true; do
        read -p "请选择 [1-2]: " c_idx
        case "$c_idx" in
            1)
                if [ ! -s "$CERT_DIR/real.cer" ] || [ ! -s "$CERT_DIR/real.key" ]; then
                    echo -e "${YELLOW}未检测到有效域名证书，需要先申请...${PLAIN}"
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

node_read() {
    jq -r --arg tag "$1" '
      .inbounds[] | select(.tag==$tag) |
      .type,
      (.listen_port|tostring),
      (.tls.certificate_path // ""),
      (.users[0].uuid // ""),
      (.users[0].password // ""),
      (.tls.server_name // ""),
      (.tls.reality.short_id[0] // ""),
      (if .tls.reality.enabled == true then "1" else "0" end),
      (if .transport.type == "ws" then "1" else "0" end)
    ' "$CONFIG_FILE" 2>/dev/null
}

resolve_conn() {
    local cert_path=$1
    local ip=$2
    CONN_ADDR=$ip
    CONN_INSECURE=1
    CONN_SNI=""
    if [[ "$cert_path" == *"/real.cer" ]]; then
        if [ -z "$REAL_DOMAIN" ] && [ -s "$cert_path" ] && command -v openssl >/dev/null 2>&1; then
            REAL_DOMAIN=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/.*CN *= *\([^,]*\).*/\1/p' | tr -d ' ')
            [ -n "$REAL_DOMAIN" ] && save_secret "REAL_DOMAIN" "$REAL_DOMAIN"
        fi
        CONN_ADDR=$REAL_DOMAIN
        CONN_INSECURE=0
        CONN_SNI=$REAL_DOMAIN
    elif [[ "$cert_path" == *"/self.cer" ]]; then
        CONN_SNI=${SELF_DOMAIN:-bing.com}
    fi
}

build_share_url() {
    local TAG=$1
    local IP=$2
    load_secrets

    local -a M
    mapfile -t M < <(node_read "$TAG")
    [ "${#M[@]}" -lt 9 ] && { echo -e "${RED}[读取节点 $TAG 失败]${PLAIN}"; return; }
    local TYPE=${M[0]} PORT=${M[1]} CERT_PATH=${M[2]}
    local N_UUID=${M[3]} N_PASS=${M[4]} SNI=${M[5]} SID=${M[6]}
    local IS_REALITY=${M[7]} IS_WS=${M[8]}

    resolve_conn "$CERT_PATH" "$IP"
    local SNI_URL="${CONN_SNI:+&sni=${CONN_SNI}}"

    local IP_URI=$(wrap_ipv6 "$IP")
    local CONN_ADDR_URI=$(wrap_ipv6 "$CONN_ADDR")

    case "$TYPE" in
        vless)
            if [ "$IS_REALITY" == "1" ]; then
                if [ -z "$IP" ]; then echo -e "${RED}[获取公网IP异常，无法生成 VLESS-REALITY 链接]${PLAIN}"; return; fi
                local var_name="REALITY_PUB_${PORT}"
                local PUB="${!var_name}"
                echo "vless://${N_UUID}@${IP_URI}:${PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${SNI}&fp=chrome&pbk=${PUB}&sid=${SID}&type=tcp&headerType=none#${TAG}"
            elif [ "$IS_WS" == "1" ]; then
                local var_ip="ARGO_IP_${PORT}"
                local var_dom="ARGO_DOMAIN_${PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                if [ -z "$A_IP" ]; then echo -e "${RED}[无法读取 Argo IP，无法生成链接]${PLAIN}"; return; fi
                local A_IP_URI=$(wrap_ipv6 "$A_IP")
                echo "vless://${N_UUID}@${A_IP_URI}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 Hysteria2 链接]${PLAIN}"; return; fi
            local AUTH_ENC=$(url_encode "$N_PASS")
            echo "hysteria2://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?security=tls&alpn=h3&insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        tuic)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 TUIC 链接]${PLAIN}"; return; fi
            local T_UUID_ENC=$(url_encode "$N_UUID")
            local T_PASS_ENC=$(url_encode "$N_PASS")
            echo "tuic://${T_UUID_ENC}:${T_PASS_ENC}@${CONN_ADDR_URI}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        anytls)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 AnyTLS 链接]${PLAIN}"; return; fi
            local AUTH_ENC=$(url_encode "$N_PASS")
            echo "anytls://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
    esac
}

print_config_detail() {
    local TAG=$1
    local IP=$(get_ip)
    load_secrets

    local -a M
    mapfile -t M < <(node_read "$TAG")
    [ "${#M[@]}" -lt 9 ] && { echo -e "${RED}[读取节点 $TAG 失败]${PLAIN}"; return; }
    local TYPE=${M[0]} PORT=${M[1]} CERT_PATH=${M[2]}
    local N_UUID=${M[3]} N_PASS=${M[4]} SNI=${M[5]} SID=${M[6]}
    local IS_REALITY=${M[7]} IS_WS=${M[8]}

    resolve_conn "$CERT_PATH" "$IP"
    local INSECURE_TEXT="true"
    [ "$CONN_INSECURE" -eq 0 ] && INSECURE_TEXT="false"
    local SNI_VAL=$CONN_SNI

    echo -e "\n-------------- ${YELLOW}$TAG${PLAIN} -------------"
    echo -e "协议 (protocol)\t\t\t= $TYPE"

    case "$TYPE" in
        vless)
            if [ "$IS_REALITY" == "1" ]; then
                local var_name="REALITY_PUB_${PORT}"
                local PUB="${!var_name}"
                local IP_DISP=$(wrap_ipv6 "$IP")
                echo -e "地址 (address)\t\t\t= ${IP_DISP:-[获取公网IP失败]}"
                echo -e "端口 (port)\t\t\t= $PORT"
                echo -e "用户ID (id)\t\t\t= $N_UUID"
                echo -e "流控 (flow)\t\t\t= xtls-rprx-vision"
                echo -e "传输层安全 (TLS)\t\t= reality"
                echo -e "伪装域名 (sni)\t\t\t= $SNI"
                echo -e "公钥 (pbk)\t\t\t= $PUB"
                echo -e "ShortId (sid)\t\t\t= $SID"
            elif [ "$IS_WS" == "1" ]; then
                local var_ip="ARGO_IP_${PORT}"
                local var_dom="ARGO_DOMAIN_${PORT}"
                local A_IP="${!var_ip}"
                local A_DOM="${!var_dom}"
                local A_IP_DISP=$(wrap_ipv6 "$A_IP")
                echo -e "地址 (address)\t\t\t= $A_IP_DISP"
                echo -e "端口 (port)\t\t\t= 443"
                echo -e "用户ID (id)\t\t\t= $N_UUID"
                echo -e "传输协议 (network)\t\t= ws"
                echo -e "传输层安全 (TLS)\t\t= tls"
                echo -e "伪装域名 (sni)\t\t\t= $A_DOM"
                echo -e "请求主机 (host)\t\t\t= $A_DOM"
                echo -e "路径 (path)\t\t\t= /argo"
            fi
            ;;
        hysteria2)
            local CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        tuic)
            local CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "用户ID (id)\t\t\t= $N_UUID"
            echo -e "密码 (password)\t\t\t= $N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            echo -e "拥塞控制算法 (congestion_control)= bbr"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        anytls)
            local CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "密码 (password)\t\t\t= $N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
    esac

    echo -e "------------- 链接 (URL) -------------"
    build_share_url "$TAG" "$IP"

    if [ "$INSECURE_TEXT" == "true" ] && [ "$IS_REALITY" != "1" ] && [ "$IS_WS" != "1" ]; then
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
        pause
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

warn_port_shared() {
    local port=$1 proto=$2 self_tag=$3
    [ -z "$proto" ] && return 1
    local other
    other=$(jq -r --argjson p "$port" --arg self "${self_tag:-}" '
      .inbounds[]
      | select(.listen_port == $p)
      | select(.tag != $self)
      | "\(.tag)|\(.type)|\(if .transport.type == "ws" then "ws" else "" end)"
    ' "$CONFIG_FILE" 2>/dev/null)
    [ -z "$other" ] && return 1

    local found=1
    while IFS='|' read -r o_tag o_type o_ws; do
        [ -z "$o_tag" ] && continue
        local o_proto=""
        case "$o_type" in
            hysteria2|tuic) o_proto="udp" ;;
            anytls)         o_proto="tcp" ;;
            vless)          [ "$o_ws" != "ws" ] && o_proto="tcp" ;;
        esac
        if [ -n "$o_proto" ] && [ "$o_proto" != "$proto" ]; then
            echo -e "\n${YELLOW}提示: 端口 ${port} 已被节点 ${o_tag} 使用 (${o_proto^^})，本节点用的是 ${proto^^}。${PLAIN}"
            echo -e "${YELLOW}内核允许 TCP/UDP 同号共存，但请确认防火墙与云服务商/NAT 端口映射${PLAIN}"
            echo -e "${YELLOW}对 ${proto^^} 和 ${o_proto^^} 两种协议都放行了 ${port}，否则其中一个节点会连不上。${PLAIN}"
            found=0
        fi
    done <<< "$other"
    return $found
}

add_config() {
    while true; do
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
        warn_port_shared "$PORT" "$f_proto"
        
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
        local jq_ok=1

        case "$proto_idx" in
            1)
                local UUID=$(get_uuid)
                local SNI=$(get_domain "请输入伪装域名" "apple.com")
                local KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
                local PK=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
                local PUB=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
                local SID=$(/usr/local/bin/sing-box generate rand --hex 8)
                save_secret "REALITY_PUB_${PORT}" "$PUB"
                
                apply_jq_config '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg pk "$PK" --arg sid "$SID" --arg tag "$TAG" || jq_ok=0
                ;;
            2)
                local PASS=$(get_pass)
                if ! prompt_cert_type; then rm -f ${CONFIG_FILE}.bak; continue; fi
                
                apply_jq_config '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            3)
                local UUID=$(get_uuid)
                local PASS=$(get_pass)
                if ! prompt_cert_type; then rm -f ${CONFIG_FILE}.bak; continue; fi
                
                apply_jq_config '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            4)
                local PASS=$(get_pass)
                if ! prompt_cert_type; then rm -f ${CONFIG_FILE}.bak; continue; fi
                
                apply_jq_config '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h2","http/1.1"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            5)
                IS_ARGO=1
                local UUID=$(get_uuid)
                local ARGO_IP=$(get_domain "请输入 Argo 优选域名/IP" "saas.sin.fan" "true")
                local ARGO_DOMAIN=$(get_domain "请输入 Argo 隧道域名" "example.com")
                
                local ARGO_TOKEN=""
                while true; do
                    read -p "请输入 Cloudflare Tunnel Token: " ARGO_TOKEN >&2
                    if [[ "$ARGO_TOKEN" =~ ^[A-Za-z0-9+/=._-]+$ ]]; then break; fi
                    echo -e "${RED}错误：Token 格式不正确或为空！${PLAIN}" >&2
                done
                
                save_secret "ARGO_IP_${PORT}" "$ARGO_IP"
                save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN"
                
                if ! apply_jq_config '.inbounds += [{"type":"vless","tag":$tag,"listen":"127.0.0.1","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG"; then
                    jq_ok=0
                else
                    if ! command -v cloudflared &> /dev/null; then
                        echo -e "${CYAN}正在下载 cloudflared 组件...${PLAIN}"
                        local TMP_CF=$(mktemp)
                        local cf_arch="amd64"
                        [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && cf_arch="arm64"
                        if fetch_url "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" "$TMP_CF"; then
                            mv $TMP_CF /usr/local/bin/cloudflared
                            chmod +x /usr/local/bin/cloudflared
                        else
                            echo -e "${RED}下载 cloudflared 失败！${PLAIN}"
                            rm -f $TMP_CF
                        fi
                    fi
                    
                    if [ "$OS_TYPE" == "alpine" ]; then
                        ( umask 077; cat > "/etc/init.d/cloudflared-${TAG}" << 'EOF'
#!/sbin/openrc-run
name="cloudflared-@@SB_TAG@@"
command="/usr/local/bin/cloudflared"
command_args="tunnel --no-autoupdate --protocol http2 run --token @@SB_TOKEN@@"
command_background=true
pidfile="/var/run/cloudflared-@@SB_TAG@@.pid"
depend() { need net; }
EOF
                        )
                        sed -i "s|@@SB_TAG@@|${TAG}|g" "/etc/init.d/cloudflared-${TAG}"
                        sed -i "s|@@SB_TOKEN@@|${ARGO_TOKEN}|g" "/etc/init.d/cloudflared-${TAG}"
                        chmod 700 "/etc/init.d/cloudflared-${TAG}"
                        rc-update add "cloudflared-${TAG}" default >/dev/null 2>&1
                        rc-service "cloudflared-${TAG}" restart >/dev/null 2>&1
                    else
                        ( umask 077; cat > "/etc/systemd/system/cloudflared-${TAG}.service" << 'EOF'
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
                        )
                        sed -i "s|@@SB_TAG@@|${TAG}|g" "/etc/systemd/system/cloudflared-${TAG}.service"
                        sed -i "s|@@SB_TOKEN@@|${ARGO_TOKEN}|g" "/etc/systemd/system/cloudflared-${TAG}.service"
                        chmod 600 "/etc/systemd/system/cloudflared-${TAG}.service"
                        systemctl daemon-reload >/dev/null 2>&1
                        systemctl enable "cloudflared-${TAG}" --now >/dev/null 2>&1
                    fi
                fi
                ;;
        esac
        
        local NODE_SEC_TYPE=""
        [ "$proto_idx" == "1" ] && NODE_SEC_TYPE="vless"

        if [ "$jq_ok" -eq 0 ]; then
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
            cleanup_node_secrets "$PORT" "$NODE_SEC_TYPE" "$IS_ARGO"
            pause
            continue
        fi

        if ! restart_service; then
            echo -e "${RED}节点添加失败(校验报错)，已为您还原配置！${PLAIN}"
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
            cleanup_node_secrets "$PORT" "$NODE_SEC_TYPE" "$IS_ARGO"
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
            pause
            continue
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
        pause
    done
}

modify_config() {
    while true; do
        clear
        echo -e "选择: 更改节点\n"
        select_inbound || return

        while true; do
            clear
            local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' "$CONFIG_FILE")
            local OLD_PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_FILE")
            
            if [ -z "$TYPE" ] || [ "$TYPE" == "null" ]; then
                break
            fi
            
            echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"
            
            local action=""
            if [ "$TYPE" == "vless" ]; then
                local IS_REALITY=0
                if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' "$CONFIG_FILE" >/dev/null 2>&1; then IS_REALITY=1; fi
                local IS_ARGO=0
                if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' "$CONFIG_FILE" >/dev/null 2>&1; then IS_ARGO=1; fi

                echo -e " 1) 更改 UUID"
                echo -e " 2) 更改端口"
                echo -e " 3) 更改节点名称"
                [ "$IS_REALITY" -eq 1 ] && echo -e " 4) 更改伪装域名"
                [ "$IS_ARGO" -eq 1 ] && echo -e " 4) 更改优选域名/IP"
                echo -e " 0) 返回\n"
                
                while true; do
                    if [ "$IS_REALITY" -eq 1 ] || [ "$IS_ARGO" -eq 1 ]; then
                        read -p "请选择 [0-4]: " mod_idx
                        case "$mod_idx" in 
                            1) action="uuid"; break ;; 
                            2) action="port"; break ;; 
                            3) action="tag"; break ;; 
                            4) [ "$IS_REALITY" -eq 1 ] && action="sni" || action="argo_ip"; break ;; 
                            0) break ;; 
                            *) echo -e "${RED}错误!${PLAIN}" ;; 
                        esac
                    else
                        read -p "请选择 [0-3]: " mod_idx
                        case "$mod_idx" in 
                            1) action="uuid"; break ;; 
                            2) action="port"; break ;; 
                            3) action="tag"; break ;; 
                            0) break ;; 
                            *) echo -e "${RED}错误!${PLAIN}" ;; 
                        esac
                    fi
                done
            elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "anytls" || "$TYPE" == "tuic" ]]; then
                echo -e " 1) 更改主密钥/密码"
                echo -e " 2) 更改端口"
                echo -e " 3) 更改节点名称"
                echo -e " 4) 更改证书类型 (域名/自签)"
                echo -e " 0) 返回\n"
                while true; do
                    read -p "请选择 [0-4]: " mod_idx
                    case "$mod_idx" in 
                        1) action="pass"; break ;; 
                        2) action="port"; break ;; 
                        3) action="tag"; break ;; 
                        4) action="cert"; break ;; 
                        0) break ;; 
                        *) echo -e "${RED}错误!${PLAIN}" ;; 
                    esac
                done
            else
                echo -e "${RED}不支持修改的协议类型${PLAIN}"
                pause
                break
            fi

            [ "$mod_idx" == "0" ] && break
            
            if [ "$action" == "argo_ip" ]; then
                local NEW_ARGO_IP=$(get_domain "请输入新的 Argo 优选域名/IP" "saas.sin.fan" "true")
                save_secret "ARGO_IP_${OLD_PORT}" "$NEW_ARGO_IP"
                echo -e "${GREEN}优选域名/IP 已成功更改为: $NEW_ARGO_IP${PLAIN}"
                pause
                continue
            fi

            cp $CONFIG_FILE ${CONFIG_FILE}.bak

            if [ "$action" == "uuid" ] || [ "$action" == "pass" ]; then
                local NEW_AUTH
                if [ "$action" == "uuid" ]; then NEW_AUTH=$(get_uuid); else NEW_AUTH=$(get_pass); fi
                
                if [ "$action" == "uuid" ]; then
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $auth' --arg tag "$TAG" --arg auth "$NEW_AUTH"; then
                        rm -f ${CONFIG_FILE}.bak
                        pause
                        continue
                    fi
                else
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .users[0].password) = $auth' --arg tag "$TAG" --arg auth "$NEW_AUTH"; then
                        rm -f ${CONFIG_FILE}.bak
                        pause
                        continue
                    fi
                fi
                
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"; mv ${CONFIG_FILE}.bak $CONFIG_FILE
                else
                    echo -e "${GREEN}节点秘钥已更新！${PLAIN}"; rm -f ${CONFIG_FILE}.bak
                fi
                pause
                
            elif [ "$action" == "cert" ]; then
                if prompt_cert_type; then
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tls.certificate_path) = $cert | (.inbounds[] | select(.tag==$tag) | .tls.key_path) = $key' \
                    --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY"; then
                        rm -f ${CONFIG_FILE}.bak
                        pause
                        continue
                    fi
                    
                    if ! restart_service; then 
                        echo -e "${RED}操作失败，已还原配置！${PLAIN}"; mv ${CONFIG_FILE}.bak $CONFIG_FILE
                    else
                        echo -e "${GREEN}节点 $TAG 的证书已更新！${PLAIN}"; rm -f ${CONFIG_FILE}.bak
                    fi
                else
                    rm -f ${CONFIG_FILE}.bak
                fi
                pause
                
            elif [ "$action" == "port" ]; then
                local f_proto=""
                local IS_ARGO=0
                if [[ "$TYPE" == "vless" && "$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type // empty' $CONFIG_FILE)" != "ws" ]]; then f_proto="tcp"
                elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"
                elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"
                fi

                if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                    echo -e "\n${YELLOW}注意: 这是 Argo 节点，入口由 Cloudflare Tunnel 提供。${PLAIN}"
                    echo -e "${YELLOW}改完本地端口后，必须去 Cloudflare Zero Trust 后台把该 Tunnel 的${PLAIN}"
                    echo -e "${YELLOW}Public Hostname (Ingress) 目标同步改成 localhost:<新端口>，${PLAIN}"
                    echo -e "${YELLOW}否则节点会立即失效(隧道返回 502)。${PLAIN}"
                    read -p "确认继续修改端口？(y/n) [默认: n]: " argo_go
                    if [[ "${argo_go:-n}" != "y" && "${argo_go:-n}" != "Y" ]]; then
                        echo -e "${CYAN}已取消。${PLAIN}"
                        pause
                        continue
                    fi
                fi

                local NEW_PORT
                while true; do
                    read -p "请输入新端口 [默认随机]: " NEW_PORT
                    NEW_PORT=${NEW_PORT:-$(rand_port)}
                    if ! [[ "$NEW_PORT" =~ ^[0-9]+$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then echo -e "${RED}错误输入!${PLAIN}"; continue; fi
                    if [ "$NEW_PORT" != "$OLD_PORT" ] && check_port "$NEW_PORT" "$f_proto"; then echo -e "${RED}端口占用!${PLAIN}"; continue; fi
                    break
                done
                warn_port_shared "$NEW_PORT" "$f_proto" "$TAG"
                
                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .listen_port) = $p' --arg tag "$TAG" --argjson p "$NEW_PORT"; then
                    rm -f ${CONFIG_FILE}.bak
                    pause
                    continue
                fi
                
                load_secrets
                local IS_REALITY_NODE=0
                if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .tls.reality.enabled' $CONFIG_FILE >/dev/null 2>&1; then
                    IS_REALITY_NODE=1
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

                local SEC_TYPE=""
                [ "$IS_REALITY_NODE" -eq 1 ] && SEC_TYPE="vless"

                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                    mv ${CONFIG_FILE}.bak $CONFIG_FILE
                    if [ "$OLD_PORT" != "$NEW_PORT" ]; then
                        cleanup_node_secrets "$NEW_PORT" "$SEC_TYPE" "$IS_ARGO"
                    fi
                else
                    if [ "$OLD_PORT" != "$NEW_PORT" ]; then
                        cleanup_node_secrets "$OLD_PORT" "$SEC_TYPE" "$IS_ARGO"
                    fi
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
                pause
                
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
                
                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tag) = $newtag' --arg tag "$TAG" --arg newtag "$NEW_TAG"; then
                    rm -f ${CONFIG_FILE}.bak
                    pause
                    continue
                fi
                
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
                    TAG="$NEW_TAG"
                fi
                pause
                
            elif [ "$action" == "sni" ]; then
                local NEW_SNI=$(get_domain "请输入新的伪装域名" "apple.com")
                
                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tls.server_name) = $sni | (.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server) = $sni' \
                --arg tag "$TAG" --arg sni "$NEW_SNI"; then
                    rm -f ${CONFIG_FILE}.bak
                    pause
                    continue
                fi
                
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                    mv ${CONFIG_FILE}.bak $CONFIG_FILE
                else
                    echo -e "${GREEN}伪装域名已成功更改为: $NEW_SNI${PLAIN}"
                    rm -f ${CONFIG_FILE}.bak
                fi
                pause
            fi
        done
    done
}

del_config() {
    while true; do
        clear
        echo -e "选择: 删除节点\n"
        select_inbound || return
        
        local TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
        local PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)
        local IS_ARGO=0
        if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then IS_ARGO=1; fi
        
        cp $CONFIG_FILE ${CONFIG_FILE}.bak
        
        if ! apply_jq_config 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$TAG"; then
            rm -f ${CONFIG_FILE}.bak
            pause
            continue
        fi
        
        if ! restart_service; then
            echo -e "${RED}删除失败：配置还原，内核未能正常重启！${PLAIN}"
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
            pause
            continue
        fi
        
        rm -f ${CONFIG_FILE}.bak
        
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
        
        cleanup_node_secrets "$PORT" "$TYPE" "$IS_ARGO"
        
        local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE)
        if [ "$INBOUND_COUNT" -eq 0 ]; then
            echo -e "${GREEN}配置 $TAG 已删除！检测到已无节点，内核已自动停止。${PLAIN}"
        else
            echo -e "${GREEN}配置 $TAG 已删除！${PLAIN}"
        fi
        pause
    done
}

view_single_config() {
    while true; do
        clear
        echo -e "选择: 单协议链接\n"
        select_inbound || return
        print_config_detail "$TAG"
        pause
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
    pause
}

view_config() {
    while true; do
        clear
        echo -e "选择: 查看节点\n"
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
        echo -e " 1) 启动"
        echo -e " 2) 停止"
        echo -e " 3) 重启"
        echo -e " 0) 返回\n"
        while true; do
            read -p "请选择 [0-3]: " run_idx
            case "$run_idx" in
                1|3) 
                   local INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE 2>/dev/null)
                   if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then echo -e "${RED}未添加节点配置！${PLAIN}"; pause; break; fi
                   if [ "$run_idx" == "1" ]; then
                       if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box start; else systemctl start sing-box; fi
                       echo -e "${GREEN}已启动${PLAIN}"
                   else
                       restart_service; echo -e "${GREEN}已重启${PLAIN}"
                   fi
                   pause; break ;;
                2) 
                   if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop; else systemctl stop sing-box; fi
                   echo -e "${GREEN}已停止${PLAIN}"; pause; break ;;
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
        if kernel_ok; then
            local extracted_ver
            extracted_ver=$( ( /usr/local/bin/sing-box version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
            [ -n "$extracted_ver" ] && CUR_VER="$extracted_ver"
        fi
        local NEW_VER=$(get_latest_version)
        local SB_UPDATE_TEXT="更新 sing-box 内核"
        if kernel_ok && [ -n "$NEW_VER" ]; then
            if [ "$CUR_VER" != "$NEW_VER" ]; then SB_UPDATE_TEXT="更新 sing-box 内核 ${GREEN}[发现新版: v${NEW_VER}]${PLAIN}"
            else SB_UPDATE_TEXT="更新 sing-box 内核 ${YELLOW}[已是最新: v${CUR_VER}]${PLAIN}"
            fi
        fi

        clear
        echo -e "选择: 更新\n"
        echo -e " 1) ${SB_UPDATE_TEXT}"
        echo -e " 2) 更新脚本"
        echo -e " 3) 强制覆盖重装内核"
        echo -e " 0) 返回\n"
        while true; do
            read -p "请选择 [0-3]: " up_idx
            case "$up_idx" in
                1)
                    if [ -z "$NEW_VER" ]; then echo -e "${RED}获取最新版本失败！API 受限或网络超时。${PLAIN}"; pause; break; fi
                    if kernel_ok && [ "$CUR_VER" == "$NEW_VER" ]; then echo -e "\n${GREEN}当前已是最新，无需更新！${PLAIN}"; pause; break; fi
                    
                    echo -e "\n${YELLOW}即将更新内核至 v${NEW_VER}...${PLAIN}"
                    install_kernel "$NEW_VER" restart
                    pause; break ;;
                2)
                    echo -e "\n${CYAN}正在拉取最新脚本代码...${PLAIN}"
                    if fetch_script; then
                        echo -e "${GREEN}脚本代码更新成功！请重新运行 sb 命令。${PLAIN}"
                        exit 0
                    else
                        echo -e "${RED}下载脚本失败或内容校验不通过！更新中止。${PLAIN}"
                    fi
                    ;;
                3)
                    if [ -z "$NEW_VER" ]; then
                        read -p "获取最新版本失败，请手动输入要安装的版本号 (如 1.10.1): " NEW_VER
                        [ -z "$NEW_VER" ] && { echo -e "${RED}未输入版本号，已取消。${PLAIN}"; pause; break; }
                    fi
                    echo -e "\n${YELLOW}将强制覆盖安装 v${NEW_VER}（无论当前版本是否相同）。${PLAIN}"
                    read -p "确认继续？(y/n) [默认: y]: " fc
                    if [[ "${fc:-y}" == "y" || "${fc:-y}" == "Y" ]]; then
                        install_kernel "$NEW_VER" restart
                    else
                        echo -e "${YELLOW}已取消。${PLAIN}"
                    fi
                    pause; break ;;
                0) return ;;
                *) echo -e "${RED}输入错误!${PLAIN}" ;;
            esac
        done
    done
}

enable_bbr() {
    echo -e "${CYAN}==> 尝试开启 BBR 加速...${PLAIN}"
    local current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$current_cc" == "bbr" ]; then
        echo -e "${GREEN}当前系统已经开启了 BBR，无需重复配置！${PLAIN}"
        pause
        return
    fi

    modprobe tcp_bbr 2>/dev/null

    if [ -f /etc/sysctl.conf ]; then
        if grep -qE '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=' /etc/sysctl.conf; then
            if [ ! -f "$CONFIG_DIR/.sysctl_backup" ]; then
                mkdir -p "$CONFIG_DIR" 2>/dev/null
                grep -E '^[[:space:]]*(net\.core\.default_qdisc|net\.ipv4\.tcp_congestion_control)[[:space:]]*=' \
                    /etc/sysctl.conf > "$CONFIG_DIR/.sysctl_backup" 2>/dev/null
                chmod 600 "$CONFIG_DIR/.sysctl_backup" 2>/dev/null
                echo -e "${CYAN}已备份 /etc/sysctl.conf 中原有的 qdisc/拥塞控制设置。${PLAIN}"
            fi
        fi
    fi

    sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf 2>/dev/null
    sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1

    local new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
    if [ "$new_cc" == "bbr" ]; then
        echo -e "${GREEN}BBR 加速开启成功！配置已写入 /etc/sysctl.d/99-bbr.conf，重启后依然生效。${PLAIN}"
    else
        echo -e "${YELLOW}应用失败，当前系统内核可能不支持 BBR，或架构受限（如 OpenVZ/LXC 容器）无法修改内核参数。${PLAIN}"
    fi
    pause
}

config_outbound() {
    while true; do
        clear
        local current_strategy=$(jq -r '.outbounds[] | select(.tag=="direct") | (.domain_resolver.strategy // .domain_strategy // "auto")' $CONFIG_FILE 2>/dev/null)
        echo -e "选择: 配置出站 IPv4/IPv6 策略"
        echo -e "当前出站策略: ${GREEN}${current_strategy}${PLAIN}\n"
        echo -e " 1) 仅 IPv4 出站 (ipv4_only)"
        echo -e " 2) 仅 IPv6 出站 (ipv6_only)"
        echo -e " 3) 自动/双栈出站 (auto)"
        echo -e " 0) 返回\n"
        read -p "请选择 [0-3]: " out_idx
        
        local USE_NEW_FORMAT=0
        if ! kernel_ok || sb_ge_112; then
            USE_NEW_FORMAT=1
        fi
        
        local strategy=""
        case "$out_idx" in
            1) strategy="ipv4_only" ;;
            2) strategy="ipv6_only" ;;
            3) strategy="auto" ;;
            0) return ;;
            *) echo -e "${RED}输入错误!${PLAIN}"; sleep 1; continue ;;
        esac

        local jq_success=0
        cp $CONFIG_FILE ${CONFIG_FILE}.bak
        if [ "$strategy" == "auto" ]; then
            apply_jq_config '(.outbounds[] | select(.tag=="direct")) |= del(.domain_strategy, .domain_resolver)' && jq_success=1
        elif [ "$USE_NEW_FORMAT" -eq 1 ]; then
            apply_jq_config "
              $JQ_DNS_LOCAL |
              (.outbounds[] | select(.tag==\"direct\")) |= (del(.domain_strategy) | .domain_resolver = {\"server\": \"dns-local\", \"strategy\": \$s})
            " --arg s "$strategy" && jq_success=1
        else
            apply_jq_config '(.outbounds[] | select(.tag=="direct")).domain_strategy = $s' --arg s "$strategy" && jq_success=1
        fi

        if [ "$jq_success" -eq 0 ]; then
            rm -f ${CONFIG_FILE}.bak
            pause
            continue
        fi
        
        if ! restart_service; then
            echo -e "${RED}操作失败(校验报错)，配置已还原！${PLAIN}"
            mv ${CONFIG_FILE}.bak $CONFIG_FILE
        else
            echo -e "${GREEN}出站策略已更新！${PLAIN}"
            rm -f ${CONFIG_FILE}.bak
        fi
        pause
    done
}

other_manage() {
    while true; do
        clear
        echo -e "选择: 其他\n"
        echo -e " 1) 开启 BBR 加速"
        echo -e " 2) 配置出站 IPv4/IPv6"
        echo -e " 0) 返回\n"
        read -p "请选择 [0-2]: " om_idx
        case "$om_idx" in
            1) enable_bbr ;;
            2) config_outbound ;;
            0) return ;;
            *) echo -e "${RED}输入错误!${PLAIN}"; sleep 1 ;;
        esac
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
            if [ -n "$REAL_DOMAIN" ] && [ "${REAL_CERT_OWNED:-1}" == "1" ]; then
                $HOME/.acme.sh/acme.sh --remove -d "$REAL_DOMAIN" >/dev/null 2>&1
            elif [ -n "$REAL_DOMAIN" ]; then
                echo -e "${YELLOW}证书 ${REAL_DOMAIN} 为复用的已有证书，已保留其 acme.sh 续期记录。${PLAIN}"
            fi
        fi
        
        SYSCTL_BAK_TMP=""
        if [ -f "$CONFIG_DIR/.sysctl_backup" ]; then
            SYSCTL_BAK_TMP=$(mktemp) && cp -f "$CONFIG_DIR/.sysctl_backup" "$SYSCTL_BAK_TMP" 2>/dev/null
        fi

        rm -rf /usr/local/bin/sing-box /usr/local/bin/cloudflared /usr/local/bin/sb /etc/sing-box
        
        if [ -f /etc/sysctl.d/99-bbr.conf ]; then
            rm -f /etc/sysctl.d/99-bbr.conf 2>/dev/null
            if [ -n "$SYSCTL_BAK_TMP" ] && [ -s "$SYSCTL_BAK_TMP" ]; then
                sed -i '/net.core.default_qdisc/d; /net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf 2>/dev/null
                cat "$SYSCTL_BAK_TMP" >> /etc/sysctl.conf 2>/dev/null
                sysctl -p /etc/sysctl.conf >/dev/null 2>&1
                echo -e "${GREEN}已还原 /etc/sysctl.conf 中原有的 qdisc/拥塞控制设置。${PLAIN}"
            else
                sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
                sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
            fi
        fi
        [ -n "$SYSCTL_BAK_TMP" ] && rm -f "$SYSCTL_BAK_TMP"
        
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
        
        VER=$( ( /usr/local/bin/sing-box version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
        if [ -n "$VER" ]; then
            if [ -n "$GLOBAL_LATEST_VER" ] && [ "$VER" != "$GLOBAL_LATEST_VER" ]; then VER_SHOW="${VER} ${YELLOW}[新版: ${GLOBAL_LATEST_VER}]${PLAIN}"
            else VER_SHOW="${VER}"
            fi
        else
            VER_SHOW="未安装"
        fi
        
        echo -e "------------- sing-box 管理脚本 -------------"
        echo -e "sing-box ${VER_SHOW}: ${ST_COLOR}${SB_STATUS}${PLAIN}\n"
        echo -e " 1) 添加节点"
        echo -e " 2) 更改节点"
        echo -e " 3) 删除节点"
        echo -e " 4) 查看节点"
        echo -e " 5) 证书管理"
        echo -e " 6) 运行管理"
        echo -e " 7) 更新"
        echo -e " 8) 其他"
        echo -e " 9) 卸载"
        echo -e " 0) 退出\n"
        read -p "请选择 [0-9]: " choice

        case "$choice" in
            1) add_config ;;
            2) modify_config ;;
            3) del_config ;;
            4) view_config ;;
            5) cert_manage ;;
            6) run_manage ;;
            7) update_manage ;;
            8) other_manage ;;
            9) uninstall_all; exit 0 ;;
            0) exit 0 ;;
            *) echo "输入错误!"; sleep 1 ;;
        esac
    done
}

if [[ "$0" != "/usr/local/bin/sb" ]] && [[ "$0" != "sb" ]] && [[ "$0" != *"/sb" ]]; then
    if [ -f "/usr/local/bin/sb" ]; then
        clear
        echo -e "${GREEN}检测到 sing-box 管理脚本已经安装！${PLAIN}\n"
        echo -e " 1. 更新覆盖脚本 + 内核"
        echo -e " 2. 卸载脚本 + 内核"
        echo -e " 3. 进入面板"
        echo -e " 4. 退出\n"
        read -p "请选择 [1-4]: " pre_choice
        case "$pre_choice" in
            1)
                echo -e "${CYAN}正在拉取最新脚本代码...${PLAIN}"
                if ! fetch_script; then
                    echo -e "${RED}下载脚本失败或内容校验不通过！${PLAIN}"
                    exit 1
                fi
                echo -e "${GREEN}脚本代码更新成功！${PLAIN}\n"

                CUR_K="未安装"
                if kernel_ok; then
                    CUR_K=$( ( /usr/local/bin/sing-box version ) 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
                fi
                NEW_K=$(get_latest_version)
                echo -e "${CYAN}当前内核: ${CUR_K}    最新版本: ${NEW_K:-获取失败}${PLAIN}"

                if [ -z "$NEW_K" ]; then
                    echo -e "${YELLOW}获取最新内核版本失败，已跳过内核覆盖。${PLAIN}"
                    echo -e "${YELLOW}可稍后执行 sb 进入面板，用 [7) 更新] 单独处理内核。${PLAIN}"
                    exit 0
                fi

                do_kernel="n"
                if ! kernel_ok; then
                    echo -e "${RED}内核缺失或损坏，将强制覆盖安装 v${NEW_K}。${PLAIN}"
                    do_kernel="y"
                elif [ "$CUR_K" != "$NEW_K" ]; then
                    read -p "发现新内核 v${NEW_K}，是否一并覆盖更新？(y/n) [默认: y]: " ans
                    [[ "${ans:-y}" == "y" || "${ans:-y}" == "Y" ]] && do_kernel="y"
                else
                    read -p "内核已是最新 v${CUR_K}，是否仍强制覆盖重装？(y/n) [默认: n]: " ans
                    [[ "${ans:-n}" == "y" || "${ans:-n}" == "Y" ]] && do_kernel="y"
                fi

                if [ "$do_kernel" == "y" ]; then
                    if [ -f "$CONFIG_FILE" ]; then
                        install_kernel "$NEW_K" restart
                    else
                        install_kernel "$NEW_K" norestart
                    fi
                fi

                echo -e "\n${GREEN}处理完毕！请执行 sb 命令进入面板。${PLAIN}"
                exit 0
                ;;
            2) uninstall_all; exit 0 ;;
            3) ;;
            *) exit 0 ;;
        esac
    else
        echo -e "${CYAN}==> 正在将管理脚本写入到全局环境...${PLAIN}"
        if fetch_script; then
            echo -e "\n${GREEN}==> 脚本安装完成！以后可随时输入 ${YELLOW}sb${GREEN} 快捷调用本面板。${PLAIN}"
            sleep 2
        else
            echo -e "${RED}初始化脚本下载失败或内容校验不通过，请检查网络！${PLAIN}"
            exit 1
        fi
    fi
fi

menu
