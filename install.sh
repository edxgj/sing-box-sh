#!/bin/bash

umask 077

SB_LOCK_DIR="/run/lock"
SB_LOCK_FILE="$SB_LOCK_DIR/sing-box-manager.lock"
SB_LOCK_FD=""
acquire_global_lock() {
    mkdir -p "$SB_LOCK_DIR" || return 1
    exec {SB_LOCK_FD}>"$SB_LOCK_FILE" || return 1
    if ! flock -n "$SB_LOCK_FD"; then
        printf '%s\n' '已有另一个管理操作正在执行，请稍后重试。' >&2
        return 1
    fi
}
release_global_lock() {
    if [ -n "${SB_LOCK_FD:-}" ]; then
        flock -u "$SB_LOCK_FD" 2>/dev/null || :
        eval "exec ${SB_LOCK_FD}>&-" 2>/dev/null || :
        SB_LOCK_FD=""
    fi
}

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

KERNEL_TMP_DIR=""
declare -a SB_OWNED_TEMP_FILES=()
cleanup_on_exit() {
    if [ -n "${CONFIG_TX_DIR:-}" ] && [ "${CONFIG_TX_RECOVERING:-0}" != 1 ]; then
        CONFIG_TX_RECOVERING=1
        restore_config_and_service || printf '事务恢复失败，备份保留: %s
' "$CONFIG_TX_DIR" >&2
    fi
    [ -n "$KERNEL_TMP_DIR" ] && rm -rf "$KERNEL_TMP_DIR" 2>/dev/null
    local owned_temp
    for owned_temp in "${SB_OWNED_TEMP_FILES[@]}"; do
        [ -n "$owned_temp" ] && rm -f -- "$owned_temp" 2>/dev/null
    done
    release_global_lock
}
cleanup_on_interrupt() {
    echo -e "\n${RED}[INFO] 接收到中断信号 (Ctrl+C)，正在清理临时文件并彻底退出...${PLAIN}" >&2
    cleanup_on_exit
    exit 130
}
trap cleanup_on_interrupt INT TERM
trap cleanup_on_exit EXIT

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

ask() {
    local __prompt="$1"
    local __var="$2"
    local __val
    if ! IFS= read -r -p "$__prompt" __val; then
        echo -e "\n${RED}输入流已结束(检测到 EOF)，无法继续交互。${PLAIN}" >&2
        echo -e "${YELLOW}如果您是用管道方式运行(例如 curl ... | bash)，请改为:${PLAIN}" >&2
        echo -e "${YELLOW}  先下载再执行，或执行 sb 命令进入面板。${PLAIN}" >&2
        exit 1
    fi
    printf -v "$__var" '%s' "$__val"
}

pause() {
    while read -r -t 0.1; do :; done
    echo ""
    ask "按回车键继续..." _PAUSE_DUMMY
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
            { date +%s; echo "$GLOBAL_IP"; } > "$IP_CACHE" 2>/dev/null
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
    local NOW
    NOW=$(date +%s)

    if [ -z "$GLOBAL_LATEST_VER" ]; then
        if [ -f "$CACHE_FILE" ]; then
            local CACHE_TIME
            CACHE_TIME=$(head -n 1 "$CACHE_FILE" 2>/dev/null)
            local CACHE_VER
            CACHE_VER=$(tail -n 1 "$CACHE_FILE" 2>/dev/null)
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
    local major
    major=$(echo "$ver" | cut -d. -f1)
    local minor
    minor=$(echo "$ver" | cut -d. -f2)
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
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [[ "$val" != *$'\n'* && "$val" != *$'\r'* && "$val" != *"'"* ]] || {
        printf '%s\n' 'secrets 值包含不支持的换行或单引号，未写入。' >&2
        return 1
    }
    touch "$SECRETS_FILE" || return 1
    local tmp
    tmp=$(mktemp "${SECRETS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SECRETS_FILE" > "$tmp" 2>/dev/null
    local rc=$?
    if [ "$rc" -le 1 ] && echo "${key}='${val}'" >> "$tmp"; then
        if chmod 600 "$tmp" && mv -f "$tmp" "$SECRETS_FILE"; then return 0; fi
        rm -f "$tmp"
        printf '%s\n' 'secrets 原子替换失败。' >&2
        return 1
    fi
    rm -f "$tmp"
    echo -e "${RED}写入 secrets 失败，已保留原文件！${PLAIN}" >&2
    return 1
}

remove_secret() {
    local key="$1" tmp rc
    [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || return 1
    [ -f "$SECRETS_FILE" ] || return 0
    tmp=$(mktemp "${SECRETS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    grep -v "^${key}=" "$SECRETS_FILE" > "$tmp"
    rc=$?
    if [ "$rc" -le 1 ] && chmod 600 "$tmp" && mv -f "$tmp" "$SECRETS_FILE"; then return 0; fi
    rm -f "$tmp"
    return 1
}

load_secrets() {
    local line key val
    # Clear all metadata, including keys removed since the previous load.
    for key in $(compgen -A variable); do
        case "$key" in
            REAL_DOMAIN|SELF_DOMAIN|REAL_CERT_OWNED|INSTALLER_SRC|CERT_TYPE|DOMAIN|ARGO_SERVICES) unset "$key" || return 1 ;;
            REALITY_PUB_*|ARGO_IP_*|ARGO_DOMAIN_*)
                [[ "$key" =~ ^(REALITY_PUB|ARGO_IP|ARGO_DOMAIN)_[0-9]+$ ]] && { unset "$key" || return 1; } ;;
        esac
    done
    [ -f "$SECRETS_FILE" ] || return 0
    [ -r "$SECRETS_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=\'(.*)\'$ ]] || continue
        key="${BASH_REMATCH[1]}"
        val="${BASH_REMATCH[2]}"
        case "$key" in
            REAL_DOMAIN|SELF_DOMAIN|REAL_CERT_OWNED|INSTALLER_SRC|CERT_TYPE|DOMAIN|ARGO_SERVICES) ;;
            *) [[ "$key" =~ ^(REALITY_PUB|ARGO_IP|ARGO_DOMAIN)_[0-9]+$ ]] || continue ;;
        esac
        printf -v "$key" '%s' "$val" || return 1
    done < "$SECRETS_FILE"
    return 0
}

apply_jq_config() {
    local filter="$1" tmp
    shift
    tmp=$(mktemp "${CONFIG_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if jq "$@" "$filter" "$CONFIG_FILE" > "$tmp" &&
       jq -e 'type == "object" and (.inbounds | type == "array")' "$tmp" >/dev/null &&
       chmod 600 "$tmp" && mv -f "$tmp" "$CONFIG_FILE"; then
        return 0
    fi
    rm -f "$tmp"
    printf '%s\n' '配置生成或写入失败，原文件未主动删除。' >&2
    return 1
}

http_get() {
    local url="$1"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --connect-timeout 5 --max-time 10 "$url" 2>/dev/null && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -T 10 -qO - "$url" 2>/dev/null && return 0
    fi
    return 1
}

fetch_script() {
    local t
    mkdir -p /usr/local/bin || return 1
    t=$(mktemp /usr/local/bin/.sb.XXXXXX) || return 1
    SB_OWNED_TEMP_FILES+=("$t")
    if fetch_url "https://raw.githubusercontent.com/edxgj/sing-box-sh/main/install.sh" "$t" \
       && [ -s "$t" ] \
       && head -n 1 "$t" | grep -q '^#!/bin/bash' \
       && tail -n 5 "$t" | grep -q '^menu$' \
       && grep -q '^install_kernel() {' "$t" \
       && grep -q '^add_config() {' "$t" \
       && bash -n "$t" 2>/dev/null; then
        if chmod 755 "$t" && mv -f "$t" /usr/local/bin/sb; then
            return 0
        fi
        rm -f "$t"
        printf '%s\n' '脚本写入失败，未完成更新。' >&2
        return 1
    fi
    rm -f "$t"
    return 1
}

register_argo_service() {
    local svc="$1"
    [[ "$svc" =~ ^cloudflared-[a-zA-Z0-9_-]+$ ]] || return 1
    load_secrets || return 1
    case ",${ARGO_SERVICES:-}," in
        *",$svc,"*) return 0 ;;
    esac
    local updated="${ARGO_SERVICES:+${ARGO_SERVICES},}${svc}"
    save_secret ARGO_SERVICES "$updated" || return 1
    ARGO_SERVICES="$updated"
}

cleanup_node_secrets() {
    local port="$1" type="$2" is_argo="${3:-0}"
    if [ "$is_argo" -eq 1 ]; then
        remove_secret "ARGO_IP_${port}" || return 1
        remove_secret "ARGO_DOMAIN_${port}" || return 1
    elif [ "$type" == "vless" ]; then
        remove_secret "REALITY_PUB_${port}" || return 1
    fi
    return 0
}

open_fw_port() {
    local port=$1
    local proto=$2
    if [ "$proto" == "both" ]; then
        open_fw_port "$port" "tcp" || return 1
        open_fw_port "$port" "udp" || return 1
        return 0
    fi
    local success=0
    local fw_found=0

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        fw_found=1
        if ufw allow "${port}"/"${proto}" comment 'sb-sh' >/dev/null 2>&1 || ufw allow "${port}"/"${proto}" >/dev/null 2>&1; then
            success=1
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        fw_found=1
        if firewall-cmd --add-port="${port}"/"${proto}" --permanent >/dev/null 2>&1 &&
           firewall-cmd --reload >/dev/null 2>&1; then success=1; fi
    elif command -v iptables >/dev/null 2>&1; then
        fw_found=1
        success=1
        if ! iptables -C INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; then
            iptables -I INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1 || success=0
        fi
        if command -v ip6tables >/dev/null 2>&1; then
            if ! ip6tables -C INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; then
                ip6tables -I INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1 || success=0
            fi
        fi
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save >/dev/null 2>&1
        elif command -v iptables-save >/dev/null 2>&1; then
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4 2>/dev/null
            command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save > /etc/iptables/rules.v6 2>/dev/null
        fi
    fi

    if [ "$fw_found" -eq 1 ] && [ "$success" -eq 1 ]; then
        local tmp_fw
        tmp_fw=$(mktemp "${FW_PORTS_FILE}.tmp.XXXXXX") || return 1
        SB_OWNED_TEMP_FILES+=("$tmp_fw")
        if ! ( if [ -f "$FW_PORTS_FILE" ]; then cat "$FW_PORTS_FILE" || exit 1; fi; printf '%s/%s\n' "$port" "$proto" ) > "$tmp_fw"; then
            rm -f "$tmp_fw"; return 1
        fi
        if ! sort -u -o "$tmp_fw" "$tmp_fw" || ! chmod 600 "$tmp_fw" || ! mv -f "$tmp_fw" "$FW_PORTS_FILE"; then
            rm -f "$tmp_fw"; return 1
        fi
        echo -e "${GREEN}放行端口 ${port}/${proto} 成功${PLAIN}" >&2
    elif [ "$fw_found" -eq 0 ]; then
        echo -e "${YELLOW}未检测到系统内置防火墙工具，请确保云服务商后台和本机系统放行了 ${port} 端口！${PLAIN}" >&2
    else
        printf '放行端口 %s/%s 失败。\n' "$port" "$proto" >&2
        return 1
    fi
    return 0
}

