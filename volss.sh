#!/bin/sh
# shellcheck shell=bash

# ========================================
#   Shadowsocks-Rust 管理脚本
#   版本: V1.5.3
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

VERSION="V1.5.3"

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
TRAFFIC_FILE="/etc/shadowsocks-rust/traffic.json"
MANUAL_FILE="/etc/shadowsocks-rust/manual.list"
SHORTCUT="/usr/local/bin/volss"
ACL_RULESET_DIR="/etc/shadowsocks-rust/rulesets"

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
    [ -f "$FILE" ] && chmod 600 "$FILE" 2>/dev/null || true
}

secure_data_files() {
    local FILE
    for FILE in "$CONFIG" "$RUNTIME" "$LINKS_FILE" "$TRAFFIC_FILE" "$MANUAL_FILE" "$ACL_PATH"; do
        secure_file "$FILE"
    done
    if [ -d "$ACL_RULESET_DIR" ]; then
        find "$ACL_RULESET_DIR" -type f -name '*.acl' -exec chmod 600 {} \; 2>/dev/null || true
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

third_party_mirrors_enabled() {
    [ "${VOLSS_ALLOW_THIRD_PARTY_MIRRORS:-0}" = "1" ]
}

# 只清零指定端口的 iptables 计数器（精确匹配，不影响其他统计）
zero_traffic_counters_for_ports() {
    local PORTS="$1"
    local CHAIN L PORT LINES
    for CHAIN in INPUT OUTPUT; do
        for PORT in $PORTS; do
            LINES=$(iptables -nvL "$CHAIN" --line-numbers 2>/dev/null | awk -v p="$PORT" '$0 ~ ("dpt:"p"( |$)") || $0 ~ ("spt:"p"( |$)") {print $1}' | sort -rn)
            for L in $LINES; do
                iptables -Z "$CHAIN" "$L" 2>/dev/null
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
        apk update -q
        apk add --no-cache curl wget openssl python3 iproute2 xz iptables net-tools bash coreutils
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq
        apt-get install -y curl wget openssl python3 iproute2 xz-utils iptables-persistent -qq
    fi
    echo -e "${GREEN}✅ 依赖安装完成${NC}"
}

install_ssrust() {
    echo -e "\n${YELLOW}>>> 安装 Shadowsocks-Rust...${NC}"

    LATEST=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
        | grep tag_name | cut -d'"' -f4)

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

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.${ARCH_NAME}.tar.xz"
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
        if wget --timeout=30 -O "$TMP_TAR" "$TRY_URL" 2>/dev/null && [ -s "$TMP_TAR" ]; then
            DOWNLOADED=1
            break
        fi
    done

    if [ "$DOWNLOADED" -ne 1 ]; then
        rm -rf "$TMP_DIR"
        echo -e "${RED}❌ 下载失败${NC}"
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

    mv "$TMP_DIR/ssserver" "$SS_BIN"
    chmod +x $SS_BIN
    mkdir -p "$CONFIG_DIR"
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
            if port_in_use "$CURRENT"; then
                echo -e "  ${YELLOW}端口 $CURRENT 已占用，跳过${NC}"
            else
                PORT_LIST+=("$CURRENT")
                echo -e "  ${GREEN}端口 $CURRENT 可用 ✓${NC}"
            fi
            CURRENT=$((CURRENT + 1))
            if [ $CURRENT -gt 65535 ]; then
                echo -e "${RED}❌ 端口耗尽，无法分配足够端口${NC}"
                return 1
            fi
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
        TRIED=0
        MAX_TRY=$(( RANGE_END - RANGE_START ))

        while [ ${#PORT_LIST[@]} -lt "$USER_COUNT" ]; do
            RAND_PORT=$(( RANGE_START + RANDOM % (RANGE_END - RANGE_START + 1) ))
            # 检查是否已在列表中
            DUP=0
            for P in "${PORT_LIST[@]}"; do
                [ "$P" = "$RAND_PORT" ] && DUP=1 && break
            done
            if [ "$DUP" = "1" ] || port_in_use $RAND_PORT; then
                TRIED=$((TRIED + 1))
                if [ $TRIED -gt $MAX_TRY ]; then
                    echo -e "${RED}❌ 范围内可用端口不足${NC}"
                    return 1
                fi
                continue
            fi
            PORT_LIST+=("$RAND_PORT")
            echo -e "  ${GREEN}端口 $RAND_PORT 已分配 ✓${NC}"
        done
    fi

    echo -e "${GREEN}✅ 端口分配完成，共 ${#PORT_LIST[@]} 个${NC}"
}

basic_config() {
    echo -e "\n${YELLOW}>>> 服务器信息${NC}"
    read -r -p "服务器域名或IP [默认自动检测]: " HOST
    if [ -z "$HOST" ]; then
        HOST=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null \
            || curl -s4 --max-time 5 ip.sb 2>/dev/null \
            || curl -s4 --max-time 5 api.ipify.org 2>/dev/null \
            || curl -s4 --max-time 5 ifconfig.co 2>/dev/null)
        echo -e "检测到IP: ${GREEN}$HOST${NC}"
    fi
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
            DOMAIN=$(echo "$DOMAIN" | sed 's/^domain-suffix://; s/^||//; s/^|//; s/^www\.//')
            echo "$DOMAIN" >> $MANUAL_FILE
            secure_file "$MANUAL_FILE"
            echo -e "  ${GREEN}已添加: $DOMAIN（含所有子域名）${NC}"
        done

        USE_ACL_FLAG=true
        rebuild_acl
        echo -e "${GREEN}✅ ACL 配置完成${NC}"
    else
        USE_ACL_FLAG=false
        echo "跳过 ACL 配置"
    fi
}

gen_password() {
    if [ "$KEY_LEN" -gt 0 ]; then
        openssl rand -base64 $KEY_LEN
    else
        openssl rand -base64 32 | tr -d '=' | cut -c1-24
    fi
}

generate_config() {
    echo -e "\n${YELLOW}>>> 生成配置文件和 SS 链接...${NC}"
    local TMP_CONFIG TMP_LINKS
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
    for i in $(seq 0 $((TOTAL - 1))); do
        PORT=${PORT_LIST[$i]}
        PASS=$(gen_password)
        NUM=$((i + 1))

        if [ $NUM -lt "$TOTAL" ]; then
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\",\"mode\":\"tcp_and_udp\"}," >> "$TMP_CONFIG"
        else
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\",\"mode\":\"tcp_and_udp\"}" >> "$TMP_CONFIG"
        fi

        USERINFO=$(echo -n "$METHOD:$PASS" | base64 | tr -d '\n')
        echo "ss://${USERINFO}@${HOST}:${PORT}#用户${NUM}" >> "$TMP_LINKS"
    done

    echo ']}' >> "$TMP_CONFIG"
    mv "$TMP_CONFIG" "$CONFIG"
    mv "$TMP_LINKS" "$LINKS_FILE"
    secure_data_files
    echo -e "${GREEN}✅ 配置生成完成${NC}"
}

apply_config() {
    python3 << PYEOF
import json, os, tempfile

with open('$CONFIG', 'r') as f:
    config = json.load(f)

# 过滤禁用用户
servers = [dict(s) for s in config['servers'] if not s.get('disabled', False)]
for s in servers:
    s.pop('disabled', None)
    s.pop('acl', None)  # 移除 server 块里的旧 acl 字段

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
    secure_data_files

    svc_reload
    svc_restart
}

create_service() {
    echo -e "\n${YELLOW}>>> 创建系统服务...${NC}"

    if [ "$SYSTEM" = "alpine" ]; then
        cat > $SERVICE << EOF
#!/sbin/openrc-run

name="shadowsocks-rust"
description="Shadowsocks-Rust Server"
command="$SS_BIN"
command_args="-c $RUNTIME"
command_background=true
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
    [ -f $SCRIPT_INSTALL_PATH ] && bash $SCRIPT_INSTALL_PATH --save-traffic 2>/dev/null || true
}
EOF
        chmod +x $SERVICE
    else
        cat > $SERVICE << EOF
[Unit]
Description=Shadowsocks-Rust Service
After=network.target

[Service]
Type=simple
User=root
ExecStart=$SS_BIN -c $RUNTIME
ExecStop=/bin/bash -c 'bash $SCRIPT_INSTALL_PATH --save-traffic'
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
    fi

    apply_config
    svc_reload
    svc_enable
    svc_restart
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
    fi
}

