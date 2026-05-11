#!/bin/bash

# ========================================
#   Shadowsocks-Rust 管理脚本
#   版本: V1.0.0
#   快捷命令: ss
# ========================================

VERSION="V1.0.0"

# ========== 颜色定义 ==========
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

# ========== 路径定义 ==========
SS_BIN="/usr/local/bin/ssserver"
CONFIG="/etc/shadowsocks-rust/config.json"
RUNTIME="/etc/shadowsocks-rust/runtime.json"
ACL_PATH="/etc/shadowsocks-rust/blocklist.acl"
LINKS_FILE="/etc/shadowsocks-rust/ss_links.txt"
SERVICE="/etc/systemd/system/shadowsocks-rust.service"
SHORTCUT="/usr/local/bin/ss"

# ========== 检查 root ==========
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本${NC}"
        exit 1
    fi
}

# ========== 打印 Banner ==========
print_banner() {
    echo -e "${BLUE}"
    echo "  ╔═══════════════════════════════════════════╗"
    echo "  ║      Shadowsocks-Rust 管理脚本            ║"
    echo "  ║      版本: ${VERSION}                        ║"
    echo "  ║      快捷命令: ss                          ║"
    echo "  ╚═══════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ========== 检查是否已安装 ==========
check_installed() {
    if [ ! -f "$SS_BIN" ] || [ ! -f "$CONFIG" ]; then
        return 1
    fi
    return 0
}

# =============================================
#   安装流程
# =============================================

# ========== 安装依赖 ==========
install_deps() {
    echo -e "\n${YELLOW}>>> 安装依赖...${NC}"
    apt-get update -qq
    apt-get install -y curl openssl python3 iptables-persistent -qq
    echo -e "${GREEN}✅ 依赖安装完成${NC}"
}

# ========== 安装 ss-rust ==========
install_ssrust() {
    echo -e "\n${YELLOW}>>> 安装 Shadowsocks-Rust...${NC}"

    LATEST=$(curl -s https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest \
        | grep tag_name | cut -d'"' -f4)

    if [ -z "$LATEST" ]; then
        echo -e "${RED}❌ 获取版本号失败，请检查网络${NC}"
        exit 1
    fi

    echo -e "最新版本: ${GREEN}$LATEST${NC}"

    ARCH=$(uname -m)
    case $ARCH in
        x86_64)  ARCH_NAME="x86_64-unknown-linux-gnu" ;;
        aarch64) ARCH_NAME="aarch64-unknown-linux-gnu" ;;
        *)
            echo -e "${RED}不支持的架构: $ARCH${NC}"
            exit 1
            ;;
    esac

    URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${LATEST}/shadowsocks-${LATEST}.${ARCH_NAME}.tar.gz"
    echo "下载中: $URL"
    curl -L -o /tmp/ss-rust.tar.gz "$URL"

    if [ $? -ne 0 ]; then
        echo -e "${RED}❌ 下载失败${NC}"
        exit 1
    fi

    tar -xzf /tmp/ss-rust.tar.gz -C /tmp/
    mv /tmp/ssserver $SS_BIN
    chmod +x $SS_BIN
    mkdir -p /etc/shadowsocks-rust

    echo -e "${GREEN}✅ ss-rust $LATEST 安装完成${NC}"
}

# ========== 选择加密方式 ==========
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

# ========== 基本配置 ==========
basic_config() {
    echo -e "\n${YELLOW}>>> 基本配置${NC}"

    read -p "服务器域名或IP [默认自动检测]: " HOST
    if [ -z "$HOST" ]; then
        HOST=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 ip.sb)
        echo -e "检测到IP: ${GREEN}$HOST${NC}"
    fi

    read -p "起始端口 [默认 30001]: " START_PORT
    START_PORT=${START_PORT:-30001}

    read -p "生成用户数量 [默认 10，最多 50]: " USER_COUNT
    USER_COUNT=${USER_COUNT:-10}
    [ "$USER_COUNT" -gt 50 ] && USER_COUNT=50
}

