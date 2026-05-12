#!/bin/bash

# ========================================
#   Shadowsocks-Rust 管理脚本
#   版本: V1.2.8
#   快捷命令: volss
# ========================================

VERSION="V1.2.8"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SS_BIN="/usr/local/bin/ssserver"
SCRIPT_INSTALL_PATH="/usr/local/bin/volss.sh"
CONFIG="/etc/shadowsocks-rust/config.json"
RUNTIME="/etc/shadowsocks-rust/runtime.json"
ACL_PATH="/etc/shadowsocks-rust/blocklist.acl"
LINKS_FILE="/etc/shadowsocks-rust/ss_links.txt"
TRAFFIC_FILE="/etc/shadowsocks-rust/traffic.json"
SERVICE="/etc/systemd/system/shadowsocks-rust.service"
SHORTCUT="/usr/local/bin/volss"

# ========== 检查 root ==========
check_root() {
    if [ "$EUID" -ne 0 ]; then
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

# =============================================
#   安装流程
# =============================================

install_deps() {
    echo -e "\n${YELLOW}>>> 安装依赖...${NC}"
    apt-get update -qq
    apt-get install -y curl wget openssl python3 iproute2 xz-utils iptables-persistent -qq
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
    case $ARCH in
        x86_64)  ARCH_NAME="x86_64-unknown-linux-gnu" ;;
        aarch64) ARCH_NAME="aarch64-unknown-linux-gnu" ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            return 1
            ;;
    esac

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.${ARCH_NAME}.tar.xz"
    echo "下载中: $URL"
    wget -O /tmp/ss-rust.tar.xz "$URL"

    if [ $? -ne 0 ] || [ ! -s /tmp/ss-rust.tar.xz ]; then
        echo -e "${RED}❌ 下载失败${NC}"
        return 1
    fi

    tar -xJf /tmp/ss-rust.tar.xz -C /tmp/
    mv /tmp/ssserver $SS_BIN
    chmod +x $SS_BIN
    mkdir -p /etc/shadowsocks-rust

    echo -e "${GREEN}✅ ss-rust $LATEST 安装完成${NC}"
}

