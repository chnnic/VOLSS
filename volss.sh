#!/usr/bin/env bash
# =============================================================================
#   VOLSB — sing-box 服务端一键部署与管理脚本
#   版本   : 1.1.8
#   项目   : https://github.com/chnnic/VOLSB
#   模式   : 部署机(落地机) / 线路机(中转机)
#   协议   : VLESS+Reality / Hysteria2 / VMess-WS / Trojan / ShadowTLS
#   系统   : Alpine(OpenRC) / Debian / Ubuntu / CentOS / RHEL /
#             Alma / Rocky / Fedora / openSUSE / Arch
#   快捷键 : 安装后输入 volsb 进入管理界面
# =============================================================================

# 注意：不使用全局 set -e，交互式脚本需要手动处理每处错误
set -uo pipefail

# ──────────────────────── 颜色 & 输出 ────────────────────────
C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[1;33m'
# shellcheck disable=SC2034
C_BLUE='\033[0;34m'; C_CYAN='\033[0;36m'; C_MAGENTA='\033[0;35m'
C_BOLD='\033[1m'; C_DIM='\033[2m'; NC='\033[0m'

info()    { echo -e "${C_GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${C_YELLOW}[!]${NC} $*"; }
err()     { echo -e "${C_RED}[✗]${NC} $*" >&2; }
step()    { echo -e "\n${C_CYAN}${C_BOLD}▶ $*${NC}"; }
ask()     { printf "${C_YELLOW}[?]${NC} %s" "$*"; }
die()     { err "$*"; exit 1; }
hr()      { echo -e "${C_DIM}$(printf '─%.0s' {1..60})${NC}"; }
banner()  { echo -e "\n${C_BOLD}${C_BLUE}  $*${NC}"; }

# ──────────────────────── 全局路径 ────────────────────────
VOLSB_VER="1.1.8"
VOLSB_REPO="https://raw.githubusercontent.com/chnnic/VOLSB/refs/heads/main/volsb.sh"

# ── 环境变量支持 (方便 CI / 自动化部署) ──
# VOLSB_IP        : 指定连接地址,跳过 IP 检测提示
# VOLSB_PORT      : 指定入站端口,跳过端口交互
# VOLSB_SNI       : 指定 Reality SNI,跳过 SNI 交互
# VOLSB_MODE      : 1=部署机 2=线路机,跳过模式选择
# VOLSB_PROTO     : 协议序号,如 "1" "1 2" "0"(全部),跳过协议选择
SB_BIN="/usr/local/bin/sing-box"
SB_CONF_DIR="/etc/sing-box"
SB_CONFIG="${SB_CONF_DIR}/config.json"
SB_CERT_DIR="${SB_CONF_DIR}/certs"
SB_DATA_DIR="/var/lib/sing-box"
SB_LOG_DIR="/var/log/sing-box"
SB_LOG="${SB_LOG_DIR}/sing-box.log"
SB_INFO="${SB_CONF_DIR}/nodes.info"          # 节点明文信息
SB_LINKS="${SB_CONF_DIR}/links.txt"          # 所有分享链接
SB_TRAFFIC="${SB_CONF_DIR}/traffic.json"     # 流量统计缓存
SB_ENV="${SB_CONF_DIR}/volsb.env"            # 持久化运行参数
VOLSB_CMD="/usr/local/bin/volsb"             # 快捷命令路径
# Systemd / OpenRC service
SB_SYSTEMD="/etc/systemd/system/sing-box.service"
SB_OPENRC="/etc/init.d/sing-box"

# ──────────────────────── 系统检测 ────────────────────────
require_root() {
    [[ $EUID -eq 0 ]] || die "请用 root 用户执行  (提示: sudo -i)"
}

detect_os() {
    if [[ -f /etc/alpine-release ]]; then
        OS_ID="alpine"; OS_VER=$(cat /etc/alpine-release)
        OS_NAME="Alpine Linux $OS_VER"
        PKG_UPDATE="apk update -q"; PKG_INSTALL="apk add -q"
        PKGS="curl wget tar jq openssl ca-certificates qrencode coreutils"
        INIT_SYS="openrc"
    elif [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        OS_ID="${ID:-unknown}"
        OS_ID_LIKE="${ID_LIKE:-}"   # 衍生发行版兜底 (PopOS, Mint, Kali 等)
        OS_VER="${VERSION_ID:-0}"
        OS_NAME="${PRETTY_NAME:-$OS_ID}"

        # 用 ID 和 ID_LIKE 共同判断发行版系列
        local os_family="" id_all="${OS_ID} ${OS_ID_LIKE}"
        if echo "$id_all" | grep -qiE "debian|ubuntu|mint|pop|kali|elementary|zorin"; then
            os_family="debian"
        elif echo "$id_all" | grep -qiE "centos|rhel|almalinux|rocky|oracle"; then
            os_family="redhat"
        elif echo "$id_all" | grep -qi "fedora"; then
            os_family="fedora"
        elif echo "$id_all" | grep -qiE "opensuse|sles"; then
            os_family="suse"
        elif echo "$id_all" | grep -qiE "arch|manjaro|endeavour"; then
            os_family="arch"
        else
            os_family="unknown"
        fi

        case "$os_family" in
            debian)
                export DEBIAN_FRONTEND=noninteractive   # 防止 apt 交互提示卡住
                PKG_UPDATE="apt-get update -y -qq"
                PKG_INSTALL="apt-get install -y -qq"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            redhat)
                local pm="yum"; command -v dnf &>/dev/null && pm="dnf"
                PKG_UPDATE="$pm makecache -q"; PKG_INSTALL="$pm install -y -q"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            fedora)
                PKG_UPDATE="dnf makecache -q"; PKG_INSTALL="dnf install -y -q"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            suse)
                PKG_UPDATE="zypper refresh -q"; PKG_INSTALL="zypper install -y -q"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            arch)
                PKG_UPDATE="pacman -Sy --noconfirm"
                PKG_INSTALL="pacman -S --noconfirm --needed"
                PKGS="curl wget tar jq openssl ca-certificates qrencode" ;;
            *) die "不支持的发行版: $OS_ID (ID_LIKE: ${OS_ID_LIKE:-无})" ;;
        esac
        INIT_SYS="systemd"
    else
        die "无法识别操作系统"
    fi
    info "系统: $OS_NAME  |  初始化: $INIT_SYS"
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  ARCH="amd64" ;;
        aarch64|arm64) ARCH="arm64" ;;
        armv7l)        ARCH="armv7" ;;
        s390x)         ARCH="s390x" ;;
        *) die "不支持的 CPU 架构: $(uname -m)" ;;
    esac
}

install_deps() {
    step "安装依赖"
    eval "$PKG_UPDATE" 2>/dev/null || warn "包列表更新失败,继续..."
    # shellcheck disable=SC2086
    eval "$PKG_INSTALL $PKGS" 2>/dev/null || warn "部分依赖安装失败,继续..."
}

# ──────────────────────── sing-box 下载安装 ────────────────────────
get_latest_version() {
    local v
    v=$(curl -fsSL --max-time 10 \
        "https://api.github.com/repos/SagerNet/sing-box/releases/latest" \
        | jq -r '.tag_name // empty' 2>/dev/null | sed 's/^v//')
    [[ -n "$v" ]] || die "获取最新版本失败,请检查网络或 GitHub 访问"
    echo "$v"
}

install_binary() {
    local ver="$1"
    local tmpdir; tmpdir=$(mktemp -d)
    local pkg="sing-box-${ver}-linux-${ARCH}.tar.gz"
    local url="https://github.com/SagerNet/sing-box/releases/download/v${ver}/${pkg}"
    info "下载 sing-box v${ver} (${ARCH})..."
    curl -fsSL --max-time 180 -o "${tmpdir}/${pkg}" "$url" \
        || { rm -rf "$tmpdir"; die "下载失败: $url"; }
    tar -xzf "${tmpdir}/${pkg}" -C "$tmpdir" 2>/dev/null || die "解压失败"
    install -m 755 "${tmpdir}/sing-box-${ver}-linux-${ARCH}/sing-box" "$SB_BIN"
    rm -rf "$tmpdir"
    info "sing-box 已安装: $("$SB_BIN" version | head -1)"
}

setup_dirs() {
    mkdir -p "$SB_CONF_DIR" "$SB_CERT_DIR" "$SB_LOG_DIR" "$SB_DATA_DIR"
    chmod 700 "$SB_CERT_DIR"
}

# ──────────────────────── 服务管理 (systemd / OpenRC) ────────────────────────
install_service() {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        cat > "$SB_OPENRC" <<'RC'
#!/sbin/openrc-run
name="sing-box"
description="sing-box proxy server"
command="/usr/local/bin/sing-box"
command_args="-D /var/lib/sing-box -C /etc/sing-box run"
command_background=true
pidfile="/run/${RC_SVCNAME}.pid"
output_log="/var/log/sing-box/sing-box.log"
error_log="/var/log/sing-box/sing-box.log"

depend() { need net; after firewall; }

start_pre() {
    /usr/local/bin/sing-box check -C /etc/sing-box || return 1
    mkdir -p /var/lib/sing-box /var/log/sing-box
}
RC
        chmod +x "$SB_OPENRC"
        rc-update add sing-box default &>/dev/null
        info "OpenRC 服务已注册 (开机自启)"
    else
        cat > "$SB_SYSTEMD" <<'UNIT'
[Unit]
Description=sing-box proxy server
Documentation=https://sing-box.sagernet.org
After=network.target network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
WorkingDirectory=/var/lib/sing-box
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=10s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNIT
        systemctl daemon-reload
        systemctl enable sing-box &>/dev/null
        info "Systemd 服务已注册 (开机自启)"
    fi
}