init_traffic() {
    echo -e "\n${YELLOW}>>> 初始化流量统计规则...${NC}"

    PORTS=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
for s in c['servers']:
    print(s['server_port'])
")

    for PORT in $PORTS; do
        for PROTO in tcp udp; do
            # 清理该端口所有旧规则，避免冗余
            while iptables -D INPUT  -p $PROTO --dport "$PORT" 2>/dev/null; do :; done
            while iptables -D OUTPUT -p $PROTO --sport "$PORT" 2>/dev/null; do :; done
            # 置顶插入（位置1），确保 ACCEPT 之前匹配
            iptables -I INPUT  1 -p $PROTO --dport "$PORT"
            iptables -I OUTPUT 1 -p $PROTO --sport "$PORT"
        done
    done

    # 只重置本脚本管理端口的计数器，避免影响服务器上其他 iptables 统计
    zero_traffic_counters_for_ports "$PORTS"

    # 持久化 iptables 规则
    if [ "$SYSTEM" = "alpine" ]; then
        # 确保 iptables 服务已安装
        if [ ! -f /etc/init.d/iptables ]; then
            apk add --no-cache iptables >/dev/null 2>&1
        fi
        mkdir -p /etc/iptables
        rc-update add iptables default 2>/dev/null
        /etc/init.d/iptables save 2>/dev/null || iptables-save > /etc/iptables/rules-save 2>/dev/null
    else
        netfilter-persistent save 2>/dev/null
    fi

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

    cat > $SHORTCUT << EOF
#!/bin/bash
bash $SCRIPT_INSTALL_PATH --menu
EOF
    chmod +x $SHORTCUT

    # 验证快捷命令是否可用
    if [ -f "$SCRIPT_INSTALL_PATH" ]; then
        echo -e "${GREEN}✅ 快捷命令已注册: 输入 ${YELLOW}volss${GREEN} 呼出管理菜单${NC}"
    else
        echo -e "${RED}❌ 快捷命令注册失败，请手动运行: bash $CURRENT_SCRIPT${NC}"
    fi
}