select_method() {
    echo -e "\n${YELLOW}>>> 选择加密方式：${NC}"
    echo "  1) 2022-blake3-aes-128-gcm        (推荐，密钥16字节)"
    echo "  2) 2022-blake3-aes-256-gcm        (强加密，密钥32字节)"
    echo "  3) 2022-blake3-chacha20-poly1305   (ARM推荐，密钥32字节)"
    echo "  4) aes-256-gcm                    (传统，兼容性好)"
    echo "  5) chacha20-ietf-poly1305         (传统，兼容性好)"
    read -p "请选择 [1-5，默认1]: " METHOD_CHOICE

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
    read -p "请选择 [1-2，默认1]: " PORT_MODE
    PORT_MODE=${PORT_MODE:-1}

    read -p "生成用户数量 [默认 10，最多 50]: " USER_COUNT
    USER_COUNT=${USER_COUNT:-10}
    [ "$USER_COUNT" -gt 50 ] && USER_COUNT=50

    if [ "$PORT_MODE" = "1" ]; then
        read -p "起始端口 [默认 30001]: " START_PORT
        START_PORT=${START_PORT:-30001}

        echo -e "\n${YELLOW}>>> 正在分配端口（跳过已占用）...${NC}"
        PORT_LIST=()
        CURRENT=$START_PORT
        while [ ${#PORT_LIST[@]} -lt $USER_COUNT ]; do
            if port_in_use $CURRENT; then
                echo -e "  ${YELLOW}端口 $CURRENT 已占用，跳过${NC}"
            else
                PORT_LIST+=($CURRENT)
                echo -e "  ${GREEN}端口 $CURRENT 可用 ✓${NC}"
            fi
            CURRENT=$((CURRENT + 1))
            if [ $CURRENT -gt 65535 ]; then
                echo -e "${RED}❌ 端口耗尽，无法分配足够端口${NC}"
                return 1
            fi
        done

    else
        read -p "端口范围起始 [默认 20000]: " RANGE_START
        read -p "端口范围结束 [默认 60000]: " RANGE_END
        RANGE_START=${RANGE_START:-20000}
        RANGE_END=${RANGE_END:-60000}

        echo -e "\n${YELLOW}>>> 正在随机分配端口（跳过已占用）...${NC}"
        PORT_LIST=()
        TRIED=0
        MAX_TRY=$(( RANGE_END - RANGE_START ))

        while [ ${#PORT_LIST[@]} -lt $USER_COUNT ]; do
            RAND_PORT=$(( RANGE_START + RANDOM % (RANGE_END - RANGE_START + 1) ))
            if [[ " ${PORT_LIST[@]} " =~ " $RAND_PORT " ]] || port_in_use $RAND_PORT; then
                TRIED=$((TRIED + 1))
                if [ $TRIED -gt $MAX_TRY ]; then
                    echo -e "${RED}❌ 范围内可用端口不足${NC}"
                    return 1
                fi
                continue
            fi
            PORT_LIST+=($RAND_PORT)
            echo -e "  ${GREEN}端口 $RAND_PORT 已分配 ✓${NC}"
        done
    fi

    echo -e "${GREEN}✅ 端口分配完成，共 ${#PORT_LIST[@]} 个${NC}"
}

basic_config() {
    echo -e "\n${YELLOW}>>> 服务器信息${NC}"
    read -p "服务器域名或IP [默认自动检测]: " HOST
    if [ -z "$HOST" ]; then
        HOST=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb)
        echo -e "检测到IP: ${GREEN}$HOST${NC}"
    fi
}

config_acl() {
    echo -e "\n${YELLOW}>>> 是否配置 ACL 黑名单？${NC}"
    read -p "配置 ACL？[y/N]: " USE_ACL

    if [[ "$USE_ACL" =~ ^[Yy]$ ]]; then
        echo -e "\n${YELLOW}输入要屏蔽的域名，每行一个，输入空行结束：${NC}"
        echo -e "${BLUE}示例: ippure.com${NC}"

        cat > $ACL_PATH << 'ACLEOF'
[outbound_block_list]
ACLEOF

        while true; do
            read -p "域名 (空行结束): " DOMAIN
            [ -z "$DOMAIN" ] && break
            # 去掉用户可能输入的前缀
            DOMAIN=$(echo "$DOMAIN" | sed 's/^domain-suffix://; s/^||//; s/^|//; s/^www\.//')
            echo "||$DOMAIN #manual" >> $ACL_PATH
            echo -e "  ${GREEN}已添加: $DOMAIN（含所有子域名）${NC}"
        done

        USE_ACL_FLAG=true
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

    # ACL 写在顶层，不写在每个 server 块里
    if [ "$USE_ACL_FLAG" = true ]; then
        echo "{\"acl\":\"$ACL_PATH\",\"servers\":[" > $CONFIG
    else
        echo '{"servers":[' > $CONFIG
    fi

    > $LINKS_FILE

    TOTAL=${#PORT_LIST[@]}
    for i in $(seq 0 $((TOTAL - 1))); do
        PORT=${PORT_LIST[$i]}
        PASS=$(gen_password)
        NUM=$((i + 1))

        if [ $NUM -lt $TOTAL ]; then
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\"}," >> $CONFIG
        else
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\"}" >> $CONFIG
        fi

        USERINFO=$(echo -n "$METHOD:$PASS" | base64 -w 0)
        echo "ss://${USERINFO}@${HOST}:${PORT}#用户${NUM}" >> $LINKS_FILE
    done

    echo ']}' >> $CONFIG
    echo -e "${GREEN}✅ 配置生成完成${NC}"
}

apply_config() {
    python3 << PYEOF
import json, os

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

with open('$RUNTIME', 'w') as f:
    json.dump(runtime, f, indent=2)
PYEOF

    systemctl daemon-reload 2>/dev/null
    systemctl restart shadowsocks-rust
}

create_service() {
    echo -e "\n${YELLOW}>>> 创建系统服务...${NC}"

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

    apply_config
    systemctl daemon-reload
    systemctl enable shadowsocks-rust
    systemctl restart shadowsocks-rust
    sleep 2

    if systemctl is-active --quiet shadowsocks-rust; then
        echo -e "${GREEN}✅ 服务启动成功${NC}"
    else
        echo -e "${RED}❌ 服务启动失败，查看日志: journalctl -u shadowsocks-rust -n 20${NC}"
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
        iptables -C OUTPUT -p tcp --sport $PORT 2>/dev/null || iptables -A OUTPUT -p tcp --sport $PORT
        iptables -C INPUT  -p tcp --dport $PORT 2>/dev/null || iptables -A INPUT  -p tcp --dport $PORT
        iptables -C OUTPUT -p udp --sport $PORT 2>/dev/null || iptables -A OUTPUT -p udp --sport $PORT
        iptables -C INPUT  -p udp --dport $PORT 2>/dev/null || iptables -A INPUT  -p udp --dport $PORT
    done

    netfilter-persistent save 2>/dev/null
    echo -e "${GREEN}✅ 流量统计初始化完成${NC}"
}

install_shortcut() {
    # 获取当前脚本绝对路径
    CURRENT_SCRIPT=$(cd "$(dirname "$0")" && pwd)/$(basename "$0")

    # 将脚本复制到固定路径
    if [ "$CURRENT_SCRIPT" != "$SCRIPT_INSTALL_PATH" ]; then
        cp "$CURRENT_SCRIPT" "$SCRIPT_INSTALL_PATH"
        if [ $? -ne 0 ]; then
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
        read -p "是否重新安装？[y/N]: " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi
    fi

    install_deps
    install_ssrust   || { read -p "按回车返回..."; return; }
    select_method
    basic_config
    select_ports     || { read -p "按回车返回..."; return; }
    config_acl
    generate_config
    create_service
    init_traffic
    install_shortcut

    echo ""
    show_links
    echo ""
    echo -e "${GREEN}🎉 安装完成！输入 ${YELLOW}volss${GREEN} 随时呼出管理菜单${NC}"
    read -p "按回车返回主菜单..."
}

# ========== 卸载 ==========
do_uninstall() {
    echo -e "${RED}⚠ 此操作将完全卸载 Shadowsocks-Rust${NC}"
    read -p "确认卸载？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    systemctl stop    shadowsocks-rust 2>/dev/null
    systemctl disable shadowsocks-rust 2>/dev/null
    rm -f $SS_BIN $SERVICE $SHORTCUT $SCRIPT_INSTALL_PATH ${SCRIPT_INSTALL_PATH}.bak
    rm -rf /etc/shadowsocks-rust
    systemctl daemon-reload

    echo -e "${GREEN}✅ 卸载完成${NC}"
    read -p "按回车继续..."
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
import json, subprocess, os

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
    try:
        out = subprocess.check_output(['iptables', '-nvxL', chain], text=True)
        total = 0
        for line in out.splitlines():
            if str(port) in line:
                parts = line.split()
                if len(parts) >= 10:
                    if direction == 'sport' and f'spt:{port}' in line:
                        total += int(parts[1])
                    elif direction == 'dport' and f'dpt:{port}' in line:
                        total += int(parts[1])
        return total
    except:
        return 0

for s in c['servers']:
    port = str(s['server_port'])
    tx = get_bytes('OUTPUT', s['server_port'], 'sport')
    rx = get_bytes('INPUT',  s['server_port'], 'dport')
    if port not in history:
        history[port] = {'tx': 0, 'rx': 0}
    history[port]['tx'] += tx
    history[port]['rx'] += rx

with open(traffic_file, 'w') as f:
    json.dump(history, f, indent=2)
PYEOF
}

show_traffic() {
    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    流量统计  ${YELLOW}(单向流量，实际带宽消耗约为 x2)${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    printf "  ${CYAN}%-4s %-8s %-14s %-14s %-6s${NC}\n" "编号" "端口" "上行(GB)" "下行(GB)" "状态"
    echo -e "  ${BLUE}-------------------------------------------------${NC}"

    python3 << PYEOF
import json, subprocess, os
from datetime import datetime

with open('$CONFIG') as f:
    c = json.load(f)

# 读取历史累计数据
if os.path.exists('$TRAFFIC_FILE'):
    with open('$TRAFFIC_FILE') as f:
        history = json.load(f)
else:
    history = {}

def get_bytes(chain, port, direction):
    try:
        out = subprocess.check_output(['iptables', '-nvxL', chain], text=True)
        total = 0
        for line in out.splitlines():
            if str(port) in line:
                parts = line.split()
                if len(parts) >= 10:
                    if direction == 'sport' and f'spt:{port}' in line:
                        total += int(parts[1])
                    elif direction == 'dport' and f'dpt:{port}' in line:
                        total += int(parts[1])
        return total
    except:
        return 0

for i, s in enumerate(c['servers'], 1):
    port = s['server_port']
    key  = str(port)

    # 当前 iptables 计数
    cur_tx = get_bytes('OUTPUT', port, 'sport')
    cur_rx = get_bytes('INPUT',  port, 'dport')

    # 历史累计
    hist_tx = history.get(key, {}).get('tx', 0)
    hist_rx = history.get(key, {}).get('rx', 0)

    total_tx = (hist_tx + cur_tx) / 1024 / 1024 / 1024
    total_rx = (hist_rx + cur_rx) / 1024 / 1024 / 1024

    # 最后重置时间
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
    read -p "输入要重置的用户编号 (0=全部重置): " NUM

    if [ "$NUM" = "0" ]; then
        iptables -Z INPUT
        iptables -Z OUTPUT
        # 清空历史文件并记录重置时间
        RESET_TIME=$(date '+%Y-%m-%d %H:%M:%S')
        python3 << PYEOF
import json
with open('$CONFIG') as f:
    c = json.load(f)
history = {}
for s in c['servers']:
    history[str(s['server_port'])] = {'tx': 0, 'rx': 0, 'reset_time': '$RESET_TIME'}
with open('$TRAFFIC_FILE', 'w') as f:
    json.dump(history, f, indent=2)
PYEOF
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

    # 清零该端口 iptables 计数
    for CHAIN in INPUT OUTPUT; do
        LINE=$(iptables -nvL $CHAIN --line-numbers | awk -v p="$PORT" '$0~p{print $1}' | head -1)
        [ -n "$LINE" ] && iptables -Z $CHAIN $LINE 2>/dev/null
    done

    # 清空该端口历史数据并记录重置时间
    RESET_TIME=$(date '+%Y-%m-%d %H:%M:%S')
    python3 << PYEOF
import json, os
if os.path.exists('$TRAFFIC_FILE'):
    with open('$TRAFFIC_FILE') as f:
        history = json.load(f)
else:
    history = {}
history['$PORT'] = {'tx': 0, 'rx': 0, 'reset_time': '$RESET_TIME'}
with open('$TRAFFIC_FILE', 'w') as f:
    json.dump(history, f, indent=2)
PYEOF

    echo -e "${GREEN}✅ 端口 $PORT 流量已重置${NC}"
}

disable_user() {
    list_users
    read -p "输入要暂停的用户编号: " NUM

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
import json
with open('$CONFIG') as f:
    c = json.load(f)
for s in c['servers']:
    if s['server_port'] == $PORT:
        s['disabled'] = True
        break
with open('$CONFIG', 'w') as f:
    json.dump(c, f, indent=2)
PYEOF

    apply_config
    echo -e "${YELLOW}⏸ 端口 $PORT 已暂停${NC}"
}

enable_user() {
    list_users
    read -p "输入要恢复的用户编号: " NUM

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
import json
with open('$CONFIG') as f:
    c = json.load(f)
for s in c['servers']:
    if s['server_port'] == $PORT:
        s.pop('disabled', None)
        break
with open('$CONFIG', 'w') as f:
    json.dump(c, f, indent=2)
PYEOF

    apply_config
    echo -e "${GREEN}✅ 端口 $PORT 已恢复${NC}"
}

delete_user() {
    list_users
    read -p "输入要删除的用户编号: " NUM
    read -p "确认删除？[y/N]: " CONFIRM
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
import json
with open('$CONFIG') as f:
    c = json.load(f)
c['servers'] = [s for s in c['servers'] if s['server_port'] != $PORT]
with open('$CONFIG', 'w') as f:
    json.dump(c, f, indent=2)
PYEOF

    grep -v ":${PORT}#" $LINKS_FILE > /tmp/ss_links_tmp.txt
    mv /tmp/ss_links_tmp.txt $LINKS_FILE

    for CHAIN in INPUT OUTPUT; do
        for PROTO in tcp udp; do
            while iptables -D $CHAIN -p $PROTO --dport $PORT 2>/dev/null; do :; done
            while iptables -D $CHAIN -p $PROTO --sport $PORT 2>/dev/null; do :; done
        done
    done

    apply_config
    echo -e "${RED}🗑 端口 $PORT 已删除${NC}"
}

regen_users() {
    echo -e "${YELLOW}>>> 重新生成所有用户（所有密码将变更）${NC}"
    read -p "确认？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then return; fi

    METHOD=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0]['method'])
")
    USER_COUNT=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(len(c['servers']))
")

    case $METHOD in
        *aes-128*)  KEY_LEN=16 ;;
        *aes-256*|*chacha20*) KEY_LEN=32 ;;
        *) KEY_LEN=0 ;;
    esac

    basic_config
    select_ports || return
    USE_ACL_FLAG=$([ -f "$ACL_PATH" ] && echo true || echo false)

    generate_config
    apply_config
    init_traffic
    show_links
}