svc_start()   {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box start
    else systemctl start sing-box; fi
}
svc_stop()    {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box stop
    else systemctl stop sing-box; fi
}
svc_restart() {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box restart
    else systemctl restart sing-box; fi
}
svc_status()  {
    if [[ "$INIT_SYS" == "openrc" ]]; then rc-service sing-box status
    else systemctl status sing-box --no-pager -l | head -30; fi
}
svc_active()  {
    if [[ "$INIT_SYS" == "openrc" ]]; then
        rc-service sing-box status 2>/dev/null | grep -q "started"
    else
        systemctl is-active --quiet sing-box 2>/dev/null
    fi
}

# ──────────────────────── 工具函数 ────────────────────────
get_public_ip() {
    local ip=""
    # 依次尝试多个 API，优先 IPv4
    for api in         "https://api.ipify.org"         "https://ipinfo.io/ip"         "https://ifconfig.me/ip"         "https://icanhazip.com"         "https://ipecho.net/plain"; do
        ip=$(curl -fsSL --max-time 5 "$api" 2>/dev/null | tr -d '[:space:]')
        # 校验是否为合法 IPv4 格式
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"; return 0
        fi
    done
    # IPv6 fallback
    ip=$(curl -fsSL --max-time 5 "https://api6.ipify.org" 2>/dev/null | tr -d '[:space:]')
    echo "${ip:-}"
}

random_port() {
    local p
    while :; do
        p=$(( RANDOM % 45000 + 10000 ))
        ss -tuln 2>/dev/null | grep -q ":${p} " || { echo "$p"; return; }
    done
}

gen_uuid()     { "$SB_BIN" generate uuid; }
gen_rand_str() { openssl rand -base64 48 | tr -d '+/=\n' | head -c "${1:-32}"; }
gen_rand_hex() { openssl rand -hex "${1:-8}"; }

gen_self_cert() {
    local cn="${1:-bing.com}"
    local crt="${SB_CERT_DIR}/${cn}.crt"
    local key="${SB_CERT_DIR}/${cn}.key"
    if [[ ! -f "$crt" ]]; then
        openssl ecparam -genkey -name prime256v1 -out "$key" 2>/dev/null
        openssl req -new -x509 -days 36500 -key "$key" -out "$crt" \
            -subj "/CN=${cn}" 2>/dev/null
        chmod 600 "$key"
    fi
    echo "${crt}:${key}"
}

open_port() {
    local port="$1" proto="${2:-tcp}"
    command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "active" && \
        ufw allow "${port}/${proto}" &>/dev/null || true
    command -v firewall-cmd &>/dev/null && \
        systemctl is-active --quiet firewalld 2>/dev/null && {
            firewall-cmd --permanent --add-port="${port}/${proto}" &>/dev/null || true
            firewall-cmd --reload &>/dev/null || true
        }
    # iptables fallback
    command -v iptables &>/dev/null && {
        iptables  -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
        ip6tables -I INPUT -p "$proto" --dport "$port" -j ACCEPT 2>/dev/null || true
    }
}

print_qr() {
    command -v qrencode &>/dev/null || return
    echo -e "\n${C_DIM}  扫码导入:${NC}"
    echo "$1" | qrencode -t ANSIUTF8 2>/dev/null || true
}

save_env() { declare -p "$1" >> "$SB_ENV" 2>/dev/null || true; }

load_env() {
    # shellcheck disable=SC1090
    [[ -f "$SB_ENV" ]] && source "$SB_ENV" 2>/dev/null || true
}

# ──────────────────────── acme.sh Let's Encrypt ────────────────────────
acme_issue() {
    local domain="$1"
    local crt="${SB_CERT_DIR}/${domain}.crt"
    local key="${SB_CERT_DIR}/${domain}.key"
    [[ -f "$crt" && -f "$key" ]] && { info "证书已存在,跳过申请"; return; }
    info "申请 Let's Encrypt 证书 (域名: $domain)..."
    svc_stop 2>/dev/null || true
    [[ -f ~/.acme.sh/acme.sh ]] || \
        curl -fsSL https://get.acme.sh | sh -s "email=acme@${domain}" >/dev/null 2>&1 \
        || die "acme.sh 安装失败"
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1
    ~/.acme.sh/acme.sh --issue -d "$domain" --standalone -k ec-256 --httpport 80 \
        || die "证书申请失败 — 请确认: ① 域名已解析到本机 ② 80端口未被占用"
    ~/.acme.sh/acme.sh --install-cert -d "$domain" --ecc \
        --cert-file "$crt" --key-file "$key" \
        --reloadcmd "$(command -v bash) $(readlink -f "$0") restart"
    info "证书已安装: $crt"
}

# ════════════════════════════════════════════════════════════
#  ██████╗ ███████╗██████╗ ██╗      ██████╗ ██╗   ██╗
#  ██╔══██╗██╔════╝██╔══██╗██║     ██╔═══██╗╚██╗ ██╔╝
#  ██║  ██║█████╗  ██████╔╝██║     ██║   ██║ ╚████╔╝
#  ██║  ██║██╔══╝  ██╔═══╝ ██║     ██║   ██║  ╚██╔╝
#  ██████╔╝███████╗██║     ███████╗╚██████╔╝   ██║
#  ╚═════╝ ╚══════╝╚═╝     ╚══════╝ ╚═════╝    ╚═╝
#           MODE: 部署机 (落地机)
# ════════════════════════════════════════════════════════════

# 全局:存放当前安装的所有入站 JSON 片段
declare -a ALL_INBOUNDS=()
declare -a ALL_LINKS=()

# ────── 公共参数收集:连接IP/域名 ──────
ask_connect_addr() {
    # 支持环境变量 VOLSB_IP 跳过交互
    if [[ -n "${VOLSB_IP:-}" ]]; then
        CONNECT_ADDR="$VOLSB_IP"
        info "连接地址 (环境变量): $CONNECT_ADDR"
        return
    fi

    local auto_ip; auto_ip=$(get_public_ip)
    echo ""
    echo "  节点链接中使用的连接地址:"
    echo "  ① 自动检测公网IP: ${C_CYAN}${auto_ip:-检测失败}${NC}"
    echo "  ② 手动输入 IP 或 DDNS 域名"
    ask "选择 [1/2] 默认1: "; read -r opt
    if [[ "$opt" == "2" ]]; then
        ask "输入 IP 或域名: "; read -r CONNECT_ADDR
        [[ -z "$CONNECT_ADDR" ]] && CONNECT_ADDR="${auto_ip:-127.0.0.1}"
    else
        CONNECT_ADDR="${auto_ip:-127.0.0.1}"
    fi
    info "连接地址: $CONNECT_ADDR"
}

# ────── 多用户输入 ──────
# 结果写入全局变量 USER_COUNT，避免子 shell 吞掉 read
USER_COUNT=1
ask_multi_user_count() {
    ask "生成节点数量 (1-10, 回车默认1): "; read -r _cnt
    [[ "$_cnt" =~ ^[1-9][0-9]?$ ]] || _cnt=1
    [[ "$_cnt" -gt 10 ]] && _cnt=10
    USER_COUNT="$_cnt"
}

# ────── 协议 1: VLESS + XTLS-Reality ──────
deploy_vless_reality() {
    step "配置 VLESS + XTLS-Reality"

    local port sni
    # 支持环境变量 VOLSB_PORT / VOLSB_SNI
    if [[ -n "${VOLSB_PORT:-}" ]]; then
        port="$VOLSB_PORT"; info "端口 (环境变量): $port"
    else
        ask "监听端口 (回车随机): "; read -r port
        [[ -z "$port" ]] && port=$(random_port)
    fi

    if [[ -n "${VOLSB_SNI:-}" ]]; then
        sni="$VOLSB_SNI"; info "SNI (环境变量): $sni"
    else
        echo ""
        echo "  SNI 用于伪装 TLS 握手,建议选目标国大型网站:"
        echo "  推荐: www.cloudflare.com / www.microsoft.com / www.apple.com / dl.google.com"
        ask "输入 SNI [默认 www.cloudflare.com]: "; read -r sni
        [[ -z "$sni" ]] && sni="www.cloudflare.com"
    fi

    # 生成 Reality 密钥对
    local keypair; keypair=$("$SB_BIN" generate reality-keypair)
    local priv_key; priv_key=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    local pub_key;  pub_key=$(echo  "$keypair" | awk '/PublicKey/{print $2}')

    ask_multi_user_count; local user_count="$USER_COUNT"

    # 先收集所有用户数据，保证 short_id 在 link 和配置里完全一致
    local users_json="["
    local short_ids_json="["
    local idx=0

    for i in $(seq 1 "$user_count"); do
        local uuid; uuid=$(gen_uuid)
        local short_id; short_id=$(gen_rand_hex 8)

        [[ $idx -gt 0 ]] && { users_json+=","; short_ids_json+=","; }
        (( idx++ )) || true

        users_json+=$(printf '{"uuid":"%s","flow":"xtls-rprx-vision"}' "$uuid")
        short_ids_json+=$(printf '"%s"' "$short_id")

        local link="vless://${uuid}@${CONNECT_ADDR}:${port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${short_id}&type=tcp#VOLSB-Reality-${i}"
        ALL_LINKS+=("$link")

        cat >> "$SB_INFO" <<INFO
  [VLESS-Reality #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port}
    UUID     : ${uuid}
    SNI      : ${sni}
    PublicKey: ${pub_key}
    ShortID  : ${short_id}
    Flow     : xtls-rprx-vision
    链接     : ${link}
INFO
    done
    users_json+="]"
    short_ids_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port      "$port" \
        --argjson users     "$users_json" \
        --arg     sni       "$sni" \
        --arg     priv_key  "$priv_key" \
        --argjson short_ids "$short_ids_json" \
        '{type:"vless",tag:"vless-reality-in",listen:"::",listen_port:$port,
           users:$users,tls:{enabled:true,server_name:$sni,
           reality:{enabled:true,handshake:{server:$sni,server_port:443},
           private_key:$priv_key,short_id:$short_ids}}}')
    ALL_INBOUNDS+=("$inbound")

    open_port "$port" tcp
    info "✓ VLESS-Reality | 端口:$port | 用户数:$user_count | SNI:$sni"
}

