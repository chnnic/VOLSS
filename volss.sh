#!/bin/bash

# ========================================
#   Shadowsocks-Rust 管理脚本
#   版本: V1.0.0
#   快捷命令: volss
# ========================================

VERSION="V1.0.0"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SS_BIN="/usr/local/bin/ssserver"
CONFIG="/etc/shadowsocks-rust/config.json"
RUNTIME="/etc/shadowsocks-rust/runtime.json"
ACL_PATH="/etc/shadowsocks-rust/blocklist.acl"
LINKS_FILE="/etc/shadowsocks-rust/ss_links.txt"
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
    echo -e "${BLUE}"
    echo "  ╔═══════════════════════════════════════════════╗"
    echo "  ║       Shadowsocks-Rust 管理脚本               ║"
    echo "  ║       版本: ${VERSION}   快捷命令: volss         ║"
    echo "  ╚═══════════════════════════════════════════════╝"
    echo -e "${NC}"
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
    apt-get install -y curl openssl python3 iproute2 iptables-persistent -qq
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

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.${ARCH_NAME}.tar.gz"
    echo "下载中: $URL"
    curl -L -o /tmp/ss-rust.tar.gz "$URL"

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 下载失败${NC}"
        return 1
    fi

    tar -xzf /tmp/ss-rust.tar.gz -C /tmp/
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

# ========== 端口分配（顺序 or 随机）==========
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
        # 顺序模式
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
            # 防止无限循环
            if [ $CURRENT -gt 65535 ]; then
                echo -e "${RED}❌ 端口耗尽，无法分配足够端口${NC}"
                return 1
            fi
        done

    else
        # 随机模式
        read -p "端口范围起始 [默认 20000]: " RANGE_START
        read -p "端口范围结束 [默认 60000]: " RANGE_END
        RANGE_START=${RANGE_START:-20000}
        RANGE_END=${RANGE_END:-60000}

        echo -e "\n${YELLOW}>>> 正在随机分配端口（跳过已占用）...${NC}"
        PORT_LIST=()
        TRIED=0
        MAX_TRY=$(( (RANGE_END - RANGE_START) ))

        while [ ${#PORT_LIST[@]} -lt $USER_COUNT ]; do
            RAND_PORT=$(( RANGE_START + RANDOM % (RANGE_END - RANGE_START + 1) ))
            # 检查是否重复或占用
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
[bypass_all]

[proxy_list]

[outbound_block_list]
ACLEOF

        while true; do
            read -p "域名 (空行结束): " DOMAIN
            [ -z "$DOMAIN" ] && break
            echo "domain-suffix:$DOMAIN" >> $ACL_PATH
            echo -e "  ${GREEN}已添加: $DOMAIN${NC}"
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

    if [ "$USE_ACL_FLAG" = true ]; then
        ACL_LINE=",\"acl\":\"$ACL_PATH\""
    else
        ACL_LINE=""
    fi

    echo '{"servers":[' > $CONFIG
    > $LINKS_FILE

    TOTAL=${#PORT_LIST[@]}
    for i in $(seq 0 $((TOTAL - 1))); do
        PORT=${PORT_LIST[$i]}
        PASS=$(gen_password)
        NUM=$((i + 1))

        if [ $NUM -lt $TOTAL ]; then
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\"$ACL_LINE}," >> $CONFIG
        else
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\"$ACL_LINE}" >> $CONFIG
        fi

        USERINFO=$(echo -n "$METHOD:$PASS" | base64 -w 0)
        echo "ss://${USERINFO}@${HOST}:${PORT}#用户${NUM}" >> $LINKS_FILE
    done

    echo ']}' >> $CONFIG
    echo -e "${GREEN}✅ 配置生成完成${NC}"
}

apply_config() {
    python3 << PYEOF
import json

with open('$CONFIG', 'r') as f:
    config = json.load(f)

runtime = {'servers': [dict(s) for s in config['servers'] if not s.get('disabled', False)]}
for s in runtime['servers']:
    s.pop('disabled', None)

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
ExecStart=$SS_BIN -c $RUNTIME
Restart=on-failure
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
    SCRIPT_PATH=$(realpath "$0")
    cat > $SHORTCUT << EOF
#!/bin/bash
bash $SCRIPT_PATH --menu
EOF
    chmod +x $SHORTCUT
    echo -e "${GREEN}✅ 快捷命令已注册: 输入 ${YELLOW}volss${GREEN} 呼出管理菜单${NC}"
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
    rm -f $SS_BIN $SERVICE $SHORTCUT
    rm -rf /etc/shadowsocks-rust
    systemctl daemon-reload

    echo -e "${GREEN}✅ 卸载完成${NC}"
    read -p "按回车继续..."
}

# =============================================
#   管理功能
# =============================================

list_users() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                   当前用户列表                       ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    printf "  ${CYAN}%-4s %-8s %-36s %-6s${NC}\n" "编号" "端口" "加密方式" "状态"
    echo -e "${BLUE}  ──────────────────────────────────────────────────${NC}"

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

    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
}

show_links() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    SS 链接列表                       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    cat $LINKS_FILE
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "  链接已保存至: ${YELLOW}$LINKS_FILE${NC}"
}