# ========== 配置 ACL ==========
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

# ========== 生成密码 ==========
gen_password() {
    if [ "$KEY_LEN" -gt 0 ]; then
        openssl rand -base64 $KEY_LEN
    else
        openssl rand -base64 32 | tr -d '=' | cut -c1-24
    fi
}

# ========== 生成配置和链接 ==========
generate_config() {
    echo -e "\n${YELLOW}>>> 生成配置文件和 SS 链接...${NC}"

    if [ "$USE_ACL_FLAG" = true ]; then
        ACL_LINE=",\"acl\":\"$ACL_PATH\""
    else
        ACL_LINE=""
    fi

    echo '{"servers":[' > $CONFIG
    > $LINKS_FILE

    for i in $(seq 1 $USER_COUNT); do
        PORT=$((START_PORT + i - 1))
        PASS=$(gen_password)

        if [ $i -lt $USER_COUNT ]; then
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\"$ACL_LINE}," >> $CONFIG
        else
            echo "  {\"server\":\"::\",\"server_port\":$PORT,\"password\":\"$PASS\",\"method\":\"$METHOD\"$ACL_LINE}" >> $CONFIG
        fi

        USERINFO=$(echo -n "$METHOD:$PASS" | base64 -w 0)
        echo "ss://${USERINFO}@${HOST}:${PORT}#用户${i}" >> $LINKS_FILE
    done

    echo ']}' >> $CONFIG
    echo -e "${GREEN}✅ 配置写入完成${NC}"
}

# ========== 应用配置（排除 disabled）==========
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

# ========== 创建 systemd 服务 ==========
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

# ========== 初始化流量统计 ==========
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

# ========== 注册快捷命令 ==========
install_shortcut() {
    SCRIPT_PATH=$(realpath "$0")
    cat > $SHORTCUT << EOF
#!/bin/bash
bash $SCRIPT_PATH --menu
EOF
    chmod +x $SHORTCUT
    echo -e "${GREEN}✅ 快捷命令已注册: ${YELLOW}ss${NC}"
}

# =============================================
#   管理功能
# =============================================

# ========== 列出当前用户 ==========
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

# ========== 查看流量统计 ==========
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

# ========== 重置流量统计 ==========
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

# ========== 暂停某个用户 ==========
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

# ========== 恢复某个用户 ==========
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

# ========== 删除某个用户 ==========
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

# ========== 重新生成所有用户 ==========
regen_users() {
    echo -e "${YELLOW}>>> 重新生成所有用户（密码会变更）${NC}"
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
    START_PORT=$(python3 -c "
import json
with open('$CONFIG') as f:
    c = json.load(f)
print(c['servers'][0]['server_port'])
")

    case $METHOD in
        *aes-128*)  KEY_LEN=16 ;;
        *aes-256*|*chacha20*) KEY_LEN=32 ;;
        *) KEY_LEN=0 ;;
    esac

    read -p "服务器域名或IP: " HOST
    USE_ACL_FLAG=$([ -f "$ACL_PATH" ] && echo true || echo false)

    generate_config
    apply_config
    init_traffic
    show_links
}

# ========== 添加 ACL 域名 ==========
add_acl_domain() {
    read -p "输入要屏蔽的域名: " NEW_DOMAIN
    if [ -n "$NEW_DOMAIN" ]; then
        if [ ! -f "$ACL_PATH" ]; then
            cat > $ACL_PATH << 'ACLEOF'
[bypass_all]

[proxy_list]

[outbound_block_list]
ACLEOF
        fi
        echo "domain-suffix:$NEW_DOMAIN" >> $ACL_PATH
        systemctl restart shadowsocks-rust
        echo -e "${GREEN}✅ 已添加并重启: $NEW_DOMAIN${NC}"
    fi
}

# ========== 删除 ACL 域名 ==========
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