# ────── 协议 2: Hysteria2 ──────
deploy_hysteria2() {
    step "配置 Hysteria2"

    local port; ask "监听端口 (回车随机): "; read -r port
    [[ -z "$port" ]] && port=$(random_port)

    local masq_domain cert_path key_path insecure="true"
    echo "  TLS 证书:"
    echo "   1) 自签证书 (客户端需开 insecure)  2) Let's Encrypt 正式证书"
    ask "选择 [1/2] 默认1: "; read -r cc; [[ -z "$cc" ]] && cc="1"
    if [[ "$cc" == "2" ]]; then
        ask "域名: "; read -r masq_domain; [[ -z "$masq_domain" ]] && die "域名不能为空"
        acme_issue "$masq_domain"
        cert_path="${SB_CERT_DIR}/${masq_domain}.crt"
        key_path="${SB_CERT_DIR}/${masq_domain}.key"
        insecure="false"
    else
        masq_domain="bing.com"
        local pair; pair=$(gen_self_cert "$masq_domain")
        cert_path="${pair%%:*}"; key_path="${pair##*:}"
    fi

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local pwd; pwd=$(gen_rand_str 24)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+="{\"password\":\"${pwd}\"}"
        local ins_param=""; [[ "$insecure" == "true" ]] && ins_param="&insecure=1"
        local link="hysteria2://${pwd}@${CONNECT_ADDR}:${port}/?sni=${masq_domain}${ins_param}#VOLSB-HY2-${i}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [Hysteria2 #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port} (UDP)
    密码     : ${pwd}
    SNI      : ${masq_domain}
    跳过验证 : ${insecure}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     cert  "$cert_path" \
        --arg     key   "$key_path" \
        '{type:"hysteria2",tag:"hysteria2-in",listen:"::",listen_port:$port,
           users:$users,tls:{enabled:true,alpn:["h3"],
           certificate_path:$cert,key_path:$key}}')
    ALL_INBOUNDS+=("$inbound")

    open_port "$port" udp
    info "✓ Hysteria2 | 端口:$port (UDP) | 用户数:$user_count"
}

# ────── 协议 3: VMess + WebSocket ──────
deploy_vmess_ws() {
    step "配置 VMess + WebSocket"
    local port ws_path
    ask "监听端口 (回车随机, 建议80): "; read -r port; [[ -z "$port" ]] && port=$(random_port)
    ask "WebSocket 路径 (回车随机): "; read -r ws_path
    [[ -z "$ws_path" ]] && ws_path="/$(gen_rand_hex 6)"
    [[ "${ws_path:0:1}" != "/" ]] && ws_path="/${ws_path}"

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local uuid; uuid=$(gen_uuid)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+="{\"uuid\":\"${uuid}\",\"alterId\":0}"
        local vmjson="{\"v\":\"2\",\"ps\":\"VOLSB-VMess-${i}\",\"add\":\"${CONNECT_ADDR}\",\"port\":\"${port}\",\"id\":\"${uuid}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"\",\"path\":\"${ws_path}\",\"tls\":\"\"}"
        local b64; b64=$(echo -n "$vmjson" | base64 -w0)
        local link="vmess://${b64}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [VMess-WS #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port}
    UUID     : ${uuid}
    路径     : ${ws_path}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     path  "$ws_path" \
        '{type:"vmess",tag:"vmess-ws-in",listen:"::",listen_port:$port,
           users:$users,transport:{type:"ws",path:$path}}')
    ALL_INBOUNDS+=("$inbound")

    open_port "$port" tcp
    info "✓ VMess-WS | 端口:$port | 路径:$ws_path | 用户数:$user_count"
}

# ────── 协议 4: Trojan + TLS ──────
deploy_trojan() {
    step "配置 Trojan + TLS"
    local port; ask "监听端口 (回车默认443): "; read -r port; [[ -z "$port" ]] && port=443
    local masq_domain cert_path key_path insecure="true"
    echo "  TLS 证书:  1) 自签  2) Let's Encrypt"
    ask "选择 [1/2] 默认1: "; read -r cc; [[ -z "$cc" ]] && cc="1"
    if [[ "$cc" == "2" ]]; then
        ask "域名: "; read -r masq_domain; [[ -z "$masq_domain" ]] && die "域名不能为空"
        acme_issue "$masq_domain"
        cert_path="${SB_CERT_DIR}/${masq_domain}.crt"
        key_path="${SB_CERT_DIR}/${masq_domain}.key"
        insecure="false"
    else
        masq_domain="bing.com"
        local pair; pair=$(gen_self_cert "$masq_domain")
        cert_path="${pair%%:*}"; key_path="${pair##*:}"
    fi

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local idx=0
    for i in $(seq 1 "$user_count"); do
        local pwd; pwd=$(gen_rand_str 24)
        [[ $idx -gt 0 ]] && users_json+=","
        (( idx++ )) || true
        users_json+="{\"password\":\"${pwd}\"}"
        local ins_param=""; [[ "$insecure" == "true" ]] && ins_param="&allowInsecure=1"
        local link="trojan://${pwd}@${CONNECT_ADDR}:${port}?sni=${masq_domain}${ins_param}#VOLSB-Trojan-${i}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [Trojan #${i}]
    地址     : ${CONNECT_ADDR}
    端口     : ${port}
    密码     : ${pwd}
    SNI      : ${masq_domain}
    跳过验证 : ${insecure}
    链接     : ${link}
INFO
    done
    users_json+="]"

    local inbound
    inbound=$(jq -n \
        --argjson port  "$port" \
        --argjson users "$users_json" \
        --arg     cert  "$cert_path" \
        --arg     key   "$key_path" \
        '{type:"trojan",tag:"trojan-in",listen:"::",listen_port:$port,
           users:$users,tls:{enabled:true,certificate_path:$cert,key_path:$key}}')
    ALL_INBOUNDS+=("$inbound")

    open_port "$port" tcp
    info "✓ Trojan | 端口:$port | 用户数:$user_count"
}