# ========== 完整安装流程 ==========
do_install() {
    if check_installed; then
        echo -e "${YELLOW}⚠ 检测到已安装 Shadowsocks-Rust${NC}"
        read -r -p "是否重新安装？[y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi
    fi

    install_deps
    install_ssrust   || { read -r -p "按回车返回..."; return; }
    select_method
    basic_config
    select_ports     || { read -r -p "按回车返回..."; return; }
    config_acl
    generate_config
    create_service
    init_traffic
    install_shortcut

    echo ""
    show_links
    echo ""
    echo -e "${GREEN}🎉 安装完成！输入 ${YELLOW}volss${GREEN} 随时呼出管理菜单${NC}"
    read -r -p "按回车返回主菜单..."
}

# ========== 卸载 ==========
do_uninstall() {
    echo -e "${RED}⚠ 此操作将完全卸载 Shadowsocks-Rust${NC}"
    read -r -p "确认卸载？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    # 清理 iptables 流量统计规则
    if [ -f "$CONFIG" ]; then
        PORTS=$(python3 -c "
import json
try:
    with open('$CONFIG') as f:
        c = json.load(f)
    for s in c['servers']:
        print(s['server_port'])
except: pass
" 2>/dev/null)
        for PORT in $PORTS; do
            for PROTO in tcp udp; do
                while iptables -D INPUT  -p $PROTO --dport "$PORT" 2>/dev/null; do :; done
                while iptables -D OUTPUT -p $PROTO --sport "$PORT" 2>/dev/null; do :; done
            done
        done
        # 持久化
        if [ "$SYSTEM" = "alpine" ]; then
            /etc/init.d/iptables save 2>/dev/null
        else
            netfilter-persistent save 2>/dev/null
        fi
    fi

    svc_stop 2>/dev/null
    svc_disable
    rm -f "$SS_BIN" "$SERVICE" "$SHORTCUT" "$SCRIPT_INSTALL_PATH" "${SCRIPT_INSTALL_PATH}.bak"
    rm -rf /etc/shadowsocks-rust
    svc_reload

    echo -e "${GREEN}✅ 卸载完成${NC}"
    read -r -p "按回车继续..."
}

# =============================================
#   管理功能
# =============================================

list_users() {
    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    当前用户列表${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    printf "  ${CYAN}%-4s %-8s %-36s %-6s${NC}\n" "编号" "端口" "加密方式" "状态"
    echo -e "  ${BLUE}-------------------------------------------------${NC}"

    python3 << PYEOF
import json
with open('$CONFIG') as f:
    c = json.load(f)
for i, s in enumerate(c['servers'], 1):
    status = '暂停' if s.get('disabled') else '正常'
    color  = '\033[0;31m' if s.get('disabled') else '\033[0;32m'
    reset  = '\033[0m'
    print(f"  {i:<4} {s['server_port']:<8} {s['method']:<36} {color}{status}{reset}")
PYEOF

    echo -e "  ${BLUE}=================================================${NC}"
}

show_links() {
    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    SS 链接列表${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    cat $LINKS_FILE
    echo -e "  ${BLUE}=================================================${NC}"
    echo -e "  链接已保存至: ${YELLOW}$LINKS_FILE${NC}"
}

# ========== 保存当前 iptables 计数到文件 ==========
save_traffic() {
    python3 << PYEOF
import json, subprocess, os, tempfile

config_file = '$CONFIG'
traffic_file = '$TRAFFIC_FILE'

with open(config_file) as f:
    c = json.load(f)

# 读取已有历史数据
if os.path.exists(traffic_file):
    with open(traffic_file) as f:
        history = json.load(f)
else:
    history = {}

def get_bytes(chain, port, direction):
    import re
    try:
        out = subprocess.check_output(['iptables', '-nvxL', chain], text=True)
        total = 0
        # 精确匹配 spt:PORT / dpt:PORT 后接非数字或行尾，避免 3000 误匹配 30001
        pat = re.compile(r'\b%s:%d(?:\D|$)' % ('spt' if direction == 'sport' else 'dpt', port))
        for line in out.splitlines():
            if pat.search(line):
                parts = line.split()
                if len(parts) >= 2:
                    try:
                        total += int(parts[1])
                    except ValueError:
                        pass
        return total
    except:
        return 0

# 读取增量并累加
for s in c['servers']:
    port = str(s['server_port'])
    tx = get_bytes('OUTPUT', s['server_port'], 'sport')
    rx = get_bytes('INPUT',  s['server_port'], 'dport')
    if port not in history:
        history[port] = {'tx': 0, 'rx': 0}
    history[port]['tx'] += tx
    history[port]['rx'] += rx

traffic_dir = os.path.dirname(traffic_file)
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(traffic_file) + '.', dir=traffic_dir, text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(history, f, indent=2)
os.replace(tmp, traffic_file)

# 关键：读取后只清零本脚本管理端口的计数器，避免影响其他 iptables 统计
import re
for s in c['servers']:
    port = s['server_port']
    for chain in ('INPUT', 'OUTPUT'):
        try:
            out = subprocess.check_output(['iptables', '-nvL', chain, '--line-numbers'], text=True)
            pat = re.compile(r'\b[sd]pt:%d(?:\D|$)' % port)
            lines = []
            for line in out.splitlines():
                if pat.search(line):
                    parts = line.split()
                    if parts and parts[0].isdigit():
                        lines.append(int(parts[0]))
            for line_no in sorted(lines, reverse=True):
                subprocess.run(['iptables', '-Z', chain, str(line_no)], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass
PYEOF
    secure_data_files
}

show_traffic() {
    # 先同步当前 iptables 增量到历史文件，并清零计数器
    save_traffic

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

reset_traffic() {
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

disable_user() {
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

    apply_config
    echo -e "${YELLOW}⏸ 端口 $PORT 已暂停${NC}"
}

enable_user() {
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

    apply_config
    echo -e "${GREEN}✅ 端口 $PORT 已恢复${NC}"
}

delete_user() {
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

    python3 << PYEOF
import json, os, tempfile
with open('$CONFIG') as f:
    c = json.load(f)
c['servers'] = [s for s in c['servers'] if s['server_port'] != $PORT]
config_file = '$CONFIG'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f, indent=2)
os.replace(tmp, config_file)
PYEOF

    TMP_LINKS=$(make_temp_for "$LINKS_FILE") || {
        echo -e "${RED}❌ 创建链接临时文件失败${NC}"
        return
    }
    grep -v ":${PORT}#" "$LINKS_FILE" > "$TMP_LINKS"
    mv "$TMP_LINKS" "$LINKS_FILE"
    secure_data_files

    for CHAIN in INPUT OUTPUT; do
        for PROTO in tcp udp; do
            while iptables -D "$CHAIN" -p $PROTO --dport "$PORT" 2>/dev/null; do :; done
            while iptables -D "$CHAIN" -p $PROTO --sport "$PORT" 2>/dev/null; do :; done
        done
    done

    apply_config
    echo -e "${RED}🗑 端口 $PORT 已删除${NC}"
}

regen_users() {
    echo -e "${YELLOW}>>> 重新生成所有用户密码（端口保持不变）${NC}"
    read -r -p "确认？所有密码将变更，旧链接失效 [y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    METHOD=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0]['method'])
")

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

    # 获取服务器地址（从现有链接提取，避免重新检测）
    if [ -f "$LINKS_FILE" ] && [ -s "$LINKS_FILE" ]; then
        HOST=$(head -1 "$LINKS_FILE" | sed 's/.*@//; s/:.*//')
    fi
    [ -z "$HOST" ] && basic_config

    USE_ACL_FLAG=$([ -f "$ACL_PATH" ] && echo true || echo false)

    generate_config
    apply_config
    init_traffic
    show_links
}

# ========== 添加新用户 ==========
rebuild_links() {
    # 根据 config.json 重建所有 SS 链接（保持端口顺序，序号重排）
    METHOD=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0]['method'] if c['servers'] else '')
")
    # 获取服务器地址
    if [ -f "$LINKS_FILE" ] && [ -s "$LINKS_FILE" ]; then
        HOST=$(head -1 "$LINKS_FILE" | sed 's/.*@//; s/:.*//; s/#.*//')
    fi
    [ -z "$HOST" ] && basic_config

    local TMP_LINKS
    TMP_LINKS=$(make_temp_for "$LINKS_FILE") || {
        echo -e "${RED}❌ 创建链接临时文件失败${NC}"
        return 1
    }
    python3 << PYEOF
import json, base64
with open('$CONFIG') as f:
    c = json.load(f)
lines = []
for i, s in enumerate(c['servers'], 1):
    userinfo = base64.b64encode(f"{s['method']}:{s['password']}".encode()).decode()
    lines.append(f"ss://{userinfo}@{'$HOST'}:{s['server_port']}#用户{i}")
with open('$TMP_LINKS', 'w') as f:
    f.write('\n'.join(lines) + '\n')
PYEOF
    mv "$TMP_LINKS" "$LINKS_FILE"
    secure_data_files
}

add_user() {
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
            if [ $CURRENT -gt 65535 ]; then
                echo -e "${RED}❌ 端口耗尽${NC}"; return
            fi
        done
    fi

    # 追加到 config.json
    NEW_PORTS_STR="${NEW_PORTS[*]}"
    python3 << PYEOF
import json, os, subprocess, tempfile

with open('$CONFIG') as f:
    c = json.load(f)

method = '$METHOD'
key_len = $KEY_LEN
new_ports = "$NEW_PORTS_STR".split()

def gen_pass():
    raw = subprocess.check_output(['openssl', 'rand', '-base64', str(key_len if key_len > 0 else 32)], text=True).strip()
    if key_len > 0:
        return raw
    return raw.replace('=', '')[:24]

for p in new_ports:
    c['servers'].append({
        'server': '::',
        'server_port': int(p),
        'password': gen_pass(),
        'method': method,
        'mode': 'tcp_and_udp'
    })

config_file = '$CONFIG'
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(config_file) + '.', dir=os.path.dirname(config_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(c, f, indent=2)
os.replace(tmp, config_file)
print(f"✅ 已添加 {len(new_ports)} 个新用户")
PYEOF
    secure_data_files

    # 为新端口添加 iptables 统计规则
    for PORT in "${NEW_PORTS[@]}"; do
        for PROTO in tcp udp; do
            while iptables -D INPUT  -p $PROTO --dport "$PORT" 2>/dev/null; do :; done
            while iptables -D OUTPUT -p $PROTO --sport "$PORT" 2>/dev/null; do :; done
            iptables -I INPUT  1 -p $PROTO --dport "$PORT"
            iptables -I OUTPUT 1 -p $PROTO --sport "$PORT"
        done
    done
    zero_traffic_counters_for_ports "$NEW_PORTS_STR"

    # 持久化 iptables
    if [ "$SYSTEM" = "alpine" ]; then
        /etc/init.d/iptables save 2>/dev/null || iptables-save > /etc/iptables/rules-save 2>/dev/null
    else
        netfilter-persistent save 2>/dev/null
    fi

    rebuild_links
    apply_config
    show_links
    echo -e "${GREEN}✅ 新用户添加完成${NC}"
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
        if wget -q --timeout=20 -O "$TMP_NEW" "$BASE/$REMOTE_PATH" 2>/dev/null && [ -s "$TMP_NEW" ] && head -1 "$TMP_NEW" | grep -q '#!/'; then
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

runtime = {'servers': servers}
if os.path.exists(acl_path):
    runtime['acl'] = acl_path

fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(runtime_file) + '.', dir=os.path.dirname(runtime_file), text=True)
with os.fdopen(fd, 'w') as f:
    json.dump(runtime, f, indent=2)
os.replace(tmp, runtime_file)
print("✅ runtime.json 已更新")
PYEOF

        # 修复旧版 ACL 格式（domain-suffix: → ||，移除无效头部）
        if [ -f "$ACL_PATH" ]; then
            sed -i 's/^domain-suffix:/||/' $ACL_PATH
            sed -i '/^\[bypass_list\]$/d' $ACL_PATH
            sed -i '/^\[accept_all\]$/d' $ACL_PATH
            sed -i '/^\[proxy_list\]$/d' $ACL_PATH
            sed -i '/^$/d' $ACL_PATH
            # 确保文件以 [outbound_block_list] 开头
            if ! grep -q "^\[outbound_block_list\]" $ACL_PATH; then
                sed -i '1i [outbound_block_list]' $ACL_PATH
            fi
            echo -e "${GREEN}✅ ACL 格式已自动修复${NC}"
        fi

        # 强制重新生成 runtime.json 确保 ACL 字段正确写入
        apply_config
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

        if grep -q "Restart=on-failure" $SERVICE 2>/dev/null; then
            sed -i 's/Restart=on-failure/Restart=always/' $SERVICE
            echo -e "${GREEN}✅ 服务文件已修复${NC}"
        fi

        # 确保 ExecStop 存在
        if ! grep -q "ExecStop" $SERVICE 2>/dev/null; then
            sed -i "/ExecStart=.*/a ExecStop=/bin/bash -c 'bash $SCRIPT_INSTALL_PATH --save-traffic'" $SERVICE
            echo -e "${GREEN}✅ 服务停止钩子已添加${NC}"
        fi

        svc_reload
        svc_restart
        echo -e "${GREEN}✅ 服务已重启${NC}"
    fi

    echo -e "\n${YELLOW}脚本将重新启动...${NC}"
    sleep 2
    exec bash "$SCRIPT_INSTALL_PATH" --menu
}

add_acl_domain() {
    read -r -p "输入要屏蔽的域名: " NEW_DOMAIN
    if [ -n "$NEW_DOMAIN" ]; then
        NEW_DOMAIN=$(echo "$NEW_DOMAIN" | sed 's/^domain-suffix://; s/^||//; s/^|//; s/^www\.//')
        if ! valid_domain "$NEW_DOMAIN"; then
            echo -e "${RED}域名格式无效${NC}"
            return
        fi
        # 检查是否已存在
        if grep -qx "$NEW_DOMAIN" "$MANUAL_FILE" 2>/dev/null; then
            echo -e "${YELLOW}⚠ $NEW_DOMAIN 已存在${NC}"
            return
        fi
        echo "$NEW_DOMAIN" >> $MANUAL_FILE
        secure_file "$MANUAL_FILE"
        rebuild_acl
        echo -e "${GREEN}✅ 已添加: $NEW_DOMAIN（含所有子域名）${NC}"
    fi
}

del_acl_domain() {
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
            grep -vx "$DOMAIN" "$MANUAL_FILE" > "$TMP_MANUAL"
            mv "$TMP_MANUAL" "$MANUAL_FILE"
        done
        secure_file "$MANUAL_FILE"
        rebuild_acl
        echo -e "${GREEN}✅ 共删除 $DELETED 条，服务已重启${NC}"
    fi
}

# ========== ACL 规则集管理 ==========
ACL_RULESET_DIR="/etc/shadowsocks-rust/rulesets"

# 规则集定义：名称|描述|来源URL
declare -A RULESET_URLS
RULESET_URLS=(
    ["ads"]="广告拦截|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Ads"
    ["adult"]="色情网站|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Adult"
    ["gambling"]="赌博网站|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Gambling"
    ["malware"]="恶意软件|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Malware"
    ["scam"]="诈骗欺诈|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Scam"
    ["tracking"]="追踪统计|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Tracking"
    ["crypto"]="挖矿劫持|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Crypto"
    ["dating"]="交友网站|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Dating"
    ["bt"]="BT下载|https://raw.githubusercontent.com/ShadowWhisperer/BlockLists/master/Lists/Torrents"
    ["finance"]="金融理财|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/domains/gambling.txt"
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

# 下载并转换规则集为 ss-rust ACL 格式
download_ruleset() {
    local NAME=$1
    local URL=$2
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
    local OUT="$ACL_RULESET_DIR/${NAME}.acl"

    echo -e "  ${YELLOW}下载中: $NAME ...${NC}"

    # 依次尝试各镜像
    local SUCCESS=0
    for MIRROR in "${GITHUB_MIRRORS[@]}"; do
        local TRY_URL
        TRY_URL=$(mirror_url "$URL" "$MIRROR")
        if wget -q --timeout=15 -O "$TMP" "$TRY_URL" 2>/dev/null && [ -s "$TMP" ]; then
            SUCCESS=1
            break
        fi
        rm -f "$TMP"
    done

    if [ $SUCCESS -eq 0 ]; then
        rm -rf "$TMP_DIR"
        echo -e "  ${RED}❌ 下载失败: $NAME（所有镜像均不可用）${NC}"
        return 1
    fi

    # 转换格式：过滤注释和空行，每行加 || 前缀
    grep -v "^#" "$TMP" | grep -v "^$" | grep -v "^\*\." | sed 's/^/||/' > "$OUT"
    COUNT=$(wc -l < "$OUT")
    rm -rf "$TMP_DIR"
    echo -e "  ${GREEN}✅ $NAME 已下载，共 $COUNT 条规则${NC}"
    return 0
}

# 重新合并所有规则集到 ACL 文件
rebuild_acl() {
    init_ruleset_dir

    # 重建 ACL 文件，从 [outbound_block_list] 开始
    echo "[outbound_block_list]" > $ACL_PATH

    # 写入手动域名（从 manual.list 读取，纯净格式无标记）
    if [ -f "$MANUAL_FILE" ] && [ -s "$MANUAL_FILE" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo "||$line" >> $ACL_PATH
        done < "$MANUAL_FILE"
    fi

    # 写入各规则集
    for RULESET_FILE in "$ACL_RULESET_DIR"/*.acl; do
        [ -f "$RULESET_FILE" ] || continue
        cat "$RULESET_FILE" >> $ACL_PATH
    done

    svc_restart
}

# 显示规则集菜单
manage_rulesets() {
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
                download_ruleset "$KEY" "$URL" && rebuild_acl
                ;;
            11)
                echo -e "${YELLOW}>>> 安装全部规则集...${NC}"
                local KEYS=("ads" "adult" "gambling" "malware" "scam" "tracking" "crypto" "dating" "bt" "finance")
                for KEY in "${KEYS[@]}"; do
                    IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
                    download_ruleset "$KEY" "$URL"
                done
                rebuild_acl
                echo -e "${GREEN}✅ 全部规则集安装完成${NC}"
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
                        rebuild_acl
                        echo -e "${GREEN}✅ 已卸载: $DEL_NAME${NC}"
                    else
                        echo -e "${RED}无效编号${NC}"
                    fi
                fi
                ;;
            13)
                echo -e "${YELLOW}>>> 更新已安装规则集...${NC}"
                for RULESET_FILE in "$ACL_RULESET_DIR"/*.acl; do
                    [ -f "$RULESET_FILE" ] || continue
                    KEY=$(basename "$RULESET_FILE" .acl)
                    if [ -n "${RULESET_URLS[$KEY]}" ]; then
                        IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
                        download_ruleset "$KEY" "$URL"
                    fi
                done
                rebuild_acl
                echo -e "${GREEN}✅ 更新完成${NC}"
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
                    download_ruleset "$CUSTOM_NAME" "$CUSTOM_URL" && rebuild_acl
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
                    MANUAL=$(grep -c "^||.*#manual" "$ACL_PATH" 2>/dev/null || true)
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
        read -r -p "  请选择 [0-22]: " CHOICE

        # 未安装时拦截管理功能
        if ! check_installed && [[ "$CHOICE" =~ ^([4-9]|1[0-9]|2[0-2])$ ]]; then
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
                    MANUAL_COUNT=0
                    [ -f "$MANUAL_FILE" ] && MANUAL_COUNT=$(grep -c "." "$MANUAL_FILE" 2>/dev/null || echo 0)
                    RULESET_COUNT=$((TOTAL - MANUAL_COUNT))
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
check_root

# 自检：快捷命令不存在或指向错误时自动修复
if [ "$1" != "--save-traffic" ]; then
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

    # 自检：ACL 格式修复（移除无效头部，确保 outbound_block_list 存在）
    if [ -f "$ACL_PATH" ]; then
        NEED_FIX=0
        grep -q "^\[accept_all\]" "$ACL_PATH" && NEED_FIX=1
        grep -q "^\[bypass_list\]" "$ACL_PATH" && NEED_FIX=1
        grep -q "^domain-suffix:" "$ACL_PATH" && NEED_FIX=1
        if [ "$NEED_FIX" -eq 1 ]; then
            sed -i 's/^domain-suffix:/||/' $ACL_PATH
            sed -i '/^\[bypass_list\]$/d' $ACL_PATH
            sed -i '/^\[accept_all\]$/d' $ACL_PATH
            sed -i '/^\[proxy_list\]$/d' $ACL_PATH
            sed -i '/^$/d' $ACL_PATH
            if ! grep -q "^\[outbound_block_list\]" $ACL_PATH; then
                sed -i '1i [outbound_block_list]' $ACL_PATH
            fi
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
                svc_restart
            fi
        fi
    fi
    secure_data_files
fi

case "$1" in
    --menu)         show_main_menu ;;
    --save-traffic) save_traffic ;;
    --version)      echo -e "Shadowsocks-Rust 管理脚本 ${GREEN}$VERSION${NC}" ;;
    *)              show_main_menu ;;
esac