# ========== 更新脚本 ==========
do_update() {
    REMOTE_URL="https://raw.githubusercontent.com/chnnic/VOLSS/refs/heads/main/volss.sh"
    TMP_NEW="/tmp/volss_new.sh"

    echo -e "\n${YELLOW}>>> 检查更新...${NC}"
    echo -e "远程地址: ${BLUE}$REMOTE_URL${NC}"

    # 下载新版本
    wget -q -O $TMP_NEW "$REMOTE_URL"
    if [ $? -ne 0 ] || [ ! -s $TMP_NEW ]; then
        echo -e "${RED}❌ 下载失败，请检查网络或 GitHub 地址${NC}"
        return 1
    fi

    # 获取远程版本号
    REMOTE_VER=$(grep '^VERSION=' $TMP_NEW | cut -d'"' -f2)
    LOCAL_VER=$VERSION

    echo -e "本地版本: ${YELLOW}$LOCAL_VER${NC}"
    echo -e "远程版本: ${GREEN}$REMOTE_VER${NC}"

    if [ "$REMOTE_VER" = "$LOCAL_VER" ]; then
        echo -e "${GREEN}✅ 已是最新版本，无需更新${NC}"
        rm -f $TMP_NEW
        return 0
    fi

    read -p "发现新版本 $REMOTE_VER，确认更新？[y/N]: " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        rm -f $TMP_NEW
        return
    fi

    # 备份当前脚本
    cp $SCRIPT_INSTALL_PATH ${SCRIPT_INSTALL_PATH}.bak 2>/dev/null
    echo -e "已备份当前脚本至: ${YELLOW}${SCRIPT_INSTALL_PATH}.bak${NC}"

    # 替换脚本到固定路径
    mv $TMP_NEW $SCRIPT_INSTALL_PATH
    chmod +x $SCRIPT_INSTALL_PATH

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
import json, os

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
    with open(config_file, 'w') as f:
        json.dump(c, f, indent=2)
    print("✅ config.json 已迁移")

# 重新生成 runtime
servers = [dict(s) for s in c['servers'] if not s.get('disabled', False)]
for s in servers:
    s.pop('disabled', None)
    s.pop('acl', None)

runtime = {'servers': servers}
if os.path.exists(acl_path):
    runtime['acl'] = acl_path

with open(runtime_file, 'w') as f:
    json.dump(runtime, f, indent=2)
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
        if grep -q "Restart=on-failure" $SERVICE 2>/dev/null; then
            sed -i 's/Restart=on-failure/Restart=always/' $SERVICE
            echo -e "${GREEN}✅ 服务文件已修复${NC}"
        fi

        # 确保 ExecStop 存在
        if ! grep -q "ExecStop" $SERVICE 2>/dev/null; then
            sed -i "/ExecStart=.*/a ExecStop=/bin/bash -c 'bash $SCRIPT_INSTALL_PATH --save-traffic'" $SERVICE
            echo -e "${GREEN}✅ 服务停止钩子已添加${NC}"
        fi

        systemctl daemon-reload
        systemctl restart shadowsocks-rust
        echo -e "${GREEN}✅ 服务已重启${NC}"
    fi

    echo -e "\n${YELLOW}脚本将重新启动...${NC}"
    sleep 2
    exec bash $SCRIPT_INSTALL_PATH --menu
}