# ========== 显示所有链接 ==========
show_links() {
    echo -e "\n${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║                    SS 链接列表                       ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    cat $LINKS_FILE
    echo -e "${BLUE}══════════════════════════════════════════════════════${NC}"
    echo -e "  链接已保存至: ${YELLOW}$LINKS_FILE${NC}"
}

# =============================================
#   管理菜单
# =============================================
show_menu() {
    print_banner
    while true; do
        echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║           Shadowsocks-Rust 管理菜单                  ║${NC}"
        echo -e "${BLUE}║           版本: ${VERSION}  快捷命令: ss              ║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 用户管理 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 1)${NC} 查看用户列表                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 2)${NC} 查看所有 SS 链接                           ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 3)${NC} 暂停某个用户                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 4)${NC} 恢复某个用户                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 5)${NC} 删除某个用户                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 6)${NC} 重新生成所有用户                           ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 流量统计 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 7)${NC} 查看流量统计                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 8)${NC} 重置流量统计                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── ACL 黑名单 ────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN} 9)${NC} 添加屏蔽域名                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}10)${NC} 删除屏蔽域名                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}11)${NC} 查看黑名单列表                             ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}  ${CYAN}── 服务管理 ──────────────────────────────────${BLUE}  ║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}12)${NC} 查看服务状态                               ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}13)${NC} 启动服务                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}14)${NC} 停止服务                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}15)${NC} 重启服务                                   ${BLUE}║${NC}"
        echo -e "${BLUE}║${NC}   ${GREEN}16)${NC} 查看实时日志                               ${BLUE}║${NC}"
        echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
        echo -e "${BLUE}║${NC}   ${RED} 0)${NC} 退出                                       ${BLUE}║${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
        read -p "请选择 [0-16]: " CHOICE

        case $CHOICE in
            1)  list_users ;;
            2)  show_links ;;
            3)  disable_user ;;
            4)  enable_user ;;
            5)  delete_user ;;
            6)  regen_users ;;
            7)  show_traffic ;;
            8)  reset_traffic ;;
            9)  add_acl_domain ;;
            10) del_acl_domain ;;
            11)
                echo -e "\n${BLUE}========== ACL 黑名单 ==========${NC}"
                [ -f "$ACL_PATH" ] && grep "domain-suffix:" $ACL_PATH || echo "未配置 ACL"
                ;;
            12) systemctl status shadowsocks-rust --no-pager ;;
            13) systemctl start   shadowsocks-rust && echo -e "${GREEN}✅ 服务已启动${NC}" ;;
            14) systemctl stop    shadowsocks-rust && echo -e "${YELLOW}⏹ 服务已停止${NC}" ;;
            15) systemctl restart shadowsocks-rust && echo -e "${GREEN}🔄 服务已重启${NC}" ;;
            16)
                echo -e "${YELLOW}按 Ctrl+C 退出日志${NC}"
                journalctl -u shadowsocks-rust -f
                ;;
            0)
                echo -e "${GREEN}再见！${NC}"
                break
                ;;
            *) echo -e "${RED}无效选项，请重新输入${NC}" ;;
        esac
    done
}

# =============================================
#   主入口
# =============================================
check_root

case "$1" in
    --menu)
        show_menu
        ;;
    --version)
        echo -e "Shadowsocks-Rust 管理脚本 ${GREEN}$VERSION${NC}"
        ;;
    *)
        print_banner
        if check_installed; then
            echo -e "${GREEN}✅ 检测到已安装，直接进入管理菜单${NC}"
            echo -e "   提示: 随时输入 ${YELLOW}ss${NC} 呼出此菜单"
            sleep 1
            show_menu
        else
            echo -e "${YELLOW}未检测到安装，开始首次安装...${NC}"
            echo ""
            install_deps
            install_ssrust
            select_method
            basic_config
            config_acl
            generate_config
            create_service
            init_traffic
            install_shortcut
            echo ""
            show_links
            echo ""
            echo -e "${GREEN}🎉 安装完成！${NC}"
            echo -e "   输入 ${YELLOW}ss${NC} 随时呼出管理菜单"
        fi
        ;;
esac
