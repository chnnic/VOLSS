#!/bin/sh
# shellcheck shell=bash

# ========================================
#   Shadowsocks-Rust 管理脚本
#   版本: V1.5.8
#   快捷命令: volss
#   支持: Debian / Ubuntu / Alpine
# ========================================

# ---- bash 自举（兼容 Alpine ash）----
# 本脚本依赖 bash 特性，若当前不是 bash 则尝试切换
if [ -z "$BASH_VERSION" ]; then
    if command -v bash >/dev/null 2>&1; then
        exec bash "$0" "$@"
    else
        # Alpine 等系统可能没有 bash，先安装
        echo "正在安装 bash..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash >/dev/null 2>&1
        elif command -v apt-get >/dev/null 2>&1; then
            DEBIAN_FRONTEND=noninteractive apt-get install -y bash >/dev/null 2>&1
        fi
        if command -v bash >/dev/null 2>&1; then
            exec bash "$0" "$@"
        else
            echo "错误: 无法安装 bash，请手动安装后重试"
            exit 1
        fi
    fi
fi

VERSION="V1.5.8"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== 系统检测 ==========
detect_system() {
    if [ -f /etc/alpine-release ]; then
        SYSTEM="alpine"
        SS_BIN="/usr/bin/ssserver"
        SERVICE="/etc/init.d/shadowsocks-rust"
    elif [ -f /etc/debian_version ] || grep -qi "ubuntu\|debian" /etc/os-release 2>/dev/null; then
        SYSTEM="debian"
        SS_BIN="/usr/local/bin/ssserver"
        SERVICE="/etc/systemd/system/shadowsocks-rust.service"
    else
        echo -e "${RED}不支持的系统，仅支持 Debian/Ubuntu/Alpine${NC}"
        exit 1
    fi
}

detect_system

SCRIPT_INSTALL_PATH="/usr/local/bin/volss.sh"
CONFIG_DIR="/etc/shadowsocks-rust"
CONFIG="/etc/shadowsocks-rust/config.json"
RUNTIME="/etc/shadowsocks-rust/runtime.json"
ACL_PATH="/etc/shadowsocks-rust/blocklist.acl"
LINKS_FILE="/etc/shadowsocks-rust/ss_links.txt"
SERVER_HOST_FILE="/etc/shadowsocks-rust/server_host"
TRAFFIC_FILE="/etc/shadowsocks-rust/traffic.json"
MANUAL_FILE="/etc/shadowsocks-rust/manual.list"
SHORTCUT="/usr/local/bin/volss"
ACL_RULESET_DIR="/etc/shadowsocks-rust/rulesets"
TRAFFIC_CHAIN="VOLSS_TRAFFIC"
STATE_LOCK_DIR="/run/volss.lock"
SS_USER="ssrust"
SS_GROUP="ssrust"

# ========== 安全写入与权限 ==========
make_temp_for() {
    local TARGET=$1
    local DIR BASE
    DIR=$(dirname "$TARGET")
    BASE=$(basename "$TARGET")
    mktemp "${DIR}/.${BASE}.XXXXXX"
}

secure_file() {
    local FILE=$1
    if [ -f "$FILE" ]; then
        chmod 600 "$FILE" 2>/dev/null || true
    fi
}

group_exists() {
    getent group "$1" >/dev/null 2>&1 || grep -q "^$1:" /etc/group 2>/dev/null
}

ensure_service_user() {
    if [ "$SYSTEM" = "alpine" ]; then
        group_exists "$SS_GROUP" || addgroup -S "$SS_GROUP" >/dev/null 2>&1 || return 1
        id -u "$SS_USER" >/dev/null 2>&1 || adduser -S -D -H -s /sbin/nologin -G "$SS_GROUP" "$SS_USER" >/dev/null 2>&1 || return 1
    else
        group_exists "$SS_GROUP" || groupadd --system "$SS_GROUP" >/dev/null 2>&1 || return 1
        id -u "$SS_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin --gid "$SS_GROUP" "$SS_USER" >/dev/null 2>&1 || return 1
    fi
}

secure_runtime_owner() {
    id -u "$SS_USER" >/dev/null 2>&1 || return 0
    if [ -f "$RUNTIME" ]; then
        chown "$SS_USER:$SS_GROUP" "$RUNTIME" 2>/dev/null || true
        chmod 400 "$RUNTIME" 2>/dev/null || true
    fi
    if [ -f "$ACL_PATH" ]; then
        chown "$SS_USER:$SS_GROUP" "$ACL_PATH" 2>/dev/null || true
        chmod 400 "$ACL_PATH" 2>/dev/null || true
    fi
}

secure_data_files() {
    local FILE
    for FILE in "$CONFIG" "$RUNTIME" "$LINKS_FILE" "$SERVER_HOST_FILE" "$TRAFFIC_FILE" "$MANUAL_FILE" "$ACL_PATH"; do
        secure_file "$FILE"
    done
    if [ -d "$ACL_RULESET_DIR" ]; then
        find "$ACL_RULESET_DIR" -type f -name '*.acl' -exec chmod 600 {} \; 2>/dev/null || true
    fi
    secure_runtime_owner
}

acquire_state_lock() {
    local WAITED=0
    while ! mkdir "$STATE_LOCK_DIR" 2>/dev/null; do
        if [ -f "$STATE_LOCK_DIR/pid" ]; then
            local LOCK_PID
            LOCK_PID=$(cat "$STATE_LOCK_DIR/pid" 2>/dev/null || true)
            if [ -n "$LOCK_PID" ] && ! kill -0 "$LOCK_PID" 2>/dev/null; then
                rm -f "$STATE_LOCK_DIR/pid" 2>/dev/null || true
                rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
                continue
            fi
        fi
        WAITED=$((WAITED + 1))
        if [ "$WAITED" -ge 30 ]; then
            echo -e "${RED}❌ 状态文件正被其他 volss 进程使用，请稍后重试${NC}"
            return 1
        fi
        sleep 1
    done
    echo "$$" > "$STATE_LOCK_DIR/pid" 2>/dev/null || true
}

release_state_lock() {
    rm -f "$STATE_LOCK_DIR/pid" 2>/dev/null || true
    rmdir "$STATE_LOCK_DIR" 2>/dev/null || true
}

with_state_lock() {
    if [ "${STATE_LOCK_HELD:-0}" = "1" ]; then
        "$@"
        return $?
    fi
    acquire_state_lock || return 1
    STATE_LOCK_HELD=1
    trap 'release_state_lock; exit 130' INT TERM HUP
    "$@"
    local STATUS=$?
    trap - INT TERM HUP
    STATE_LOCK_HELD=0
    release_state_lock
    return "$STATUS"
}

harden_service_if_needed() {
    check_installed || return 0
    ensure_service_user || {
        echo -e "${RED}❌ 无法创建 Shadowsocks 服务用户${NC}"
        return 1
    }
    local CHANGED=0

    if [ "$SYSTEM" = "alpine" ]; then
        if [ -f "$SERVICE" ] && ! grep -q '^command_user=' "$SERVICE" 2>/dev/null; then
            sed -i "/^command_background=/a command_user=\"$SS_USER:$SS_GROUP\"" "$SERVICE"
            CHANGED=1
        fi
        if [ -f "$SERVICE" ] && grep -q -- '--save-traffic' "$SERVICE" 2>/dev/null && ! grep -q -- '--save-traffic-if-unlocked' "$SERVICE" 2>/dev/null; then
            sed -i 's/--save-traffic/--save-traffic-if-unlocked/g' "$SERVICE"
            CHANGED=1
        fi
    else
        if [ -f "$SERVICE" ]; then
            if grep -q "^User=root" "$SERVICE" 2>/dev/null; then
                sed -i "s/^User=root/User=$SS_USER/" "$SERVICE"
                CHANGED=1
            elif ! grep -q "^User=" "$SERVICE" 2>/dev/null; then
                sed -i "/^\[Service\]/a User=$SS_USER" "$SERVICE"
                CHANGED=1
            fi
            if ! grep -q "^Group=" "$SERVICE" 2>/dev/null; then
                sed -i "/^User=$SS_USER/a Group=$SS_GROUP" "$SERVICE"
                CHANGED=1
            fi
            if ! grep -q "ExecStop" "$SERVICE" 2>/dev/null; then
                sed -i "/ExecStart=.*/a ExecStop=+/bin/bash -c 'bash $SCRIPT_INSTALL_PATH --save-traffic-if-unlocked'" "$SERVICE"
                CHANGED=1
            elif grep -q "^ExecStop=/bin/bash" "$SERVICE" 2>/dev/null; then
                sed -i 's#^ExecStop=/bin/bash#ExecStop=+/bin/bash#' "$SERVICE"
                CHANGED=1
            fi
            if grep -q -- '--save-traffic' "$SERVICE" 2>/dev/null && ! grep -q -- '--save-traffic-if-unlocked' "$SERVICE" 2>/dev/null; then
                sed -i 's/--save-traffic/--save-traffic-if-unlocked/g' "$SERVICE"
                CHANGED=1
            fi
            if ! grep -q "^ProtectSystem=strict" "$SERVICE" 2>/dev/null; then
                if grep -q "^RestartSec=" "$SERVICE" 2>/dev/null; then
                    sed -i "/^RestartSec=.*/a ProtectHome=true\nProtectSystem=strict\nReadOnlyPaths=$SS_BIN\nReadWritePaths=$CONFIG_DIR\nPrivateTmp=true" "$SERVICE"
                else
                    sed -i "/^ExecStop=.*/a ProtectHome=true\nProtectSystem=strict\nReadOnlyPaths=$SS_BIN\nReadWritePaths=$CONFIG_DIR\nPrivateTmp=true" "$SERVICE"
                fi
                CHANGED=1
            elif ! grep -q "^ReadWritePaths=$CONFIG_DIR" "$SERVICE" 2>/dev/null; then
                sed -i "/^ProtectSystem=strict/a ReadWritePaths=$CONFIG_DIR" "$SERVICE"
                CHANGED=1
            fi
        fi
    fi

    secure_data_files
    if [ "$CHANGED" -eq 1 ]; then
        svc_reload
        svc_restart 2>/dev/null || true
        echo -e "${GREEN}✅ 服务权限已自动加固${NC}"
    fi
}

# ========== 服务运行状态检测 ==========
check_svc_running() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-service shadowsocks-rust status 2>/dev/null | grep -q "started" && return 0
    else
        systemctl is-active --quiet shadowsocks-rust 2>/dev/null && return 0
    fi
    # 服务管理器不可用时再回退到进程检测，避免 pgrep -f 误判
    pgrep -x ssserver >/dev/null 2>&1 && return 0
    return 1
}

# ========== 服务管理抽象 ==========
svc_start() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-service shadowsocks-rust start
    else
        systemctl start shadowsocks-rust
    fi
}
svc_stop() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-service shadowsocks-rust stop
    else
        systemctl stop shadowsocks-rust
    fi
}
svc_restart() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-service shadowsocks-rust restart
    else
        systemctl restart shadowsocks-rust
    fi
}
svc_status() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-service shadowsocks-rust status
    else
        systemctl status shadowsocks-rust --no-pager
    fi
}
svc_enable() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-update add shadowsocks-rust default 2>/dev/null
    else
        systemctl enable shadowsocks-rust 2>/dev/null
    fi
}
svc_disable() {
    if [ "$SYSTEM" = "alpine" ]; then
        rc-update del shadowsocks-rust default 2>/dev/null
    else
        systemctl disable shadowsocks-rust 2>/dev/null
    fi
}
svc_reload() {
    [ "$SYSTEM" = "alpine" ] || systemctl daemon-reload 2>/dev/null
}
svc_log() {
    if [ "$SYSTEM" = "alpine" ]; then
        tail -f /var/log/shadowsocks-rust.log
    else
        journalctl -u shadowsocks-rust -f
    fi
}

# ========== 检查 root ==========
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本${NC}"
        exit 1
    fi
}

# ========== 检查是否已安装 ==========
check_installed() {
    [ -f "$SS_BIN" ] && [ -f "$CONFIG" ]
}

# ========== 打印 Banner ==========
print_banner() {
    clear
    echo -e "${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    Shadowsocks-Rust 管理脚本${NC}"
    echo -e "${BLUE}    版本: ${VERSION}    快捷命令: volss${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    echo ""
}

# ========== 检查端口是否被占用 ==========
port_in_use() {
    local PORT=$1
    ss -tlun 2>/dev/null | grep -q ":${PORT} " || \
    ss -tlun 2>/dev/null | grep -q ":${PORT}$"
}

# ========== 输入校验 ==========
is_uint() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

valid_port() {
    is_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_ruleset_name() {
    [[ "$1" =~ ^[A-Za-z0-9_-]+$ ]]
}

valid_domain() {
    [[ "$1" =~ ^[A-Za-z0-9._*-]+$ ]]
}

normalize_link_name() {
    python3 - "$1" << 'PYEOF'
import sys
import unicodedata

name = sys.argv[1].strip()
if not name or len(name) > 80 or any(unicodedata.category(ch).startswith('C') for ch in name):
    raise SystemExit(1)
print(name)
PYEOF
}

default_link_name() {
    local NAME
    NAME=$(hostname 2>/dev/null || true)
    [ -n "$NAME" ] || NAME=${HOST:-shadowsocks}
    normalize_link_name "$NAME" 2>/dev/null || echo shadowsocks
}

encode_link_name() {
    python3 - "$1" << 'PYEOF'
import sys
from urllib.parse import quote

print(quote(sys.argv[1], safe=''))
PYEOF
}

select_link_name_prefix() {
    local DEFAULT_NAME INPUT_NAME NORMALIZED
    DEFAULT_NAME=$(default_link_name)
    while true; do
        read -r -p "SS 链接名称 [默认 $DEFAULT_NAME]: " INPUT_NAME
        INPUT_NAME=${INPUT_NAME:-$DEFAULT_NAME}
        if NORMALIZED=$(normalize_link_name "$INPUT_NAME" 2>/dev/null); then
            LINK_NAME_PREFIX=$NORMALIZED
            NAME_LIST=()
            echo -e "链接名称: ${GREEN}$LINK_NAME_PREFIX${NC}"
            return 0
        fi
        echo -e "${RED}❌ 名称不能为空、不能包含控制字符，且最多 80 个字符${NC}"
    done
}

normalize_server_host() {
    python3 - "$1" << 'PYEOF'
import ipaddress
import re
import sys

host = sys.argv[1].strip()
if host.startswith('[') and host.endswith(']'):
    host = host[1:-1]
if not host or any(ch.isspace() for ch in host):
    raise SystemExit(1)

try:
    print(ipaddress.ip_address(host).compressed)
    raise SystemExit(0)
except ValueError:
    pass

host = host.rstrip('.')
try:
    ascii_host = host.encode('idna').decode('ascii').lower()
except UnicodeError:
    raise SystemExit(1)
if len(ascii_host) > 253:
    raise SystemExit(1)
labels = ascii_host.split('.')
if not labels or any(
    not label
    or len(label) > 63
    or not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]*[a-z0-9])?', label)
    for label in labels
):
    raise SystemExit(1)