add_acl_domain() {
    if [ ! -f "$ACL_PATH" ]; then
        cat > $ACL_PATH << 'ACLEOF'
[outbound_block_list]
ACLEOF
    fi
    read -p "输入要屏蔽的域名: " NEW_DOMAIN
    if [ -n "$NEW_DOMAIN" ]; then
        NEW_DOMAIN=$(echo "$NEW_DOMAIN" | sed 's/^domain-suffix://; s/^||//; s/^|//; s/^www\.//')
        echo "||$NEW_DOMAIN #manual" >> $ACL_PATH
        systemctl restart shadowsocks-rust
        echo -e "${GREEN}✅ 已添加并重启: $NEW_DOMAIN（含所有子域名）${NC}"
    fi
}

del_acl_domain() {
    if [ ! -f "$ACL_PATH" ]; then
        echo -e "${RED}ACL 文件不存在${NC}"; return
    fi

    # 只列出手动添加的域名
    MANUAL_LIST=$(grep "^||.*#manual" "$ACL_PATH" 2>/dev/null | sed 's/ #manual//')

    if [ -z "$MANUAL_LIST" ]; then
        echo -e "${YELLOW}没有手动添加的域名${NC}"; return
    fi

    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    手动添加的域名${NC}"
    echo -e "${BLUE}  =================================================${NC}"
    echo "$MANUAL_LIST" | sed 's/^||//' | nl -ba
    echo -e "  ${BLUE}=================================================${NC}"

    read -p "输入要删除的编号: " DEL_NUM
    DOMAIN_LINE=$(echo "$MANUAL_LIST" | sed -n "${DEL_NUM}p")
    if [ -z "$DOMAIN_LINE" ]; then echo -e "${RED}无效编号${NC}"; return; fi

    # 精确删除该行（含 #manual 标记）
    sed -i "\|^${DOMAIN_LINE} #manual$|d" $ACL_PATH
    systemctl restart shadowsocks-rust
    echo -e "${GREEN}✅ 已删除: $(echo $DOMAIN_LINE | sed 's/^||//')（含所有子域名）${NC}"
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
    ["finance"]="金融理财|https://raw.githubusercontent.com/hagezi/dns-blocklists/main/wildcard/gambling.txt"
)

