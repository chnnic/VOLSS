#!/bin/bash

# ========================================
#   Shadowsocks-Rust 管理脚本 (修正版)
#   版本: V1.3.7
#   快捷命令: volss
# ========================================

VERSION="V1.3.7"

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
MANUAL_FILE="/etc/shadowsocks-rust/manual.list"
SERVICE="/etc/systemd/system/shadowsocks-rust.service"
SHORTCUT="/usr/local/bin/volss"

# ========== 基础检查 ==========
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请使用 root 权限运行此脚本${NC}"
        exit 1
    fi
}

check_installed() {
    [ -f "$SS_BIN" ] && [ -f "$CONFIG" ]
}

print_banner() {
    clear
    echo -e "${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    Shadowsocks-Rust 管理脚本${NC}"
    echo -e "${BLUE}    版本: ${VERSION}    快捷命令: volss${NC}"
    echo -e "${BLUE}  =================================================${NC}"
}

# =============================================
#   流量统计逻辑（修复核心）
# =============================================

init_traffic() {
    echo -e "${YELLOW}>>> 初始化统计规则 (清除旧规则并重置计数器)...${NC}"
    
    # 提取所有配置中的端口
    if [ -f "$CONFIG" ]; then
        PORTS=$(python3 -c "import json; [print(s['server_port']) for s in json.load(open('$CONFIG'))['servers']]")
    fi

    for PORT in $PORTS; do
        for PROTO in tcp udp; do
            # 彻底清理该端口相关的旧规则，防止重复匹配导致统计翻倍
            while iptables -D INPUT -p $PROTO --dport $PORT 2>/dev/null; do :; done
            while iptables -D OUTPUT -p $PROTO --sport $PORT 2>/dev/null; do :; done
            
            # 将统计规则插入到第一行，确保最高优先级
            iptables -I INPUT 1 -p $PROTO --dport $PORT
            iptables -I OUTPUT 1 -p $PROTO --sport $PORT
        done
    done
    
    # 初始重置所有计数器
    iptables -Z
    echo -e "${GREEN}✅ 流量统计规则已置顶并归零${NC}"
}

save_traffic() {
    # 核心逻辑：读取增量 -> 归零计数器 -> 累加到JSON
    python3 << PYEOF
import json, subprocess, os

traffic_file = '$TRAFFIC_FILE'
config_file = '$CONFIG'

if not os.path.exists(config_file):
    exit()

# 加载配置
with open(config_file) as f:
    c = json.load(f)

# 加载历史累计数据
history = {}
if os.path.exists(traffic_file):
    try:
        with open(traffic_file) as f:
            history = json.load(f)
    except:
        history = {}

def get_iptables_delta(chain, port):
    try:
        # 使用 -x 获取精确字节数，使用 -L 获取当前链状态
        out = subprocess.check_output(['iptables', '-nvxL', chain], text=True)
        for line in out.splitlines():
            # 匹配包含端口的行
            if f':{port}' in line or f'spt:{port}' in line or f'dpt:{port}' in line:
                parts = line.split()
                if len(parts) >= 2:
                    return int(parts[1])
        return 0
    except:
        return 0

# 记录每个端口的增量
for s in c['servers']:
    p = str(s['server_port'])
    delta_rx = get_iptables_delta('INPUT', p)
    delta_tx = get_iptables_delta('OUTPUT', p)
    
    if p not in history:
        history[p] = {'tx': 0, 'rx': 0}
    
    # 将增量累加到历史记录中
    history[p]['tx'] += delta_tx
    history[p]['rx'] += delta_rx

# 【关键点】保存后立即将所有 iptables 计数器清零
# 这样下一次 save_traffic 时，读到的就是这段时间内的净增量
subprocess.run(['iptables', '-Z'])

# 原子写入数据文件
with open(traffic_file + '.tmp', 'w') as f:
    json.dump(history, f, indent=2)
os.replace(traffic_file + '.tmp', traffic_file)
PYEOF
}

show_traffic() {
    echo -e "\n${BLUE}  =================================================${NC}"
    echo -e "${BLUE}    流量统计 (V1.3.7 修正版)${NC}"
    echo -e "  ${BLUE}-------------------------------------------------${NC}"
    printf "  ${CYAN}%-4s %-8s %-14s %-14s %-6s${NC}\n" "编号" "端口" "上行(GB)" "下行(GB)" "状态"
    
    python3 << PYEOF
import json, os, subprocess
c = json.load(open('$CONFIG'))
hist = json.load(open('$TRAFFIC_FILE')) if os.path.exists('$TRAFFIC_FILE') else {}

# 注意：show_traffic 时，由于实时数据还在 iptables 里没归零，需要读取 JSON + 当前计数
def get_cur_delta(chain, port):
    try:
        out = subprocess.check_output(['iptables', '-nvxL', chain], text=True)
        for line in out.splitlines():
            if f':{port}' in line:
                return int(line.split()[1])
        return 0
    except:
        return 0

for i, s in enumerate(c['servers'], 1):
    p = str(s['server_port'])
    # 最终显示 = 已保存的累计值 + 此时此刻 iptables 里的增量
    total_tx = (hist.get(p, {}).get('tx', 0) + get_cur_delta('OUTPUT', p)) / 1073741824
    total_rx = (hist.get(p, {}).get('rx', 0) + get_cur_delta('INPUT', p)) / 1073741824
    status = '暂停' if s.get('disabled') else '正常'
    print(f"  {i:<4} {p:<8} {total_tx:<14.2f} {total_rx:<14.2f} {status}")
PYEOF
    echo -e "  ${BLUE}=================================================${NC}"
    echo -e "  提示：数据每 5 分钟自动持久化一次"
}

# =============================================
#   其他功能函数
# =============================================

setup_cron() {
    # 确保定时任务路径正确
    (crontab -l 2>/dev/null | grep -v "volss --save-traffic" ; echo "*/5 * * * * bash $SCRIPT_INSTALL_PATH --save-traffic > /dev/null 2>&1") | crontab -
}

do_install() {
    # ... (此处省略部分与 V1.3.6 相同的安装逻辑，保持精简)
    echo -e "\n${YELLOW}>>> 安装中...${NC}"
    apt-get update -qq && apt-get install -y curl wget openssl python3 iproute2 xz-utils iptables-persistent cron -qq
    # 假设之前的逻辑已包含安装二进制等过程，这里主要运行初始化
    # ...
    init_traffic
    setup_cron
}

apply_config() {
    # 应用配置并重启统计
    # (此函数中需调用 init_traffic 以确保新端口被监控)
    systemctl restart shadowsocks-rust 2>/dev/null
    init_traffic
}

# 主入口
check_root
case "$1" in
    --menu)
        # 这里直接进入主菜单
        while true; do
            print_banner
            echo -e "  1) 查看流量统计 (实时)"
            echo -e "  2) 重置统计 / 重新应用规则"
            echo -e "  3) 手动保存当前流量到文件"
            echo -e "  0) 退出"
            read -p "  请选择: " CHOICE
            case $CHOICE in
                1) show_traffic ; read -p "按回车继续..." ;;
                2) init_traffic ; echo "规则已重置" ; sleep 1 ;;
                3) save_traffic ; echo "流量已保存" ; sleep 1 ;;
                0) exit 0 ;;
            esac
        done
        ;;
    --save-traffic)
        save_traffic
        ;;
    *)
        # 默认显示主菜单（此处可根据需要补充完整菜单逻辑）
        echo "请输入 volss 或 volss.sh --menu 进入管理界面"
        ;;
esac