# ────── 协议 5: ShadowTLS v3 + Shadowsocks ──────
deploy_shadowtls() {
    step "配置 ShadowTLS v3 + Shadowsocks"
    local stls_port sni
    ask "ShadowTLS 监听端口 (回车随机): "; read -r stls_port
    [[ -z "$stls_port" ]] && stls_port=$(random_port)
    echo "  推荐 SNI: www.bing.com / www.apple.com / gateway.icloud.com"
    ask "伪装 SNI [默认 www.bing.com]: "; read -r sni; [[ -z "$sni" ]] && sni="www.bing.com"

    local ss_port; ss_port=$(random_port)
    ask_multi_user_count; local user_count="$USER_COUNT"
    local stls_users="["; local ss_users="["; local idx=0

    for i in $(seq 1 "$user_count"); do
        local sp; sp=$(gen_rand_str 32)
        local ssp; ssp=$(gen_rand_str 32)
        [[ $idx -gt 0 ]] && { stls_users+=","; ss_users+=","; }
        (( idx++ )) || true
        stls_users+="{\"name\":\"user${i}\",\"password\":\"${sp}\"}"
        ss_users+="{\"name\":\"user${i}\",\"password\":\"${ssp}\"}"
        cat >> "$SB_INFO" <<INFO
  [ShadowTLS v3 #${i}]
    地址         : ${CONNECT_ADDR}
    ShadowTLS 端口: ${stls_port}
    ShadowTLS 密码: ${sp}
    SS 内层密码  : ${ssp}
    SS 加密      : 2022-blake3-aes-128-gcm
    伪装 SNI     : ${sni}
    [客户端配置见: https://sing-box.sagernet.org/configuration/outbound/shadowtls/]
INFO
    done
    stls_users+="]"; ss_users+="]"

    local stls_inbound ss_inbound
    stls_inbound=$(jq -n \
        --argjson port  "$stls_port" \
        --argjson users "$stls_users" \
        --arg     sni   "$sni" \
        '{type:"shadowtls",tag:"shadowtls-in",listen:"::",listen_port:$port,
           version:3,users:$users,handshake:{server:$sni,server_port:443},
           detour:"ss-backend-in"}')
    ss_inbound=$(jq -n \
        --argjson port  "$ss_port" \
        --argjson users "$ss_users" \
        '{type:"shadowsocks",tag:"ss-backend-in",listen:"127.0.0.1",
           listen_port:$port,method:"2022-blake3-aes-128-gcm",users:$users}')
    ALL_INBOUNDS+=("$stls_inbound")
    ALL_INBOUNDS+=("$ss_inbound")

    open_port "$stls_port" tcp
    info "✓ ShadowTLS v3 | 端口:$stls_port | 用户数:$user_count | SNI:$sni"
}

# ════════════════════════════════════════════════════════════
#  线路机 (中转机) 模式
#  原理: VLESS-Reality 入站 → Shadowsocks 出站 → 落地机
# ════════════════════════════════════════════════════════════

deploy_relay() {
    step "线路机模式部署"
    echo ""
    warn "线路机模式: 本机接收 VLESS-Reality 流量,转发至落地机 Shadowsocks 节点"
    echo ""

    # ── 落地机信息 ──
    banner "落地机 (Shadowsocks) 信息"
    echo ""
    echo "  输入方式:"
    echo "   1) 粘贴 SS 链接  (ss://...)"
    echo "   2) 手动输入"
    ask "选择 [1/2] 默认1: "; read -r ss_input_mode
    [[ -z "$ss_input_mode" ]] && ss_input_mode="1"

    if [[ "$ss_input_mode" == "1" ]]; then
        # ── 解析 SS 链接 ──
        ask "粘贴 SS 链接: "; read -r ss_link
        [[ -z "$ss_link" ]] && { err "SS 链接不能为空"; return 1; }

        # 去掉 ss:// 前缀和 #备注 后缀
        local ss_body; ss_body="${ss_link#ss://}"
        ss_body="${ss_body%%#*}"

        # 判断格式：SIP002 (method:pwd@host:port) 或 旧格式 (base64@host:port)
        if echo "$ss_body" | grep -q '@'; then
            local userinfo hostinfo
            userinfo="${ss_body%@*}"   # method:pwd 或 base64
            hostinfo="${ss_body##*@}"  # host:port

            # 提取 host 和 port（支持 IPv6 [::1]:port）
            if echo "$hostinfo" | grep -q '^\['; then
                LAND_ADDR="${hostinfo%]*}"; LAND_ADDR="${LAND_ADDR#[}"
                LAND_PORT="${hostinfo##*]:}"
            else
                LAND_ADDR="${hostinfo%:*}"
                LAND_PORT="${hostinfo##*:}"
            fi

            # 判断 userinfo 是否是 base64（不含 : 则是 base64）
            if echo "$userinfo" | grep -q ':'; then
                # SIP002 明文格式：method:password
                LAND_METHOD="${userinfo%%:*}"
                LAND_PASS="${userinfo#*:}"
            else
                # 旧格式：base64(method:password)
                local decoded; decoded=$(echo "$userinfo" | base64 -d 2>/dev/null                     || echo "$userinfo" | base64 -di 2>/dev/null || true)
                if [[ -n "$decoded" && "$decoded" == *:* ]]; then
                    LAND_METHOD="${decoded%%:*}"
                    LAND_PASS="${decoded#*:}"
                else
                    err "SS 链接解析失败，请检查格式"; return 1
                fi
            fi
        else
            err "SS 链接格式不正确，应为 ss://...@host:port"; return 1
        fi

        # 验证解析结果
        if [[ -z "$LAND_ADDR" || -z "$LAND_PORT" || -z "$LAND_PASS" || -z "$LAND_METHOD" ]]; then
            err "SS 链接解析失败: addr=$LAND_ADDR port=$LAND_PORT method=$LAND_METHOD"
            return 1
        fi
        info "解析成功: ${LAND_METHOD} @ ${LAND_ADDR}:${LAND_PORT}"

    else
        # ── 手动输入 ──
        ask "落地机 IP 或域名: "; read -r LAND_ADDR
        [[ -z "$LAND_ADDR" ]] && { err "落地机地址不能为空"; return 1; }
        ask "落地机 SS 端口: "; read -r LAND_PORT
        [[ -z "$LAND_PORT" ]] && { err "落地机端口不能为空"; return 1; }
        ask "落地机 SS 密码: "; read -r LAND_PASS
        [[ -z "$LAND_PASS" ]] && { err "落地机密码不能为空"; return 1; }
        echo "  加密方式:  1) 2022-blake3-aes-128-gcm (推荐)  2) aes-256-gcm  3) chacha20-ietf-poly1305"
        ask "选择 [1-3] 默认1: "; read -r enc_choice
        case "${enc_choice:-1}" in
            2) LAND_METHOD="aes-256-gcm" ;;
            3) LAND_METHOD="chacha20-ietf-poly1305" ;;
            *)  LAND_METHOD="2022-blake3-aes-128-gcm" ;;
        esac
    fi

    # ── 线路机入站 (VLESS-Reality) ──
    banner "线路机入站配置"
    ask_connect_addr  # 获取线路机自身公网IP

    local in_port sni
    ask "入站端口 (回车随机): "; read -r in_port; [[ -z "$in_port" ]] && in_port=$(random_port)
    echo "  SNI 推荐: www.cloudflare.com / www.microsoft.com"
    ask "伪装 SNI [默认 www.cloudflare.com]: "; read -r sni; [[ -z "$sni" ]] && sni="www.cloudflare.com"

    local keypair; keypair=$("$SB_BIN" generate reality-keypair)
    local priv_key; priv_key=$(echo "$keypair" | awk '/PrivateKey/{print $2}')
    local pub_key;  pub_key=$(echo  "$keypair" | awk '/PublicKey/{print $2}')

    ask_multi_user_count; local user_count="$USER_COUNT"
    local users_json="["; local short_ids="["; local idx=0

    for i in $(seq 1 "$user_count"); do
        local uuid; uuid=$(gen_uuid)
        local sid; sid=$(gen_rand_hex 8)
        [[ $idx -gt 0 ]] && { users_json+=","; short_ids+=","; }
        (( idx++ )) || true
        users_json+="{\"uuid\":\"${uuid}\",\"flow\":\"xtls-rprx-vision\"}"
        short_ids+="\"${sid}\""
        local link="vless://${uuid}@${CONNECT_ADDR}:${in_port}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pub_key}&sid=${sid}&type=tcp#VOLSB-Relay-${i}"
        ALL_LINKS+=("$link")
        cat >> "$SB_INFO" <<INFO
  [线路机 VLESS-Reality #${i}]
    连接地址  : ${CONNECT_ADDR}
    端口      : ${in_port}
    UUID      : ${uuid}
    PublicKey : ${pub_key}
    ShortID   : ${sid}
    落地机    : ${LAND_ADDR}:${LAND_PORT}
    链接      : ${link}
INFO
    done
    users_json+="]"; short_ids+="]"

    # ── 写入配置 ──
    mkdir -p "$SB_CONF_DIR"
    cat > "$SB_CONFIG" <<JSON
{
  "log": {"level": "warn", "output": "${SB_LOG}", "timestamp": true},
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-relay-in",
      "listen": "::",
      "listen_port": ${in_port},
      "users": ${users_json},
      "tls": {
        "enabled": true,
        "server_name": "${sni}",
        "reality": {
          "enabled": true,
          "handshake": {"server": "${sni}", "server_port": 443},
          "private_key": "${priv_key}",
          "short_id": ${short_ids}
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "ss-land",
      "server": "${LAND_ADDR}",
      "server_port": ${LAND_PORT},
      "method": "${LAND_METHOD}",
      "password": "${LAND_PASS}"
    },
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ],
  "route": {
    "rules": [{"inbound": ["vless-relay-in"], "outbound": "ss-land"}],
    "final": "direct"
  }
}
JSON

    open_port "$in_port" tcp
    info "✓ 线路机配置完成 | 入站端口:$in_port → 落地:${LAND_ADDR}:${LAND_PORT}"

    # ── 生成回到落地机的一键线路机安装命令 ──
    banner "一键安装命令 (在其他线路机上执行)"
    echo ""
    echo -e "  ${C_YELLOW}以下命令可直接在其他 VPS 上运行,生成相同配置的线路机:${NC}"
    echo ""
    local script_url="https://raw.githubusercontent.com/your-repo/volsb/main/volsb.sh"
    echo -e "  ${C_CYAN}bash <(curl -fsSL ${script_url}) relay \\
    --land-addr '${LAND_ADDR}' \\
    --land-port '${LAND_PORT}' \\
    --land-pass '${LAND_PASS}' \\
    --land-method '${LAND_METHOD}'${NC}"
    echo ""
}

# ════════════════════════════════════════════════════════════
#  配置组装 & 写入
# ════════════════════════════════════════════════════════════

select_protocols() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'BANNER'
  ┌──────────────────────────────────────────────────────┐
  │        VOLSB — 部署机协议选择                        │
  └──────────────────────────────────────────────────────┘
BANNER
    echo -e "${NC}"
    hr
    printf "  ${C_BOLD}%-5s %-30s %-10s %s${NC}\n" "序号" "协议" "传输" "说明"
    hr
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "1)" "VLESS + XTLS-Reality"     "TCP"   "★ 推荐 | 抗审查首选,无需域名"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "2)" "Hysteria2"                "UDP"   "★ 推荐 | 高速UDP,弱网友好"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "3)" "VMess + WebSocket"        "TCP/WS" "适合套 CDN / Nginx 反代"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "4)" "Trojan + TLS"             "TCP"   "经典方案,广泛兼容"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "5)" "ShadowTLS v3 + SS"        "TCP"   "真实 TLS 握手伪装"
    printf "  ${C_BOLD}%-5s${NC} %-30s %-10s %s\n" "0)" "全部协议"                 "-"     "同时部署以上所有"
    hr
    echo ""
    echo -e "  支持多选: ${C_CYAN}1 2${NC}  ${C_CYAN}1 2 4${NC}  ${C_CYAN}0${NC}(全部)"
    echo ""
    # 支持环境变量 VOLSB_PROTO 跳过交互
    local raw_input="${VOLSB_PROTO:-}"
    if [[ -z "$raw_input" ]]; then
        ask "请选择协议 [0-5]: "; read -r raw_input
    else
        info "协议选择 (环境变量): $raw_input"
    fi
    [[ -z "$raw_input" ]] && raw_input="1"
    [[ "$raw_input" == "0" ]] && raw_input="1 2 3 4 5"

    SELECTED_PROTOS=()
    for n in $raw_input; do
        case "$n" in
            1) SELECTED_PROTOS+=("vless_reality") ;;
            2) SELECTED_PROTOS+=("hysteria2") ;;
            3) SELECTED_PROTOS+=("vmess_ws") ;;
            4) SELECTED_PROTOS+=("trojan") ;;
            5) SELECTED_PROTOS+=("shadowtls") ;;
            *) warn "忽略无效输入: $n" ;;
        esac
    done
    [[ ${#SELECTED_PROTOS[@]} -eq 0 ]] && die "未选择任何协议"
}

# ────── 写入配置的公共函数 ──────
_write_config() {
    # $1 = inbounds JSON array string
    local inbounds_json="$1"
    step "写入配置文件"
    cat > "$SB_CONFIG" <<JSON
{
  "log": {
    "level": "warn",
    "output": "${SB_LOG}",
    "timestamp": true
  },
  "inbounds": ${inbounds_json},
  "outbounds": [
    {"type": "direct", "tag": "direct"},
    {"type": "block",  "tag": "block"}
  ],
  "route": {
    "final": "direct"
  }
}
JSON
    if "$SB_BIN" check -c "$SB_CONFIG" 2>/dev/null; then
        info "配置写入完成，校验通过"
    else
        err "配置校验失败:"; "$SB_BIN" check -c "$SB_CONFIG"; return 1
    fi
}

# ────── 初始化节点信息头 ──────
_init_info_header() {
    cat > "$SB_INFO" <<INFOHEADER
==============================================
  VOLSB — 节点信息
  更新时间 : $(date '+%Y-%m-%d %H:%M:%S')
  服务器   : ${CONNECT_ADDR:-$(get_public_ip)}
==============================================
INFOHEADER
    : > "$SB_LINKS"   # 清空链接文件
}

# ────── 全新安装：覆盖所有入站 ──────
assemble_and_write_config() {
    if [[ ! -x "$SB_BIN" ]]; then
        err "sing-box 未安装，请先执行菜单选项 1 安装"; return 1
    fi
    ALL_INBOUNDS=(); ALL_LINKS=()
    _init_info_header

    for proto in "${SELECTED_PROTOS[@]}"; do
        case "$proto" in
            vless_reality) deploy_vless_reality ;;
            hysteria2)     deploy_hysteria2 ;;
            vmess_ws)      deploy_vmess_ws ;;
            trojan)        deploy_trojan ;;
            shadowtls)     deploy_shadowtls ;;
        esac
    done

    local joined; joined=$(printf '%s
' "${ALL_INBOUNDS[@]}" | jq -s '.')
    _write_config "$joined" || return 1
    printf '%s
' "${ALL_LINKS[@]}" > "$SB_LINKS"
}