print(ascii_host)
PYEOF
}

format_ss_host() {
    if [[ "$1" == *:* ]]; then
        printf '[%s]\n' "$1"
    else
        printf '%s\n' "$1"
    fi
}

server_bind_address() {
    if python3 - << 'PYEOF' >/dev/null 2>&1
import socket

sock = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
try:
    sock.bind(('::', 0))
finally:
    sock.close()
PYEOF
    then
        echo "::"
    else
        echo "0.0.0.0"
    fi
}

save_server_host() {
    local HOST_VALUE=$1
    local TMP_HOST
    mkdir -p "$CONFIG_DIR" || return 1
    TMP_HOST=$(make_temp_for "$SERVER_HOST_FILE") || return 1
    printf '%s\n' "$HOST_VALUE" > "$TMP_HOST" || {
        rm -f "$TMP_HOST"
        return 1
    }
    mv "$TMP_HOST" "$SERVER_HOST_FILE" || return 1
    secure_file "$SERVER_HOST_FILE"
}

get_server_host() {
    local HOST_VALUE=""
    if [ -s "$SERVER_HOST_FILE" ]; then
        HOST_VALUE=$(normalize_server_host "$(head -n 1 "$SERVER_HOST_FILE")" 2>/dev/null) || HOST_VALUE=""
    fi
    if [ -z "$HOST_VALUE" ] && [ -s "$LINKS_FILE" ]; then
        HOST_VALUE=$(python3 - "$LINKS_FILE" << 'PYEOF'
import sys

with open(sys.argv[1], encoding='utf-8') as f:
    line = f.readline().strip()
try:
    authority = line.split('@', 1)[1].split('#', 1)[0]
    if authority.startswith('['):
        host = authority[1:authority.index(']')]
    else:
        host = authority.rsplit(':', 1)[0]
    print(host)
except (IndexError, ValueError):
    raise SystemExit(1)
PYEOF
) || HOST_VALUE=""
        if [ -n "$HOST_VALUE" ]; then
            HOST_VALUE=$(normalize_server_host "$HOST_VALUE" 2>/dev/null) || HOST_VALUE=""
        fi
    fi
    [ -n "$HOST_VALUE" ] || return 1
    save_server_host "$HOST_VALUE" || return 1
    printf '%s\n' "$HOST_VALUE"
}

normalize_domain() {
    echo "$1" | sed 's/^domain-suffix://; s/^||//; s/^|//; s/^www\.//'
}

manual_domain_count() {
    if [ -f "$MANUAL_FILE" ]; then
        awk 'NF {count++} END {print count + 0}' "$MANUAL_FILE"
    else
        echo 0
    fi
}

third_party_mirrors_enabled() {
    [ "${VOLSS_ALLOW_THIRD_PARTY_MIRRORS:-0}" = "1" ]
}

sha256_file() {
    local FILE=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$FILE" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$FILE" | awk '{print $NF}'
    elif command -v python3 >/dev/null 2>&1; then
        python3 - "$FILE" << 'PYEOF'
import hashlib
import sys

h = hashlib.sha256()
with open(sys.argv[1], 'rb') as f:
    for chunk in iter(lambda: f.read(1024 * 1024), b''):
        h.update(chunk)
print(h.hexdigest())
PYEOF
    else
        return 1
    fi
}

verify_sha256() {
    local FILE=$1
    local EXPECTED=$2
    local ACTUAL
    ACTUAL=$(sha256_file "$FILE") || return 1
    [ "$ACTUAL" = "$EXPECTED" ]
}

persist_firewall_rules() {
    if [ "$SYSTEM" = "alpine" ]; then
        if [ ! -f /etc/init.d/iptables ]; then
            apk add --no-cache iptables >/dev/null 2>&1
        fi
        mkdir -p /etc/iptables
        rc-update add iptables default 2>/dev/null
        /etc/init.d/iptables save 2>/dev/null || iptables-save > /etc/iptables/rules-save 2>/dev/null
        if ipv6_firewall_available; then
            if [ -f /etc/init.d/ip6tables ]; then
                rc-update add ip6tables default 2>/dev/null
                /etc/init.d/ip6tables save 2>/dev/null || true
            else
                ip6tables-save > /etc/iptables/rules6-save 2>/dev/null || true
            fi
        fi
    else
        netfilter-persistent save 2>/dev/null || true
    fi
}

ipv6_firewall_available() {
    command -v ip6tables >/dev/null 2>&1 && ip6tables -L -n >/dev/null 2>&1
}

firewall_tools() {
    command -v iptables >/dev/null 2>&1 && iptables -L -n >/dev/null 2>&1 && echo iptables
    ipv6_firewall_available && echo ip6tables
}

config_ports() {
    python3 -c "
import json
try:
    with open('$CONFIG') as f:
        c = json.load(f)
    print(' '.join(str(s['server_port']) for s in c.get('servers', [])))
except Exception:
    pass
"
}

ensure_traffic_chain() {
    local IPT CHAIN TOOLS
    TOOLS=$(firewall_tools)
    [ -n "$TOOLS" ] || return 1
    for IPT in $TOOLS; do
        "$IPT" -N "$TRAFFIC_CHAIN" 2>/dev/null || true
        for CHAIN in INPUT OUTPUT; do
            while "$IPT" -D "$CHAIN" -j "$TRAFFIC_CHAIN" 2>/dev/null; do :; done
            "$IPT" -I "$CHAIN" 1 -j "$TRAFFIC_CHAIN" || return 1
        done
    done
}

remove_legacy_traffic_rules_for_ports() {
    local PORTS="$1"
    local IPT PORT PROTO
    for IPT in $(firewall_tools); do
        for PORT in $PORTS; do
            for PROTO in tcp udp; do
                while "$IPT" -D INPUT  -p "$PROTO" --dport "$PORT" 2>/dev/null; do :; done
                while "$IPT" -D OUTPUT -p "$PROTO" --sport "$PORT" 2>/dev/null; do :; done
            done
        done
    done
}

add_traffic_rules_for_ports() {
    local PORTS="$1"
    local IPT PORT PROTO
    for IPT in $(firewall_tools); do
        for PORT in $PORTS; do
            for PROTO in tcp udp; do
                "$IPT" -A "$TRAFFIC_CHAIN" -p "$PROTO" --dport "$PORT" || return 1
                "$IPT" -A "$TRAFFIC_CHAIN" -p "$PROTO" --sport "$PORT" || return 1
            done
        done
    done
}

add_traffic_rules_for_new_ports() {
    local PORTS="$1"
    [ -n "$PORTS" ] || return 0
    ensure_traffic_chain || return 1
    remove_legacy_traffic_rules_for_ports "$PORTS"
    add_traffic_rules_for_ports "$PORTS" || return 1
    zero_traffic_counters_for_ports "$PORTS"
    persist_firewall_rules
}

rebuild_traffic_rules() {
    local PORTS="$1"
    if [ -z "$PORTS" ]; then
        cleanup_traffic_rules ""
        return 0
    fi
    ensure_traffic_chain || return 1
    local IPT
    for IPT in $(firewall_tools); do
        "$IPT" -F "$TRAFFIC_CHAIN" 2>/dev/null || return 1
    done
    remove_legacy_traffic_rules_for_ports "$PORTS"
    add_traffic_rules_for_ports "$PORTS" || return 1
    zero_traffic_counters_for_ports "$PORTS"
    persist_firewall_rules
}

cleanup_traffic_rules() {
    local PORTS="$1"
    remove_legacy_traffic_rules_for_ports "$PORTS"
    local IPT CHAIN
    for IPT in $(firewall_tools); do
        "$IPT" -F "$TRAFFIC_CHAIN" 2>/dev/null || true
        for CHAIN in INPUT OUTPUT; do
            while "$IPT" -D "$CHAIN" -j "$TRAFFIC_CHAIN" 2>/dev/null; do :; done
        done
        "$IPT" -X "$TRAFFIC_CHAIN" 2>/dev/null || true
    done
    persist_firewall_rules
}

traffic_chains_installed() {
    local IPT FOUND=0
    for IPT in $(firewall_tools); do
        FOUND=1
        "$IPT" -L "$TRAFFIC_CHAIN" -n >/dev/null 2>&1 || return 1
    done
    [ "$FOUND" -eq 1 ]
}

migrate_traffic_rules_if_needed() {
    check_installed || return 0
    traffic_chains_installed && return 0
    local PORTS
    PORTS=$(config_ports)
    [ -n "$PORTS" ] || return 0
    save_traffic || return 1
    rebuild_traffic_rules "$PORTS"
}

# 只清零指定端口的 iptables 计数器（精确匹配，不影响其他统计）
zero_traffic_counters_for_ports() {
    local PORTS="$1"
    local IPT CHAIN L PORT LINES
    for IPT in $(firewall_tools); do
        for CHAIN in "$TRAFFIC_CHAIN" INPUT OUTPUT; do
            "$IPT" -L "$CHAIN" -n >/dev/null 2>&1 || continue
            for PORT in $PORTS; do
                LINES=$("$IPT" -nvL "$CHAIN" --line-numbers 2>/dev/null | awk -v p="$PORT" '$0 ~ ("dpt:"p"( |$)") || $0 ~ ("spt:"p"( |$)") {print $1}' | sort -rn)
                for L in $LINES; do
                    "$IPT" -Z "$CHAIN" "$L" 2>/dev/null
                done
            done
        done
    done
}

# ========== 时间同步相关 ==========

# 获取标准时间（从 HTTP HEAD 或 NTP 获取）
get_standard_time() {
    # 优先尝试 Cloudflare（响应快）
    local TS
    TS=$(curl -sI --max-time 3 https://cloudflare.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //; s/\r$//')
    if [ -z "$TS" ]; then
        TS=$(curl -sI --max-time 3 https://www.google.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //; s/\r$//')
    fi
    if [ -z "$TS" ]; then
        TS=$(curl -sI --max-time 3 https://www.baidu.com 2>/dev/null | grep -i "^date:" | sed 's/^[Dd]ate: //; s/\r$//')
    fi
    echo "$TS"
}

# 计算本地时间和标准时间的差值（秒）
get_time_diff() {
    local STD_TIME
    STD_TIME=$(get_standard_time)
    if [ -z "$STD_TIME" ]; then
        echo "N/A"
        return
    fi
    # 优先用 GNU date -d，失败则回退到 python（兼容 busybox）
    local STD_EPOCH
    STD_EPOCH=$(date -d "$STD_TIME" +%s 2>/dev/null)
    if [ -z "$STD_EPOCH" ]; then
        STD_EPOCH=$(python3 -c "
import sys
from email.utils import parsedate_to_datetime
try:
    print(int(parsedate_to_datetime('$STD_TIME').timestamp()))
except:
    pass
" 2>/dev/null)
    fi
    local LOCAL_EPOCH
    LOCAL_EPOCH=$(date +%s)
    if [ -z "$STD_EPOCH" ]; then
        echo "N/A"
        return
    fi
    local DIFF=$((LOCAL_EPOCH - STD_EPOCH))
    echo "$DIFF"
}

# 格式化时间差显示
format_time_diff() {
    local DIFF=$1
    if [ "$DIFF" = "N/A" ]; then
        echo "${YELLOW}未知${NC}"
        return
    fi
    local ABS="${DIFF#-}"
    if [ "$ABS" -le 2 ]; then
        echo "${GREEN}已同步 (±${ABS}s)${NC}"
    elif [ "$ABS" -le 10 ]; then
        if [ "$DIFF" -gt 0 ]; then
            echo "${YELLOW}本地快 ${ABS}s${NC}"
        else
            echo "${YELLOW}本地慢 ${ABS}s${NC}"
        fi
    else
        if [ "$DIFF" -gt 0 ]; then
            echo "${RED}本地快 ${ABS}s${NC}"
        else
            echo "${RED}本地慢 ${ABS}s${NC}"
        fi
    fi
}

# 执行时间同步
do_time_sync() {
    echo -e "\n${YELLOW}>>> 时间同步${NC}"
    echo -e "当前本地时间: ${CYAN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    STD_TIME=$(get_standard_time)
    if [ -n "$STD_TIME" ]; then
        echo -e "标准时间:     ${CYAN}$STD_TIME${NC}"
    fi

    DIFF=$(get_time_diff)
    echo -e "时间差:       $(format_time_diff "$DIFF")"
    echo ""

    read -r -p "确认同步系统时间？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    echo -e "\n${YELLOW}>>> 安装并执行时间同步...${NC}"

    if [ "$SYSTEM" = "alpine" ]; then
        # Alpine 使用 chrony 或 busybox ntpd
        apk add --no-cache chrony 2>/dev/null
        if command -v chronyd >/dev/null 2>&1; then
            rc-service chronyd stop 2>/dev/null
            chronyd -q 'server pool.ntp.org iburst' 2>&1 | head -5
            rc-service chronyd start
            rc-update add chronyd default 2>/dev/null
        else
            # 回退到 busybox ntpd
            ntpd -nqp pool.ntp.org 2>&1 | head -5
        fi
    else
        # Debian/Ubuntu 使用 chrony 或 systemd-timesyncd
        if command -v timedatectl >/dev/null 2>&1; then
            timedatectl set-ntp true
            DEBIAN_FRONTEND=noninteractive apt-get install -y chrony -qq 2>/dev/null
            systemctl restart chrony 2>/dev/null || systemctl restart systemd-timesyncd 2>/dev/null
            sleep 2
            chronyc -a makestep 2>/dev/null || true
        else
            DEBIAN_FRONTEND=noninteractive apt-get install -y ntpdate -qq
            ntpdate -u pool.ntp.org
        fi
    fi

    sleep 2
    echo ""
    echo -e "${GREEN}✅ 同步完成${NC}"
    echo -e "当前本地时间: ${CYAN}$(date '+%Y-%m-%d %H:%M:%S %Z')${NC}"
    DIFF=$(get_time_diff)
    echo -e "时间差:       $(format_time_diff "$DIFF")"
}

# =============================================
#   安装流程
# =============================================

install_deps() {
    echo -e "\n${YELLOW}>>> 安装依赖...${NC}"
    if [ "$SYSTEM" = "alpine" ]; then
        apk update -q || {
            echo -e "${RED}❌ 更新 Alpine 软件索引失败${NC}"
            return 1
        }
        apk add --no-cache curl wget openssl python3 iproute2 xz iptables net-tools bash coreutils || {
            echo -e "${RED}❌ 安装依赖失败${NC}"
            return 1
        }
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || {
            echo -e "${RED}❌ 更新 APT 软件索引失败${NC}"
            return 1
        }
        apt-get install -y curl wget openssl python3 iproute2 xz-utils iptables-persistent -qq || {
            echo -e "${RED}❌ 安装依赖失败${NC}"
            return 1
        }
    fi
    echo -e "${GREEN}✅ 依赖安装完成${NC}"
}

install_ssrust() {
    echo -e "\n${YELLOW}>>> 安装 Shadowsocks-Rust...${NC}"

    RELEASE_JSON=$(curl -fsSL --max-time 20 https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest 2>/dev/null)
    LATEST=$(printf '%s\n' "$RELEASE_JSON" | python3 -c "import json, sys; print(json.load(sys.stdin).get('tag_name', ''))" 2>/dev/null)

    if [ -z "$LATEST" ]; then
        echo -e "${RED}❌ 获取版本号失败，请检查网络${NC}"
        return 1
    fi

    echo -e "最新版本: ${GREEN}$LATEST${NC}"

    ARCH=$(uname -m)
    if [ "$SYSTEM" = "alpine" ]; then
        # Alpine 使用 musl 版本
        case $ARCH in
            x86_64)  ARCH_NAME="x86_64-unknown-linux-musl" ;;
            aarch64) ARCH_NAME="aarch64-unknown-linux-musl" ;;
            armv7l)  ARCH_NAME="armv7-unknown-linux-musleabihf" ;;
            *)
                echo -e "${RED}不支持的架构: $ARCH${NC}"
                return 1
                ;;
        esac
    else
        case $ARCH in
            x86_64)  ARCH_NAME="x86_64-unknown-linux-gnu" ;;
            aarch64) ARCH_NAME="aarch64-unknown-linux-gnu" ;;
            *)
                echo -e "${RED}不支持的架构: $ARCH${NC}"
                return 1
                ;;
        esac
    fi

    ASSET_NAME="shadowsocks-${LATEST}.${ARCH_NAME}.tar.xz"
    EXPECTED_SHA256=$(printf '%s\n' "$RELEASE_JSON" | python3 -c "
import json, sys
name = sys.argv[1]
for asset in json.load(sys.stdin).get('assets', []):
    if asset.get('name') == name:
        digest = asset.get('digest', '')
        if digest.startswith('sha256:'):
            print(digest.split(':', 1)[1])
        break
" "$ASSET_NAME" 2>/dev/null)
    if [ -z "$EXPECTED_SHA256" ]; then
        echo -e "${RED}❌ 未找到 $ASSET_NAME 的 SHA256 校验信息，已停止安装${NC}"
        return 1
    fi

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/${ASSET_NAME}"
    TMP_DIR=$(mktemp -d /tmp/volss.XXXXXX) || {
        echo -e "${RED}❌ 创建临时目录失败${NC}"
        return 1
    }
    TMP_TAR="$TMP_DIR/ss-rust.tar.xz"

    # 默认只使用官方源；如确需第三方镜像，可显式设置 VOLSS_ALLOW_THIRD_PARTY_MIRRORS=1
    DOWNLOAD_PREFIXES=("")
    if third_party_mirrors_enabled; then
        DOWNLOAD_PREFIXES+=("https://gh.api.99988866.xyz/" "https://ghproxy.net/" "https://mirror.ghproxy.com/")
    fi
    DOWNLOADED=0
    for PREFIX in "${DOWNLOAD_PREFIXES[@]}"; do
        TRY_URL="${PREFIX}${URL}"
        echo "下载中: $TRY_URL"
        if fetch_url "$TRY_URL" "$TMP_TAR" 45; then
            DOWNLOADED=1
            break
        fi
    done

    if [ "$DOWNLOADED" -ne 1 ]; then
        rm -rf "$TMP_DIR"
        echo -e "${RED}❌ 下载失败${NC}"
        return 1
    fi

    if ! verify_sha256 "$TMP_TAR" "$EXPECTED_SHA256"; then
        rm -rf "$TMP_DIR"
        echo -e "${RED}❌ 下载文件 SHA256 校验失败，已停止安装${NC}"
        return 1
    fi

    if ! tar -xJf "$TMP_TAR" -C "$TMP_DIR" 2>/dev/null; then
        rm -rf "$TMP_DIR"
        echo -e "${RED}❌ 解压失败，请确认已安装 xz${NC}"
        return 1
    fi

    if [ ! -f "$TMP_DIR/ssserver" ]; then
        rm -rf "$TMP_DIR"
        echo -e "${RED}❌ 解压后未找到 ssserver${NC}"
        return 1
    fi

    mv "$TMP_DIR/ssserver" "$SS_BIN" || {
        rm -rf "$TMP_DIR"
        echo -e "${RED}❌ 安装 ssserver 文件失败${NC}"
        return 1
    }
    chmod +x "$SS_BIN" || return 1
    mkdir -p "$CONFIG_DIR" || return 1
    rm -rf "$TMP_DIR"

    echo -e "${GREEN}✅ ss-rust $LATEST 安装完成${NC}"
}