close_fw_port() {
    local port=$1
    local proto=$2
    if [ "$proto" == "both" ]; then
        local failed=0
        close_fw_port "$port" "tcp" || failed=1
        close_fw_port "$port" "udp" || failed=1
        return "$failed"
    fi

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
        ufw delete allow "${port}"/"${proto}" >/dev/null 2>&1
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --remove-port="${port}"/"${proto}" --permanent >/dev/null 2>&1
        firewall-cmd --reload >/dev/null 2>&1
    elif command -v iptables >/dev/null 2>&1; then
        while iptables -C INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; do
            iptables -D INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1 || break
        done
        if command -v ip6tables >/dev/null 2>&1; then
            while ip6tables -C INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1; do
                ip6tables -D INPUT -p "${proto}" --dport "${port}" -m comment --comment "sb-sh" -j ACCEPT >/dev/null 2>&1 || break
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
    load_secrets || return 1
    [ -f "$CERT_DIR/fullchain.cer" ] || return 0
    (
        umask 077
        local kind=self d changed=0 complete=0 f
        [ "${CERT_TYPE:-}" != real ] || kind=real
        [ -f "$CERT_DIR/private.key" ] || { printf '%s\n' '旧证书私钥缺失，取消迁移。' >&2; exit 1; }
        # Do not overwrite an already existing destination pair.
        for f in "$CERT_DIR/$kind.cer" "$CERT_DIR/$kind.key"; do
            [ ! -e "$f" ] && [ ! -L "$f" ] || { printf '%s\n' '证书迁移目标已存在，保留全部原文件。' >&2; exit 1; }
        done
        d=$(mktemp -d "$CONFIG_DIR/.cert-migrate.XXXXXX") || exit 1
        migration_finish() {
            local rc=$? failed=0 target tmp
            trap - EXIT INT TERM
            if [ "$changed" = 1 ] && [ "$complete" = 0 ]; then
                for target in config secrets; do
                    if [ "$target" = config ]; then f="$CONFIG_FILE"; else f="$SECRETS_FILE"; fi
                    tmp=$(mktemp "${f}.restore.XXXXXX") || { failed=1; continue; }
                    if ! cp -p "$d/$target" "$tmp" || ! mv -f "$tmp" "$f"; then rm -f "$tmp"; failed=1; fi
                done
                cp -p "$d/cert" "$CERT_DIR/fullchain.cer" || failed=1
                cp -p "$d/key" "$CERT_DIR/private.key" || failed=1
                if [ "$failed" = 0 ]; then
                    rm -f "$CERT_DIR/$kind.cer" "$CERT_DIR/$kind.key" || failed=1
                fi
            fi
            if [ "$failed" != 0 ]; then printf '证书迁移恢复失败，备份保留: %s\n' "$d" >&2; exit 1; fi
            rm -rf "$d"
            exit "$rc"
        }
        trap migration_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cp -p "$CONFIG_FILE" "$d/config" &&
        cp -p "$SECRETS_FILE" "$d/secrets" &&
        cp -p "$CERT_DIR/fullchain.cer" "$d/cert" &&
        cp -p "$CERT_DIR/private.key" "$d/key" || exit 1
        changed=1
        cp -p "$d/cert" "$CERT_DIR/$kind.cer" &&
        cp -p "$d/key" "$CERT_DIR/$kind.key" || exit 1
        apply_jq_config '
          (.inbounds[] | select(.tls.certificate_path? == $oldcert) | .tls.certificate_path) = $newcert |
          (.inbounds[] | select(.tls.key_path? == $oldkey) | .tls.key_path) = $newkey' \
          --arg oldcert "$CERT_DIR/fullchain.cer" --arg oldkey "$CERT_DIR/private.key" \
          --arg newcert "$CERT_DIR/$kind.cer" --arg newkey "$CERT_DIR/$kind.key" || exit 1
        /usr/local/bin/sing-box check -c "$CONFIG_FILE" || exit 1
        if [ "$kind" = real ]; then save_secret REAL_DOMAIN "${DOMAIN:-}" || exit 1
        else save_secret SELF_DOMAIN "${DOMAIN:-}" || exit 1; fi
        remove_secret CERT_TYPE && remove_secret DOMAIN || exit 1
        rm -f "$CERT_DIR/fullchain.cer" "$CERT_DIR/private.key" || exit 1
        complete=1
    )
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
    local ver="$1" mode="${2:-restart}"
    [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    (
        umask 077
        local d newbin active=0 touched=0 done_ok=0
        mkdir -p /usr/local/bin || exit 1
        d=$(mktemp -d /usr/local/bin/.kernel-tx.XXXXXX) || exit 1
        kernel_tx_finish() {
            local rc=$? failed=0
            trap - EXIT INT TERM
            if [ "$touched" = 1 ] && [ "$done_ok" = 0 ]; then
                # Stop a partially started candidate before restoring the old binary.
                if [ "$OS_TYPE" = alpine ]; then
                    rc-service sing-box stop >/dev/null 2>&1 || {
                        rc-service sing-box status >/dev/null 2>&1 && failed=1
                    }
                else
                    systemctl stop sing-box >/dev/null 2>&1 || failed=1
                fi
                if [ -f "$d/old" ]; then
                    if ! cp -p "$d/old" "$d/restore" || ! mv -f "$d/restore" /usr/local/bin/sing-box; then failed=1; fi
                else
                    rm -f /usr/local/bin/sing-box || failed=1
                fi
                if [ "$failed" = 0 ] && [ "$active" = 1 ]; then
                    if [ "$OS_TYPE" = alpine ]; then
                        rc-service sing-box start || failed=1
                        rc-service sing-box status >/dev/null 2>&1 || failed=1
                    else
                        systemctl start sing-box || failed=1
                        systemctl is-active --quiet sing-box || failed=1
                    fi
                fi
            fi
            if [ "$failed" = 1 ]; then
                printf '内核或服务恢复失败，完整备份保留: %s\n' "$d" >&2
                exit 1
            fi
            rm -rf "$d"
            exit "$rc"
        }
        trap kernel_tx_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        if [ "$OS_TYPE" = alpine ]; then
            rc-service sing-box status >/dev/null 2>&1 && active=1
        else
            systemctl is-active --quiet sing-box && active=1
        fi
        if [ -e /usr/local/bin/sing-box ]; then cp -p /usr/local/bin/sing-box "$d/old" || exit 1; fi
        printf '==> 正在下载 sing-box v%s (%s)...\n' "$ver" "$SB_ARCH"
        fetch_url "https://github.com/SagerNet/sing-box/releases/download/v${ver}/sing-box-${ver}-linux-${SB_ARCH}.tar.gz" "$d/archive" || exit 1
        mkdir "$d/extract" || exit 1
        # Extract only the expected binary, never arbitrary archive paths.
        tar -xzf "$d/archive" -C "$d/extract" "sing-box-${ver}-linux-${SB_ARCH}/sing-box" || exit 1
        newbin="$d/extract/sing-box-${ver}-linux-${SB_ARCH}/sing-box"
        [ -f "$newbin" ] && [ ! -L "$newbin" ] && chmod 755 "$newbin" || exit 1
        "$newbin" version >/dev/null 2>&1 || exit 1
        if [ "$mode" != norestart ] && [ -f "$CONFIG_FILE" ]; then "$newbin" check -c "$CONFIG_FILE" || exit 1; fi
        touched=1
        if [ "$active" = 1 ]; then
            if [ "$OS_TYPE" = alpine ]; then rc-service sing-box stop || exit 1; else systemctl stop sing-box || exit 1; fi
        fi
        mv -f "$newbin" /usr/local/bin/sing-box || exit 1
        if [ "$mode" != norestart ]; then restart_service || exit 1; fi
        done_ok=1
        printf '==> 内核 v%s 安装完毕！\n' "$ver"
    )
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
            crontab) if [ "$OS_TYPE" == "alpine" ]; then pkgs+=(dcron); elif [ "$OS_TYPE" == "centos" ]; then pkgs+=(cronie); else pkgs+=(cron); fi ;;
            ss) if [ "$OS_TYPE" = "centos" ]; then pkgs+=(iproute); else pkgs+=(iproute2); fi ;;
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
    ensure_deps curl wget jq tar openssl socat ss crontab flock || return 1

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
            ask "请手动输入要安装的 sing-box 版本号 (例如 1.10.1): " VERSION
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
            ask "是否重建为空白配置？原文件会被备份，但现有节点将丢失。(y/n) [默认: n]: " rebuild
            if [[ "${rebuild:-n}" != "y" && "${rebuild:-n}" != "Y" ]]; then
                echo -e "${YELLOW}已取消，未做任何修改。请手动修复该文件后再运行本脚本。${PLAIN}"
                return 1
            fi
            local broken_bak
            broken_bak="${CONFIG_FILE}.broken.$(date +%Y%m%d%H%M%S)"
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
                  (.outbounds[] | select(has(\"domain_resolver\"))) |= (if (.domain_resolver | type) == \"object\" then (if .domain_resolver.server == null or .domain_resolver.server == \"\" then .domain_resolver.server = \"dns-local\" else . end) else . end)
                " >/dev/null 2>&1
            fi
        fi
    fi
    migrate_certs || return 1

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
    local INBOUND_COUNT service_tmp
    if ! INBOUND_COUNT=$(jq -r 'if (.inbounds | type) == "array" then (.inbounds | length) else error("invalid inbounds") end' "$CONFIG_FILE" 2>/dev/null); then
        printf '%s\n' '配置无法读取或已损坏，拒绝操作服务。' >&2
        return 1
    fi
    if [ "$INBOUND_COUNT" -eq 0 ]; then
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service sing-box stop >/dev/null 2>&1 || return 1
        else
            systemctl stop sing-box >/dev/null 2>&1 || return 1
        fi
        return 0
    fi

    if ! /usr/local/bin/sing-box check -c $CONFIG_FILE; then return 1; fi
    
    if [ "$OS_TYPE" == "alpine" ]; then
        if [ ! -e "/etc/init.d/sing-box" ] && [ ! -L "/etc/init.d/sing-box" ]; then
            service_tmp=$(mktemp "/etc/init.d/sing-box.tmp.XXXXXX") || return 1
            SB_OWNED_TEMP_FILES+=("$service_tmp")
            if ! cat > "$service_tmp" << 'EOF'
#!/sbin/openrc-run
name="sing-box"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
command_background=true
pidfile="/var/run/sing-box.pid"
rc_ulimit="-n 65535"
depend() { need net; }
EOF
            then rm -f "$service_tmp"; return 1; fi
            if ! chmod 755 "$service_tmp" || ! mv -f "$service_tmp" "/etc/init.d/sing-box"; then
                rm -f "$service_tmp"
                return 1
            fi
        fi
        rc-update add sing-box default >/dev/null 2>&1 || return 1
        rc-service sing-box restart >/dev/null 2>&1 || return 1
        sleep 2
        if ! rc-service sing-box status 2>/dev/null | grep -q 'started'; then return 1; fi
    else
        if [ ! -e "/etc/systemd/system/sing-box.service" ] && [ ! -L "/etc/systemd/system/sing-box.service" ]; then
            service_tmp=$(mktemp "/etc/systemd/system/sing-box.service.tmp.XXXXXX") || return 1
            SB_OWNED_TEMP_FILES+=("$service_tmp")
            if ! cat > "$service_tmp" << 'EOF'
[Unit]
Description=sing-box service
Wants=network-online.target
After=network.target network-online.target
[Service]
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF
            then rm -f "$service_tmp"; return 1; fi
            if ! chmod 644 "$service_tmp" || ! mv -f "$service_tmp" "/etc/systemd/system/sing-box.service"; then
                rm -f "$service_tmp"
                return 1
            fi
        fi
        systemctl daemon-reload || return 1
        systemctl enable sing-box >/dev/null 2>&1 || return 1
        systemctl restart sing-box >/dev/null 2>&1 || return 1
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
        ask "$prompt [默认: $default]: " val
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
    printf '%s\n' "$val"
}

apply_real_cert() {
    local NEW_DOMAIN
    NEW_DOMAIN=$(get_domain "请输入解析到本机的域名" "") || exit 1

    local reuse=0
    local had_prior=0
    if [ -f ~/.acme.sh/acme.sh ]; then
        local dconf
        dconf=$(~/.acme.sh/acme.sh --info -d "${NEW_DOMAIN}" 2>/dev/null | sed -n 's/^DOMAIN_CONF=//p')
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
                local end_ts
                end_ts=$(date -d "$(openssl x509 -in "$exist_cer" -noout -enddate 2>/dev/null | cut -d= -f2)" +%s 2>/dev/null)
                [ -n "$end_ts" ] && left_days=$(( (end_ts - $(date +%s)) / 86400 ))
            fi
            if [ -n "$left_days" ] && [ "$left_days" -gt 7 ]; then
                echo -e "\n${GREEN}检测到 ${NEW_DOMAIN} 已有有效证书，剩余 ${left_days} 天。${PLAIN}"
                echo -e "${YELLOW}Let's Encrypt 对同一域名限制 168 小时内最多签发 5 次，建议直接复用。${PLAIN}"
                ask "是否复用现有证书？(y/n) [默认: y]: " ru
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
        ask "请选择 [1-2]: " v_mode
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
        if ! ~/.acme.sh/acme.sh --issue -d "${NEW_DOMAIN}" --standalone --force; then
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
            ask "请输入 Cloudflare Global API Key: " NEW_CF_Key
            if [[ "$NEW_CF_Key" =~ ^[A-Za-z0-9]+$ ]]; then break; fi
            echo -e "${RED}错误：API Key 格式不正确！${PLAIN}" >&2
        done
        
        local NEW_CF_Email=""
        while true; do
            ask "请输入 Cloudflare 邮箱: " NEW_CF_Email
            if [[ "$NEW_CF_Email" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then break; fi
            echo -e "${RED}错误：邮箱格式不正确，请重新输入！${PLAIN}" >&2
        done
        
        if ! CF_Key="${NEW_CF_Key}" CF_Email="${NEW_CF_Email}" ~/.acme.sh/acme.sh --issue --dns dns_cf -d "${NEW_DOMAIN}" --force; then
            echo -e "${RED}申请失败！请检查 CF API 是否正确，或该域名已达 Let's Encrypt 签发频率上限。${PLAIN}"
            return 1
        fi
    fi
    fi
    
    deploy_real_cert "$NEW_DOMAIN" "$had_prior" || return 1
    echo -e "${GREEN}域名证书申请并安装完成！${PLAIN}"
    return 0
}


deploy_real_cert() {
    local domain="$1" had_prior="$2"
    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ && "$domain" != .* && "$domain" != *..* ]] || return 1
    (
        umask 077
        local stage changed=0 completed=0 active=0 reload name target i
        local -a targets=()
        stage=$(mktemp -d "$CERT_DIR/.real-deploy.XXXXXX") || exit 1
        targets=("$CERT_DIR/real.cer" "$CERT_DIR/real.key" "$SECRETS_FILE"
                 "$HOME/.acme.sh/$domain/$domain.conf"
                 "$HOME/.acme.sh/${domain}_ecc/$domain.conf")
        if [ "$OS_TYPE" = alpine ]; then
            rc-service sing-box status >/dev/null 2>&1 && active=1
            reload="rc-service sing-box restart >/dev/null 2>&1"
        else
            systemctl is-active --quiet sing-box && active=1
            reload="systemctl restart sing-box >/dev/null 2>&1"
        fi
        real_restore_one() {
            local index="$1" path="$2" tmp
            if [ -f "$stage/$index.absent" ]; then rm -f -- "$path"; return $?; fi
            tmp=$(mktemp "${path}.restore.XXXXXX") || return 1
            if cp -p "$stage/$index" "$tmp" && mv -f "$tmp" "$path"; then return 0; fi
            rm -f "$tmp"; return 1
        }
        real_finish() {
            local rc=$? failed=0 j
            trap - EXIT INT TERM
            if [ "$changed" = 1 ] && [ "$completed" = 0 ]; then
                for j in "${!targets[@]}"; do real_restore_one "$j" "${targets[$j]}" || failed=1; done
                if [ "$failed" = 0 ]; then
                    if [ "$OS_TYPE" = alpine ]; then
                        if [ "$active" = 1 ]; then rc-service sing-box restart || failed=1
                        else rc-service sing-box stop || failed=1; fi
                    else
                        if [ "$active" = 1 ]; then systemctl restart sing-box || failed=1
                        else systemctl stop sing-box || failed=1; fi
                    fi
                fi
            fi
            if [ "$failed" != 0 ]; then
                printf '域名证书恢复失败，备份保留: %s\n' "$stage" >&2
                exit 1
            fi
            rm -rf -- "$stage"
            exit "$rc"
        }
        trap real_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        for i in "${!targets[@]}"; do
            target="${targets[$i]}"
            # Do not replace a symlink with a regular file during rollback.
            [ ! -L "$target" ] || exit 1
            if [ -e "$target" ]; then
                [ -f "$target" ] && cp -p "$target" "$stage/$i" || exit 1
            else touch "$stage/$i.absent" || exit 1; fi
        done
        changed=1
        if ! "$HOME/.acme.sh/acme.sh" --installcert -d "$domain" \
            --fullchainpath "$CERT_DIR/real.cer" --keypath "$CERT_DIR/real.key" \
            --reloadcmd "$reload"; then
            echo -e "${RED}证书部署命令失败，未完成安装。${PLAIN}" >&2
            exit 1
        fi
        openssl x509 -in "$CERT_DIR/real.cer" -noout -checkend 0 >/dev/null &&
        openssl x509 -in "$CERT_DIR/real.cer" -noout -checkhost "$domain" >/dev/null &&
        openssl pkey -in "$CERT_DIR/real.key" -check -noout >/dev/null &&
        openssl x509 -in "$CERT_DIR/real.cer" -pubkey -noout > "$stage/cert.pub" &&
        openssl pkey -in "$CERT_DIR/real.key" -pubout > "$stage/key.pub" &&
        cmp -s "$stage/cert.pub" "$stage/key.pub" || exit 1
        chmod 644 "$CERT_DIR/real.cer" && chmod 600 "$CERT_DIR/real.key" || exit 1
        save_secret REAL_DOMAIN "$domain" || exit 1
        if [ "$had_prior" = 1 ]; then save_secret REAL_CERT_OWNED 0 || exit 1
        else save_secret REAL_CERT_OWNED 1 || exit 1; fi
        completed=1
    )
}

generate_self_cert() {
    ensure_deps openssl || return 1
    local NEW_DOMAIN
    NEW_DOMAIN=$(get_domain "请输入伪装域名" "bing.com") || exit 1
    echo -e "${CYAN}正在生成自签证书...${PLAIN}"
    (
        umask 077
        local stage changed=0 completed=0
        stage=$(mktemp -d "$CERT_DIR/.self-cert.XXXXXX") || exit 1
        cert_restore_one() {
            local name="$1" target="$2" tmp
            if [ -f "$stage/$name.absent" ]; then
                rm -f "$target"
            else
                tmp=$(mktemp "${target}.restore.XXXXXX") || return 1
                if cp -p "$stage/$name" "$tmp" && mv -f "$tmp" "$target"; then return 0; fi
                rm -f "$tmp"; return 1
            fi
        }
        cert_finish() {
            local rc=$? restore_failed=0
            trap - EXIT INT TERM
            if [ "$changed" = 1 ] && [ "$completed" = 0 ]; then
                cert_restore_one old.cer "$CERT_DIR/self.cer" || restore_failed=1
                cert_restore_one old.key "$CERT_DIR/self.key" || restore_failed=1
                cert_restore_one old.secrets "$SECRETS_FILE" || restore_failed=1
            fi
            if [ "$restore_failed" = 1 ]; then
                printf '自签证书恢复失败，备份保留在 %s\n' "$stage" >&2
                exit 1
            fi
            rm -rf "$stage"
            exit "$rc"
        }
        trap cert_finish EXIT
        trap 'exit 130' INT
        trap 'exit 143' TERM
        cert_backup_one() {
            local source="$1" name="$2"
            if [ -e "$source" ]; then cp -p "$source" "$stage/$name"; else touch "$stage/$name.absent"; fi
        }
        cert_backup_one "$CERT_DIR/self.cer" old.cer &&
        cert_backup_one "$CERT_DIR/self.key" old.key &&
        cert_backup_one "$SECRETS_FILE" old.secrets || exit 1
        if ! openssl req -x509 -nodes -days 36500 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
            -keyout "$stage/new.key" -out "$stage/new.cer" -subj "/CN=${NEW_DOMAIN}" \
            -addext "subjectAltName=DNS:${NEW_DOMAIN}"; then
            echo -e "${RED}生成自签证书失败！请查看上方报错信息。${PLAIN}" >&2
            exit 1
        fi
        openssl x509 -in "$stage/new.cer" -noout -checkend 0 >/dev/null &&
        openssl pkey -in "$stage/new.key" -check -noout >/dev/null &&
        openssl x509 -in "$stage/new.cer" -pubkey -noout > "$stage/cert.pub" &&
        openssl pkey -in "$stage/new.key" -pubout > "$stage/key.pub" &&
        cmp -s "$stage/cert.pub" "$stage/key.pub" || exit 1
        chmod 644 "$stage/new.cer" && chmod 600 "$stage/new.key" || exit 1
        changed=1
        mv -f "$stage/new.key" "$CERT_DIR/self.key" &&
        mv -f "$stage/new.cer" "$CERT_DIR/self.cer" &&
        save_secret SELF_DOMAIN "$NEW_DOMAIN" || exit 1
        completed=1
        echo -e "${GREEN}自签证书生成完毕！${PLAIN}"
    )
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
        local cert_idx
        ask "请选择 [0-3]: " cert_idx
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
        ask "请选择 [1-2]: " c_idx
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
        ask "请输入UUID [默认随机]: " val
        val=${val:-$(/usr/local/bin/sing-box generate uuid)}
        if [[ "$val" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
            break
        else
            echo -e "${RED}错误：输入的格式不规范！必须是标准 UUIDv4 格式。${PLAIN}" >&2
        fi
    done
    echo -e "UUID: ${GREEN}${val}${PLAIN}" >&2
    printf '%s\n' "$val"
}

get_pass() {
    local val
    while true; do
        ask "请输入密码(支持特殊符号,会自动安全编码) [默认随机]: " val
        val=${val:-$(/usr/local/bin/sing-box generate rand --hex 16)}
        if [[ "$val" =~ [^[:space:]] ]]; then
            break
        else
            echo -e "${RED}错误：密码不能全为空白字符！${PLAIN}" >&2
        fi
    done
    printf '密码: %b%s%b\n' "$GREEN" "$val" "$PLAIN" >&2
    printf '%s\n' "$val"
}
get_ss_method() {
    local METHODS=("aes-128-gcm" "aes-256-gcm" "chacha20-ietf-poly1305" "2022-blake3-aes-128-gcm" "2022-blake3-aes-256-gcm" "2022-blake3-chacha20-poly1305")
    echo -e "选择加密方式:" >&2
    local i
    for i in "${!METHODS[@]}"; do
        echo -e " $((i + 1))) ${METHODS[$i]}" >&2
    done
    echo -e "${YELLOW}提示: 4/5/6 为 SIP022 (2022) 方法，密码将自动生成 base64 密钥${PLAIN}" >&2
    local idx
    while true; do
        ask "请选择 [1-${#METHODS[@]}] [默认: 1]: " idx
        idx=${idx:-1}
        if [[ "$idx" =~ ^[1-9][0-9]*$ ]] && [ "$idx" -ge 1 ] && [ "$idx" -le "${#METHODS[@]}" ]; then
            echo "${METHODS[$((idx - 1))]}"
            return
        fi
        echo -e "${RED}输入错误，请重新选择！${PLAIN}" >&2
    done
}

get_ss_password() {
    local method=$1
    case "$method" in
        2022-blake3-aes-128-gcm)  /usr/local/bin/sing-box generate rand --base64 16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) /usr/local/bin/sing-box generate rand --base64 32 ;;
        *)  /usr/local/bin/sing-box generate rand --hex 16 ;;
    esac
}

get_ss_pass_valid() {
    local method="$1" pass="$2" size
    case "$method" in
        2022-blake3-aes-128-gcm) size=16 ;;
        2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305) size=32 ;;
        *) [[ "$pass" =~ [^[:space:]] ]]; return ;;
    esac
    [[ "$pass" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || return 1
    (set -o pipefail; printf '%s' "$pass" | base64 -d >/dev/null 2>&1) || return 1
    [ "$(printf '%s' "$pass" | base64 -d 2>/dev/null | wc -c)" -eq "$size" ]
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
      (if .type == "shadowsocks" then .password else .users[0].password end // ""),
      (.tls.server_name // ""),
      (.tls.reality.short_id[0] // ""),
      (if .tls.reality.enabled == true then "1" else "0" end),
      (if .transport.type == "ws" then "1" else "0" end),
      (.method // "")
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
    local IS_REALITY=${M[7]} IS_WS=${M[8]} SS_METHOD=${M[9]}

    resolve_conn "$CERT_PATH" "$IP"
    local SNI_URL="${CONN_SNI:+&sni=${CONN_SNI}}"

    local IP_URI
    IP_URI=$(wrap_ipv6 "$IP")
    local CONN_ADDR_URI
    CONN_ADDR_URI=$(wrap_ipv6 "$CONN_ADDR")

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
                local A_IP_URI
                A_IP_URI=$(wrap_ipv6 "$A_IP")
                echo "vless://${N_UUID}@${A_IP_URI}:443?encryption=none&security=tls&type=ws&host=${A_DOM}&path=%2Fargo&sni=${A_DOM}#${TAG}"
            fi
            ;;
        hysteria2)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 Hysteria2 链接]${PLAIN}"; return; fi
            local AUTH_ENC
            AUTH_ENC=$(url_encode "$N_PASS")
            echo "hysteria2://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?security=tls&alpn=h3&insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        tuic)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 TUIC 链接]${PLAIN}"; return; fi
            local T_UUID_ENC
            T_UUID_ENC=$(url_encode "$N_UUID")
            local T_PASS_ENC
            T_PASS_ENC=$(url_encode "$N_PASS")
            echo "tuic://${T_UUID_ENC}:${T_PASS_ENC}@${CONN_ADDR_URI}:${PORT}?congestion_control=bbr&udp_relay_mode=native&alpn=h3&insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        anytls)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 AnyTLS 链接]${PLAIN}"; return; fi
            local AUTH_ENC
            AUTH_ENC=$(url_encode "$N_PASS")
            echo "anytls://${AUTH_ENC}@${CONN_ADDR_URI}:${PORT}?insecure=${CONN_INSECURE}&allowInsecure=${CONN_INSECURE}${SNI_URL}#${TAG}"
            ;;
        shadowsocks)
            if [ -z "$CONN_ADDR" ]; then echo -e "${RED}[获取连接地址失败，无法生成 Shadowsocks 链接]${PLAIN}"; return; fi
            local SS_CRED
            if [[ "$SS_METHOD" == 2022-* ]]; then
                SS_CRED="$(url_encode "$SS_METHOD"):$(url_encode "$N_PASS")"
            else
                SS_CRED=$(printf '%s' "${SS_METHOD}:${N_PASS}" | base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')
            fi
            echo "ss://${SS_CRED}@${CONN_ADDR_URI}:${PORT}#${TAG}"
            ;;
    esac
}

print_config_detail() {
    local TAG=$1
    local IP
    IP=$(get_ip)
    load_secrets

    local -a M
    mapfile -t M < <(node_read "$TAG")
    [ "${#M[@]}" -lt 9 ] && { echo -e "${RED}[读取节点 $TAG 失败]${PLAIN}"; return; }
    local TYPE=${M[0]} PORT=${M[1]} CERT_PATH=${M[2]}
    local N_UUID=${M[3]} N_PASS=${M[4]} SNI=${M[5]} SID=${M[6]}
    local IS_REALITY=${M[7]} IS_WS=${M[8]} SS_METHOD=${M[9]}

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
                local IP_DISP
                IP_DISP=$(wrap_ipv6 "$IP")
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
                local A_IP_DISP
                A_IP_DISP=$(wrap_ipv6 "$A_IP")
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
            local CONN_ADDR_DISP
            CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        tuic)
            local CONN_ADDR_DISP
            CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            echo -e "用户ID (id)\t\t\t= $N_UUID"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "应用层协议协商 (Alpn)\t\t= h3"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            echo -e "拥塞控制算法 (congestion_control)= bbr"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        anytls)
            local CONN_ADDR_DISP
            CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "传输层安全 (TLS)\t\t= tls"
            echo -e "跳过证书验证 (allowInsecure)\t= $INSECURE_TEXT"
            [ -n "$SNI_VAL" ] && echo -e "伪装域名 (sni)\t\t\t= $SNI_VAL"
            ;;
        shadowsocks)
            local CONN_ADDR_DISP
            CONN_ADDR_DISP=$(wrap_ipv6 "$CONN_ADDR")
            echo -e "地址 (address)\t\t\t= ${CONN_ADDR_DISP:-[获取目标地址失败]}"
            echo -e "端口 (port)\t\t\t= $PORT"
            printf '密码 (password)\t\t\t= %s\n' "$N_PASS"
            echo -e "加密方式 (method)\t\t= ${SS_METHOD:-未知}"
            echo -e "传输模式 (mode)\t\t= tcp+udp"
            ;;
    esac

    echo -e "------------- 链接 (URL) -------------"
    build_share_url "$TAG" "$IP"

    if [ "$INSECURE_TEXT" == "true" ] && [ "$IS_REALITY" != "1" ] && [ "$IS_WS" != "1" ] && [ "$TYPE" != "shadowsocks" ]; then
        echo -e "\n${YELLOW}警告! 此节点使用自签名证书，请确保客户端已开启「跳过证书验证」！${PLAIN}\n"
    fi
}