# ────── 追加协议：保留旧入站，合并新入站 ──────
append_and_write_config() {
    if [[ ! -x "$SB_BIN" ]]; then
        err "sing-box 未安装，请先执行菜单选项 1 安装"; return 1
    fi

    # 读出旧的入站 JSON 数组
    local old_inbounds_json="[]"
    if [[ -f "$SB_CONFIG" ]]; then
        old_inbounds_json=$(jq '.inbounds' "$SB_CONFIG" 2>/dev/null) || old_inbounds_json="[]"
    fi

    # 询问是否保留旧节点
    local keep_old=true
    if [[ "$old_inbounds_json" != "[]" && -n "$old_inbounds_json" ]]; then
        local old_count; old_count=$(echo "$old_inbounds_json" | jq 'length' 2>/dev/null || echo 0)
        echo ""
        echo -e "  ${C_BOLD}检测到已有 ${old_count} 个入站节点:${NC}"
        echo "$old_inbounds_json" | jq -r             '.[] | "  - \(.type) 端口:\(.listen_port) [\(.tag)]"' 2>/dev/null || true
        echo ""
        echo "  选项:"
        echo "   1) 保留旧节点，追加新节点（推荐）"
        echo "   2) 清除旧节点，只保留新节点"
        ask "选择 [1/2] 默认1: "; read -r keep_choice
        [[ "${keep_choice:-1}" == "2" ]] && keep_old=false
    fi

    # 生成新入站
    ALL_INBOUNDS=(); ALL_LINKS=()

    # 若保留旧节点，先把旧入站塞进 ALL_INBOUNDS
    if $keep_old && [[ "$old_inbounds_json" != "[]" ]]; then
        # 把旧入站每个元素拆出来加入数组
        local old_count; old_count=$(echo "$old_inbounds_json" | jq 'length' 2>/dev/null || echo 0)
        local oi=0
        while [[ $oi -lt $old_count ]]; do
            local ib; ib=$(echo "$old_inbounds_json" | jq ".[$oi]" 2>/dev/null)
            ALL_INBOUNDS+=("$ib")
            (( oi++ )) || true
        done
        # 同时保留旧链接
        if [[ -f "$SB_LINKS" ]]; then
            while IFS= read -r lnk; do
                [[ -n "$lnk" ]] && ALL_LINKS+=("$lnk")
            done < "$SB_LINKS"
        fi
        info "已保留 ${old_count} 个旧入站"
    fi

    # 重置 SB_INFO 头，但追加模式下先把旧 SB_INFO 内容（节点详情）保留
    local old_info_body=""
    if $keep_old && [[ -f "$SB_INFO" ]]; then
        # 跳过头部（前5行），保留节点详情
        old_info_body=$(tail -n +6 "$SB_INFO" 2>/dev/null || true)
    fi
    _init_info_header
    [[ -n "$old_info_body" ]] && echo "$old_info_body" >> "$SB_INFO"

    # 部署新协议
    for proto in "${SELECTED_PROTOS[@]}"; do
        case "$proto" in
            vless_reality) deploy_vless_reality ;;
            hysteria2)     deploy_hysteria2 ;;
            vmess_ws)      deploy_vmess_ws ;;
            trojan)        deploy_trojan ;;
            shadowtls)     deploy_shadowtls ;;
        esac
    done

    # 检查 tag 重复（同类型入站 tag 要唯一）
    local all_tags; all_tags=$(printf '%s
' "${ALL_INBOUNDS[@]}" | jq -r '.tag // ""' 2>/dev/null)
    local unique_tags; unique_tags=$(echo "$all_tags" | sort -u | wc -l | tr -d ' ')
    local total_tags; total_tags=$(echo "$all_tags" | wc -l | tr -d ' ')
    if [[ "$unique_tags" -lt "$total_tags" ]]; then
        warn "检测到重复的入站 tag，自动重命名..."
        local fixed_inbounds=()
        local tag_count=0
        for ib in "${ALL_INBOUNDS[@]}"; do
            local t; t=$(echo "$ib" | jq -r '.tag // ""' 2>/dev/null)
            local new_tag="${t}-$(( ++tag_count ))"
            ib=$(echo "$ib" | jq --arg nt "$new_tag" '.tag = $nt' 2>/dev/null)
            fixed_inbounds+=("$ib")
        done
        ALL_INBOUNDS=("${fixed_inbounds[@]}")
    fi

    local joined; joined=$(printf '%s
' "${ALL_INBOUNDS[@]}" | jq -s '.')
    _write_config "$joined" || return 1
    printf '%s
' "${ALL_LINKS[@]}" > "$SB_LINKS"
    info "共 ${#ALL_INBOUNDS[@]} 个入站节点"
}

# ════════════════════════════════════════════════════════════
#  流量统计
# ════════════════════════════════════════════════════════════

# sing-box 启用 ClashAPI 后可通过 REST 查询连接/流量
# 这里用 /proc/net 统计全量入出流量作为轻量实现

SB_STAT_API="127.0.0.1:8080"  # sing-box 统计 API 监听地址

traffic_init_api() {
    # 注入 sing-box v2ray 兼容统计 API（用于按入站/用户统计流量）
    if ! jq -e '.experimental.v2ray_api' "$SB_CONFIG" &>/dev/null; then
        local tmp; tmp=$(mktemp)
        jq '.experimental = (.experimental // {}) + {
            "v2ray_api": {
                "listen": "127.0.0.1:8080",
                "stats": {"enabled": true, "inbounds": true, "outbounds": true, "users": true}
            }
        }' "$SB_CONFIG" > "$tmp" && mv "$tmp" "$SB_CONFIG"
        info "已启用流量统计 API ($SB_STAT_API)"
    fi
}

human_bytes() {
    # 清除换行/空格，强制转整数，防止 awk/jq 输出带换行导致比较报错
    local b
    b=$(echo "${1:-0}" | tr -d '[:space:]')
    b=$(( b + 0 )) 2>/dev/null || b=0
    if   [[ $b -ge 1073741824 ]]; then printf "%.2f GB" "$(echo "scale=2; $b/1073741824" | bc)"
    elif [[ $b -ge 1048576 ]];    then printf "%.2f MB" "$(echo "scale=2; $b/1048576" | bc)"
    elif [[ $b -ge 1024 ]];       then printf "%.2f KB" "$(echo "scale=2; $b/1024" | bc)"
    else printf "%d B" "$b"; fi
}

# 清洗数值：去换行空格，转整数，出错返回0
clean_num() { local v; v=$(echo "${1:-0}" | tr -d '[:space:]'); echo $(( v + 0 )) 2>/dev/null || echo 0; }

show_traffic() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'HDR'
  ╔════════════════════════════════════════════════════╗
  ║              VOLSB — 流量统计                      ║
  ╚════════════════════════════════════════════════════╝