select_method() {
    echo -e "\n${YELLOW}>>> 选择加密方式：${NC}"
    echo "  1) 2022-blake3-aes-128-gcm        (推荐，密钥16字节)"
    echo "  2) 2022-blake3-aes-256-gcm        (强加密，密钥32字节)"
    echo "  3) 2022-blake3-chacha20-poly1305   (ARM推荐，密钥32字节)"
    echo "  4) aes-256-gcm                    (传统，兼容性好)"
    echo "  5) chacha20-ietf-poly1305         (传统，兼容性好)"
    read -r -p "请选择 [1-5，默认1]: " METHOD_CHOICE

    case $METHOD_CHOICE in
        2) METHOD="2022-blake3-aes-256-gcm";        KEY_LEN=32 ;;
        3) METHOD="2022-blake3-chacha20-poly1305";  KEY_LEN=32 ;;
        4) METHOD="aes-256-gcm";                   KEY_LEN=0  ;;
        5) METHOD="chacha20-ietf-poly1305";        KEY_LEN=0  ;;
        *) METHOD="2022-blake3-aes-128-gcm";       KEY_LEN=16 ;;
    esac

    echo -e "已选择: ${GREEN}$METHOD${NC}"
}

# ========== 端口分配 ==========
select_ports() {
    echo -e "\n${YELLOW}>>> 端口分配方式：${NC}"
    echo "  1) 顺序端口（从指定端口开始，自动跳过占用端口）"
    echo "  2) 随机端口（在指定范围内随机分配）"
    read -r -p "请选择 [1-2，默认1]: " PORT_MODE
    PORT_MODE=${PORT_MODE:-1}

    read -r -p "生成用户数量 [默认 10，最多 50]: " USER_COUNT
    USER_COUNT=${USER_COUNT:-10}
    if ! is_uint "$USER_COUNT" || [ "$USER_COUNT" -lt 1 ]; then
        echo -e "${RED}❌ 用户数量必须是正整数${NC}"
        return 1
    fi
    [ "$USER_COUNT" -gt 50 ] && USER_COUNT=50

    if [ "$PORT_MODE" = "1" ]; then
        read -r -p "起始端口 [默认 30001]: " START_PORT
        START_PORT=${START_PORT:-30001}
        if ! valid_port "$START_PORT"; then
            echo -e "${RED}❌ 起始端口无效${NC}"
            return 1
        fi

        echo -e "\n${YELLOW}>>> 正在分配端口（跳过已占用）...${NC}"
        PORT_LIST=()
        CURRENT=$START_PORT
        while [ ${#PORT_LIST[@]} -lt "$USER_COUNT" ]; do
            if [ "$CURRENT" -gt 65535 ]; then
                echo -e "${RED}❌ 端口耗尽，无法分配足够端口${NC}"
                return 1
            fi
            if port_in_use "$CURRENT"; then
                echo -e "  ${YELLOW}端口 $CURRENT 已占用，跳过${NC}"
            else
                PORT_LIST+=("$CURRENT")
                echo -e "  ${GREEN}端口 $CURRENT 可用 ✓${NC}"
            fi
            CURRENT=$((CURRENT + 1))
        done

    else
        read -r -p "端口范围起始 [默认 20000]: " RANGE_START
        read -r -p "端口范围结束 [默认 60000]: " RANGE_END
        RANGE_START=${RANGE_START:-20000}
        RANGE_END=${RANGE_END:-60000}
        if ! valid_port "$RANGE_START" || ! valid_port "$RANGE_END" || [ "$RANGE_END" -lt "$RANGE_START" ]; then
            echo -e "${RED}❌ 端口范围无效${NC}"
            return 1
        fi
        if [ $((RANGE_END - RANGE_START + 1)) -lt "$USER_COUNT" ]; then
            echo -e "${RED}❌ 端口范围小于用户数量${NC}"
            return 1
        fi

        echo -e "\n${YELLOW}>>> 正在随机分配端口（跳过已占用）...${NC}"
        PORT_LIST=()
        while IFS= read -r RAND_PORT; do
            port_in_use "$RAND_PORT" && continue
            PORT_LIST+=("$RAND_PORT")
            echo -e "  ${GREEN}端口 $RAND_PORT 已分配 ✓${NC}"
            [ ${#PORT_LIST[@]} -ge "$USER_COUNT" ] && break
        done < <(shuf -i "$RANGE_START-$RANGE_END")
        if [ ${#PORT_LIST[@]} -lt "$USER_COUNT" ]; then
            echo -e "${RED}❌ 范围内可用端口不足${NC}"
            return 1
        fi
    fi

    echo -e "${GREEN}✅ 端口分配完成，共 ${#PORT_LIST[@]} 个${NC}"
}

basic_config() {
    echo -e "\n${YELLOW}>>> 服务器信息${NC}"
    local INPUT_HOST NORMALIZED URL CANDIDATE
    while true; do
        read -r -p "服务器域名或IP [默认自动检测]: " INPUT_HOST
        if [ -z "$INPUT_HOST" ]; then
            INPUT_HOST=""
            for URL in https://ifconfig.me/ip https://ip.sb https://api.ipify.org https://ifconfig.co/ip; do
                CANDIDATE=$(curl -fsS4 --max-time 5 "$URL" 2>/dev/null | tr -d '\r\n') || continue
                if NORMALIZED=$(normalize_server_host "$CANDIDATE" 2>/dev/null); then
                    INPUT_HOST=$NORMALIZED
                    break
                fi
            done
            if [ -z "$INPUT_HOST" ]; then
                echo -e "${RED}❌ 自动检测失败，请手动输入域名或 IP${NC}"
                continue
            fi
        fi
        if NORMALIZED=$(normalize_server_host "$INPUT_HOST" 2>/dev/null); then
            HOST=$NORMALIZED
            save_server_host "$HOST" || {
                echo -e "${RED}❌ 保存服务器地址失败${NC}"
                return 1
            }
            echo -e "服务器地址: ${GREEN}$HOST${NC}"
            return 0
        fi
        echo -e "${RED}❌ 域名或 IP 格式无效${NC}"
    done
}

config_acl() {
    echo -e "\n${YELLOW}>>> 是否配置 ACL 黑名单？${NC}"
    read -r -p "配置 ACL？[y/N]: " USE_ACL

    if [[ "$USE_ACL" =~ ^[Yy]$ ]]; then
        echo -e "\n${YELLOW}输入要屏蔽的域名，每行一个，输入空行结束：${NC}"
        echo -e "${BLUE}示例: ippure.com${NC}"

        local TMP_ACL
        TMP_ACL=$(make_temp_for "$ACL_PATH") || {
            echo -e "${RED}❌ 创建 ACL 临时文件失败${NC}"
            return 1
        }
        cat > "$TMP_ACL" << 'ACLEOF'
[outbound_block_list]
ACLEOF
        mv "$TMP_ACL" "$ACL_PATH"

        while true; do
            read -r -p "域名 (空行结束): " DOMAIN
            [ -z "$DOMAIN" ] && break
            # 去掉用户可能输入的前缀
            DOMAIN=$(normalize_domain "$DOMAIN")
            if ! valid_domain "$DOMAIN"; then
                echo -e "  ${RED}域名格式无效，已跳过${NC}"
                continue
            fi
            if grep -Fqx -- "$DOMAIN" "$MANUAL_FILE" 2>/dev/null; then
                echo -e "  ${YELLOW}$DOMAIN 已存在，已跳过${NC}"
                continue
            fi
            echo "$DOMAIN" >> "$MANUAL_FILE"
            secure_file "$MANUAL_FILE"
            echo -e "  ${GREEN}已添加: $DOMAIN（含所有子域名）${NC}"
        done

        USE_ACL_FLAG=true
        rebuild_acl || return 1
        echo -e "${GREEN}✅ ACL 配置完成${NC}"
    else
        USE_ACL_FLAG=false
        echo "跳过 ACL 配置"
    fi
}

gen_password() {
    if [ "$KEY_LEN" -gt 0 ]; then
        openssl rand -base64 "$KEY_LEN"
    else
        openssl rand -base64 32 | tr -d '=' | cut -c1-24
    fi
}

generate_config() {
    echo -e "\n${YELLOW}>>> 生成配置文件和 SS 链接...${NC}"
    local TMP_CONFIG TMP_LINKS BIND_ADDRESS LINK_HOST NAME NAME_JSON TAG
    HOST=$(normalize_server_host "$HOST" 2>/dev/null) || {
        echo -e "${RED}❌ 服务器地址无效${NC}"
        return 1
    }
    save_server_host "$HOST" || return 1
    BIND_ADDRESS=$(server_bind_address)
    LINK_HOST=$(format_ss_host "$HOST")
    TMP_CONFIG=$(make_temp_for "$CONFIG") || {
        echo -e "${RED}❌ 创建配置临时文件失败${NC}"
        return 1
    }
    TMP_LINKS=$(make_temp_for "$LINKS_FILE") || {
        rm -f "$TMP_CONFIG"
        echo -e "${RED}❌ 创建链接临时文件失败${NC}"
        return 1
    }

    # ACL 写在顶层，不写在每个 server 块里
    if [ "$USE_ACL_FLAG" = true ]; then
        echo "{\"acl\":\"$ACL_PATH\",\"servers\":[" > "$TMP_CONFIG"
    else
        echo '{"servers":[' > "$TMP_CONFIG"
    fi

    : > "$TMP_LINKS"

    TOTAL=${#PORT_LIST[@]}
    [ -n "${LINK_NAME_PREFIX:-}" ] || LINK_NAME_PREFIX=$(default_link_name)
    for i in $(seq 0 $((TOTAL - 1))); do
        PORT=${PORT_LIST[$i]}
        PASS=$(gen_password)
        NUM=$((i + 1))
        NAME=${NAME_LIST[$i]:-}
        if [ -z "$NAME" ]; then
            if [ "$TOTAL" -eq 1 ]; then
                NAME=$LINK_NAME_PREFIX
            else
                NAME="${LINK_NAME_PREFIX}-${NUM}"
            fi
        fi
        NAME=$(normalize_link_name "$NAME" 2>/dev/null) || {
            rm -f "$TMP_CONFIG" "$TMP_LINKS"
            echo -e "${RED}❌ SS 链接名称无效${NC}"
            return 1
        }
        NAME_JSON=$(python3 - "$NAME" << 'PYEOF'
import json
import sys

print(json.dumps(sys.argv[1], ensure_ascii=False))
PYEOF
)
        TAG=$(encode_link_name "$NAME") || {
            rm -f "$TMP_CONFIG" "$TMP_LINKS"
            echo -e "${RED}❌ SS 链接名称编码失败${NC}"
            return 1
        }

        if [ $NUM -lt "$TOTAL" ]; then
            echo "  {\"server\":\"$BIND_ADDRESS\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\",\"mode\":\"tcp_and_udp\",\"name\":$NAME_JSON}," >> "$TMP_CONFIG"
        else
            echo "  {\"server\":\"$BIND_ADDRESS\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\",\"mode\":\"tcp_and_udp\",\"name\":$NAME_JSON}" >> "$TMP_CONFIG"
        fi

        USERINFO=$(echo -n "$METHOD:$PASS" | base64 | tr -d '\n')
        echo "ss://${USERINFO}@${LINK_HOST}:${PORT}#${TAG}" >> "$TMP_LINKS"
    done

    echo ']}' >> "$TMP_CONFIG" || return 1
    mv "$TMP_CONFIG" "$CONFIG" || return 1
    mv "$TMP_LINKS" "$LINKS_FILE" || return 1
    secure_data_files
    echo -e "${GREEN}✅ 配置生成完成${NC}"
}

apply_config() {
    # 锁内配置变更会触发服务重启；先由当前进程保存计数，ExecStop 看到锁后可直接跳过。
    if [ -f "$TRAFFIC_FILE" ] || traffic_chains_installed; then
        save_traffic || return 1
    fi
    if ! python3 << PYEOF
import json, os, tempfile

with open('$CONFIG', 'r') as f:
    config = json.load(f)

# 过滤禁用用户
servers = [dict(s) for s in config['servers'] if not s.get('disabled', False)]
for s in servers:
    s.pop('disabled', None)
    s.pop('acl', None)  # 移除 server 块里的旧 acl 字段
    s.pop('name', None)  # 链接名称仅供 volss 管理，不传给 ssserver

runtime = {'servers': servers}

# 顶层 ACL 继承
if 'acl' in config and os.path.exists(config['acl']):
    runtime['acl'] = config['acl']
elif os.path.exists('$ACL_PATH'):
    runtime['acl'] = '$ACL_PATH'

runtime_file = '$RUNTIME'
runtime_dir = os.path.dirname(runtime_file)
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(runtime_file) + '.', dir=runtime_dir, text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(runtime, f, indent=2)
os.replace(tmp, runtime_file)
PYEOF
    then
        echo -e "${RED}❌ 生成 runtime.json 失败${NC}"
        return 1
    fi
    secure_data_files

    svc_reload || return 1
    if ! svc_restart; then
        echo -e "${RED}❌ Shadowsocks-Rust 服务重启失败${NC}"
        return 1
    fi
}

create_service() {
    echo -e "\n${YELLOW}>>> 创建系统服务...${NC}"
    ensure_service_user || {
        echo -e "${RED}❌ 创建 Shadowsocks 服务用户失败${NC}"
        return 1
    }

    if [ "$SYSTEM" = "alpine" ]; then
        cat > $SERVICE << EOF
#!/sbin/openrc-run

name="shadowsocks-rust"
description="Shadowsocks-Rust Server"
command="$SS_BIN"
command_args="-c $RUNTIME"
command_background=true
command_user="$SS_USER:$SS_GROUP"
pidfile="/run/\${RC_SVCNAME}.pid"
output_log="/var/log/shadowsocks-rust.log"
error_log="/var/log/shadowsocks-rust.log"

depend() {
    need net
    after firewall
}

start_pre() {
    [ -x $SS_BIN ] || return 1
    [ -f $RUNTIME ] || return 1
}

stop_pre() {
    [ -f $SCRIPT_INSTALL_PATH ] && bash $SCRIPT_INSTALL_PATH --save-traffic-if-unlocked 2>/dev/null || true
}
EOF
        chmod +x "$SERVICE" || return 1
    else
        cat > $SERVICE << EOF
[Unit]
Description=Shadowsocks-Rust Service
After=network.target

[Service]
Type=simple
User=$SS_USER
Group=$SS_GROUP
ExecStart=$SS_BIN -c $RUNTIME
ExecStop=+/bin/bash -c 'bash $SCRIPT_INSTALL_PATH --save-traffic-if-unlocked'
Restart=always
RestartSec=5s
ProtectHome=true
ProtectSystem=strict
ReadOnlyPaths=$SS_BIN
ReadWritePaths=$CONFIG_DIR
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
    fi

    if [ ! -s "$SERVICE" ]; then
        echo -e "${RED}❌ 写入系统服务文件失败${NC}"
        return 1
    fi

    svc_reload || {
        echo -e "${RED}❌ 重新加载服务配置失败${NC}"
        return 1
    }
    apply_config || return 1
    svc_enable || {
        echo -e "${RED}❌ 设置服务开机启动失败${NC}"
        return 1
    }
    sleep 2

    if check_svc_running; then
        echo -e "${GREEN}✅ 服务启动成功${NC}"
    else
        echo -e "${RED}❌ 服务启动失败${NC}"
        if [ "$SYSTEM" = "alpine" ]; then
            echo "日志: tail -20 /var/log/shadowsocks-rust.log"
        else
            echo "日志: journalctl -u shadowsocks-rust -n 20"
        fi
        return 1
    fi
}

init_traffic() {
    echo -e "\n${YELLOW}>>> 初始化流量统计规则...${NC}"

    PORTS=$(config_ports)
    rebuild_traffic_rules "$PORTS" || {
        echo -e "${RED}❌ 初始化流量统计规则失败${NC}"
        return 1
    }

    echo -e "${GREEN}✅ 流量统计初始化完成${NC}"
}

install_shortcut() {
    # 获取当前脚本绝对路径
    CURRENT_SCRIPT=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

    # 将脚本复制到固定路径
    if [ "$CURRENT_SCRIPT" != "$SCRIPT_INSTALL_PATH" ]; then
        if ! cp "$CURRENT_SCRIPT" "$SCRIPT_INSTALL_PATH"; then
            echo -e "${RED}❌ 脚本复制失败，快捷命令将指向当前路径: $CURRENT_SCRIPT${NC}"
            SCRIPT_INSTALL_PATH="$CURRENT_SCRIPT"
        else
            chmod +x "$SCRIPT_INSTALL_PATH"
            echo -e "${GREEN}✅ 脚本已安装至: ${YELLOW}$SCRIPT_INSTALL_PATH${NC}"
        fi
    fi

    # 如果已存在且不是 volss 脚本则跳过，避免覆盖其他快捷命令
    if [ -f "$SHORTCUT" ]; then
        if ! grep -q "volss" "$SHORTCUT" 2>/dev/null; then
            echo -e "${YELLOW}⚠ $SHORTCUT 已被其他脚本占用，跳过注册${NC}"
            return
        fi
    fi

    if ! cat > "$SHORTCUT" << EOF
#!/bin/bash
bash $SCRIPT_INSTALL_PATH --menu
EOF
    then
        echo -e "${RED}❌ 写入快捷命令失败${NC}"
        return 1
    fi
    chmod +x "$SHORTCUT" || return 1

    # 验证快捷命令是否可用
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        echo -e "${GREEN}✅ 快捷命令已注册: 输入 ${YELLOW}volss${GREEN} 呼出管理菜单${NC}"
    else
        echo -e "${RED}❌ 快捷命令注册失败，请手动运行: bash $CURRENT_SCRIPT${NC}"
    fi
}

# ========== 完整安装流程 ==========
do_install_locked() {
    if check_installed; then
        echo -e "${YELLOW}⚠ 检测到已安装 Shadowsocks-Rust${NC}"
        read -r -p "是否重新安装？[y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi
    fi

    install_deps      || { read -r -p "按回车返回..."; return 1; }
    install_ssrust    || { read -r -p "按回车返回..."; return 1; }
    select_method     || { read -r -p "按回车返回..."; return 1; }
    basic_config      || { read -r -p "按回车返回..."; return 1; }
    select_link_name_prefix || { read -r -p "按回车返回..."; return 1; }
    select_ports      || { read -r -p "按回车返回..."; return 1; }
    config_acl        || { read -r -p "按回车返回..."; return 1; }
    generate_config   || { read -r -p "按回车返回..."; return 1; }
    create_service    || { read -r -p "按回车返回..."; return 1; }
    init_traffic      || { read -r -p "按回车返回..."; return 1; }
    install_shortcut  || { read -r -p "按回车返回..."; return 1; }

    echo ""
    show_links
    echo ""
    echo -e "${GREEN}🎉 安装完成！输入 ${YELLOW}volss${GREEN} 随时呼出管理菜单${NC}"
    read -r -p "按回车返回主菜单..."
}

# ========== 卸载 ==========
do_uninstall_locked() {
    echo -e "${RED}⚠ 此操作将完全卸载 Shadowsocks-Rust${NC}"
    read -r -p "确认卸载？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    # 清理 iptables 流量统计规则
    if [ -f "$CONFIG" ]; then
        PORTS=$(config_ports)
        cleanup_traffic_rules "$PORTS"
    fi

    svc_stop 2>/dev/null
    svc_disable
    rm -f "$SS_BIN" "$SERVICE" "$SHORTCUT" "$SCRIPT_INSTALL_PATH" "${SCRIPT_INSTALL_PATH}.bak"
    rm -rf /etc/shadowsocks-rust
    svc_reload

    echo -e "${GREEN}✅ 卸载完成${NC}"
    read -r -p "按回车继续..."
}

do_install() {
    with_state_lock do_install_locked
}

do_uninstall() {
    with_state_lock do_uninstall_locked
}

# =============================================
#   管理功能
# =============================================

list_users() {
    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    当前用户列表${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    printf "  ${CYAN}%-4s %-8s %-22s %-30s %-6s${NC}\n" "编号" "端口" "名称" "加密方式" "状态"
    echo -e "  ${BLUE}-------------------------------------------------${NC}"

    python3 << PYEOF
import json
with open('$CONFIG') as f:
    c = json.load(f)
for i, s in enumerate(c['servers'], 1):
    status = '暂停' if s.get('disabled') else '正常'
    color  = '\033[0;31m' if s.get('disabled') else '\033[0;32m'
    reset  = '\033[0m'
    name = str(s.get('name') or '-')
    if len(name) > 20:
        name = name[:19] + '…'
    print(f"  {i:<4} {s['server_port']:<8} {name:<22} {s['method']:<30} {color}{status}{reset}")
PYEOF

    echo -e "  ${BLUE}=================================================${NC}"
}

show_links() {
    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    SS 链接列表${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    cat "$LINKS_FILE"
    echo -e "  ${BLUE}=================================================${NC}"
    echo -e "  链接已保存至: ${YELLOW}$LINKS_FILE${NC}"
}

save_traffic_locked() {
    if ! python3 << PYEOF
import json, subprocess, os, tempfile

config_file = '$CONFIG'
traffic_file = '$TRAFFIC_FILE'

with open(config_file) as f:
    c = json.load(f)

try:
    with open(traffic_file) as f:
        history = json.load(f)
except Exception:
    history = {}

def tool_available(tool):
    try:
        return subprocess.run([tool, '-L', '-n'],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except OSError:
        return False

def chain_exists(tool, chain):
    return subprocess.run([tool, '-L', chain, '-n'],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def snapshot_and_zero(tool, chain):
    try:
        return subprocess.check_output([tool, '-nvxL', chain, '-Z'], text=True)
    except Exception:
        return ''

def snapshot_only(tool, chain):
    try:
        return subprocess.check_output([tool, '-nvxL', chain], text=True)
    except Exception:
        return ''

def collect_bytes(output, ports):
    import re
    totals = {str(port): {'tx': 0, 'rx': 0} for port in ports}
    patterns = []
    for port in ports:
        patterns.append((str(port), 'tx', re.compile(r'\bspt:%d(?:\D|$)' % port)))
        patterns.append((str(port), 'rx', re.compile(r'\bdpt:%d(?:\D|$)' % port)))
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            byte_count = int(parts[1])
        except ValueError:
            continue
        for key, direction, pat in patterns:
            if pat.search(line):
                totals[key][direction] += byte_count
    return totals

traffic_chain = '$TRAFFIC_CHAIN'
ports = [int(s['server_port']) for s in c['servers']]
totals = {str(port): {'tx': 0, 'rx': 0} for port in ports}

for tool in (tool for tool in ('iptables', 'ip6tables') if tool_available(tool)):
    if chain_exists(tool, traffic_chain):
        family_totals = collect_bytes(snapshot_and_zero(tool, traffic_chain), ports)
    else:
        output_totals = collect_bytes(snapshot_only(tool, 'OUTPUT'), ports)
        input_totals = collect_bytes(snapshot_only(tool, 'INPUT'), ports)
        family_totals = {}
        for port in ports:
            key = str(port)
            family_totals[key] = {
                'tx': output_totals.get(key, {}).get('tx', 0),
                'rx': input_totals.get(key, {}).get('rx', 0),
            }
    for port in ports:
        key = str(port)
        totals[key]['tx'] += family_totals.get(key, {}).get('tx', 0)
        totals[key]['rx'] += family_totals.get(key, {}).get('rx', 0)

for s in c['servers']:
    port = str(s['server_port'])
    if port not in history:
        history[port] = {'tx': 0, 'rx': 0}
    history[port]['tx'] += totals.get(port, {}).get('tx', 0)
    history[port]['rx'] += totals.get(port, {}).get('rx', 0)

traffic_dir = os.path.dirname(traffic_file)
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(traffic_file) + '.', dir=traffic_dir, text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(history, f, indent=2)
os.replace(tmp, traffic_file)
PYEOF
    then
        echo -e "${RED}❌ 保存流量数据失败${NC}"
        return 1
    fi
    if ! traffic_chains_installed; then
        PORTS=$(config_ports)
        zero_traffic_counters_for_ports "$PORTS"
    fi
    secure_data_files
}

# ========== 保存当前 iptables 计数到文件 ==========
save_traffic() {
    with_state_lock save_traffic_locked
}

save_traffic_if_unlocked() {
    # 配置操作持锁并主动保存流量时，避免 systemd/OpenRC 的停止钩子反向等待同一把锁。
    if [ -d "$STATE_LOCK_DIR" ]; then
        local LOCK_PID=""
        [ -f "$STATE_LOCK_DIR/pid" ] && LOCK_PID=$(cat "$STATE_LOCK_DIR/pid" 2>/dev/null || true)
        if [ -z "$LOCK_PID" ] || kill -0 "$LOCK_PID" 2>/dev/null; then
            return 0
        fi
        rm -f "$STATE_LOCK_DIR/pid" 2>/dev/null || true
        rmdir "$STATE_LOCK_DIR" 2>/dev/null || return 0
    fi
    save_traffic
}

show_traffic() {
    # 先同步当前 iptables 增量到历史文件，并清零计数器
    save_traffic || return 1

    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    流量统计  ${YELLOW}(单向流量，实际带宽消耗约为 x2)${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    printf "  ${CYAN}%-4s %-8s %-14s %-14s %-6s${NC}\n" "编号" "端口" "上行(GB)" "下行(GB)" "状态"
    echo -e "  ${BLUE}-------------------------------------------------${NC}"

    python3 << PYEOF
import json, os
from datetime import datetime

with open('$CONFIG') as f:
    c = json.load(f)

# 读取累计数据（已包含最新增量）
if os.path.exists('$TRAFFIC_FILE'):
    with open('$TRAFFIC_FILE') as f:
        history = json.load(f)
else:
    history = {}

for i, s in enumerate(c['servers'], 1):
    port = s['server_port']
    key  = str(port)

    total_tx = history.get(key, {}).get('tx', 0) / 1024 / 1024 / 1024
    total_rx = history.get(key, {}).get('rx', 0) / 1024 / 1024 / 1024
    last_reset = history.get(key, {}).get('reset_time', '从未重置')

    status = '暂停' if s.get('disabled') else '正常'
    color  = '\033[0;31m' if s.get('disabled') else '\033[0;32m'
    reset  = '\033[0m'
    print(f"  {i:<4} {port:<8} {total_tx:<14.2f} {total_rx:<14.2f} {color}{status}{reset}  重置: {last_reset}")
PYEOF

    echo -e "  ${BLUE}=================================================${NC}"
    echo -e "  ${YELLOW}提示: 手动重置前流量数据永久累计，不受重启影响${NC}"
}

reset_traffic_locked() {
    list_users
    read -r -p "输入要重置的用户编号 (0=全部重置): " NUM
    if ! is_uint "$NUM"; then
        echo -e "${RED}无效编号${NC}"
        return
    fi

    if [ "$NUM" = "0" ]; then
        # 只清零本脚本管理端口的内核计数器
        PORTS=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(' '.join(str(s['server_port']) for s in c['servers']))
")
        zero_traffic_counters_for_ports "$PORTS"
        # 写入归零数据并记录重置时间
        RESET_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        python3 << PYEOF
import json, os, tempfile
with open('$CONFIG') as f:
    c = json.load(f)
history = {}
for s in c['servers']:
    history[str(s['server_port'])] = {'tx': 0, 'rx': 0, 'reset_time': '$RESET_TIME'}
traffic_file = '$TRAFFIC_FILE'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(traffic_file) + '.', dir=os.path.dirname(traffic_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(history, f, indent=2)
os.replace(tmp, traffic_file)
PYEOF
        secure_data_files
        echo -e "${GREEN}✅ 所有用户流量已重置${NC}"
        return
    fi

    PORT=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
ports = [s['server_port'] for s in c['servers']]
idx = $NUM - 1
if 0 <= idx < len(ports):
    print(ports[idx])
")
    if [ -z "$PORT" ]; then echo -e "${RED}无效编号${NC}"; return; fi

    # 先把当前所有端口的增量保存到文件，再清零该端口
    save_traffic

    # 单独清零该端口的 iptables 规则计数（精确匹配）
    zero_traffic_counters_for_ports "$PORT"

    # 写入该端口归零
    RESET_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    python3 << PYEOF
import json, os, tempfile
if os.path.exists('$TRAFFIC_FILE'):
    with open('$TRAFFIC_FILE') as f:
        history = json.load(f)
else:
    history = {}
history['$PORT'] = {'tx': 0, 'rx': 0, 'reset_time': '$RESET_TIME'}
traffic_file = '$TRAFFIC_FILE'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(traffic_file) + '.', dir=os.path.dirname(traffic_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(history, f, indent=2)
os.replace(tmp, traffic_file)
PYEOF
    secure_data_files

    echo -e "${GREEN}✅ 端口 $PORT 流量已重置${NC}"
}

disable_user_locked() {
    list_users
    read -r -p "输入要暂停的用户编号: " NUM
    if ! is_uint "$NUM" || [ "$NUM" -lt 1 ]; then
        echo -e "${RED}无效编号${NC}"
        return
    fi

    PORT=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
ports = [s['server_port'] for s in c['servers']]
idx = $NUM - 1
if 0 <= idx < len(ports):
    print(ports[idx])
")
    if [ -z "$PORT" ]; then echo -e "${RED}无效编号${NC}"; return; fi

    python3 << PYEOF
import json, os, tempfile
with open('$CONFIG') as f:
    c = json.load(f)
for s in c['servers']:
    if s['server_port'] == $PORT:
        s['disabled'] = True
        break
config_file = '$CONFIG'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f, indent=2)
os.replace(tmp, config_file)
PYEOF

    apply_config || return 1
    echo -e "${YELLOW}⏸ 端口 $PORT 已暂停${NC}"
}

enable_user_locked() {
    list_users
    read -r -p "输入要恢复的用户编号: " NUM
    if ! is_uint "$NUM" || [ "$NUM" -lt 1 ]; then
        echo -e "${RED}无效编号${NC}"
        return
    fi

    PORT=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
ports = [s['server_port'] for s in c['servers']]
idx = $NUM - 1
if 0 <= idx < len(ports):
    print(ports[idx])
")
    if [ -z "$PORT" ]; then echo -e "${RED}无效编号${NC}"; return; fi

    python3 << PYEOF
import json, os, tempfile
with open('$CONFIG') as f:
    c = json.load(f)
for s in c['servers']:
    if s['server_port'] == $PORT:
        s.pop('disabled', None)
        break
config_file = '$CONFIG'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f, indent=2)
os.replace(tmp, config_file)
PYEOF

    apply_config || return 1
    echo -e "${GREEN}✅ 端口 $PORT 已恢复${NC}"
}

delete_user_locked() {
    list_users
    read -r -p "输入要删除的用户编号: " NUM
    if ! is_uint "$NUM" || [ "$NUM" -lt 1 ]; then
        echo -e "${RED}无效编号${NC}"
        return
    fi
    read -r -p "确认删除？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    PORT=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
ports = [s['server_port'] for s in c['servers']]
idx = $NUM - 1
if 0 <= idx < len(ports):
    print(ports[idx])
    ")
    if [ -z "$PORT" ]; then echo -e "${RED}无效编号${NC}"; return; fi

    # 配置仍包含待删除端口时先保存所有内核计数，避免刷新规则造成流量丢失。
    save_traffic || return 1

    if ! python3 << PYEOF
import json, os, tempfile
with open('$CONFIG') as f:
    c = json.load(f)
c['servers'] = [s for s in c['servers'] if s['server_port'] != $PORT]
config_file = '$CONFIG'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f, indent=2)
os.replace(tmp, config_file)

traffic_file = '$TRAFFIC_FILE'
try:
    with open(traffic_file) as f:
        history = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    history = {}
history.pop(str($PORT), None)
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(traffic_file) + '.', dir=os.path.dirname(traffic_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(history, f, indent=2)
os.replace(tmp, traffic_file)
PYEOF
    then
        echo -e "${RED}❌ 删除用户配置失败${NC}"
        return 1
    fi
    secure_data_files

    PORTS=$(config_ports)
    rebuild_traffic_rules "$PORTS" || {
        echo -e "${RED}❌ 重建流量规则失败${NC}"
        return 1
    }

    rebuild_links || return 1
    apply_config || return 1
    echo -e "${RED}🗑 端口 $PORT 已删除${NC}"
}

regen_users_locked() {
    echo -e "${YELLOW}>>> 重新生成所有用户密码（端口保持不变）${NC}"
    read -r -p "确认？所有密码将变更，旧链接失效 [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    METHOD=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0]['method'] if c.get('servers') else '')
")
    if [ -z "$METHOD" ]; then
        echo -e "${RED}❌ 当前没有用户，请先添加用户${NC}"
        return 1
    fi

    case $METHOD in
        *aes-128*)  KEY_LEN=16 ;;
        *aes-256*|*chacha20*) KEY_LEN=32 ;;
        *) KEY_LEN=0 ;;
    esac

    # 保留原有端口列表（读入 bash 数组）
    PORT_STR=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(' '.join(str(s['server_port']) for s in c['servers']))
")
    read -r -a PORT_LIST <<< "$PORT_STR"

    mapfile -t NAME_LIST < <(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
for s in c['servers']:
    print(s.get('name', ''))
")
    LINK_NAME_PREFIX=$(default_link_name)

    HOST=$(get_server_host 2>/dev/null) || basic_config || return 1

    USE_ACL_FLAG=$([ -f "$ACL_PATH" ] && echo true || echo false)

    generate_config || return 1
    apply_config || return 1
    init_traffic || return 1
    show_links
}

# ========== 添加新用户 ==========
rebuild_links() {
    # 根据 config.json 重建所有 SS 链接（保持端口顺序，序号重排）
    HOST=$(get_server_host 2>/dev/null) || basic_config || return 1
    local LINK_HOST DEFAULT_NAME
    LINK_HOST=$(format_ss_host "$HOST")
    DEFAULT_NAME=$(default_link_name)

    local TMP_LINKS
    TMP_LINKS=$(make_temp_for "$LINKS_FILE") || {
        echo -e "${RED}❌ 创建链接临时文件失败${NC}"
        return 1
    }
    if ! python3 - "$CONFIG" "$TMP_LINKS" "$LINK_HOST" "$DEFAULT_NAME" << 'PYEOF'
import json, base64
import sys
from urllib.parse import quote

with open(sys.argv[1]) as f:
    c = json.load(f)
lines = []
servers = c['servers']
for i, s in enumerate(servers, 1):
    userinfo = base64.b64encode(f"{s['method']}:{s['password']}".encode()).decode()
    fallback = sys.argv[4] if len(servers) == 1 else f"{sys.argv[4]}-{i}"
    name = s.get('name')
    if not isinstance(name, str) or not name.strip():
        name = fallback
    lines.append(f"ss://{userinfo}@{sys.argv[3]}:{s['server_port']}#{quote(name.strip(), safe='')}")
with open(sys.argv[2], 'w') as f:
    if lines:
        f.write('\n'.join(lines) + '\n')
PYEOF
    then
        rm -f "$TMP_LINKS"
        echo -e "${RED}❌ 重建 SS 链接失败${NC}"
        return 1
    fi
    mv "$TMP_LINKS" "$LINKS_FILE" || return 1
    secure_data_files
}

migrate_server_host_if_needed() {
    check_installed || return 0
    [ -s "$LINKS_FILE" ] || return 0
    local STORED_HOST
    STORED_HOST=$(get_server_host 2>/dev/null) || return 0
    if [[ "$STORED_HOST" == *:* ]] && ! grep -Fq "@[$STORED_HOST]:" "$LINKS_FILE"; then
        rebuild_links
    fi
}

migrate_link_names_if_needed() {
    check_installed || return 0
    local DEFAULT_NAME CHANGED
    DEFAULT_NAME=$(default_link_name)
    CHANGED=$(python3 - "$CONFIG" "$DEFAULT_NAME" << 'PYEOF'
import json
import os
import sys
import tempfile
import unicodedata

config_file, default_name = sys.argv[1:]
with open(config_file) as f:
    config = json.load(f)
servers = config.get('servers', [])
changed = False
for i, server in enumerate(servers, 1):
    name = server.get('name')
    normalized = name.strip() if isinstance(name, str) else ''
    valid = (
        isinstance(name, str)
        and 0 < len(normalized) <= 80
        and not any(unicodedata.category(ch).startswith('C') for ch in normalized)
    )
    if not valid:
        server['name'] = default_name if len(servers) == 1 else f'{default_name}-{i}'
        changed = True
    elif name != normalized:
        server['name'] = normalized
        changed = True
if changed:
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
    with os.fdopen(fd, 'w') as f:
        json.dump(config, f, indent=2, ensure_ascii=False)
    os.replace(tmp, config_file)
print('1' if changed else '0')
PYEOF
) || return 1
    if [ "$CHANGED" = "1" ]; then
        secure_data_files
        rebuild_links || return 1
        echo -e "${GREEN}✅ SS 链接名称已自动迁移${NC}"
    fi
}

add_user_locked() {
    if ! check_installed; then
        echo -e "${RED}请先安装 Shadowsocks-Rust${NC}"; return
    fi

    # 沿用现有加密方式
    METHOD=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0]['method'] if c['servers'] else '2022-blake3-aes-128-gcm')
")
    case $METHOD in
        *aes-128*)  KEY_LEN=16 ;;
        *aes-256*|*chacha20*) KEY_LEN=32 ;;
        *) KEY_LEN=0 ;;
    esac
    BIND_ADDRESS=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0].get('server', '') if c.get('servers') else '')
" 2>/dev/null)
    [ -n "$BIND_ADDRESS" ] || BIND_ADDRESS=$(server_bind_address)
    echo -e "${YELLOW}>>> 添加新用户（加密方式: ${GREEN}$METHOD${YELLOW}）${NC}"

    read -r -p "新增用户数量 [默认 1]: " ADD_COUNT
    ADD_COUNT=${ADD_COUNT:-1}
    if ! is_uint "$ADD_COUNT" || [ "$ADD_COUNT" -lt 1 ]; then
        echo -e "${RED}❌ 数量必须是正整数${NC}"; return
    fi

    echo -e "\n  1) 自动分配端口（从现有最大端口+1 顺延，跳过占用）"
    echo -e "  2) 手动指定端口"
    read -r -p "请选择 [1-2，默认1]: " ADD_MODE
    ADD_MODE=${ADD_MODE:-1}
    if [ "$ADD_MODE" != "1" ] && [ "$ADD_MODE" != "2" ]; then
        echo -e "${RED}❌ 无效的端口分配方式${NC}"
        return 1
    fi

    # 现有端口列表（用于查重）
    EXIST_PORTS=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(' '.join(str(s['server_port']) for s in c['servers']))
")

    NEW_PORTS=()
    if [ "$ADD_MODE" = "2" ]; then
        # 手动指定
        COUNT=0
        while [ $COUNT -lt "$ADD_COUNT" ]; do
            read -r -p "输入第 $((COUNT+1)) 个端口: " P
            if ! valid_port "$P"; then
                echo -e "${RED}  端口无效${NC}"; continue
            fi
            if echo "$EXIST_PORTS ${NEW_PORTS[*]}" | grep -qw "$P"; then
                echo -e "${YELLOW}  端口 $P 已存在${NC}"; continue
            fi
            if port_in_use "$P"; then
                echo -e "${YELLOW}  端口 $P 已被占用${NC}"; continue
            fi
            NEW_PORTS+=("$P")
            COUNT=$((COUNT+1))
        done
    else
        # 自动顺延
        MAX_PORT=$(echo "$EXIST_PORTS" | tr ' ' '\n' | sort -n | tail -1)
        [ -z "$MAX_PORT" ] && MAX_PORT=30000
        CURRENT=$((MAX_PORT + 1))
        while [ ${#NEW_PORTS[@]} -lt "$ADD_COUNT" ]; do
            if [ "$CURRENT" -gt 65535 ]; then
                echo -e "${RED}❌ 端口耗尽${NC}"
                return 1
            fi
            if echo "$EXIST_PORTS ${NEW_PORTS[*]}" | grep -qw "$CURRENT"; then
                CURRENT=$((CURRENT+1)); continue
            fi
            if port_in_use "$CURRENT"; then
                echo -e "  ${YELLOW}端口 $CURRENT 已占用，跳过${NC}"
            else
                NEW_PORTS+=("$CURRENT")
                echo -e "  ${GREEN}端口 $CURRENT 可用 ✓${NC}"
            fi
            CURRENT=$((CURRENT+1))
        done
    fi

    EXIST_COUNT=$(python3 -c "
import json
with open('$CONFIG') as f:
    print(len(json.load(f).get('servers', [])))
")
    DEFAULT_NAME=$(default_link_name)
    FINAL_COUNT=$((EXIST_COUNT + ADD_COUNT))
    NEW_NAMES=()
    for i in "${!NEW_PORTS[@]}"; do
        USER_NUM=$((EXIST_COUNT + i + 1))
        if [ "$FINAL_COUNT" -eq 1 ]; then
            SUGGESTED_NAME=$DEFAULT_NAME
        else
            SUGGESTED_NAME="${DEFAULT_NAME}-${USER_NUM}"
        fi
        while true; do
            read -r -p "端口 ${NEW_PORTS[$i]} 的链接名称 [默认 $SUGGESTED_NAME]: " INPUT_NAME
            INPUT_NAME=${INPUT_NAME:-$SUGGESTED_NAME}
            if NORMALIZED_NAME=$(normalize_link_name "$INPUT_NAME" 2>/dev/null); then
                NEW_NAMES+=("$NORMALIZED_NAME")
                break
            fi
            echo -e "${RED}❌ 名称不能为空、不能包含控制字符，且最多 80 个字符${NC}"
        done
    done

    # 追加到 config.json
    NEW_PORTS_STR="${NEW_PORTS[*]}"
    if ! python3 - "$CONFIG" "$METHOD" "$KEY_LEN" "$BIND_ADDRESS" "$ADD_COUNT" "${NEW_PORTS[@]}" "${NEW_NAMES[@]}" << 'PYEOF'
import json, os, subprocess, tempfile
import sys

config_file, method, key_len, bind_address, count = sys.argv[1:6]
count = int(count)
key_len = int(key_len)
new_ports = sys.argv[6:6 + count]
new_names = sys.argv[6 + count:6 + count * 2]
if len(new_ports) != count or len(new_names) != count:
    raise SystemExit('port/name argument count mismatch')

with open(config_file) as f:
    c = json.load(f)

def gen_pass():
    raw = subprocess.check_output(['openssl', 'rand', '-base64', str(key_len if key_len > 0 else 32)], text=True).strip()
    if key_len > 0:
        return raw
    return raw.replace('=', '')[:24]

for p, name in zip(new_ports, new_names):
    c['servers'].append({
        'server': bind_address,
        'server_port': int(p),
        'password': gen_pass(),
        'method': method,
        'mode': 'tcp_and_udp',
        'name': name,
    })

fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f, indent=2, ensure_ascii=False)
os.replace(tmp, config_file)
print(f"✅ 已添加 {len(new_ports)} 个新用户")
PYEOF
    then
        echo -e "${RED}❌ 写入新用户配置失败${NC}"
        return 1
    fi
    secure_data_files

    add_traffic_rules_for_new_ports "$NEW_PORTS_STR" || {
        echo -e "${RED}❌ 添加流量统计规则失败${NC}"
        return 1
    }

    rebuild_links || return 1
    apply_config || return 1
    show_links
    echo -e "${GREEN}✅ 新用户添加完成${NC}"
}

reset_traffic() {
    with_state_lock reset_traffic_locked
}

disable_user() {
    with_state_lock disable_user_locked
}

enable_user() {
    with_state_lock enable_user_locked
}

delete_user() {
    with_state_lock delete_user_locked
}

regen_users() {
    with_state_lock regen_users_locked
}

add_user() {
    with_state_lock add_user_locked
}

rename_user_locked() {
    list_users
    read -r -p "输入要修改名称的用户编号: " NUM
    if ! is_uint "$NUM" || [ "$NUM" -lt 1 ]; then
        echo -e "${RED}无效编号${NC}"
        return 1
    fi

    CURRENT_NAME=$(python3 - "$CONFIG" "$NUM" << 'PYEOF'
import json
import sys

with open(sys.argv[1]) as f:
    servers = json.load(f).get('servers', [])
idx = int(sys.argv[2]) - 1
if 0 <= idx < len(servers):
    print(servers[idx].get('name', ''))
PYEOF
)
    if [ -z "$CURRENT_NAME" ]; then
        echo -e "${RED}无效编号${NC}"
        return 1
    fi

    while true; do
        read -r -p "新名称 [当前: $CURRENT_NAME]: " INPUT_NAME
        INPUT_NAME=${INPUT_NAME:-$CURRENT_NAME}
        if NEW_NAME=$(normalize_link_name "$INPUT_NAME" 2>/dev/null); then
            break
        fi
        echo -e "${RED}❌ 名称不能为空、不能包含控制字符，且最多 80 个字符${NC}"
    done

    if ! python3 - "$CONFIG" "$NUM" "$NEW_NAME" << 'PYEOF'
import json
import os
import sys
import tempfile

config_file, number, name = sys.argv[1:]
with open(config_file) as f:
    config = json.load(f)
idx = int(number) - 1
if not 0 <= idx < len(config.get('servers', [])):
    raise SystemExit(1)
config['servers'][idx]['name'] = name
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(config, f, indent=2, ensure_ascii=False)
os.replace(tmp, config_file)
PYEOF
    then
        echo -e "${RED}❌ 修改用户名称失败${NC}"
        return 1
    fi
    secure_data_files
    rebuild_links || return 1
    echo -e "${GREEN}✅ 用户名称已修改为: $NEW_NAME${NC}"
}

rename_user() {
    with_state_lock rename_user_locked
}

# ========== 更新脚本 ==========
do_update() {
    REMOTE_PATH="chnnic/VOLSS/refs/heads/main/volss.sh"
    TMP_DIR=$(mktemp -d /tmp/volss-update.XXXXXX) || {
        echo -e "${RED}❌ 创建临时目录失败${NC}"
        return 1
    }
    TMP_NEW="$TMP_DIR/volss_new.sh"

    echo -e "\n${YELLOW}>>> 检查更新...${NC}"

    # 默认只使用官方源；如确需第三方镜像，可显式设置 VOLSS_ALLOW_THIRD_PARTY_MIRRORS=1
    UPDATE_BASES=("https://raw.githubusercontent.com")
    if third_party_mirrors_enabled; then
        UPDATE_BASES+=("https://raw.gitmirror.com" "https://gh.api.99988866.xyz/https://raw.githubusercontent.com")
    fi
    DL_OK=0
    for BASE in "${UPDATE_BASES[@]}"; do
        if fetch_url "$BASE/$REMOTE_PATH" "$TMP_NEW" 25 && bash -n "$TMP_NEW" 2>/dev/null && grep -q '^VERSION="V' "$TMP_NEW"; then
            DL_OK=1
            break
        fi
    done

    if [ "$DL_OK" -ne 1 ]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 GitHub 地址${NC}"
        rm -rf "$TMP_DIR"
        return 1
    fi

    # 获取远程版本号
    REMOTE_VER=$(grep '^VERSION=' "$TMP_NEW" | cut -d'"' -f2)
    LOCAL_VER=$VERSION

    echo -e "本地版本: ${YELLOW}$LOCAL_VER${NC}"
    echo -e "远程版本: ${GREEN}$REMOTE_VER${NC}"

    if [ "$REMOTE_VER" = "$LOCAL_VER" ]; then
        echo -e "${GREEN}✅ 已是最新版本，无需更新${NC}"
        rm -rf "$TMP_DIR"
        return 0
    fi

    read -r -p "发现新版本 $REMOTE_VER，确认更新？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -rf "$TMP_DIR"
        return
    fi

    # 备份当前脚本
    cp "$SCRIPT_INSTALL_PATH" "${SCRIPT_INSTALL_PATH}.bak" 2>/dev/null
    echo -e "已备份当前脚本至: ${YELLOW}${SCRIPT_INSTALL_PATH}.bak${NC}"

    # 替换脚本到固定路径
    mv "$TMP_NEW" "$SCRIPT_INSTALL_PATH"
    chmod +x "$SCRIPT_INSTALL_PATH"
    rm -rf "$TMP_DIR"

    # 更新快捷命令（仅当是 volss 自己的快捷命令时才更新）
    if [ ! -f "$SHORTCUT" ] || grep -q "volss" "$SHORTCUT" 2>/dev/null; then
        cat > $SHORTCUT << EOF
#!/bin/bash
bash $SCRIPT_INSTALL_PATH --menu
EOF
        chmod +x $SHORTCUT
    fi

    echo -e "${GREEN}✅ 更新完成！已从 $LOCAL_VER 更新到 $REMOTE_VER${NC}"

    # 自动迁移修复（兼容旧版配置）
    if [ -f "$CONFIG" ]; then
        echo -e "\n${YELLOW}>>> 自动修复旧版配置...${NC}"
        python3 << PYEOF
import json, os, tempfile

config_file = '$CONFIG'
runtime_file = '$RUNTIME'
acl_path = '$ACL_PATH'

with open(config_file) as f:
    c = json.load(f)

changed = False

# 检查 server 块里是否有 acl 字段（旧版写法），迁移到顶层
for s in c['servers']:
    if 'acl' in s:
        s.pop('acl')
        changed = True

# 如果 ACL 文件存在但顶层没有配置，自动补上
if os.path.exists(acl_path) and c.get('acl') != acl_path:
    c['acl'] = acl_path
    changed = True

if changed:
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
    with os.fdopen(fd, 'w') as f:
        json.dump(c, f, indent=2)
    os.replace(tmp, config_file)
    print("✅ config.json 已迁移")

# 重新生成 runtime
servers = [dict(s) for s in c['servers'] if not s.get('disabled', False)]
for s in servers:
    s.pop('disabled', None)
    s.pop('acl', None)
    s.pop('name', None)

runtime = {'servers': servers}
if os.path.exists(acl_path):
    runtime['acl'] = acl_path

fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(runtime_file) + '.', dir=os.path.dirname(runtime_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(runtime, f, indent=2)
os.replace(tmp, runtime_file)
print("✅ runtime.json 已更新")
PYEOF

        harden_service_if_needed

        # 修复旧版 ACL 格式（domain-suffix: → ||，移除 ssserver 不使用的本地 ACL 段）
        if [ -f "$ACL_PATH" ]; then
            sed -i 's/^domain-suffix:/||/' $ACL_PATH
            sed -i '/^\[bypass_list\]$/d' $ACL_PATH
            sed -i '/^\[proxy_list\]$/d' $ACL_PATH
            sed -i '/^$/d' $ACL_PATH
            # 确保文件以 [outbound_block_list] 开头
            if ! grep -q "^\[outbound_block_list\]" $ACL_PATH; then
                sed -i '1i [outbound_block_list]' $ACL_PATH
            fi
            echo -e "${GREEN}✅ ACL 格式已自动修复${NC}"
        fi

        # 强制重新生成 runtime.json 确保 ACL 字段正确写入
        apply_config || return 1
        echo -e "${GREEN}✅ runtime.json 已同步${NC}"

        # 补全旧配置缺失的 mode 字段
        python3 << PYEOF
import json
changed = False
for f in ['$CONFIG', '$RUNTIME']:
    try:
        with open(f) as fp:
            c = json.load(fp)
        for s in c.get('servers', []):
            if 'mode' not in s:
                s['mode'] = 'tcp_and_udp'
                changed = True
        with open(f, 'w') as fp:
            json.dump(c, fp, indent=2)
    except:
        pass
if changed:
    print("✅ mode 字段已补全（TCP+UDP）")
PYEOF

        if [ "$SYSTEM" != "alpine" ] && grep -q "Restart=on-failure" $SERVICE 2>/dev/null; then
            sed -i 's/Restart=on-failure/Restart=always/' $SERVICE
            echo -e "${GREEN}✅ 服务文件已修复${NC}"
        fi

        svc_reload
        svc_restart
        echo -e "${GREEN}✅ 服务已重启${NC}"
    fi

    echo -e "\n${YELLOW}脚本将重新启动...${NC}"
    sleep 2
    exec bash "$SCRIPT_INSTALL_PATH" --menu
}

add_acl_domain_locked() {
    read -r -p "输入要屏蔽的域名: " NEW_DOMAIN
    if [ -n "$NEW_DOMAIN" ]; then
        NEW_DOMAIN=$(normalize_domain "$NEW_DOMAIN")
        if ! valid_domain "$NEW_DOMAIN"; then
            echo -e "${RED}域名格式无效${NC}"
            return
        fi
        # 检查是否已存在
        if grep -Fqx -- "$NEW_DOMAIN" "$MANUAL_FILE" 2>/dev/null; then
            echo -e "${YELLOW}⚠ $NEW_DOMAIN 已存在${NC}"
            return
        fi
        echo "$NEW_DOMAIN" >> "$MANUAL_FILE"
        secure_file "$MANUAL_FILE"
        rebuild_acl || return 1
        echo -e "${GREEN}✅ 已添加: $NEW_DOMAIN（含所有子域名）${NC}"
    fi
}

del_acl_domain_locked() {
    if [ ! -f "$MANUAL_FILE" ] || [ ! -s "$MANUAL_FILE" ]; then
        echo -e "${YELLOW}没有手动添加的域名${NC}"; return
    fi

    mapfile -t MANUAL_ARR < "$MANUAL_FILE"

    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    手动添加的域名${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    for i in "${!MANUAL_ARR[@]}"; do
        echo "    $((i+1))) ${MANUAL_ARR[$i]}"
    done
    echo -e "  ${BLUE}=================================================${NC}"

    read -r -p "输入要删除的编号（多个用逗号分隔，如 1,3,5）: " INPUT

    IFS=',' read -ra NUMS <<< "$INPUT"
    DELETED=0
    # 收集要删除的域名
    declare -a TO_DELETE
    for NUM in "${NUMS[@]}"; do
        NUM=$(echo "$NUM" | tr -d ' ')
        [ -z "$NUM" ] && continue
        if ! is_uint "$NUM"; then
            echo -e "${RED}编号 $NUM 无效，跳过${NC}"
            continue
        fi
        IDX=$((NUM-1))
        if [ $IDX -lt 0 ] || [ $IDX -ge ${#MANUAL_ARR[@]} ]; then
            echo -e "${RED}编号 $NUM 无效，跳过${NC}"
            continue
        fi
        TO_DELETE+=("${MANUAL_ARR[$IDX]}")
        echo -e "${GREEN}✅ 已删除: ${MANUAL_ARR[$IDX]}${NC}"
        DELETED=$((DELETED+1))
    done

    if [ "$DELETED" -gt 0 ]; then
        # 从 manual.list 删除对应行
        for DOMAIN in "${TO_DELETE[@]}"; do
            TMP_MANUAL=$(make_temp_for "$MANUAL_FILE") || {
                echo -e "${RED}❌ 创建手动列表临时文件失败${NC}"
                return
            }
            grep -Fvx -- "$DOMAIN" "$MANUAL_FILE" > "$TMP_MANUAL"
            mv "$TMP_MANUAL" "$MANUAL_FILE"
        done
        secure_file "$MANUAL_FILE"
        rebuild_acl || return 1
        echo -e "${GREEN}✅ 共删除 $DELETED 条，服务已重启${NC}"
    fi
}

add_acl_domain() {
    with_state_lock add_acl_domain_locked
}

del_acl_domain() {
    with_state_lock del_acl_domain_locked
}

# ========== ACL 规则集管理 ==========
ACL_RULESET_DIR="/etc/shadowsocks-rust/rulesets"

# 规则集定义：名称|描述|来源URL列表（逗号分隔，按顺序回退）
declare -A RULESET_URLS
RULESET_URLS=(
    ["ads"]="广告拦截|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Ads"
    ["adult"]="色情网站|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Adult"
    ["gambling"]="赌博网站|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Gambling"
    ["malware"]="恶意软件|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Malware"
    ["scam"]="诈骗欺诈|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Scam"
    ["tracking"]="追踪统计|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Tracking"
    ["crypto"]="挖矿劫持|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Cryptocurrency,https://raw.githubusercontent.com/blocklistproject/Lists/master/crypto.txt"
    ["dating"]="交友网站|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Dating"
    ["bt"]="BT下载|https://raw.githubusercontent.com/blocklistproject/Lists/master/torrent.txt,https://raw.githubusercontent.com/blocklistproject/Lists/master/piracy.txt"
    ["finance"]="金融理财|https://raw.githubusercontent.com/blocklistproject/Lists/master/fraud.txt,https://raw.githubusercontent.com/blocklistproject/Lists/master/phishing.txt"
)

# GitHub 镜像列表，下载失败时自动切换
GITHUB_MIRRORS=("https://raw.githubusercontent.com")
if third_party_mirrors_enabled; then
    GITHUB_MIRRORS+=(
        "https://raw.gitmirror.com"
        "https://raw.fastgit.org"
        "https://gh.api.99988866.xyz/https://raw.githubusercontent.com"
    )
fi

# 初始化规则集目录
init_ruleset_dir() {
    mkdir -p $ACL_RULESET_DIR
    [ ! -f "$ACL_RULESET_DIR/installed.txt" ] && touch "$ACL_RULESET_DIR/installed.txt"
}

# 将 URL 替换为镜像地址
mirror_url() {
    local URL=$1
    local MIRROR=$2
    echo "${URL/https:\/\/raw.githubusercontent.com/$MIRROR}"
}

# 下载 URL 到指定文件。优先 wget，失败后回退 curl，兼容不同系统网络栈。
fetch_url() {
    local URL=$1
    local OUT=$2
    local TIMEOUT=${3:-20}
    rm -f "$OUT"
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout="$TIMEOUT" -O "$OUT" "$URL" 2>/dev/null && [ -s "$OUT" ] && return 0
    fi
    rm -f "$OUT"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time "$TIMEOUT" -o "$OUT" "$URL" 2>/dev/null && [ -s "$OUT" ] && return 0
    fi
    rm -f "$OUT"
    return 1
}

# 下载并转换规则集为 ss-rust ACL 格式
download_ruleset() {
    local NAME=$1
    local URLS=$2
    if ! valid_ruleset_name "$NAME"; then
        echo -e "  ${RED}❌ 规则集名称只能包含英文、数字、下划线和中划线${NC}"
        return 1
    fi
    local TMP_DIR
    TMP_DIR=$(mktemp -d /tmp/volss-ruleset.XXXXXX) || {
        echo -e "  ${RED}❌ 创建临时目录失败${NC}"
        return 1
    }
    local TMP="$TMP_DIR/ruleset.tmp"
    local TMP_OUT="$TMP_DIR/${NAME}.acl"
    local OUT="$ACL_RULESET_DIR/${NAME}.acl"

    echo -e "  ${YELLOW}下载中: $NAME ...${NC}"

    # 依次尝试候选源与镜像
    local SUCCESS=0
    local BASE_URL TRY_URL MIRROR
    IFS=',' read -r -a BASE_URLS <<< "$URLS"
    for BASE_URL in "${BASE_URLS[@]}"; do
        [ -n "$BASE_URL" ] || continue
        if [[ "$BASE_URL" == https://raw.githubusercontent.com/* ]]; then
            for MIRROR in "${GITHUB_MIRRORS[@]}"; do
                TRY_URL=$(mirror_url "$BASE_URL" "$MIRROR")
                if fetch_url "$TRY_URL" "$TMP"; then
                    SUCCESS=1
                    break 2
                fi
            done
        else
            if fetch_url "$BASE_URL" "$TMP"; then
                SUCCESS=1
                break
            fi
        fi
    done

    if [ $SUCCESS -eq 0 ]; then
        rm -rf "$TMP_DIR"
        echo -e "  ${RED}❌ 下载失败: $NAME（所有镜像均不可用）${NC}"
        return 1
    fi

    # 转换格式：兼容纯域名、hosts、AdGuard/ACL 常见写法，输出 ss-rust ACL 域名规则
    awk '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        {
            sub(/\r$/, "")
            line = trim($0)
            if (line == "" || line ~ /^#/) next
            sub(/[[:space:]]+#.*$/, "", line)
            if (line ~ /^(0\.0\.0\.0|127\.0\.0\.1|::1)[[:space:]]+/) {
                split(line, fields, /[[:space:]]+/)
                line = fields[2]
            }
            sub(/^\|\|/, "", line)
            sub(/\^$/, "", line)
            sub(/^domain-suffix:/, "", line)
            sub(/^\*\./, "", line)
            if (line ~ /^[A-Za-z0-9._-]+$/ && line ~ /\./) print "||" line
        }
    ' "$TMP" | LC_ALL=C sort -u > "$TMP_OUT"
    COUNT=$(wc -l < "$TMP_OUT")
    if [ "$COUNT" -eq 0 ]; then
        rm -rf "$TMP_DIR"
        echo -e "  ${RED}❌ 下载失败: $NAME（未解析到有效域名规则，已保留旧规则）${NC}"
        return 1
    fi
    mv "$TMP_OUT" "$OUT"
    chmod 600 "$OUT" 2>/dev/null || true
    rm -rf "$TMP_DIR"
    echo -e "  ${GREEN}✅ $NAME 已下载，共 $COUNT 条规则${NC}"
    return 0
}

# 重新合并所有规则集到 ACL 文件
rebuild_acl() {
    init_ruleset_dir || return 1

    local TMP_ACL
    TMP_ACL=$(make_temp_for "$ACL_PATH") || {
        echo -e "${RED}❌ 创建 ACL 临时文件失败${NC}"
        return 1
    }

    # 重建 ACL 文件，从 [outbound_block_list] 开始
    echo "[outbound_block_list]" > "$TMP_ACL" || return 1

    # 写入手动域名（从 manual.list 读取，纯净格式无标记）
    if [ -f "$MANUAL_FILE" ] && [ -s "$MANUAL_FILE" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "||$line" >> "$TMP_ACL"
        done < "$MANUAL_FILE"
    fi

    # 写入各规则集
    for RULESET_FILE in "$ACL_RULESET_DIR"/*.acl; do
        [ -f "$RULESET_FILE" ] || continue
        cat "$RULESET_FILE" >> "$TMP_ACL"
    done

    mv "$TMP_ACL" "$ACL_PATH" || return 1
    secure_data_files

    # 既有安装首次启用 ACL 时，同步持久配置和运行配置，确保立即生效。
    if [ -f "$CONFIG" ]; then
        if ! python3 << PYEOF
import json, os, tempfile

config_file = '$CONFIG'
with open(config_file) as f:
    config = json.load(f)
config['acl'] = '$ACL_PATH'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(config, f, indent=2)
os.replace(tmp, config_file)
PYEOF
        then
            echo -e "${RED}❌ 更新 ACL 配置失败${NC}"
            return 1
        fi
        apply_config || return 1
    fi
}

# 显示规则集菜单
manage_rulesets_locked() {
    init_ruleset_dir

    while true; do
        echo -e "\n${BLUE}  =================================================${NC}"
        echo -e "${BLUE}    ACL 规则集管理${NC}"
        echo -e "${BLUE}  =================================================${NC}"

        # 显示所有可用规则集和安装状态
        local i=1
        local KEYS=("ads" "adult" "gambling" "malware" "scam" "tracking" "crypto" "dating" "bt" "finance")
        for KEY in "${KEYS[@]}"; do
            IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
            if [ -f "$ACL_RULESET_DIR/${KEY}.acl" ]; then
                COUNT=$(wc -l < "$ACL_RULESET_DIR/${KEY}.acl")
                STATUS="${GREEN}● 已安装 ($COUNT 条)${NC}"
            else
                STATUS="${RED}○ 未安装${NC}"
            fi
            # 中文字符占2列宽，手动补空格对齐
            # 用字节数和字符数的差值计算中文字符数（UTF-8 中文占3字节，差值/2=中文数）
            DESC_LEN=${#DESC}
            DESC_BYTES=$(printf '%s' "$DESC" | wc -c)
            CN_CHARS=$(( (DESC_BYTES - DESC_LEN) / 2 ))
            PAD=$((10 - DESC_LEN - CN_CHARS))
            [ "$PAD" -lt 0 ] && PAD=0
            SPACES=$(printf '%*s' "$PAD" '')
            printf "  \033[0;32m%2d)\033[0m %-12s %s%s %b\n" "$i" "$KEY" "$DESC" "$SPACES" "$STATUS"
            i=$((i+1))
        done

        echo -e "  ${BLUE}-------------------------------------------------${NC}"
        echo -e "  ${GREEN}11)${NC} 安装全部规则集"
        echo -e "  ${GREEN}12)${NC} 卸载某个规则集"
        echo -e "  ${GREEN}13)${NC} 更新已安装规则集"
        echo -e "  ${GREEN}14)${NC} 添加自定义规则集 URL"
        echo -e "  ${GREEN}15)${NC} 查看当前生效规则数量"
        echo -e "  ${RED} 0)${NC} 返回主菜单"
        echo -e "${BLUE}  =================================================${NC}"
        read -r -p "  请选择: " CHOICE

        case $CHOICE in
            [1-9]|10)
                local IDX=$((CHOICE-1))
                local KEY="${KEYS[$IDX]}"
                IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
                if [ -f "$ACL_RULESET_DIR/${KEY}.acl" ]; then
                    echo -e "${YELLOW}$DESC 已安装，重新下载更新？[y/N]${NC}"
                    read -r -p "" CONFIRM
                    [[ ! "$CONFIRM" =~ ^[Yy]$ ]] && continue
                fi
                if download_ruleset "$KEY" "$URL"; then
                    rebuild_acl || echo -e "${RED}❌ 规则已下载，但应用 ACL 失败${NC}"
                fi
                ;;
            11)
                echo -e "${YELLOW}>>> 安装全部规则集...${NC}"
                local KEYS=("ads" "adult" "gambling" "malware" "scam" "tracking" "crypto" "dating" "bt" "finance")
                local OK=0 FAIL=0
                local FAILED_RULESETS=()
                for KEY in "${KEYS[@]}"; do
                    IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
                    if download_ruleset "$KEY" "$URL"; then
                        OK=$((OK + 1))
                    else
                        FAIL=$((FAIL + 1))
                        FAILED_RULESETS+=("$KEY")
                    fi
                done
                if [ "$OK" -gt 0 ] && ! rebuild_acl; then
                    echo -e "${RED}❌ 规则集已下载，但应用 ACL 失败${NC}"
                    FAIL=$((FAIL + 1))
                fi
                if [ "$FAIL" -eq 0 ]; then
                    echo -e "${GREEN}✅ 全部规则集安装完成（成功 $OK 个）${NC}"
                elif [ "$OK" -gt 0 ]; then
                    echo -e "${YELLOW}⚠ 规则集部分安装完成：成功 $OK 个，失败 $FAIL 个（${FAILED_RULESETS[*]}）${NC}"
                else
                    echo -e "${RED}❌ 没有规则集安装成功，请检查网络或源地址${NC}"
                fi
                ;;
            12)
                echo -e "\n已安装的规则集："
                INSTALLED_ARR=()
                for f in "$ACL_RULESET_DIR"/*.acl; do
                    [ -f "$f" ] || continue
                    INSTALLED_ARR+=("$(basename "$f" .acl)")
                done
                if [ ${#INSTALLED_ARR[@]} -eq 0 ]; then
                    echo -e "${YELLOW}没有已安装的规则集${NC}"
                else
                    for i in "${!INSTALLED_ARR[@]}"; do
                        echo "  $((i+1))) ${INSTALLED_ARR[$i]}"
                    done
                    read -r -p "输入要卸载的编号: " DEL_IDX
                    IDX=$((DEL_IDX - 1))
                    if [ $IDX -ge 0 ] && [ $IDX -lt ${#INSTALLED_ARR[@]} ]; then
                        DEL_NAME="${INSTALLED_ARR[$IDX]}"
                        rm -f "$ACL_RULESET_DIR/${DEL_NAME}.acl"
                        if rebuild_acl; then
                            echo -e "${GREEN}✅ 已卸载: $DEL_NAME${NC}"
                        else
                            echo -e "${RED}❌ 规则集文件已删除，但应用 ACL 失败${NC}"
                        fi
                    else
                        echo -e "${RED}无效编号${NC}"
                    fi
                fi
                ;;
            13)
                echo -e "${YELLOW}>>> 更新已安装规则集...${NC}"
                local OK=0 FAIL=0 SKIP=0
                local FAILED_RULESETS=()
                local SKIPPED_RULESETS=()
                for RULESET_FILE in "$ACL_RULESET_DIR"/*.acl; do
                    [ -f "$RULESET_FILE" ] || continue
                    KEY=$(basename "$RULESET_FILE" .acl)
                    if [ -n "${RULESET_URLS[$KEY]}" ]; then
                        IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
                        if download_ruleset "$KEY" "$URL"; then
                            OK=$((OK + 1))
                        else
                            FAIL=$((FAIL + 1))
                            FAILED_RULESETS+=("$KEY")
                        fi
                    else
                        SKIP=$((SKIP + 1))
                        SKIPPED_RULESETS+=("$KEY")
                    fi
                done
                if [ "$OK" -gt 0 ] && ! rebuild_acl; then
                    echo -e "${RED}❌ 规则集已更新，但应用 ACL 失败${NC}"
                    FAIL=$((FAIL + 1))
                fi
                if [ "$OK" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "$SKIP" -eq 0 ]; then
                    echo -e "${YELLOW}没有已安装的规则集${NC}"
                elif [ "$FAIL" -eq 0 ]; then
                    echo -e "${GREEN}✅ 更新完成（成功 $OK 个）${NC}"
                elif [ "$OK" -gt 0 ]; then
                    echo -e "${YELLOW}⚠ 规则集部分更新完成：成功 $OK 个，失败 $FAIL 个（${FAILED_RULESETS[*]}，已保留旧规则）${NC}"
                else
                    echo -e "${RED}❌ 已安装规则集更新失败（${FAILED_RULESETS[*]}，已保留旧规则）${NC}"
                fi
                [ "$SKIP" -gt 0 ] && echo -e "${YELLOW}⚠ 已跳过自定义规则集（未保存 URL，暂不能自动更新）: ${SKIPPED_RULESETS[*]}${NC}"
                ;;
            14)
                read -r -p "规则集名称 (英文，如 mylist): " CUSTOM_NAME
                read -r -p "规则集 URL: " CUSTOM_URL
                if ! valid_ruleset_name "$CUSTOM_NAME"; then
                    echo -e "${RED}规则集名称只能包含英文、数字、下划线和中划线${NC}"
                elif [[ ! "$CUSTOM_URL" =~ ^https?:// ]]; then
                    echo -e "${RED}规则集 URL 必须以 http:// 或 https:// 开头${NC}"
                elif [ -n "$CUSTOM_NAME" ] && [ -n "$CUSTOM_URL" ]; then
                    RULESET_URLS["$CUSTOM_NAME"]="自定义|$CUSTOM_URL"
                    if download_ruleset "$CUSTOM_NAME" "$CUSTOM_URL"; then
                        rebuild_acl || echo -e "${RED}❌ 规则已下载，但应用 ACL 失败${NC}"
                    fi
                fi
                ;;
            15)
                echo -e "\n${BLUE}  =================================================${NC}"
                echo -e "${BLUE}    当前生效规则统计${NC}"
                echo -e "${BLUE}  =================================================${NC}"
                if [ -f "$ACL_PATH" ]; then
                    TOTAL=$(grep -c "^||" "$ACL_PATH")
                    echo -e "  总规则数: ${GREEN}$TOTAL 条${NC}"
                    echo ""
                    for RULESET_FILE in "$ACL_RULESET_DIR"/*.acl; do
                        [ -f "$RULESET_FILE" ] || continue
                        NAME=$(basename "$RULESET_FILE" .acl)
                        COUNT=$(wc -l < "$RULESET_FILE")
                        printf "  %-15s %s 条\n" "$NAME" "$COUNT"
                    done
                    MANUAL=$(manual_domain_count)
                    [ "$MANUAL" -gt 0 ] && printf "  %-15s %s 条\n" "手动添加" "$MANUAL"
                else
                    echo -e "  未配置 ACL"
                fi
                echo -e "${BLUE}  =================================================${NC}"
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
        read -r -p "按回车继续..."
    done
}

manage_rulesets() {
    with_state_lock manage_rulesets_locked
}


# =============================================
#   主菜单
# =============================================

show_main_menu() {
    while true; do
        print_banner

        # 状态检测
        if check_installed; then
            SS_STATUS="${GREEN}● 已安装${NC}"
            if check_svc_running; then
                SVC_LABEL="${GREEN}● 运行中${NC}"
            else
                SVC_LABEL="${RED}● 已停止${NC}"
            fi
        else
            SS_STATUS="${RED}● 未安装${NC}"
            SVC_LABEL="${RED}● 未运行${NC}"
        fi

        # 获取时间差（缓存 60 秒避免每次刷新都请求网络）
        if [ -z "$LAST_TIME_CHECK" ] || [ $(($(date +%s) - LAST_TIME_CHECK)) -gt 60 ]; then
            TIME_DIFF=$(get_time_diff)
            LAST_TIME_CHECK=$(date +%s)
        fi
        TIME_STATUS=$(format_time_diff "$TIME_DIFF")

        echo -e "  ${BLUE}=================================================${NC}"
        echo -e "    Shadowsocks-Rust 管理脚本    ${VERSION}    快捷命令: volss"
        echo -e "  ${BLUE}=================================================${NC}"
        printf "    安装: %-20b 服务: %-20b\n" "$SS_STATUS" "$SVC_LABEL"
        printf "    时间: %b\n" "$TIME_STATUS"
        echo -e "  ${BLUE}-------------------------------------------------${NC}"
        echo -e "  ${CYAN}  -- 安装管理 --${NC}"
        echo -e "      1)  安装 Shadowsocks-Rust"
        echo -e "      2)  卸载 Shadowsocks-Rust"
        echo -e "      3)  更新脚本"
        echo -e "  ${CYAN}  -- 用户管理 --${NC}"
        echo -e "      4)  查看用户列表"
        echo -e "      5)  查看所有 SS 链接"
        echo -e "      6)  添加新用户"
        echo -e "      7)  暂停某个用户"
        echo -e "      8)  恢复某个用户"
        echo -e "      9)  删除某个用户"
        echo -e "     10)  重新生成所有用户"
        echo -e "     23)  修改用户名称"
        echo -e "  ${CYAN}  -- 流量统计 --${NC}"
        echo -e "     11)  查看流量统计"
        echo -e "     12)  重置流量统计"
        echo -e "  ${CYAN}  -- ACL 黑名单 --${NC}"
        echo -e "     13)  手动添加屏蔽域名"
        echo -e "     14)  手动删除屏蔽域名"
        echo -e "     15)  查看黑名单列表"
        echo -e "     16)  规则集管理（广告/色情/赌博/BT等）"
        echo -e "  ${CYAN}  -- 服务管理 --${NC}"
        echo -e "     17)  查看服务状态"
        echo -e "     18)  启动服务"
        echo -e "     19)  停止服务"
        echo -e "     20)  重启服务"
        echo -e "     21)  查看实时日志"
        echo -e "     22)  时间同步"
        echo -e "  ${BLUE}-------------------------------------------------${NC}"
        echo -e "   ${RED}  0)  退出${NC}"
        echo -e "  ${BLUE}=================================================${NC}"
        read -r -p "  请选择 [0-23]: " CHOICE

        # 未安装时拦截管理功能
        if ! check_installed && [[ "$CHOICE" =~ ^([4-9]|1[0-9]|2[0-3])$ ]]; then
            echo -e "${RED}⚠ 请先安装 Shadowsocks-Rust（选项 1）${NC}"
            sleep 2
            continue
        fi

        case $CHOICE in
            1)  do_install ;;
            2)  do_uninstall ;;
            3)  do_update ;;
            4)  list_users;    read -r -p "按回车继续..." ;;
            5)  show_links;    read -r -p "按回车继续..." ;;
            6)  add_user;      read -r -p "按回车继续..." ;;
            7)  disable_user;  read -r -p "按回车继续..." ;;
            8)  enable_user;   read -r -p "按回车继续..." ;;
            9)  delete_user;   read -r -p "按回车继续..." ;;
            10) regen_users;   read -r -p "按回车继续..." ;;
            23) rename_user;   read -r -p "按回车继续..." ;;
            11) show_traffic;  read -r -p "按回车继续..." ;;
            12) reset_traffic; read -r -p "按回车继续..." ;;
            13) add_acl_domain; read -r -p "按回车继续..." ;;
            14) del_acl_domain; read -r -p "按回车继续..." ;;
            15)
                echo -e "\n${BLUE}  =================================================${NC}"
                echo -e "${BLUE}    ACL 黑名单${NC}"
                echo -e "${BLUE}  =================================================${NC}"
                if [ -f "$ACL_PATH" ]; then
                    TOTAL=$(grep -c "^||" "$ACL_PATH")
                    MANUAL_COUNT=$(manual_domain_count)
                    RULESET_COUNT=$((TOTAL - MANUAL_COUNT))
                    [ "$RULESET_COUNT" -lt 0 ] && RULESET_COUNT=0
                    echo -e "  总规则数: ${GREEN}$TOTAL 条${NC}（手动: $MANUAL_COUNT 条，规则集: $RULESET_COUNT 条）"

                    echo -e "\n  ${CYAN}── 手动添加 ($MANUAL_COUNT 条) ──${NC}"
                    if [ -f "$MANUAL_FILE" ] && [ -s "$MANUAL_FILE" ]; then
                        i=1
                        while IFS= read -r line; do
                            [ -z "$line" ] && continue
                            echo "    $i) $line"
                            i=$((i+1))
                        done < "$MANUAL_FILE"
                    else
                        echo "  （无）"
                    fi

                    echo -e "\n  ${CYAN}── 已安装规则集 ──${NC}"
                    FOUND=0
                    if [ -d "$ACL_RULESET_DIR" ]; then
                        for f in "$ACL_RULESET_DIR"/*.acl; do
                            [ -f "$f" ] || continue
                            NAME=$(basename "$f" .acl)
                            COUNT=$(wc -l < "$f")
                            echo -e "  ${GREEN}●${NC} $NAME ($COUNT 条)  ${YELLOW}[查看详情请进入选项 16]${NC}"
                            FOUND=1
                        done
                    fi
                    [ "$FOUND" -eq 0 ] && echo "  （未安装任何规则集，请选择选项 16 安装）"
                else
                    echo "  未配置 ACL"
                fi
                read -r -p "按回车继续..."
                ;;
            16) manage_rulesets ;;
            17) svc_status; read -r -p "按回车继续..." ;;
            18) svc_start   && echo -e "${GREEN}✅ 服务已启动${NC}"; read -r -p "按回车继续..." ;;
            19) svc_stop    && echo -e "${YELLOW}⏹ 服务已停止${NC}"; read -r -p "按回车继续..." ;;
            20) svc_restart && echo -e "${GREEN}🔄 服务已重启${NC}"; read -r -p "按回车继续..." ;;
            21)
                echo -e "${YELLOW}按 Ctrl+C 退出日志${NC}"
                svc_log
                ;;
            22)
                do_time_sync
                # 刷新时间差缓存
                TIME_DIFF=$(get_time_diff)
                LAST_TIME_CHECK=$(date +%s)
                read -r -p "按回车继续..."
                ;;
            0)
                echo -e "${GREEN}再见！${NC}"
                exit 0
                ;;
            *) echo -e "${RED}无效选项${NC}"; sleep 1 ;;
        esac
    done
}

# =============================================
#   主入口
# =============================================
if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

check_root

# 自检：快捷命令不存在或指向错误时自动修复
if [ "$1" != "--save-traffic" ] && [ "$1" != "--save-traffic-if-unlocked" ]; then
    if [ ! -f "$SHORTCUT" ] || ! grep -q "volss" "$SHORTCUT" 2>/dev/null; then
        CURRENT_SCRIPT=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")
        if [ "$CURRENT_SCRIPT" != "$SCRIPT_INSTALL_PATH" ] && [ -f "$CURRENT_SCRIPT" ]; then
            cp "$CURRENT_SCRIPT" "$SCRIPT_INSTALL_PATH" && chmod +x "$SCRIPT_INSTALL_PATH"
        fi
        if [ -f "$SCRIPT_INSTALL_PATH" ]; then
            cat > $SHORTCUT << EOF
#!/bin/bash
bash $SCRIPT_INSTALL_PATH --menu
EOF
            chmod +x $SHORTCUT
            echo -e "${GREEN}✅ 快捷命令已自动修复，输入 ${YELLOW}volss${GREEN} 呼出管理菜单${NC}"
        fi
    fi

    harden_service_if_needed

    # 自检：ACL 格式修复（移除 ssserver 不使用的本地 ACL 段，确保 outbound_block_list 存在）
    if [ -f "$ACL_PATH" ]; then
        NEED_FIX=0
        grep -q "^\[bypass_list\]" "$ACL_PATH" && NEED_FIX=1
        grep -q "^\[proxy_list\]" "$ACL_PATH" && NEED_FIX=1
        grep -q "^domain-suffix:" "$ACL_PATH" && NEED_FIX=1
        if [ "$NEED_FIX" -eq 1 ]; then
            sed -i 's/^domain-suffix:/||/' $ACL_PATH
            sed -i '/^\[bypass_list\]$/d' $ACL_PATH
            sed -i '/^\[proxy_list\]$/d' $ACL_PATH
            sed -i '/^$/d' $ACL_PATH
            if ! grep -q "^\[outbound_block_list\]" $ACL_PATH; then
                sed -i '1i [outbound_block_list]' $ACL_PATH
            fi
            secure_data_files
            svc_restart 2>/dev/null
            echo -e "${GREEN}✅ ACL 格式已自动修复并重启服务${NC}"
        fi

        # 确保 runtime.json 有 acl 字段（grep 快速判断）
        if [ -f "$ACL_PATH" ] && [ -f "$RUNTIME" ]; then
            if ! grep -q '"acl"' "$RUNTIME" 2>/dev/null; then
                python3 -c "
import json, os, tempfile
with open('$RUNTIME') as f: r=json.load(f)
r['acl']='$ACL_PATH'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename('$RUNTIME') + '.', dir=os.path.dirname('$RUNTIME'), text=True)
with os.fdopen(fd, 'w') as f: json.dump(r,f,indent=2)
os.replace(tmp, '$RUNTIME')
print('✅ runtime.json acl 字段已补全')
"
                secure_data_files
                svc_restart
            fi
        fi

        # 确保所有 server 有 mode=tcp_and_udp（先用 grep 快速判断）
        if [ -f "$RUNTIME" ]; then
            SERVER_NUM=$(grep -c "server_port" "$RUNTIME" 2>/dev/null || echo 0)
            MODE_NUM=$(grep -c "tcp_and_udp" "$RUNTIME" 2>/dev/null || echo 0)
            if [ "$SERVER_NUM" != "$MODE_NUM" ]; then
                python3 << PYEOF
import json, os, tempfile
for path in ['$CONFIG', '$RUNTIME']:
    try:
        with open(path) as f:
            c = json.load(f)
        for s in c.get('servers', []):
            s['mode'] = 'tcp_and_udp'
        fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(path) + '.', dir=os.path.dirname(path), text=True)
        with os.fdopen(fd, 'w') as f:
            json.dump(c, f, indent=2)
        os.replace(tmp, path)
    except:
        pass
print('✅ UDP 模式已自动开启')
PYEOF
                secure_data_files
                svc_restart
            fi
        fi
    fi
    secure_data_files
    with_state_lock migrate_server_host_if_needed
    with_state_lock migrate_link_names_if_needed
    with_state_lock migrate_traffic_rules_if_needed
fi

case "$1" in
    --menu)                     show_main_menu ;;
    --save-traffic)             save_traffic ;;
    --save-traffic-if-unlocked) save_traffic_if_unlocked ;;
    --version)                  echo -e "Shadowsocks-Rust 管理脚本 ${GREEN}$VERSION${NC}" ;;
    *)                          show_main_menu ;;
esac