select_inbound() {
    local old_IFS=$IFS
    IFS=$'\n'
    mapfile -t TAGS < <(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' "$CONFIG_FILE")
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
        ask "请选择 [0-${#TAGS[@]}]: " idx
        if [[ -z "$idx" ]] || [[ "$idx" == "0" ]]; then return 1; fi
        if ! [[ "$idx" =~ ^[1-9][0-9]*$ ]] || [ "$idx" -gt "${#TAGS[@]}" ]; then 
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
            shadowsocks)    o_proto="both" ;;
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
        echo -e " 6) Shadowsocks"
        echo -e " 0) 返回\n"
        
        local proto_idx
        while true; do
            ask "请选择 [0-6]: " proto_idx
            if [[ "$proto_idx" =~ ^[0-6]$ ]]; then break; fi
            echo -e "${RED}输入错误，请重新选择！${PLAIN}"
        done
        [ "$proto_idx" == "0" ] && return

        load_secrets
        local DEF_PORT
        DEF_PORT=$(rand_port)
        local PORT
        
        local f_proto=""
        if [[ "$proto_idx" == "1" || "$proto_idx" == "4" ]]; then f_proto="tcp"
        elif [[ "$proto_idx" == "2" || "$proto_idx" == "3" ]]; then f_proto="udp"
        elif [ "$proto_idx" == "6" ]; then f_proto="both"
        fi

        while true; do
            ask "请输入监听端口 [默认: $DEF_PORT]: " PORT
            PORT=${PORT:-$DEF_PORT}
            if ! [[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
                echo -e "${RED}端口必须为 1-65535 之间的数字${PLAIN}"; continue
            fi
            if check_port "$PORT" "$f_proto"; then
                echo -e "${RED}错误! 端口 ${PORT} 已被占用！${PLAIN}"; continue
            fi
            break
        done
        echo -e "使用: ${GREEN}${PORT}${PLAIN}"
        warn_port_shared "$PORT" "$f_proto"
        
        local raw_hostname
        raw_hostname=$(hostname 2>/dev/null || echo "vps")
        local HOST_NAME
        HOST_NAME=$(echo "$raw_hostname" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')
        [ -z "$HOST_NAME" ] && HOST_NAME="vps"
        
        local DEF_TAG=""
        case "$proto_idx" in
            1) DEF_TAG="vless-reality" ;;
            2) DEF_TAG="hysteria2" ;;
            3) DEF_TAG="tuic" ;;
            4) DEF_TAG="anytls" ;;
            5) DEF_TAG="vless-argo" ;;
            6) DEF_TAG="shadowsocks" ;;
        esac
        DEF_TAG="${DEF_TAG}-${HOST_NAME}"
        
        local input_tag
        while true; do
            ask "请输入节点名称 [默认: $DEF_TAG]: " input_tag
            input_tag=${input_tag:-$DEF_TAG}
            input_tag=${input_tag// /-}
            if [[ "$input_tag" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                break
            else
                echo -e "${RED}错误：节点名称仅限字母、数字、短横线和下划线！${PLAIN}" >&2
            fi
        done
        local TAG
        TAG=$(get_unique_tag "$input_tag")
        
        backup_config || return 1
        local IS_ARGO=0
        local jq_ok=1

        case "$proto_idx" in
            1)
                local UUID
                UUID=$(get_uuid) || exit 1
                local SNI
                SNI=$(get_domain "请输入伪装域名" "apple.com") || exit 1
                local KEYS
                KEYS=$(/usr/local/bin/sing-box generate reality-keypair)
                local PK
                PK=$(echo "$KEYS" | grep PrivateKey | awk '{print $2}')
                local PUB
                PUB=$(echo "$KEYS" | grep PublicKey | awk '{print $2}')
                local SID
                SID=$(/usr/local/bin/sing-box generate rand --hex 4)
                save_secret "REALITY_PUB_${PORT}" "$PUB" || { restore_config_and_service || return 1; return 1; }
                
                apply_jq_config '.inbounds += [{"type":"vless","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"flow":"xtls-rprx-vision"}],"tls":{"enabled":true,"server_name":$sni,"reality":{"enabled":true,"handshake":{"server":$sni,"server_port":443},"private_key":$pk,"short_id":[$sid]}}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg sni "$SNI" --arg pk "$PK" --arg sid "$SID" --arg tag "$TAG" || jq_ok=0
                ;;
            2)
                local PASS
                PASS=$(get_pass) || exit 1
                if ! prompt_cert_type; then commit_config || return 1; continue; fi
                
                apply_jq_config '.inbounds += [{"type":"hysteria2","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            3)
                local UUID
                UUID=$(get_uuid) || exit 1
                local PASS
                PASS=$(get_pass) || exit 1
                if ! prompt_cert_type; then commit_config || return 1; continue; fi
                
                apply_jq_config '.inbounds += [{"type":"tuic","tag":$tag,"listen":"::","listen_port":$p,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"alpn":["h3"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            4)
                local PASS
                PASS=$(get_pass) || exit 1
                if ! prompt_cert_type; then commit_config || return 1; continue; fi
                
                apply_jq_config '.inbounds += [{"type":"anytls","tag":$tag,"listen":"::","listen_port":$p,"users":[{"password":$pass}],"tls":{"enabled":true,"alpn":["h2","http/1.1"],"certificate_path":$cert,"key_path":$key}}]' \
                --argjson p "$PORT" --arg pass "$PASS" --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY" || jq_ok=0
                ;;
            5)
                IS_ARGO=1
                local UUID
                UUID=$(get_uuid) || exit 1
                local ARGO_IP
                ARGO_IP=$(get_domain "请输入 Argo 优选域名/IP" "saas.sin.fan" "true") || exit 1
                local ARGO_DOMAIN
                ARGO_DOMAIN=$(get_domain "请输入 Argo 隧道域名" "example.com") || exit 1
                
                local ARGO_TOKEN=""
                while true; do
                    ask "请输入 Cloudflare Tunnel Token: " ARGO_TOKEN
                    if [[ "$ARGO_TOKEN" =~ ^[A-Za-z0-9+/=._-]+$ ]]; then break; fi
                    echo -e "${RED}错误：Token 格式不正确或为空！${PLAIN}" >&2
                done
                
                save_secret "ARGO_IP_${PORT}" "$ARGO_IP" || { restore_config_and_service || return 1; return 1; }
                save_secret "ARGO_DOMAIN_${PORT}" "$ARGO_DOMAIN" || { restore_config_and_service || return 1; return 1; }
                
                if ! apply_jq_config '.inbounds += [{"type":"vless","tag":$tag,"listen":"127.0.0.1","listen_port":$p,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/argo"}}]' \
                --argjson p "$PORT" --arg uuid "$UUID" --arg tag "$TAG"; then
                    jq_ok=0
                else
                    local CF_FAILED=0
                    if ! command -v cloudflared &> /dev/null; then
                        echo -e "${CYAN}正在下载 cloudflared 组件...${PLAIN}"
                        local TMP_CF
                        TMP_CF=$(mktemp)
                        local cf_arch="amd64"
                        [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]] && cf_arch="arm64"
                        if fetch_url "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${cf_arch}" "$TMP_CF"; then
                            mv "$TMP_CF" /usr/local/bin/cloudflared
                            chmod +x /usr/local/bin/cloudflared
                        else
                            echo -e "${RED}下载 cloudflared 失败！${PLAIN}"
                            rm -f "$TMP_CF"
                            CF_FAILED=1
                        fi
                    fi
                    
                    if [ "${CF_FAILED:-0}" -eq 0 ] && [ "$OS_TYPE" == "alpine" ]; then
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
                        rc-service "cloudflared-${TAG}" restart >/dev/null 2>&1 &&
                        register_argo_service "cloudflared-${TAG}" || CF_FAILED=1
                    elif [ "${CF_FAILED:-0}" -eq 0 ]; then
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
                        systemctl enable "cloudflared-${TAG}" --now >/dev/null 2>&1 &&
                        register_argo_service "cloudflared-${TAG}" || CF_FAILED=1
                    else
                        echo -e "${RED}cloudflared 组件缺失且下载失败，节点已添加但隧道未运行！${PLAIN}"
                        echo -e "${YELLOW}请稍后重新添加该节点，或手动安装 cloudflared 后自行启动隧道服务。${PLAIN}"
                    fi
                fi
                ;;
            6)
                local SS_METHOD
                SS_METHOD=$(get_ss_method) || exit 1
                local SS_DEFAULT_PASS
                SS_DEFAULT_PASS=$(get_ss_password "$SS_METHOD")
                local PASS
                while true; do
                    ask "请输入SS密码 [默认按方法自动生成]: " PASS
                    PASS=${PASS:-$SS_DEFAULT_PASS}
                    if get_ss_pass_valid "$SS_METHOD" "$PASS"; then break; fi
                    echo -e "${RED}错误：$SS_METHOD 要求 base64 密钥且长度精确(16/32字节)，请重新输入！${PLAIN}" >&2
                done
                apply_jq_config '.inbounds += [{"type":"shadowsocks","tag":$tag,"listen":"::","listen_port":$p,"method":$m,"password":$pass}]' \
                --argjson p "$PORT" --arg m "$SS_METHOD" --arg pass "$PASS" --arg tag "$TAG" || jq_ok=0
                ;;
        esac
        
        local NODE_SEC_TYPE=""
        [ "$proto_idx" == "1" ] && NODE_SEC_TYPE="vless"

        if [ "$jq_ok" -eq 0 ]; then
            restore_config_and_service || return 1
            pause
            continue
        fi

        if ! restart_service; then
            echo -e "${RED}节点添加失败(校验报错)，已为您还原配置！${PLAIN}"
            restore_config_and_service || return 1
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
        
        commit_config || return 1
        
        if [ -n "$f_proto" ]; then
            echo ""
            ask "是否自动放行端口？(y/n) [默认: y]: " auto_fw
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
            local TYPE
            TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' "$CONFIG_FILE")
            local OLD_PORT
            OLD_PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' "$CONFIG_FILE")
            
            if [ -z "$TYPE" ] || [ "$TYPE" == "null" ]; then
                break
            fi
            
            echo -e "\n当前选中: ${YELLOW}$TAG${PLAIN}"
            
            local action=""
            if [ "$TYPE" == "vless" ]; then
                local IS_REALITY
                IS_REALITY=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .tls.reality.enabled] | .[0] // false' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_REALITY" == "true" ] && IS_REALITY=1 || IS_REALITY=0
                local IS_ARGO
                IS_ARGO=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_ARGO" == "ws" ] && IS_ARGO=1 || IS_ARGO=0

                echo -e " 1) 更改 UUID"
                echo -e " 2) 更改端口"
                echo -e " 3) 更改节点名称"
                [ "$IS_REALITY" -eq 1 ] && echo -e " 4) 更改伪装域名"
                [ "$IS_ARGO" -eq 1 ] && echo -e " 4) 更改优选域名/IP"
                echo -e " 0) 返回\n"
                
                while true; do
                    local mod_idx
                    if [ "$IS_REALITY" -eq 1 ] || [ "$IS_ARGO" -eq 1 ]; then
                        ask "请选择 [0-4]: " mod_idx
                        case "$mod_idx" in 
                            1) action="uuid"; break ;; 
                            2) action="port"; break ;; 
                            3) action="tag"; break ;; 
                            4) [ "$IS_REALITY" -eq 1 ] && action="sni" || action="argo_ip"; break ;; 
                            0) break ;; 
                            *) echo -e "${RED}错误!${PLAIN}" ;; 
                        esac
                    else
                    local mod_idx
                    ask "请选择 [0-3]: " mod_idx
                        case "$mod_idx" in 
                            1) action="uuid"; break ;; 
                            2) action="port"; break ;; 
                            3) action="tag"; break ;; 
                            0) break ;; 
                            *) echo -e "${RED}错误!${PLAIN}" ;; 
                        esac
                    fi
                done
            elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "anytls" || "$TYPE" == "tuic" || "$TYPE" == "shadowsocks" ]]; then
                echo -e " 1) 更改主密钥/密码"
                echo -e " 2) 更改端口"
                echo -e " 3) 更改节点名称"
                if [ "$TYPE" != "shadowsocks" ]; then echo -e " 4) 更改证书类型 (域名/自签)"; fi
                echo -e " 0) 返回\n"
                while true; do
                    if [ "$TYPE" == "shadowsocks" ]; then ask "请选择 [0-3]: " mod_idx; else ask "请选择 [0-4]: " mod_idx; fi
                    case "$mod_idx" in 
                        1) action="pass"; break ;; 
                        2) action="port"; break ;; 
                        3) action="tag"; break ;; 
                        4) if [ "$TYPE" != "shadowsocks" ]; then action="cert"; break; else echo -e "${RED}错误!${PLAIN}"; fi ;; 
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
                local NEW_ARGO_IP
                NEW_ARGO_IP=$(get_domain "请输入新的 Argo 优选域名/IP" "saas.sin.fan" "true") || exit 1
                save_secret "ARGO_IP_${OLD_PORT}" "$NEW_ARGO_IP" || return 1
                echo -e "${GREEN}优选域名/IP 已成功更改为: $NEW_ARGO_IP${PLAIN}"
                pause
                continue
            fi

            backup_config || return 1

            if [ "$action" == "uuid" ] || [ "$action" == "pass" ]; then
                local NEW_AUTH
                if [ "$action" == "uuid" ]; then NEW_AUTH=$(get_uuid) || exit 1
                elif [ "$TYPE" == "shadowsocks" ]; then
                    local SS_METHOD_CUR
                    SS_METHOD_CUR=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .method // ""' $CONFIG_FILE)
                    local SS_DEFAULT_PASS
                    SS_DEFAULT_PASS=$(get_ss_password "$SS_METHOD_CUR")
                    while true; do
                        ask "请输入新SS密码 [默认按方法自动生成]: " NEW_AUTH
                        NEW_AUTH=${NEW_AUTH:-$SS_DEFAULT_PASS}
                        if get_ss_pass_valid "$SS_METHOD_CUR" "$NEW_AUTH"; then break; fi
                        echo -e "${RED}错误：$SS_METHOD_CUR 要求 base64 密钥且长度精确(16/32字节)，请重新输入！${PLAIN}" >&2
                    done
                else
                    NEW_AUTH=$(get_pass) || exit 1
                fi
                
                if [ "$action" == "uuid" ]; then
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .users[0].uuid) = $auth' --arg tag "$TAG" --arg auth "$NEW_AUTH"; then
                        commit_config || return 1
                        pause
                        continue
                    fi
                else
                    local PASS_FILTER='(.inbounds[] | select(.tag==$tag) | .users[0].password) = $auth'
                    if [ "$TYPE" == "shadowsocks" ]; then PASS_FILTER='(.inbounds[] | select(.tag==$tag) | .password) = $auth'; fi
                    if ! apply_jq_config "$PASS_FILTER" --arg tag "$TAG" --arg auth "$NEW_AUTH"; then
                        commit_config || return 1
                        pause
                        continue
                    fi
                fi
                
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"; restore_config_and_service || return 1
                else
                    echo -e "${GREEN}节点秘钥已更新！${PLAIN}"; commit_config || return 1
                fi
                pause
                
            elif [ "$action" == "cert" ]; then
                if prompt_cert_type; then
                    if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tls.certificate_path) = $cert | (.inbounds[] | select(.tag==$tag) | .tls.key_path) = $key' \
                    --arg tag "$TAG" --arg cert "$SEL_CERT" --arg key "$SEL_KEY"; then
                        commit_config || return 1
                        pause
                        continue
                    fi
                    
                    if ! restart_service; then 
                        echo -e "${RED}操作失败，已还原配置！${PLAIN}"; restore_config_and_service || return 1
                    else
                        echo -e "${GREEN}节点 $TAG 的证书已更新！${PLAIN}"; commit_config || return 1
                    fi
                else
                    commit_config || return 1
                fi
                pause
                
            elif [ "$action" == "port" ]; then
                local f_proto=""
                local IS_ARGO=0
                if [[ "$TYPE" == "vless" && "$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type // empty' $CONFIG_FILE)" != "ws" ]]; then f_proto="tcp"
                elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"
                elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"
                elif [ "$TYPE" == "shadowsocks" ]; then f_proto="both"
                fi

                if jq -e --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .transport.type=="ws"' $CONFIG_FILE >/dev/null 2>&1; then
                    echo -e "\n${YELLOW}注意: 这是 Argo 节点，入口由 Cloudflare Tunnel 提供。${PLAIN}"
                    echo -e "${YELLOW}改完本地端口后，必须去 Cloudflare Zero Trust 后台把该 Tunnel 的${PLAIN}"
                    echo -e "${YELLOW}Public Hostname (Ingress) 目标同步改成 localhost:<新端口>，${PLAIN}"
                    echo -e "${YELLOW}否则节点会立即失效(隧道返回 502)。${PLAIN}"
                    ask "确认继续修改端口？(y/n) [默认: n]: " argo_go
                    if [[ "${argo_go:-n}" != "y" && "${argo_go:-n}" != "Y" ]]; then
                        commit_config || return 1
                        echo -e "${CYAN}已取消。${PLAIN}"
                        pause
                        continue
                    fi
                fi

                local NEW_PORT
                while true; do
                    ask "请输入新端口 [默认随机]: " NEW_PORT
                    NEW_PORT=${NEW_PORT:-$(rand_port)}
                    if ! [[ "$NEW_PORT" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then echo -e "${RED}错误输入!${PLAIN}"; continue; fi
                    if [ "$NEW_PORT" != "$OLD_PORT" ] && check_port "$NEW_PORT" "$f_proto"; then echo -e "${RED}端口占用!${PLAIN}"; continue; fi
                    break
                done
                warn_port_shared "$NEW_PORT" "$f_proto" "$TAG"
                
                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .listen_port) = $p' --arg tag "$TAG" --argjson p "$NEW_PORT"; then
                    commit_config || return 1
                    pause
                    continue
                fi
                
                load_secrets
                local IS_REALITY_NODE
                IS_REALITY_NODE=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .tls.reality.enabled] | .[0] // false' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_REALITY_NODE" == "true" ] && IS_REALITY_NODE=1 || IS_REALITY_NODE=0
                if [ "$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)" == "ws" ]; then
                    IS_ARGO=1
                fi
                if [ "$IS_REALITY_NODE" -eq 1 ]; then
                    local var_pub="REALITY_PUB_${OLD_PORT}"
                    local PUB="${!var_pub}"
                    if [ -n "$PUB" ]; then
                        save_secret "REALITY_PUB_${NEW_PORT}" "$PUB" || { restore_config_and_service || return 1; return 1; }
                    fi
                fi
                if [ "$IS_ARGO" -eq 1 ]; then
                    local var_ip="ARGO_IP_${OLD_PORT}"
                    local var_dom="ARGO_DOMAIN_${OLD_PORT}"
                    local A_IP="${!var_ip}"
                    local A_DOM="${!var_dom}"
                    if [ -n "$A_IP" ]; then
                        save_secret "ARGO_IP_${NEW_PORT}" "$A_IP" || { restore_config_and_service || return 1; return 1; }
                    fi
                    if [ -n "$A_DOM" ]; then
                        save_secret "ARGO_DOMAIN_${NEW_PORT}" "$A_DOM" || { restore_config_and_service || return 1; return 1; }
                    fi
                fi

                local SEC_TYPE=""
                [ "$IS_REALITY_NODE" -eq 1 ] && SEC_TYPE="vless"
                if [ "$OLD_PORT" != "$NEW_PORT" ]; then
                    cleanup_node_secrets "$OLD_PORT" "$SEC_TYPE" "$IS_ARGO" || { restore_config_and_service || return 1; return 1; }
                fi
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                    restore_config_and_service || return 1
                else
                    commit_config || return 1
                    
                    echo -e "${GREEN}端口已更改为: $NEW_PORT${PLAIN}"
                    
                    if [ -n "$f_proto" ] && [ "$OLD_PORT" != "$NEW_PORT" ]; then
                        close_fw_port "$OLD_PORT" "$f_proto"
                        remove_fw_record "${OLD_PORT}" "$f_proto"
                        ask "是否自动放行新端口？(y/n) [默认: y]: " auto_fw
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
                    ask "请输入新的节点名称: " NEW_TAG
                    NEW_TAG=${NEW_TAG// /-}
                    if [ -z "$NEW_TAG" ]; then echo -e "${RED}不能为空!${PLAIN}"; continue; fi
                    if ! [[ "$NEW_TAG" =~ ^[a-zA-Z0-9_-]+$ ]]; then echo -e "${RED}错误：节点名称仅限字母、数字、短横线和下划线！${PLAIN}"; continue; fi
                    if jq -e --arg tag "$NEW_TAG" '.inbounds[] | select(.tag == $tag)' "$CONFIG_FILE" >/dev/null 2>&1; then echo -e "${RED}名称已存在！${PLAIN}"; continue; fi
                    break
                done
                
                local IS_ARGO
                IS_ARGO=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)
                [ "$IS_ARGO" == "ws" ] && IS_ARGO=1 || IS_ARGO=0
                
                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tag) = $newtag' --arg tag "$TAG" --arg newtag "$NEW_TAG"; then
                    commit_config || return 1
                    pause
                    continue
                fi
                
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                    restore_config_and_service || return 1
                else
                    if [ "$IS_ARGO" -eq 1 ]; then
                        if ! rename_argo_service "$TAG" "$NEW_TAG"; then
                            restore_config_and_service || return 1
                            printf '%s\n' 'Argo 服务重命名失败，节点名称已恢复。' >&2
                            return 1
                        fi
                    fi
                    echo -e "${GREEN}节点名称已成功更改为: $NEW_TAG${PLAIN}"
                    commit_config || return 1
                    TAG="$NEW_TAG"
                fi
                pause
                
            elif [ "$action" == "sni" ]; then
                local NEW_SNI
                NEW_SNI=$(get_domain "请输入新的伪装域名" "apple.com") || exit 1
                
                if ! apply_jq_config '(.inbounds[] | select(.tag==$tag) | .tls.server_name) = $sni | (.inbounds[] | select(.tag==$tag) | .tls.reality.handshake.server) = $sni' \
                --arg tag "$TAG" --arg sni "$NEW_SNI"; then
                    commit_config || return 1
                    pause
                    continue
                fi
                
                if ! restart_service; then 
                    echo -e "${RED}操作失败，已还原配置！${PLAIN}"
                    restore_config_and_service || return 1
                else
                    echo -e "${GREEN}伪装域名已成功更改为: $NEW_SNI${PLAIN}"
                    commit_config || return 1
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
        
        local TYPE
        TYPE=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .type' $CONFIG_FILE)
        local PORT
        PORT=$(jq -r --arg tag "$TAG" '.inbounds[] | select(.tag==$tag) | .listen_port' $CONFIG_FILE)
        local IS_ARGO
        IS_ARGO=$(jq -r --arg tag "$TAG" '[.inbounds[] | select(.tag==$tag) | .transport.type] | .[0] // ""' "$CONFIG_FILE" 2>/dev/null)
        [ "$IS_ARGO" == "ws" ] && IS_ARGO=1 || IS_ARGO=0
        
        backup_config || return 1
        
        if ! apply_jq_config 'del(.inbounds[] | select(.tag == $tag))' --arg tag "$TAG"; then
            commit_config || return 1
            pause
            continue
        fi
        
        if ! cleanup_node_secrets "$PORT" "$TYPE" "$IS_ARGO"; then
            restore_config_and_service || return 1
            return 1
        fi
        if ! restart_service; then
            echo -e "${RED}删除失败：配置还原，内核未能正常重启！${PLAIN}"
            restore_config_and_service || return 1
            pause
            continue
        fi
        
        commit_config || return 1
        
        local f_proto=""
        if [[ "$TYPE" == "vless" && "$IS_ARGO" -eq 0 ]]; then f_proto="tcp"
        elif [[ "$TYPE" == "hysteria2" || "$TYPE" == "tuic" ]]; then f_proto="udp"
        elif [ "$TYPE" == "anytls" ]; then f_proto="tcp"
        elif [ "$TYPE" == "shadowsocks" ]; then f_proto="both"
        fi

        if [ -n "$f_proto" ]; then
            close_fw_port "$PORT" "$f_proto"
                        remove_fw_record "${PORT}" "$f_proto"
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
        
        
        local INBOUND_COUNT
        INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE)
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
    mapfile -t TAGS < <(jq -r '.inbounds[] | select(.tag != null and .tag != "dns-in") | .tag' "$CONFIG_FILE")
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
            local v_idx
            ask "请选择 [0-2]: " v_idx
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
            ask "请选择 [0-3]: " run_idx
            case "$run_idx" in
                1|3) 
                   local INBOUND_COUNT
                   INBOUND_COUNT=$(jq '.inbounds | length' $CONFIG_FILE 2>/dev/null)
                   if [ -z "$INBOUND_COUNT" ] || [ "$INBOUND_COUNT" -eq 0 ]; then echo -e "${RED}未添加节点配置！${PLAIN}"; pause; break; fi
                   if ! restart_service; then
                       echo -e "${RED}操作失败！内核启动失败，请检查配置。${PLAIN}"
                   else
                       echo -e "${GREEN}已启动${PLAIN}"
                   fi
                   pause; break ;;
                2) 
                   local stop_rc=0
                   if [ "$OS_TYPE" == "alpine" ]; then rc-service sing-box stop || stop_rc=$?; else systemctl stop sing-box || stop_rc=$?; fi
                   if [ "$stop_rc" = 0 ]; then
                       echo -e "${GREEN}已停止${PLAIN}"
                   else
                       printf '%s\n' '停止服务失败，请检查服务状态。' >&2
                   fi
                   pause; break ;;
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
        local NEW_VER
        NEW_VER=$(get_latest_version)
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
        local up_idx
        while true; do
            ask "请选择 [0-3]: " up_idx
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
                        ask "获取最新版本失败，请手动输入要安装的版本号 (如 1.10.1): " NEW_VER
                        [ -z "$NEW_VER" ] && { echo -e "${RED}未输入版本号，已取消。${PLAIN}"; pause; break; }
                    fi
                    if ! [[ "$NEW_VER" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                        echo -e "${RED}版本号格式错误(应为 x.y.z)，已取消。${PLAIN}"
                        pause; break
                    fi
                    echo -e "\n${YELLOW}将强制覆盖安装 v${NEW_VER}（无论当前版本是否相同）。${PLAIN}"
                    ask "确认继续？(y/n) [默认: y]: " fc
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
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
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

    sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d' /etc/sysctl.conf 2>/dev/null
    sed -i '/^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf 2>/dev/null

    mkdir -p /etc/sysctl.d
    cat > /etc/sysctl.d/99-bbr.conf << 'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

    sysctl --system >/dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1

    local new_cc
    new_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)
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
        local current_strategy
        current_strategy=$(jq -r '.outbounds[] | select(.tag=="direct") | ((if (.domain_resolver | type) == "object" then .domain_resolver.strategy else null end) // .domain_strategy // "auto")' $CONFIG_FILE 2>/dev/null)
        echo -e "选择: 配置出站 IPv4/IPv6 策略"
        echo -e "当前出站策略: ${GREEN}${current_strategy}${PLAIN}\n"
        echo -e " 1) 仅 IPv4 出站 (ipv4_only)"
        echo -e " 2) 仅 IPv6 出站 (ipv6_only)"
        echo -e " 3) 自动/双栈出站 (auto)"
        echo -e " 0) 返回\n"
        ask "请选择 [0-3]: " out_idx
        
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
        backup_config || return 1
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
            commit_config || return 1
            pause
            continue
        fi
        
        if ! restart_service; then
            echo -e "${RED}操作失败(校验报错)，配置已还原！${PLAIN}"
            restore_config_and_service || return 1
        else
            echo -e "${GREEN}出站策略已更新！${PLAIN}"
            commit_config || return 1
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
        ask "请选择 [0-2]: " om_idx
        case "$om_idx" in
            1) enable_bbr ;;
            2) config_outbound ;;
            0) return ;;
            *) echo -e "${RED}输入错误!${PLAIN}"; sleep 1 ;;
        esac
    done
}