HDR
    echo -e "${NC}"

    if svc_active 2>/dev/null; then
        echo -e "  服务状态: ${C_GREEN}● 运行中${NC}"
    else
        echo -e "  服务状态: ${C_RED}● 已停止${NC}"
        warn "服务未运行，流量数据不可用"
    fi
    echo ""

    [[ ! -f "$SB_CONFIG" ]] && { warn "配置文件不存在"; return; }

    # ── 方法1: sing-box v2ray_api 按入站统计（最准确）──
    local api_ok=false
    if jq -e '.experimental.v2ray_api' "$SB_CONFIG" &>/dev/null; then
        local api_addr
        api_addr=$(jq -r '.experimental.v2ray_api.listen // "127.0.0.1:8080"' "$SB_CONFIG")

        # 调用 grpc 统计（sing-box 1.8+ 支持 HTTP query stats）
        local stat_url="http://${api_addr}/stats/query?reset=false&pattern="
        local stat_raw
        stat_raw=$(curl -fsSL --max-time 3 "$stat_url" 2>/dev/null) || stat_raw=""

        if [[ -n "$stat_raw" ]] && echo "$stat_raw" | jq -e '.stat' &>/dev/null; then
            api_ok=true
            echo -e "  ${C_BOLD}按入站/出站流量统计 (sing-box API):${NC}"
            hr
            printf "  ${C_BOLD}%-35s %-16s %-16s${NC}\n" "统计项" "上行" "下行"
            hr

            echo "$stat_raw" | jq -r '.stat[] | "\(.name)|\(.value)"' 2>/dev/null \
            | while IFS='|' read -r name value; do
                value=$(( ${value:-0} + 0 )) 2>/dev/null || value=0
                # 只显示入站（inbound）和用户（user）统计
                if [[ "$name" == *"inbound>>>"* || "$name" == *"user>>>"* ]]; then
                    local dir label
                    if [[ "$name" == *">>>uplink" ]]; then
                        dir="up"; label="${name/>>>uplink/}"
                    else
                        dir="down"; label="${name/>>>downlink/}"
                    fi
                    printf "  %-35s" "$label"
                    [[ "$dir" == "up"   ]] && printf " ${C_YELLOW}%-16s${NC}" "$(human_bytes $value)" || true
                    [[ "$dir" == "down" ]] && printf " ${C_GREEN}%-16s${NC}\n" "$(human_bytes $value)" || true
                fi
            done
            hr
        fi
    fi

    # ── 方法2: 按端口当前连接数（/proc/net/tcp + udp）──
    echo ""
    echo -e "  ${C_BOLD}当前活跃连接数 (per 端口):${NC}"
    hr
    printf "  ${C_BOLD}%-10s %-22s %-12s %-12s %s${NC}\n" \
        "端口" "类型" "TCP" "UDP" "合计"
    hr

    local inbounds_raw
    inbounds_raw=$(jq -r         '.inbounds[] | [(.listen_port|if . then tostring else "" end), (.type//"unknown"), (.listen//"")] | join("|")'         "$SB_CONFIG" 2>/dev/null) || inbounds_raw=""

    local any_conn=false
    while IFS='|' read -r port type listen; do
        [[ -z "$port" || "$port" == "0" || "$listen" == "127.0.0.1" ]] && continue

        local hex_port tcp_c udp_c
        hex_port=$(printf "%04X" "$port" 2>/dev/null) || continue

        tcp_c=$(awk -v p=":$hex_port" \
            'NR>1 && $2~p && $4=="01" {c++} END{print c+0}' \
            /proc/net/tcp /proc/net/tcp6 2>/dev/null | tr -d '[:space:]')
        tcp_c=$(( ${tcp_c:-0} + 0 )) 2>/dev/null || tcp_c=0

        udp_c=$(awk -v p=":$hex_port" \
            'NR>1 && $2~p {c++} END{print c+0}' \
            /proc/net/udp /proc/net/udp6 2>/dev/null | tr -d '[:space:]')
        udp_c=$(( ${udp_c:-0} + 0 )) 2>/dev/null || udp_c=0

        local total=$(( tcp_c + udp_c ))
        printf "  ${C_CYAN}%-10s${NC} %-22s " "$port" "$type"
        if [[ $total -gt 0 ]]; then
            printf "${C_GREEN}%-12s %-12s %s${NC}\n" "$tcp_c" "$udp_c" "${total} 个"
            any_conn=true
        else
            printf "${C_DIM}%-12s %-12s %s${NC}\n" "0" "0" "无"
        fi
    done <<< "$inbounds_raw"
    hr

    # ── 方法3: 网卡总量 + 实时速率 ──
    echo ""
    echo -e "  ${C_BOLD}网卡流量:${NC}"
    local iface
    iface=$(ip route 2>/dev/null | awk '/default/{print $5; exit}')
    if [[ -n "${iface:-}" ]] && [[ -f /proc/net/dev ]]; then
        local rx tx
        rx=$(awk -v i="${iface}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null | tr -d '[:space:]'); rx=$(( ${rx:-0}+0 ))
        tx=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null | tr -d '[:space:]'); tx=$(( ${tx:-0}+0 ))
        printf "  接口 ${C_CYAN}%s${NC} | 累计 ↓ ${C_GREEN}%s${NC}  ↑ ${C_YELLOW}%s${NC}\n" \
            "$iface" "$(human_bytes $rx)" "$(human_bytes $tx)"

        # 实时速率（1秒采样）
        local r1 t1 r2 t2
        r1=$(awk -v i="${iface}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null | tr -d '[:space:]'); r1=$(( ${r1:-0}+0 ))
        t1=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null | tr -d '[:space:]'); t1=$(( ${t1:-0}+0 ))
        sleep 1
        r2=$(awk -v i="${iface}:" '$1==i{print $2}'  /proc/net/dev 2>/dev/null | tr -d '[:space:]'); r2=$(( ${r2:-0}+0 ))
        t2=$(awk -v i="${iface}:" '$1==i{print $10}' /proc/net/dev 2>/dev/null | tr -d '[:space:]'); t2=$(( ${t2:-0}+0 ))
        printf "  实时速率 | ↓ ${C_GREEN}%s/s${NC}  ↑ ${C_YELLOW}%s/s${NC}\n" \
            "$(human_bytes $(( r2 - r1 )))" "$(human_bytes $(( t2 - t1 )))"
    fi

    if ! $api_ok; then
        echo ""
        warn "按入站流量统计不可用。重新安装或执行以下命令后重启服务可启用:"
        echo -e "  ${C_DIM}volsb restart${NC}"
    fi

    echo ""; hr
}


reset_traffic_log() {
    ask "确认清空流量日志? [y/N]: "; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    : > "$SB_LOG" 2>/dev/null && info "日志已清空"
    echo "{}" > "$SB_TRAFFIC"
}

# ════════════════════════════════════════════════════════════
#  快捷命令安装
# ════════════════════════════════════════════════════════════

install_shortcut() {
    local self; self=$(readlink -f "$0")
    cat > "$VOLSB_CMD" <<SHORTCUT
#!/usr/bin/env bash
exec bash "${self}" "\$@"
SHORTCUT
    chmod +x "$VOLSB_CMD"
    info "快捷命令已安装,现在可以输入 ${C_BOLD}volsb${NC} 进入管理界面"
}

# ════════════════════════════════════════════════════════════
#  节点信息展示
# ════════════════════════════════════════════════════════════

show_nodes() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'HDR'
  ╔════════════════════════════════════════════════════╗
  ║              VOLSB — 节点信息总览                  ║
  ╚════════════════════════════════════════════════════╝
HDR
    echo -e "${NC}"

    # ── 从 config.json 实时读取入站端口和类型（一次性读取）──
    if [[ -f "$SB_CONFIG" ]]; then
        echo -e "  ${C_BOLD}当前运行入站:${NC}"
        hr
        local n=0
        while IFS='|' read -r ib_type ib_port ib_tag ib_listen; do
            [[ "$ib_listen" == "127.0.0.1" ]] && continue
            (( n++ )) || true
            printf "  ${C_BOLD}%-4s${NC} ${C_GREEN}%-20s${NC} 端口: ${C_CYAN}%-8s${NC} 标签: %s\n" \
                "${n})" "$ib_type" "$ib_port" "$ib_tag"
        done < <(jq -r '.inbounds[] | [(.type//"unknown"), (.listen_port//""|tostring), (.tag//""), (.listen//"")]  | join("|")' \
            "$SB_CONFIG" 2>/dev/null)
        [[ $n -eq 0 ]] && warn "未读取到入站配置"
        hr
    else
        warn "配置文件不存在，请先安装"
    fi
    # ── 展示节点详情（与当前 config.json 比对，提示陈旧数据）──
    if [[ -f "$SB_INFO" ]]; then
        echo ""
        echo -e "  ${C_BOLD}节点详情:${NC}"
        # 检查 SB_INFO 里的端口是否和 config.json 一致
        local config_ports info_ports stale=false
        config_ports=$(jq -r '.inbounds[].listen_port | tostring' "$SB_CONFIG" 2>/dev/null | tr '\n' ' ')
        info_ports=$(grep -oP '端口\s*:\s*\K[0-9]+' "$SB_INFO" 2>/dev/null | sort -u | tr '\n' ' ')
        # 若 SB_INFO 里有 config.json 里不存在的端口，说明有旧数据
        for p in $info_ports; do
            if ! echo "$config_ports" | grep -qw "$p"; then
                stale=true; break
            fi
        done
        if $stale; then
            warn "节点信息含旧数据（端口 $info_ports 与当前配置 $config_ports 不完全匹配）"
            warn "建议重新安装以同步节点信息: 菜单选 1"
            echo ""
        fi
        cat "$SB_INFO"
    fi

    # ── 展示所有分享链接（带编号和二维码）──
    if [[ -f "$SB_LINKS" ]] && [[ -s "$SB_LINKS" ]]; then
        hr
        echo -e "
  ${C_BOLD}分享链接:${NC}
"
        local i=0
        while IFS= read -r link; do
            [[ -z "$link" ]] && continue
            (( i++ )) || true
            # 从链接提取协议和名称
            local proto name
            proto=$(echo "$link" | cut -d: -f1 | tr '[:lower:]' '[:upper:]')
            name=$(echo "$link" | grep -oP '(?<=#)[^#]*$' || echo "节点$i")
            echo -e "  ${C_BOLD}${C_YELLOW}[$i] ${proto} — ${name}${NC}"
            echo -e "  ${C_DIM}${link}${NC}"
            echo ""
            print_qr "$link"
        done < "$SB_LINKS"
        echo -e "  共 ${C_BOLD}${i}${NC} 条链接，已保存: ${C_DIM}$SB_LINKS${NC}"
    else
        echo ""
        warn "暂无分享链接，请先完成安装配置"
    fi
    echo ""
}

# ════════════════════════════════════════════════════════════
#  端口 & 密码重置
# ════════════════════════════════════════════════════════════