# 初始化规则集目录
init_ruleset_dir() {
    mkdir -p $ACL_RULESET_DIR
    # 初始化已安装记录文件
    [ ! -f "$ACL_RULESET_DIR/installed.txt" ] && touch "$ACL_RULESET_DIR/installed.txt"
}

# 下载并转换规则集为 ss-rust ACL 格式
download_ruleset() {
    local NAME=$1
    local URL=$2
    local TMP="/tmp/ruleset_${NAME}.tmp"
    local OUT="$ACL_RULESET_DIR/${NAME}.acl"

    echo -e "  ${YELLOW}下载中: $NAME ...${NC}"
    wget -q -O "$TMP" "$URL"
    if [ $? -ne 0 ] || [ ! -s "$TMP" ]; then
        echo -e "  ${RED}❌ 下载失败: $NAME${NC}"
        rm -f "$TMP"
        return 1
    fi

    # 转换格式：过滤注释和空行，每行加 || 前缀
    grep -v "^#" "$TMP" | grep -v "^$" | sed 's/^/||/' > "$OUT"
    COUNT=$(wc -l < "$OUT")
    rm -f "$TMP"
    echo -e "  ${GREEN}✅ $NAME 已下载，共 $COUNT 条规则${NC}"
    return 0
}

# 重新合并所有规则集到 ACL 文件
rebuild_acl() {
    init_ruleset_dir

    # 读取手动添加的域名（保留）
    MANUAL_DOMAINS=""
    if [ -f "$ACL_PATH" ]; then
        # 提取不属于任何规则集的手动条目（带 #manual 标记）
        MANUAL_DOMAINS=$(grep "^||.*#manual" "$ACL_PATH" 2>/dev/null | sed 's/ #manual//')
    fi

    # 重建 ACL 文件
    cat > $ACL_PATH << 'ACLEOF'
[outbound_block_list]
ACLEOF

    # 写入手动域名
    if [ -n "$MANUAL_DOMAINS" ]; then
        echo "# ---- 手动添加 ----" >> $ACL_PATH
        echo "$MANUAL_DOMAINS" | while read line; do
            echo "$line #manual" >> $ACL_PATH
        done
    fi

    # 写入各规则集
    for RULESET_FILE in $ACL_RULESET_DIR/*.acl; do
        [ -f "$RULESET_FILE" ] || continue
        NAME=$(basename "$RULESET_FILE" .acl)
        COUNT=$(wc -l < "$RULESET_FILE")
        echo "" >> $ACL_PATH
        echo "# ---- $NAME ($COUNT 条) ----" >> $ACL_PATH
        cat "$RULESET_FILE" >> $ACL_PATH
    done

    systemctl restart shadowsocks-rust
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
            DESC_LEN=${#DESC}
            # 每个中文字符多占1列，计算需要补的空格数
            CN_CHARS=$(echo "$DESC" | grep -oP '[\x{4e00}-\x{9fff}]' | wc -l)
            PAD=$((10 - DESC_LEN - CN_CHARS))
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
        read -p "  请选择: " CHOICE

        case $CHOICE in
            [1-9]|10)
                local IDX=$((CHOICE-1))
                local KEY="${KEYS[$IDX]}"
                IFS='|' read -r DESC URL <<< "${RULESET_URLS[$KEY]}"
                if [ -f "$ACL_RULESET_DIR/${KEY}.acl" ]; then
                    echo -e "${YELLOW}$DESC 已安装，重新下载更新？[y/N]${NC}"
                    read -p "" CONFIRM
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
                ls $ACL_RULESET_DIR/*.acl 2>/dev/null | xargs -I{} basename {} .acl | nl -ba
                read -p "输入要卸载的编号: " DEL_IDX
                DEL_NAME=$(ls $ACL_RULESET_DIR/*.acl 2>/dev/null | xargs -I{} basename {} .acl | sed -n "${DEL_IDX}p")
                if [ -n "$DEL_NAME" ]; then
                    rm -f "$ACL_RULESET_DIR/${DEL_NAME}.acl"
                    rebuild_acl
                    echo -e "${GREEN}✅ 已卸载: $DEL_NAME${NC}"
                else
                    echo -e "${RED}无效编号${NC}"
                fi
                ;;
            13)
                echo -e "${YELLOW}>>> 更新已安装规则集...${NC}"
                for RULESET_FILE in $ACL_RULESET_DIR/*.acl; do
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
                read -p "规则集名称 (英文，如 mylist): " CUSTOM_NAME
                read -p "规则集 URL: " CUSTOM_URL
                if [ -n "$CUSTOM_NAME" ] && [ -n "$CUSTOM_URL" ]; then
                    RULESET_URLS["$CUSTOM_NAME"]="自定义|$CUSTOM_URL"
                    download_ruleset "$CUSTOM_NAME" "$CUSTOM_URL" && rebuild_acl
                fi
                ;;
            15)
                echo -e "\n${BLUE}  =================================================${NC}"
                echo -e "${BLUE}    当前生效规则统计${NC}"
                echo -e "${BLUE}  =================================================${NC}"
                if [ -f "$ACL_PATH" ]; then
                    TOTAL=$(grep "^||" "$ACL_PATH" | wc -l)
                    echo -e "  总规则数: ${GREEN}$TOTAL 条${NC}"
                    echo ""
                    for RULESET_FILE in $ACL_RULESET_DIR/*.acl; do
                        [ -f "$RULESET_FILE" ] || continue
                        NAME=$(basename "$RULESET_FILE" .acl)
                        COUNT=$(wc -l < "$RULESET_FILE")
                        printf "  %-15s %s 条\n" "$NAME" "$COUNT"
                    done
                    MANUAL=$(grep "^||.*#manual" "$ACL_PATH" 2>/dev/null | wc -l)
                    [ "$MANUAL" -gt 0 ] && printf "  %-15s %s 条\n" "手动添加" "$MANUAL"
                else
                    echo -e "  未配置 ACL"
                fi
                echo -e "${BLUE}  =================================================${NC}"
                ;;
            0) return ;;
            *) echo -e "${RED}无效选项${NC}" ;;
        esac
        read -p "按回车继续..."
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
            if pgrep -x ssserver > /dev/null 2>&1; then
                SVC_LABEL="${GREEN}● 运行中${NC}"
            else
                SVC_LABEL="${RED}● 已停止${NC}"
            fi
        else
            SS_STATUS="${RED}● 未安装${NC}"
            SVC_LABEL="${RED}● 未运行${NC}"
        fi

        echo -e "  ${BLUE}=================================================${NC}"
        echo -e "    Shadowsocks-Rust 管理脚本    ${VERSION}    快捷命令: volss"
        echo -e "  ${BLUE}=================================================${NC}"
        printf "    安装: %-20b 服务: %-20b\n" "$SS_STATUS" "$SVC_LABEL"
        echo -e "  ${BLUE}-------------------------------------------------${NC}"
        echo -e "  ${CYAN}  -- 安装管理 --${NC}"
        echo -e "      1)  安装 Shadowsocks-Rust"
        echo -e "      2)  卸载 Shadowsocks-Rust"
        echo -e "      3)  更新脚本"
        echo -e "  ${CYAN}  -- 用户管理 --${NC}"
        echo -e "      4)  查看用户列表"
        echo -e "      5)  查看所有 SS 链接"
        echo -e "      6)  暂停某个用户"
        echo -e "      7)  恢复某个用户"
        echo -e "      8)  删除某个用户"
        echo -e "      9)  重新生成所有用户"
        echo -e "  ${CYAN}  -- 流量统计 --${NC}"
        echo -e "     10)  查看流量统计"
        echo -e "     11)  重置流量统计"
        echo -e "  ${CYAN}  -- ACL 黑名单 --${NC}"
        echo -e "     12)  手动添加屏蔽域名"
        echo -e "     13)  手动删除屏蔽域名"
        echo -e "     14)  查看黑名单列表"
        echo -e "     15)  规则集管理（广告/色情/赌博/BT等）"
        echo -e "  ${CYAN}  -- 服务管理 --${NC}"
        echo -e "     16)  查看服务状态"
        echo -e "     17)  启动服务"
        echo -e "     18)  停止服务"
        echo -e "     19)  重启服务"
        echo -e "     20)  查看实时日志"
        echo -e "  ${BLUE}-------------------------------------------------${NC}"
        echo -e "   ${RED}  0)  退出${NC}"
        echo -e "  ${BLUE}=================================================${NC}"
        read -p "  请选择 [0-20]: " CHOICE

        # 未安装时拦截管理功能
        if ! check_installed && [[ "$CHOICE" =~ ^([4-9]|1[0-9]|20)$ ]]; then
            echo -e "${RED}⚠ 请先安装 Shadowsocks-Rust（选项 1）${NC}"
            sleep 2
            continue
        fi

        case $CHOICE in
            1)  do_install ;;
            2)  do_uninstall ;;
            3)  do_update ;;
            4)  list_users;    read -p "按回车继续..." ;;
            5)  show_links;    read -p "按回车继续..." ;;
            6)  disable_user;  read -p "按回车继续..." ;;
            7)  enable_user;   read -p "按回车继续..." ;;
            8)  delete_user;   read -p "按回车继续..." ;;
            9)  regen_users;   read -p "按回车继续..." ;;
            10) show_traffic;  read -p "按回车继续..." ;;
            11) reset_traffic; read -p "按回车继续..." ;;
            12) add_acl_domain; read -p "按回车继续..." ;;
            13) del_acl_domain; read -p "按回车继续..." ;;
            14)
                echo -e "\n${BLUE}  =================================================${NC}"
                echo -e "${BLUE}    ACL 黑名单${NC}"
                echo -e "${BLUE}  =================================================${NC}"
                if [ -f "$ACL_PATH" ]; then
                    MANUAL=$(grep "^||.*#manual" "$ACL_PATH" | sed 's/^||//; s/ #manual//')
                    TOTAL=$(grep "^||" "$ACL_PATH" | wc -l)
                    MANUAL_COUNT=$(grep "^||.*#manual" "$ACL_PATH" | wc -l)
                    RULESET_COUNT=$((TOTAL - MANUAL_COUNT))
                    echo -e "  总规则数: ${GREEN}$TOTAL 条${NC}（手动: $MANUAL_COUNT 条，规则集: $RULESET_COUNT 条）"
                    echo -e "\n  ${CYAN}── 手动添加 ──${NC}"
                    if [ -n "$MANUAL" ]; then
                        echo "$MANUAL" | nl -ba | sed 's/^/  /'
                    else
                        echo "  （无）"
                    fi
                    echo -e "\n  ${CYAN}── 已安装规则集 ──${NC}"
                    FOUND=0
                    if [ -d "$ACL_RULESET_DIR" ]; then
                        for f in $ACL_RULESET_DIR/*.acl; do
                            [ -f "$f" ] || continue
                            NAME=$(basename "$f" .acl)
                            COUNT=$(wc -l < "$f")
                            echo -e "  ${GREEN}●${NC} $NAME ($COUNT 条)"
                            FOUND=1
                        done
                    fi
                    [ "$FOUND" -eq 0 ] && echo "  （未安装任何规则集，请选择选项 15 安装）"
                else
                    echo "  未配置 ACL"
                fi
                read -p "按回车继续..."
                ;;
            15) manage_rulesets ;;
            16) systemctl status shadowsocks-rust --no-pager; read -p "按回车继续..." ;;
            17) systemctl start   shadowsocks-rust && echo -e "${GREEN}✅ 服务已启动${NC}"; read -p "按回车继续..." ;;
            18) systemctl stop    shadowsocks-rust && echo -e "${YELLOW}⏹ 服务已停止${NC}"; read -p "按回车继续..." ;;
            19) systemctl restart shadowsocks-rust && echo -e "${GREEN}🔄 服务已重启${NC}"; read -p "按回车继续..." ;;
            20)
                echo -e "${YELLOW}按 Ctrl+C 退出日志${NC}"
                journalctl -u shadowsocks-rust -f
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
            systemctl restart shadowsocks-rust 2>/dev/null
            echo -e "${GREEN}✅ ACL 格式已自动修复并重启服务${NC}"
        fi
    fi
fi

case "$1" in
    --menu)         show_main_menu ;;
    --save-traffic) save_traffic ;;
    --version)      echo -e "Shadowsocks-Rust 管理脚本 ${GREEN}$VERSION${NC}" ;;
    *)              show_main_menu ;;
esac