uninstall_all() {
    local un
    ask "确认卸载脚本、sing-box和所有节点配置吗？(y/n): " un
    if [[ "$un" == "y" ]]; then
        load_secrets
        [ -z "${_UNINST_SRC:-}" ] && _UNINST_SRC="${INSTALLER_SRC:-}"
        remove_all_fw_rules
        if [ "$OS_TYPE" == "alpine" ]; then
            rc-service sing-box stop >/dev/null 2>&1
            rc-update del sing-box default >/dev/null 2>&1
            rm -f /etc/init.d/sing-box
            if [ -n "${ARGO_SERVICES:-}" ]; then
                while IFS= read -r svc; do
                    [[ "$svc" =~ ^cloudflared-[a-zA-Z0-9_-]+$ ]] || continue
                    rc-service "$svc" stop >/dev/null 2>&1
                    rc-update del "$svc" default >/dev/null 2>&1
                    rm -f -- "/etc/init.d/$svc"
                done < <(printf '%s\n' "$ARGO_SERVICES" | tr ',' '\n')
            fi
        else
            systemctl stop sing-box >/dev/null 2>&1
            systemctl disable sing-box >/dev/null 2>&1
            rm -f /etc/systemd/system/sing-box.service
            if [ -n "${ARGO_SERVICES:-}" ]; then
                while IFS= read -r svc; do
                    [[ "$svc" =~ ^cloudflared-[a-zA-Z0-9_-]+$ ]] || continue
                    systemctl stop "$svc" >/dev/null 2>&1
                    systemctl disable "$svc" >/dev/null 2>&1
                    rm -f -- "/etc/systemd/system/$svc.service"
                done < <(printf '%s\n' "$ARGO_SERVICES" | tr ',' '\n')
            fi
            systemctl daemon-reload >/dev/null 2>&1
        fi
        
        if [ -f "$HOME/.acme.sh/acme.sh" ]; then
            load_secrets
            if [ -n "$REAL_DOMAIN" ] && [ "${REAL_CERT_OWNED:-1}" == "1" ]; then
                "$HOME"/.acme.sh/acme.sh --remove -d "$REAL_DOMAIN" >/dev/null 2>&1
            elif [ -n "$REAL_DOMAIN" ]; then
                echo -e "${YELLOW}证书 ${REAL_DOMAIN} 为复用的已有证书，已保留其 acme.sh 续期记录。${PLAIN}"
            fi
        fi
        
        SYSCTL_BAK_TMP=""
        if [ -f "$CONFIG_DIR/.sysctl_backup" ]; then
            SYSCTL_BAK_TMP=$(mktemp) && cp -f "$CONFIG_DIR/.sysctl_backup" "$SYSCTL_BAK_TMP" 2>/dev/null
        fi

        rm -rf /usr/local/bin/sing-box /usr/local/bin/cloudflared /usr/local/bin/sb /etc/sing-box
        
        rm -f /etc/sysctl.d/99-bbr.conf 2>/dev/null
        if [ -n "$SYSCTL_BAK_TMP" ] && [ -s "$SYSCTL_BAK_TMP" ]; then
            sed -i '/^[[:space:]]*net\.core\.default_qdisc[[:space:]]*=/d; /^[[:space:]]*net\.ipv4\.tcp_congestion_control[[:space:]]*=/d' /etc/sysctl.conf 2>/dev/null
            cat "$SYSCTL_BAK_TMP" >> /etc/sysctl.conf 2>/dev/null
            sysctl -p /etc/sysctl.conf >/dev/null 2>&1
            echo -e "${GREEN}已还原 /etc/sysctl.conf 中原有的 qdisc/拥塞控制设置。${PLAIN}"
        else
            sysctl -w net.ipv4.tcp_congestion_control=cubic >/dev/null 2>&1
            sysctl -w net.core.default_qdisc=fq_codel >/dev/null 2>&1
        fi
        [ -n "$SYSCTL_BAK_TMP" ] && rm -f "$SYSCTL_BAK_TMP"
        
        local _src=""
        [ -n "${_UNINST_SRC:-}" ] && _src="$_UNINST_SRC"
        [ -z "$_src" ] && [[ "${0}" != "/usr/local/bin/sb" && "${0}" != "sb" && "${0}" != *"/sb" ]] && _src="${0}"
        if [ -n "$_src" ] && [ -f "$_src" ] && [ "$_src" != "/usr/local/bin/sb" ]; then
            rm -f "$_src"
            [ -f "$_src" ] && echo -e "${YELLOW}提示: 安装器文件 ${_src} 删除失败，请手动移除。${PLAIN}" || echo -e "${GREEN}已删除初始安装器: ${_src}${PLAIN}"
        fi
        
        echo -e "${GREEN}已彻底卸载！系统已恢复原状。${PLAIN}"
    fi
}