reset_ports() {
    require_root
    [[ -f "$SB_CONFIG" ]] || { warn "未找到配置文件"; return; }

    echo ""
    echo -e "  ${C_BOLD}重置选项:${NC}"
    echo "   1) 仅重置端口"
    echo "   2) 仅重置密码/UUID"
    echo "   3) 同时重置端口和密码/UUID"
    ask "选择 [1-3] 默认3: "; read -r reset_opt
    [[ -z "$reset_opt" ]] && reset_opt="3"

    local backup; backup=$(mktemp)
    cp "$SB_CONFIG" "$backup"   # 备份原配置,失败时回滚

    local updated; updated=$(cat "$SB_CONFIG")

    # ── 重置端口 ──
    if [[ "$reset_opt" == "1" || "$reset_opt" == "3" ]]; then
        step "重置入站端口"
        local ports_old; ports_old=$(jq -r '.inbounds[].listen_port // empty' "$SB_CONFIG")
        for old_p in $ports_old; do
            local new_p; new_p=$(random_port)
            updated=$(echo "$updated" | sed "s/\"listen_port\": ${old_p}/\"listen_port\": ${new_p}/g")
            info "端口 $old_p → $new_p"
            open_port "$new_p" tcp; open_port "$new_p" udp
        done
    fi

    # ── 重置密码/UUID ──
    if [[ "$reset_opt" == "2" || "$reset_opt" == "3" ]]; then
        step "重置密码 / UUID"
        # 替换所有 password 字段
        local pwd_list; pwd_list=$(echo "$updated" | jq -r '.. | objects | .password? // empty' 2>/dev/null | sort -u)
        for old_pwd in $pwd_list; do
            local new_pwd; new_pwd=$(gen_rand_str 24)
            updated=$(echo "$updated" | sed "s|\"password\": \"${old_pwd}\"|\"password\": \"${new_pwd}\"|g")
            info "密码已更新 (${old_pwd:0:6}… → ${new_pwd:0:6}…)"
        done
        # 替换所有 uuid 字段
        local uuid_list; uuid_list=$(echo "$updated" | jq -r '.. | objects | .uuid? // empty' 2>/dev/null | sort -u)
        for old_uuid in $uuid_list; do
            local new_uuid; new_uuid=$(gen_uuid)
            updated=$(echo "$updated" | sed "s/${old_uuid}/${new_uuid}/g")
            info "UUID 已更新 (${old_uuid:0:8}… → ${new_uuid:0:8}…)"
        done
    fi

    echo "$updated" > "$SB_CONFIG"

    if "$SB_BIN" check -c "$SB_CONFIG" &>/dev/null; then
        svc_restart && info "重置完成,服务已重启"
        # 刷新节点信息文件提示
        warn "节点信息已变更,请执行菜单 9 重新查看最新链接"
    else
        err "配置校验失败,回滚至备份"
        cp "$backup" "$SB_CONFIG"
    fi
    rm -f "$backup"
}

# ════════════════════════════════════════════════════════════
#  主安装流程
# ════════════════════════════════════════════════════════════

# 结果写入全局变量 DEPLOY_MODE，避免子 shell 吞掉 read
DEPLOY_MODE="1"
select_deploy_mode() {
    clear
    echo -e "${C_BOLD}${C_CYAN}"
    cat <<'LOGO'
  ██╗   ██╗ ██████╗ ██╗     ███████╗██████╗
  ██║   ██║██╔═══██╗██║     ██╔════╝██╔══██╗
  ██║   ██║██║   ██║██║     ███████╗██████╔╝
  ╚██╗ ██╔╝██║   ██║██║     ╚════██║██╔══██╗
   ╚████╔╝ ╚██████╔╝███████╗███████║██████╔╝
    ╚═══╝   ╚═════╝ ╚══════╝╚══════╝╚═════╝
LOGO
    echo -e "  ${C_DIM}sing-box 服务端一键部署管理脚本  v${VOLSB_VER}${NC}"
    echo -e "${NC}"
    hr
    echo ""
    echo -e "  ${C_BOLD}选择部署模式:${NC}"
    echo ""
    printf "  ${C_BOLD}%-5s${NC} ${C_GREEN}%-20s${NC} %s\n" "1)" "部署机 (落地机)" "直接接收客户端流量,出口上网"
    printf "  ${C_BOLD}%-5s${NC} ${C_YELLOW}%-20s${NC} %s\n" "2)" "线路机 (中转机)" "接收客户端流量后转发至落地机"
    echo ""
    hr
    # 支持环境变量 VOLSB_MODE 跳过交互
    if [[ -n "${VOLSB_MODE:-}" ]]; then
        DEPLOY_MODE="$VOLSB_MODE"; return
    fi
    ask "选择模式 [1/2] 默认1: "; read -r _mode
    [[ -z "$_mode" ]] && _mode="1"
    DEPLOY_MODE="$_mode"
}

do_install() {
    require_root
    detect_os
    detect_arch
    install_deps
    setup_dirs

    step "获取 sing-box 最新版本"
    local ver; ver=$(get_latest_version)
    if [[ -x "$SB_BIN" ]]; then
        local cur; cur=$("$SB_BIN" version 2>/dev/null | awk '{print $3}' | head -1)
        if [[ "$cur" == "$ver" ]]; then
            warn "sing-box 已是最新版本 v${ver}，跳过下载，继续配置"
        else
            info "当前 v${cur} → 最新 v${ver}，升级中..."
            install_binary "$ver"
        fi
    else
        install_binary "$ver"
    fi

    # 验证安装成功
    if [[ ! -x "$SB_BIN" ]]; then
        err "sing-box 安装失败，请检查网络后重试"
        return 1
    fi
    info "sing-box 就绪: $("$SB_BIN" version 2>/dev/null | head -1)"

    install_service
    install_shortcut

    # 节点信息文件由 assemble_and_write_config 统一写入，此处无需初始化

    select_deploy_mode

    if [[ "$DEPLOY_MODE" == "2" ]]; then
        # 线路机模式
        deploy_relay
        assemble_relay_check
    else
        # 部署机模式
        ask_connect_addr
        select_protocols
        assemble_and_write_config
        traffic_init_api
    fi

    step "启动 sing-box 服务"
    svc_start
    # 等待进程就绪后二次确认状态
    local retry=0
    while ! svc_active 2>/dev/null && [[ $retry -lt 5 ]]; do
        sleep 1; (( retry++ )) || true
    done

    if svc_active; then
        info "sing-box 运行中 ✔  (用时 ${retry}s)"
    else
        err "启动失败! 查看日志:"
        [[ -f "$SB_LOG" ]] && tail -20 "$SB_LOG" || true
        exit 1
    fi

    show_nodes
    echo ""
    info "安装完成!  输入 ${C_BOLD}volsb${NC} 进入管理界面"
}

# 线路机配置独立写入,不走 assemble_and_write_config
assemble_relay_check() {
    "$SB_BIN" check -c "$SB_CONFIG" &>/dev/null || {
        err "线路机配置校验失败:"
        "$SB_BIN" check -c "$SB_CONFIG"
        exit 1
    }
    info "线路机配置校验通过"
}

do_uninstall() {
    require_root
    ask "确认完全卸载 VOLSB / sing-box? [y/N]: "; read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || { info "已取消"; return; }
    svc_stop 2>/dev/null || true
    if [[ "$INIT_SYS" == "openrc" ]]; then
        rc-update del sing-box default &>/dev/null || true
        rm -f "$SB_OPENRC"
    else
        systemctl disable sing-box &>/dev/null || true
        rm -f "$SB_SYSTEMD"
        systemctl daemon-reload
    fi
    rm -f "$SB_BIN" "$VOLSB_CMD"
    rm -rf "$SB_CONF_DIR" "$SB_LOG_DIR" "$SB_DATA_DIR"
    info "卸载完成"
}

# ────── 升级 sing-box 核心 ──────
do_update_singbox() {
    require_root
    [[ -x "$SB_BIN" ]] || die "sing-box 未安装"
    detect_arch
    local cur new
    cur=$("$SB_BIN" version | awk '{print $3}' | head -1)
    new=$(get_latest_version)
    if [[ "$cur" == "$new" ]]; then
        info "sing-box 已是最新版本 v${cur}"; return
    fi
    info "升级 sing-box: v${cur} → v${new}"
    install_binary "$new"
    svc_restart && info "sing-box 升级完成 ✔"
}

# ────── 升级 VOLSB 脚本自身 ──────
do_update_script() {
    require_root
    step "更新 VOLSB 脚本"

    # 获取远端版本号 — 用 || true 防止 pipefail 误触发 set -e
    local remote_ver=""
    info "检查远端版本 ..."
    local raw_remote
    raw_remote=$(curl -fsSL --max-time 15 "$VOLSB_REPO" 2>/dev/null) || true

    if [[ -n "$raw_remote" ]]; then
        remote_ver=$(echo "$raw_remote" | grep -m1 'VOLSB_VER='             | sed 's/.*VOLSB_VER="\([^"]*\)".*/\1/' 2>/dev/null) || true
    fi

    if [[ -z "$remote_ver" ]]; then
        err "无法获取远端版本信息"
        err "请检查网络或仓库地址: $VOLSB_REPO"
        return 1
    fi

    info "本地版本: v${VOLSB_VER}  |  远端版本: v${remote_ver}"

    if [[ "$remote_ver" == "$VOLSB_VER" ]]; then
        info "VOLSB 已是最新版本 v${VOLSB_VER}"; return 0
    fi

    info "发现新版本: v${VOLSB_VER} → v${remote_ver}"
    ask "确认更新? [Y/n]: "; read -r _ans
    [[ "$_ans" =~ ^[Nn]$ ]] && { info "已取消"; return 0; }

    # 确定脚本真实路径:
    # $0 可能是 /usr/local/bin/volsb (wrapper)，需要找到实际脚本
    local self
    # 优先用 BASH_SOURCE[0]，它始终指向实际脚本文件
    self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null) || self=$(readlink -f "$0")
    info "脚本路径: $self"

    local tmpfile; tmpfile=$(mktemp /tmp/volsb_update.XXXXXX)

    step "下载新版脚本"
    if ! curl -fsSL --max-time 60 -o "$tmpfile" "$VOLSB_REPO"; then
        rm -f "$tmpfile"
        err "下载失败: $VOLSB_REPO"; return 1
    fi

    # 完整性校验：必须含 VOLSB_VER= 且第一行是 bash shebang
    local first_line; first_line=$(head -1 "$tmpfile" 2>/dev/null)
    if ! grep -q "VOLSB_VER=" "$tmpfile" 2>/dev/null         || [[ "$first_line" != *"bash"* ]]; then
        rm -f "$tmpfile"
        err "下载内容校验失败,中止更新"; return 1
    fi

    # 备份当前版本
    local backup="${self}.bak.${VOLSB_VER}"
    cp "$self" "$backup" && info "已备份至: $backup"

    # 原子替换：先写临时文件再 mv，避免写到一半进程读取
    chmod +x "$tmpfile"
    mv "$tmpfile" "$self"
    info "脚本已替换: $self"

    # 同步更新 /usr/local/bin/volsb wrapper（重写指向 self）
    if [[ -f "$VOLSB_CMD" && "$VOLSB_CMD" != "$self" ]]; then
        cat > "$VOLSB_CMD" <<SHORTCUT