show_traffic() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                     流量统计                         ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    printf "  ${CYAN}%-4s %-8s %-14s %-14s %-6s${NC}\n" "编号" "端口" "上行(MB)" "下行(MB)" "状态"
    echo -e "${BLUE}  ──────────────────────────────────────────────────${NC}"

    python3 << PYEOF
import json, subprocess

with open('$CONFIG') as f:
    c = json.load(f)

def get_mb(chain, port, direction):
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
        return total / 1024 / 1024
    except:
        return 0.0

for i, s in enumerate(c['servers'], 1):
    port   = s['server_port']
    tx     = get_mb('OUTPUT', port, 'sport')
    rx     = get_mb('INPUT',  port, 'dport')
    status = '暂停' if s.get('disabled') else '正常'
    color  = '\033[0;31m' if s.get('disabled') else '\033[0;32m'
    reset  = '\033[0m'
    print(f"  {i:<4} {port:<8} {tx:<14.2f} {rx:<14.2f} {color}{status}{reset}")
PYEOF

    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo -e "  ${YELLOW}提示: 流量从规则创建后开始统计，重启服务器后重置${NC}"
}

reset_traffic() {
    list_users
    read -p "输入要重置的用户编号 (0=全部重置): " NUM

    if [ "$NUM" = "0" ]; then
        iptables -Z INPUT
        iptables -Z OUTPUT
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

    for CHAIN in INPUT OUTPUT; do
        LINE=$(iptables -nvL $CHAIN --line-numbers | awk -v p="$PORT" '$0~p{print $1}' | head -1)
        [ -n "$LINE" ] && iptables -Z $CHAIN $LINE 2>/dev/null
    done
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

add_acl_domain() {
    if [ ! -f "$ACL_PATH" ]; then
        cat > $ACL_PATH << 'ACLEOF'
[bypass_all]

[proxy_list]

[outbound_block_list]
ACLEOF
    fi
    read -p "输入要屏蔽的域名: " NEW_DOMAIN
    if [ -n "$NEW_DOMAIN" ]; then
        echo "domain-suffix:$NEW_DOMAIN" >> $ACL_PATH
        systemctl restart shadowsocks-rust
        echo -e "${GREEN}✅ 已添加并重启: $NEW_DOMAIN${NC}"
    fi
}

del_acl_domain() {
    if [ ! -f "$ACL_PATH" ]; then
        echo -e "${RED}ACL 文件不存在${NC}"; return
    fi
    echo -e "\n${BLUE}========== 当前 ACL 黑名单 ==========${NC}"
    grep "domain-suffix:" $ACL_PATH | nl -ba
    echo -e "${BLUE}=====================================${NC}"
    read -p "输入要删除的编号: " DEL_NUM
    DOMAIN_LINE=$(grep "domain-suffix:" $ACL_PATH | sed -n "${DEL_NUM}p")
    if [ -z "$DOMAIN_LINE" ]; then echo -e "${RED}无效编号${NC}"; return; fi
    sed -i "/${DOMAIN_LINE}/d" $ACL_PATH
    systemctl restart shadowsocks-rust
    echo -e "${GREEN}✅ 已删除: $DOMAIN_LINE${NC}"
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
            SVC_STATUS=$(systemctl is-active shadowsocks-rust 2>/dev/null)
            if [ "$SVC_STATUS" = "active" ]; then
                SVC_LABEL="${GREEN}● 运行中${NC}"
            else
                SVC_LABEL="${RED}● 已停止${NC}"
            fi
        else
            SS_STATUS="${RED}● 未安装${NC}"
            SVC_LABEL="${RED}● 未运行${NC}"
        fi

        echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║       Shadowsocks-Rust 管理脚本  ${VERSION}          ║${NC}"
        echo -e "${BLUE}║       快捷命令: volss                                ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
        printf "${BLUE}║${NC}  安装: %-30b 服务: %-20b${BLUE}║${NC}\n" "$SS_STATUS" "$SVC_LABEL"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 安装管理 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 1)${NC} 安装 Shadowsocks-Rust                      ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 2)${NC} 卸载 Shadowsocks-Rust                      ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 用户管理 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 3)${NC} 查看用户列表                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 4)${NC} 查看所有 SS 链接                           ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 5)${NC} 暂停某个用户                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 6)${NC} 恢复某个用户                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 7)${NC} 删除某个用户                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 8)${NC} 重新生成所有用户                           ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 流量统计 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 9)${NC} 查看流量统计                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}10)${NC} 重置流量统计                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── ACL 黑名单 ────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}11)${NC} 添加屏蔽域名                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}12)${NC} 删除屏蔽域名                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}13)${NC} 查看黑名单列表                             ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 服务管理 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}14)${NC} 查看服务状态                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}15)${NC} 启动服务                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}16)${NC} 停止服务                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}17)${NC} 重启服务                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}18)${NC} 查看实时日志                               ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}   ${RED} 0)${NC} 退出                                       ${BLUE}║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
        read -p "请选择 [0-18]: " CHOICE

        # 未安装时拦截管理功能
        if ! check_installed && [[ "$CHOICE" =~ ^([3-9]|1[0-8])$ ]]; then
            echo -e "${RED}⚠ 请先安装 Shadowsocks-Rust（选项 1）${NC}"
            sleep 2
            continue
        fi

        case $CHOICE in
            1)  do_install ;;
            2)  do_uninstall ;;
            3)  list_users;    read -p "按回车继续..." ;;
            4)  show_links;    read -p "按回车继续..." ;;
            5)  disable_user;  read -p "按回车继续..." ;;
            6)  enable_user;   read -p "按回车继续..." ;;
            7)  delete_user;   read -p "按回车继续..." ;;
            8)  regen_users;   read -p "按回车继续..." ;;
            9)  show_traffic;  read -p "按回车继续..." ;;
            10) reset_traffic; read -p "按回车继续..." ;;
            11) add_acl_domain; read -p "按回车继续..." ;;
            12) del_acl_domain; read -p "按回车继续..." ;;
            13)
                echo -e "\n${BLUE}========== ACL 黑名单 ==========${NC}"
                [ -f "$ACL_PATH" ] && grep "domain-suffix:" $ACL_PATH || echo "未配置 ACL"
                read -p "按回车继续..."
                ;;
            14) systemctl status shadowsocks-rust --no-pager; read -p "按回车继续..." ;;
            15) systemctl start   shadowsocks-rust && echo -e "${GREEN}✅ 服务已启动${NC}"; read -p "按回车继续..." ;;
            16) systemctl stop    shadowsocks-rust && echo -e "${YELLOW}⏹ 服务已停止${NC}"; read -p "按回车继续..." ;;
            17) systemctl restart shadowsocks-rust && echo -e "${GREEN}🔄 服务已重启${NC}"; read -p "按回车继续..." ;;
            18)
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

case "$1" in
    --menu)    show_main_menu ;;
    --version) echo -e "Shadowsocks-Rust 管理脚本 ${GREEN}$VERSION${NC}" ;;
    *)         show_main_menu ;;
esac