menu() {
    init_base || { echo -e "${RED}系统环境初始化失败，无法继续运行！${PLAIN}"; exit 1; }
    local LATEST_VER_CACHE
    LATEST_VER_CACHE=$(get_latest_version)
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
        ask "请选择 [0-9]: " choice

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


commit_config() {
    rm -f "${CONFIG_FILE}.bak" || return 1
    if [ -n "${CONFIG_TX_DIR:-}" ]; then
        rm -rf "$CONFIG_TX_DIR" || return 1
        CONFIG_TX_DIR=""
    fi
}


rename_argo_service() {
    local old="$1" new="$2" src dst d enabled=0 active=0
    [[ "$old" =~ ^[A-Za-z0-9_-]+$ && "$new" =~ ^[A-Za-z0-9_-]+$ ]] || return 1
    if [ "$OS_TYPE" = alpine ]; then
        src="/etc/init.d/cloudflared-$old"; dst="/etc/init.d/cloudflared-$new"
        [ -e "/etc/runlevels/default/cloudflared-$old" ] && enabled=1
        rc-service "cloudflared-$old" status >/dev/null 2>&1 && active=1
    else
        src="/etc/systemd/system/cloudflared-$old.service"; dst="/etc/systemd/system/cloudflared-$new.service"
        systemctl is-enabled --quiet "cloudflared-$old" && enabled=1
        systemctl is-active --quiet "cloudflared-$old" && active=1
    fi
    if [ ! -f "$src" ] || [ -e "$dst" ] || [ -L "$dst" ]; then
        printf '%s\n' '原 Argo 服务文件缺失或目标服务文件已存在，取消重命名。' >&2
        return 1
    fi
    d=$(mktemp -d "$CONFIG_DIR/.argo-rename.XXXXXX") || return 1
    cp -p "$src" "$d/original" || { rm -rf "$d"; return 1; }
    if [ "$OS_TYPE" = alpine ]; then
        if rc-service "cloudflared-$old" stop &&
           rc-update del "cloudflared-$old" default &&
           mv "$src" "$dst" &&
           sed -i "s/cloudflared-$old/cloudflared-$new/g" "$dst" &&
           rc-update add "cloudflared-$new" default &&
           rc-service "cloudflared-$new" start; then rm -rf "$d"; return 0; fi
        rc-service "cloudflared-$new" stop >/dev/null 2>&1
        rc-update del "cloudflared-$new" default >/dev/null 2>&1
    else
        if systemctl stop "cloudflared-$old" &&
           systemctl disable "cloudflared-$old" &&
           mv "$src" "$dst" &&
           sed -i "s/tunnel for $old/tunnel for $new/g" "$dst" &&
           systemctl daemon-reload &&
           systemctl enable "cloudflared-$new" --now &&
           systemctl is-active --quiet "cloudflared-$new"; then rm -rf "$d"; return 0; fi
        systemctl stop "cloudflared-$new" >/dev/null 2>&1
        systemctl disable "cloudflared-$new" >/dev/null 2>&1
    fi
    if ! cp -p "$d/original" "$src" || ! rm -f "$dst"; then
        printf 'Argo 文件恢复失败，备份保留在 %s\n' "$d" >&2
        return 1
    fi
    local failed=0
    if [ "$OS_TYPE" = alpine ]; then
        if [ "$enabled" = 1 ]; then rc-update add "cloudflared-$old" default || failed=1; fi
        if [ "$active" = 1 ]; then rc-service "cloudflared-$old" start || failed=1; fi
    else
        systemctl daemon-reload || failed=1
        if [ "$enabled" = 1 ]; then systemctl enable "cloudflared-$old" || failed=1; fi
        if [ "$active" = 1 ]; then systemctl start "cloudflared-$old" || failed=1; fi
    fi
    if [ "$failed" = 0 ]; then rm -rf "$d"; else printf 'Argo 服务恢复失败，备份: %s\n' "$d" >&2; fi
    return 1
}

# Internal helpers; no new menu or feature.
remove_fw_record() {
    local p="$1" proto="$2" tmp
    [ -f "$FW_PORTS_FILE" ] || return 0
    tmp=$(mktemp "${FW_PORTS_FILE}.tmp.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$tmp")
    if awk -F/ -v p="$p" -v proto="$proto" \
        '!($1 == p && ($2 == proto || (proto == "both" && ($2 == "tcp" || $2 == "udp"))))' \
        "$FW_PORTS_FILE" > "$tmp" && mv -f "$tmp" "$FW_PORTS_FILE"; then return 0; fi
    rm -f "$tmp"; return 1
}
backup_config() {
    if [ -n "${CONFIG_TX_DIR:-}" ]; then
        printf '%s\n' '上一次配置事务尚未结束，拒绝覆盖备份。' >&2
        return 1
    fi
    local d
    d=$(mktemp -d "$CONFIG_DIR/.transaction.XXXXXX") || return 1
    if ! cp -p "$CONFIG_FILE" "$d/config.json"; then rm -rf "$d"; return 1; fi
    if [ -e "$SECRETS_FILE" ]; then
        if ! cp -p "$SECRETS_FILE" "$d/secrets"; then rm -rf "$d"; return 1; fi
    else
        touch "$d/secrets.absent" || { rm -rf "$d"; return 1; }
    fi
    if ! cp -p "$CONFIG_FILE" "${CONFIG_FILE}.bak"; then rm -rf "$d"; return 1; fi
    CONFIG_TX_DIR="$d"
}
restore_config_and_service() {
    local d="${CONFIG_TX_DIR:-}"
    if [ -z "$d" ] || [ ! -f "$d/config.json" ]; then
        printf '%s\n' '缺少完整事务备份，拒绝不完整恢复。' >&2
        return 1
    fi
    local restore_tmp
    restore_tmp=$(mktemp "${CONFIG_FILE}.restore.XXXXXX") || return 1
    SB_OWNED_TEMP_FILES+=("$restore_tmp")
    if ! cp -p "$d/config.json" "$restore_tmp" || ! mv -f "$restore_tmp" "$CONFIG_FILE"; then
        rm -f "$restore_tmp"
        return 1
    fi
    if [ -f "$d/secrets.absent" ]; then
        rm -f "$SECRETS_FILE" || return 1
    else
        restore_tmp=$(mktemp "${SECRETS_FILE}.restore.XXXXXX") || return 1
        SB_OWNED_TEMP_FILES+=("$restore_tmp")
        if ! cp -p "$d/secrets" "$restore_tmp" || ! mv -f "$restore_tmp" "$SECRETS_FILE"; then
            rm -f "$restore_tmp"
            return 1
        fi
    fi
    load_secrets || return 1
    if ! restart_service; then
        printf '配置与 secrets 已恢复，但服务恢复失败；备份保留在 %s\n' "$d" >&2
        return 1
    fi
    commit_config
}

if ! acquire_global_lock; then exit 1; fi

if [[ "$0" != "/usr/local/bin/sb" ]] && [[ "$0" != "sb" ]] && [[ "$0" != *"/sb" ]]; then
    if [ -f "/usr/local/bin/sb" ]; then
        clear
        echo -e "${GREEN}检测到 sing-box 管理脚本已经安装！${PLAIN}\n"
        echo -e " 1. 更新覆盖脚本 + 内核"
        echo -e " 2. 卸载脚本 + 内核"
        echo -e " 3. 进入面板"
        echo -e " 4. 退出\n"
        mkdir -p "$CONFIG_DIR" 2>/dev/null
        save_secret "INSTALLER_SRC" "$0"
        ask "请选择 [1-4]: " pre_choice
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
                    ask "发现新内核 v${NEW_K}，是否一并覆盖更新？(y/n) [默认: y]: " ans
                    [[ "${ans:-y}" == "y" || "${ans:-y}" == "Y" ]] && do_kernel="y"
                else
                    ask "内核已是最新 v${CUR_K}，是否仍强制覆盖重装？(y/n) [默认: n]: " ans
                    [[ "${ans:-n}" == "y" || "${ans:-n}" == "Y" ]] && do_kernel="y"
                fi

                if [ "$do_kernel" == "y" ]; then
                    if [ -f "$CONFIG_FILE" ]; then
                        install_kernel "$NEW_K" restart || exit 1
                    else
                        install_kernel "$NEW_K" norestart || exit 1
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
        mkdir -p "$CONFIG_DIR" 2>/dev/null
        save_secret "INSTALLER_SRC" "$0"
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