#!/usr/bin/env bash
exec bash "${self}" "\$@"
SHORTCUT
        chmod +x "$VOLSB_CMD"
        info "快捷命令已同步: $VOLSB_CMD"
    fi

    echo ""
    info "VOLSB 更新完成: v${VOLSB_VER} → v${remote_ver} ✔"
    warn "请重新运行: ${C_BOLD}volsb${NC}"
}

# ────── 统一更新入口(菜单调用) ──────
do_update_menu() {
    echo ""
    echo -e "  ${C_BOLD}选择更新内容:${NC}"
    hr
    printf "  ${C_BOLD}%-5s${NC} %s\n" "1)" "更新 VOLSB 脚本  (当前 v${VOLSB_VER})"
    printf "  ${C_BOLD}%-5s${NC} %s\n" "2)" "升级 sing-box 核心版本"
    printf "  ${C_BOLD}%-5s${NC} %s\n" "3)" "全部更新"
    printf "  ${C_BOLD}%-5s${NC} %s\n" "0)" "取消"
    hr
    ask "选择 [0-3]: "; read -r uc
    case "$uc" in
        1) do_update_script ;;
        2) do_update_singbox ;;
        3) do_update_script; do_update_singbox ;;
        *) info "已取消" ;;
    esac
}

# ════════════════════════════════════════════════════════════
#  管理界面 (volsb 命令入口)
# ════════════════════════════════════════════════════════════

main_menu() {
    # 检测 INIT_SYS(管理界面直接调用时需要)
    if [[ -z "${INIT_SYS:-}" ]]; then
        [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
    fi

    while true; do
        clear
        echo -e "${C_BOLD}${C_CYAN}"
        cat <<'LOGO'
  ██╗   ██╗ ██████╗ ██╗     ███████╗██████╗
  ██║   ██║██╔═══██╗██║     ██╔════╝██╔══██╗
  ██║   ██║██║   ██║██║     ███████╗██████╔╝
  ╚██╗ ██╔╝██║   ██║██║     ╚════██║██╔══██╗
   ╚████╔╝ ╚██████╔╝███████╗███████║██████╔╝
    ╚═══╝   ╚═════╝ ╚══════╝╚══════╝╚═════╝
LOGO
        echo -e "  ${C_DIM}v${VOLSB_VER}  |  $(date '+%Y-%m-%d %H:%M:%S')  |  ${VOLSB_REPO##*/}${NC}"
        echo -e "${NC}"

        # 状态栏
        if svc_active 2>/dev/null; then
            echo -e "  状态: ${C_GREEN}${C_BOLD}● 运行中${NC}"
        elif [[ -f "$SB_SYSTEMD" || -f "$SB_OPENRC" ]]; then
            echo -e "  状态: ${C_RED}${C_BOLD}● 已停止${NC}"
        else
            echo -e "  状态: ${C_YELLOW}${C_BOLD}● 未安装${NC}"
        fi
        [[ -x "$SB_BIN" ]] && \
            echo -e "  版本: ${C_DIM}$("$SB_BIN" version 2>/dev/null | awk '{print $3}' | head -1)${NC}"
        [[ -f "$SB_LINKS" ]] && \
            echo -e "  节点: ${C_DIM}$(wc -l < "$SB_LINKS") 条链接${NC}"

        echo ""; hr
        echo -e "  ${C_BOLD}📦 安装管理${NC}"
        echo "   1) 全新安装 / 重新部署"
        echo "   2) 追加新协议"
        echo "   3) 更新 (脚本/sing-box)"
        echo "   4) 卸载"
        echo ""
        echo -e "  ${C_BOLD}⚙️  服务控制${NC}"
        echo "   5) 启动    6) 停止    7) 重启    8) 查看状态"
        echo ""
        echo -e "  ${C_BOLD}📋 节点与配置${NC}"
        echo "   9) 查看节点信息 & 分享链接"
        echo "  10) 重置端口 / 密码 / UUID"
        echo "  11) 编辑配置文件"
        echo ""
        echo -e "  ${C_BOLD}📊 流量管理${NC}"
        echo "  12) 查看流量统计"
        echo "  13) 清空流量日志"
        echo "  14) 实时日志"
        hr
        echo "   0) 退出"
        echo ""
        ask "请选择 [0-14]: "; read -r opt

        case "$opt" in
            1)  do_install || true ;;
            2)  require_root; ask_connect_addr; select_protocols
                append_and_write_config || true
                svc_restart && info "配置已更新" || true ;;
            3)  do_update_menu || true ;;
            4)  do_uninstall || true ;;
            5)  require_root; svc_start  && info "已启动" || true ;;
            6)  require_root; svc_stop   && info "已停止" || true ;;
            7)  require_root; svc_restart && info "已重启" || true ;;
            8)  svc_status || true ;;
            9)  show_nodes || true ;;
            10) reset_ports || true ;;
            11) require_root; ${EDITOR:-vi} "$SB_CONFIG"
                "$SB_BIN" check -c "$SB_CONFIG" &>/dev/null && {
                    svc_restart && info "配置已保存并重启"
                } || { err "配置有误,未重启"; "$SB_BIN" check -c "$SB_CONFIG" || true; } ;;
            12) show_traffic || true ;;
            13) reset_traffic_log || true ;;
            14) [[ -f "$SB_LOG" ]] && tail -f "$SB_LOG" || journalctl -u sing-box -f || true ;;
            0)  exit 0 ;;
            *)  warn "无效选项: $opt" ;;
        esac

        echo ""; ask "按回车继续..."; read -r
    done
}

# ════════════════════════════════════════════════════════════
#  命令行入口
# ════════════════════════════════════════════════════════════

print_help() {
    cat <<HELP
VOLSB — sing-box 服务端部署管理脚本 v${VOLSB_VER}
项目地址: https://github.com/chnnic/VOLSB

用法:
  volsb [命令]

命令:
  (无参数)         进入交互式管理界面
  install          全新安装
  relay            以线路机模式安装
  add              追加协议到现有配置
  update           升级 sing-box 核心版本
  self-update      更新 VOLSB 脚本自身
  uninstall        完全卸载
  start            启动服务
  stop             停止服务
  restart          重启服务
  status           查看运行状态
  info             查看节点信息和分享链接
  traffic          查看流量统计
  log              实时日志
  -h, --help       显示帮助

HELP
}

# relay 模式命令行参数解析
parse_relay_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --land-addr)   LAND_ADDR="$2";   shift 2 ;;
            --land-port)   LAND_PORT="$2";   shift 2 ;;
            --land-pass)   LAND_PASS="$2";   shift 2 ;;
            --land-method) LAND_METHOD="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
}

main() {
    local cmd="${1:-menu}"; [[ $# -gt 0 ]] && shift || true

    case "$cmd" in
        install|i)        do_install ;;
        relay)
            require_root; detect_os; detect_arch; install_deps; setup_dirs
            local ver; ver=$(get_latest_version)
            install_binary "$ver"; install_service; install_shortcut
            cat > "$SB_INFO" <<HDR
==============================================
  VOLSB 线路机 — 节点信息
  安装时间 : $(date '+%Y-%m-%d %H:%M:%S')
==============================================
HDR
            parse_relay_args "$@"
            ask_connect_addr
            deploy_relay; assemble_relay_check
            svc_start; sleep 2
            svc_active && info "线路机运行中 ✔" || { err "启动失败"; exit 1; }
            show_nodes
            ;;
        add)
            require_root
            [[ -f "$SB_CONFIG" ]] || die "请先安装"
            ask_connect_addr; select_protocols; append_and_write_config
            svc_restart && info "已更新并重启" ;;
        update|upgrade)   do_update_singbox ;;
        self-update)      do_update_script ;;
        uninstall|remove) detect_os; do_uninstall ;;
        start)            require_root
                          [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_start ;;
        stop)             require_root
                          [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_stop ;;
        restart|r)        require_root
                          [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_restart ;;
        status|s)         [[ -f /etc/alpine-release ]] && INIT_SYS="openrc" || INIT_SYS="systemd"
                          svc_status ;;
        info|node)        show_nodes ;;
        traffic|stats)    show_traffic ;;
        log|logs)         [[ -f "$SB_LOG" ]] && tail -f "$SB_LOG" \
                              || journalctl -u sing-box -f ;;
        menu|"")          main_menu ;;
        -h|--help|help)   print_help ;;
        *)                err "未知命令: $cmd"; print_help; exit 1 ;;
    esac
}

main "$@"
