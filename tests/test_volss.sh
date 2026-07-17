#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2034,SC2317
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$SCRIPT_DIR/volss.sh"

TESTS=0
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_eq() {
    local EXPECTED=$1
    local ACTUAL=$2
    local LABEL=$3
    TESTS=$((TESTS + 1))
    [ "$EXPECTED" = "$ACTUAL" ] || fail "$LABEL: expected '$EXPECTED', got '$ACTUAL'"
}

assert_true() {
    local LABEL=$1
    shift
    TESTS=$((TESTS + 1))
    "$@" || fail "$LABEL"
}

test_host_helpers() {
    assert_eq "2001:db8::1" "$(normalize_server_host '[2001:0db8::1]')" "normalize IPv6"
    assert_eq "example.com" "$(normalize_server_host 'Example.COM.')" "normalize hostname"
    assert_eq "[2001:db8::1]" "$(format_ss_host '2001:db8::1')" "format IPv6 URI host"
    if normalize_server_host 'bad host' >/dev/null 2>&1; then
        fail "reject invalid host"
    fi
    TESTS=$((TESTS + 1))

    CONFIG_DIR="$TMP_ROOT/host"
    SERVER_HOST_FILE="$CONFIG_DIR/server_host"
    LINKS_FILE="$CONFIG_DIR/links.txt"
    mkdir -p "$CONFIG_DIR"
    printf 'ss://dGVzdA==@[2001:db8::2]:30001#test\n' > "$LINKS_FILE"
    assert_eq "2001:db8::2" "$(get_server_host)" "recover IPv6 host from link"

    CONFIG="$CONFIG_DIR/config.json"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    MANUAL_FILE="$CONFIG_DIR/manual.list"
    RUNTIME="$CONFIG_DIR/runtime.json"
    HOST="2001:db8::3"
    METHOD="2022-blake3-aes-128-gcm"
    KEY_LEN=16
    USE_ACL_FLAG=false
    PORT_LIST=(30001)
    LINK_NAME_PREFIX="Hong Kong Node"
    NAME_LIST=()
    generate_config >/dev/null || fail "generate IPv6 configuration"
    assert_true "generate bracketed IPv6 link" grep -Fq '@[2001:db8::3]:30001#Hong%20Kong%20Node' "$LINKS_FILE"
    assert_true "generate supported bind address" grep -Eq '"server":"(::|0\.0\.0\.0)"' "$CONFIG"
    assert_eq "Hong Kong Node" "$(python3 -c "import json; print(json.load(open('$CONFIG'))['servers'][0]['name'])")" "persist custom link name"
    assert_eq "Node Name" "$(normalize_link_name '  Node Name  ')" "normalize link name"
    if normalize_link_name $'bad\tname' >/dev/null 2>&1; then
        fail "reject control characters in link name"
    fi
    TESTS=$((TESTS + 1))
}

test_link_name_management() {
    CONFIG_DIR="$TMP_ROOT/names"
    CONFIG="$CONFIG_DIR/config.json"
    RUNTIME="$CONFIG_DIR/runtime.json"
    LINKS_FILE="$CONFIG_DIR/links.txt"
    SERVER_HOST_FILE="$CONFIG_DIR/server_host"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    MANUAL_FILE="$CONFIG_DIR/manual.list"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' 'example.com' > "$SERVER_HOST_FILE"
    printf '%s\n' '{"servers":[{"server_port":30001,"method":"aes-256-gcm","password":"one"},{"server_port":30002,"method":"aes-256-gcm","password":"two"}]}' > "$CONFIG"

    hostname() { echo "test-host"; }
    check_installed() { return 0; }
    secure_data_files() { :; }
    list_users() { :; }

    assert_eq "test-host" "$(default_link_name)" "default link name uses hostname"
    migrate_link_names_if_needed >/dev/null || fail "migrate missing link names"
    assert_eq "test-host-1 test-host-2" "$(python3 -c "import json; print(' '.join(s['name'] for s in json.load(open('$CONFIG'))['servers']))")" "migrate names with hostname"
    assert_true "rebuild migrated first link" grep -Fq '#test-host-1' "$LINKS_FILE"

    rename_user_locked <<< $'2\n自定义 Node\n' >/dev/null || fail "rename user"
    assert_eq "自定义 Node" "$(python3 -c "import json; print(json.load(open('$CONFIG'))['servers'][1]['name'])")" "persist renamed user"
    assert_true "encode renamed link fragment" grep -Fq '#%E8%87%AA%E5%AE%9A%E4%B9%89%20Node' "$LINKS_FILE"
}

test_runtime_omits_link_names() {
    CONFIG_DIR="$TMP_ROOT/runtime-name"
    CONFIG="$CONFIG_DIR/config.json"
    RUNTIME="$CONFIG_DIR/runtime.json"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server":"::","server_port":30001,"method":"aes-256-gcm","password":"one","mode":"tcp_and_udp","name":"Node One","quota_bytes":1073741824,"expires_at":"2030-01-01","disabled_reason":"quota"}]}' > "$CONFIG"
    traffic_chains_installed() { return 1; }
    svc_reload() { :; }
    svc_restart() { :; }
    secure_data_files() { :; }

    apply_config >/dev/null || fail "build runtime with managed name"
    assert_eq "0" "$(python3 -c "import json; print(int('name' in json.load(open('$RUNTIME'))['servers'][0]))")" "omit link name from runtime"
    assert_eq "0" "$(python3 -c "import json; s=json.load(open('$RUNTIME'))['servers'][0]; print(int(any(k in s for k in ('quota_bytes','expires_at','disabled_reason'))))")" "omit policy metadata from runtime"
}

test_client_exports_and_qr() {
    CONFIG_DIR="$TMP_ROOT/exports"
    CONFIG="$CONFIG_DIR/config.json"
    RUNTIME="$CONFIG_DIR/runtime.json"
    LINKS_FILE="$CONFIG_DIR/links.txt"
    SERVER_HOST_FILE="$CONFIG_DIR/server_host"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    MANUAL_FILE="$CONFIG_DIR/manual.list"
    EXPORT_DIR="$CONFIG_DIR/client"
    CLASH_CONFIG="$EXPORT_DIR/clash.yaml"
    MIHOMO_CONFIG="$EXPORT_DIR/mihomo.yaml"
    SINGBOX_CONFIG="$EXPORT_DIR/sing-box.json"
    QR_DIR="$CONFIG_DIR/qrcodes"
    TRAFFIC_BACKEND_FILE="$CONFIG_DIR/traffic_backend"
    NFT_RULES_FILE="$CONFIG_DIR/volss.nft"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' 'example.com' > "$SERVER_HOST_FILE"
    printf '%s\n' '{"servers":[{"server":"::","server_port":30001,"method":"aes-256-gcm","password":"one","name":"Node One"},{"server":"::","server_port":30002,"method":"aes-256-gcm","password":"two","name":"节点二"}]}' > "$CONFIG"

    generate_client_configs || fail "generate client exports"
    assert_eq "2" "$(grep -c 'udp: true' "$CLASH_CONFIG")" "Clash export enables UDP"
    assert_eq "2" "$(grep -c 'udp: true' "$MIHOMO_CONFIG")" "Mihomo export enables UDP"
    assert_eq "2" "$(python3 -c "import json; c=json.load(open('$SINGBOX_CONFIG')); print(sum(o.get('type') == 'shadowsocks' for o in c['outbounds']))")" "sing-box exports all users"

    qrencode() {
        local OUTPUT=""
        while [ "$#" -gt 0 ]; do
            case $1 in
                -o) OUTPUT=$2; shift 2 ;;
                -s|-t) shift 2 ;;
                --) shift; break ;;
                *) shift ;;
            esac
        done
        [ -z "$OUTPUT" ] || printf 'png\n' > "$OUTPUT"
    }
    printf '%s\n' 'ss://dGVzdA==@example.com:30001#Node%20One' 'ss://dGVzdA==@example.com:30002#Node%20Two' > "$LINKS_FILE"
    generate_qr_codes || fail "generate QR artifacts"
    assert_true "generate SS QR image" test -f "$QR_DIR/ss-30001.png"
    assert_true "generate Clash QR image" test -f "$QR_DIR/clash-config.png"
}

test_backup_validation() {
    CONFIG_DIR="$TMP_ROOT/backup-data"
    CONFIG="$CONFIG_DIR/config.json"
    SERVER_HOST_FILE="$CONFIG_DIR/server_host"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    MANUAL_FILE="$CONFIG_DIR/manual.list"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    LINKS_FILE="$CONFIG_DIR/links.txt"
    TRAFFIC_BACKEND_FILE="$CONFIG_DIR/traffic_backend"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    mkdir -p "$ACL_RULESET_DIR"
    printf '%s\n' '{"servers":[{"server_port":30001,"method":"aes-256-gcm","password":"one","expires_at":"2030-01-01"}]}' > "$CONFIG"
    printf '%s\n' 'example.com' > "$SERVER_HOST_FILE"
    printf '%s\n' '{"30001":{"tx":1,"rx":2}}' > "$TRAFFIC_FILE"
    printf '%s\n' '||example.com' > "$ACL_RULESET_DIR/test.acl"

    BACKUP="$TMP_ROOT/volss-backup.tar.gz"
    EXTRACTED="$TMP_ROOT/backup-extracted"
    mkdir -p "$EXTRACTED"
    create_backup_archive "$BACKUP" || fail "create backup archive"
    extract_and_validate_backup "$BACKUP" "$EXTRACTED" || fail "validate backup archive"
    assert_true "backup includes config" test -f "$EXTRACTED/config.json"
    assert_true "backup includes ACL rulesets" test -f "$EXTRACTED/rulesets/test.acl"

    BAD_BACKUP="$TMP_ROOT/bad-backup.tar.gz"
    python3 - "$BAD_BACKUP" << 'PYEOF'
import io
import tarfile
import sys
with tarfile.open(sys.argv[1], 'w:gz') as tar:
    data = b'bad'
    item = tarfile.TarInfo('volss-backup/unexpected')
    item.size = len(data)
    tar.addfile(item, io.BytesIO(data))
PYEOF
    if extract_and_validate_backup "$BAD_BACKUP" "$TMP_ROOT/bad-out" >/dev/null 2>&1; then
        fail "reject unexpected backup members"
    fi
    TESTS=$((TESTS + 1))

    migrate_link_names_if_needed() { :; }
    rebuild_links() { :; }
    apply_config() { :; }
    rebuild_traffic_rules() { :; }
    generate_client_configs() { :; }
    secure_data_files() { :; }
    printf '%s\n' '{"servers":[{"server_port":40001,"method":"aes-256-gcm","password":"changed"}]}' > "$CONFIG"
    restore_backup_archive "$BACKUP" || fail "restore validated backup"
    assert_eq "one" "$(python3 -c "import json; print(json.load(open('$CONFIG'))['servers'][0]['password'])")" "restore user configuration"

    printf '%s\n' '{"servers":[{"server_port":40002,"method":"aes-256-gcm","password":"rollback"}]}' > "$CONFIG"
    apply_config() { return 1; }
    if restore_backup_archive "$BACKUP" >/dev/null 2>&1; then
        fail "report failed restored configuration apply"
    fi
    assert_eq "rollback" "$(python3 -c "import json; print(json.load(open('$CONFIG'))['servers'][0]['password'])")" "rollback failed restore"
}

test_nftables_traffic() {
    local FAKE_BIN="$TMP_ROOT/nft-bin"
    local ORIGINAL_PATH=$PATH
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/nft" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "-j" ]; then
    printf '%s\n' '{"nftables":[{"counter":{"family":"inet","table":"volss","name":"rx_30001","bytes":300}},{"counter":{"family":"inet","table":"volss","name":"tx_30001","bytes":400}}]}'
elif [ "$1" = "list" ] && [ "$2" = "tables" ]; then
    exit 0
elif [ "$1" = "list" ] && [ "$2" = "table" ]; then
    printf 'table inet volss { }\n'
elif [ "$1" = "-f" ]; then
    cp "$2" "$NFT_CAPTURE"
fi
exit 0
EOF
    chmod +x "$FAKE_BIN/nft"
    PATH="$FAKE_BIN:$PATH"
    export NFT_CAPTURE="$TMP_ROOT/nft-rules.txt"

    CONFIG_DIR="$TMP_ROOT/nft-data"
    CONFIG="$CONFIG_DIR/config.json"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    TRAFFIC_BACKEND_FILE="$CONFIG_DIR/traffic_backend"
    NFT_RULES_FILE="$CONFIG_DIR/volss.nft"
    NFT_FAMILY=inet
    NFT_TABLE=volss
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server_port":30001}]}' > "$CONFIG"
    printf '%s\n' '{"30001":{"tx":10,"rx":20}}' > "$TRAFFIC_FILE"
    printf '%s\n' 'nftables' > "$TRAFFIC_BACKEND_FILE"
    nft_config_file() { echo "$CONFIG_DIR/nftables.conf"; }

    save_traffic_locked || fail "save nftables traffic"
    assert_eq "410" "$(python3 -c "import json; print(json.load(open('$TRAFFIC_FILE'))['30001']['tx'])")" "read nftables upload counter"
    assert_eq "320" "$(python3 -c "import json; print(json.load(open('$TRAFFIC_FILE'))['30001']['rx'])")" "read nftables download counter"
    rebuild_nft_traffic_rules "30001" || fail "build nftables dual-stack rules"
    assert_true "nftables rules include TCP" grep -Fq 'tcp dport 30001 counter name rx_30001' "$NFT_CAPTURE"
    assert_true "nftables rules include UDP" grep -Fq 'udp dport 30001 counter name rx_30001' "$NFT_CAPTURE"
    PATH=$ORIGINAL_PATH
    unset NFT_CAPTURE
}

test_user_policy_enforcement() {
    CONFIG_DIR="$TMP_ROOT/policy"
    CONFIG="$CONFIG_DIR/config.json"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server_port":30001,"name":"quota","quota_bytes":100},{"server_port":30002,"name":"expired","expires_at":"2020-01-01"},{"server_port":30003,"name":"manual","expires_at":"2020-01-01","disabled":true,"disabled_reason":"manual"},{"server_port":30004,"name":"resume","quota_bytes":1000,"disabled":true,"disabled_reason":"quota"}]}' > "$CONFIG"
    printf '%s\n' '{"30001":{"tx":60,"rx":40},"30004":{"tx":1,"rx":1}}' > "$TRAFFIC_FILE"
    POLICY_APPLIED=0
    check_installed() { return 0; }
    save_traffic_locked() { :; }
    apply_config() { POLICY_APPLIED=$((POLICY_APPLIED + 1)); }
    secure_data_files() { :; }

    enforce_user_policies_locked >/dev/null || fail "enforce user policies"
    assert_eq "quota expired manual none" "$(python3 -c "import json; c=json.load(open('$CONFIG')); print(' '.join(s.get('disabled_reason','none') for s in c['servers']))")" "apply quota and expiry policy reasons"
    assert_eq "1 1 1 0" "$(python3 -c "import json; c=json.load(open('$CONFIG')); print(' '.join(str(int(s.get('disabled',False))) for s in c['servers']))")" "pause and resume policy users"
    assert_eq "1" "$POLICY_APPLIED" "apply runtime after policy state change"
}

test_port_listener_helper() {
    ss() {
        printf 'tcp LISTEN 0 128 0.0.0.0:30001 0.0.0.0:*\n'
    }
    assert_true "detect exact TCP listener" port_has_listener tcp "" 30001
    if port_has_listener tcp "" 3000; then
        fail "listener helper accepts partial port"
    fi
    TESTS=$((TESTS + 1))
}

test_health_check() {
    CONFIG_DIR="$TMP_ROOT/health"
    CONFIG="$CONFIG_DIR/config.json"
    RUNTIME="$CONFIG_DIR/runtime.json"
    SS_BIN="$CONFIG_DIR/ssserver"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server":"::","server_port":30001,"method":"aes-256-gcm","password":"one","quota_bytes":1000,"expires_at":"2030-01-01"}]}' > "$CONFIG"
    printf '%s\n' '{"servers":[{"server":"::","server_port":30001,"method":"aes-256-gcm","password":"one"}]}' > "$RUNTIME"
    cat > "$SS_BIN" << 'EOF'
#!/usr/bin/env bash
if [ "$1" = "--help" ]; then echo --check-config; fi
exit 0
EOF
    chmod +x "$SS_BIN"
    SYSTEM=alpine
    check_installed() { return 0; }
    check_svc_running() { return 0; }
    port_has_listener() { return 0; }
    get_server_host() { echo 203.0.113.1; }
    traffic_backend() { echo iptables; }
    traffic_chains_installed() { return 0; }
    ipv6_firewall_available() { return 0; }

    HEALTH_OUTPUT=$(health_check) || fail "health check reports valid service as failed"
    assert_true "health check covers TCP" grep -Fq 'TCP 端口正在监听' <<< "$HEALTH_OUTPUT"
    assert_true "health check covers UDP" grep -Fq 'UDP 端口正在监听' <<< "$HEALTH_OUTPUT"
}

test_ssserver_upgrade_preserves_config() {
    CONFIG_DIR="$TMP_ROOT/upgrade"
    CONFIG="$CONFIG_DIR/config.json"
    SS_BIN="$CONFIG_DIR/ssserver"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server_port":30001,"password":"keep"}]}' > "$CONFIG"
    cat > "$SS_BIN" << 'EOF'
#!/usr/bin/env bash
echo old-version
EOF
    chmod +x "$SS_BIN"
    BEFORE=$(sha256_file "$CONFIG")
    RESTARTS=0
    check_installed() { return 0; }
    check_svc_running() { return 0; }
    save_traffic_locked() { :; }
    svc_restart() { RESTARTS=$((RESTARTS + 1)); }
    install_ssrust() {
        cat > "$SS_BIN" << 'EOF'
#!/usr/bin/env bash
echo new-version
EOF
        chmod +x "$SS_BIN"
    }

    upgrade_ssserver_locked <<< $'y\n' >/dev/null || fail "upgrade ssserver independently"
    assert_eq "$BEFORE" "$(sha256_file "$CONFIG")" "preserve config during ssserver upgrade"
    assert_eq "new-version" "$("$SS_BIN" --version)" "install new ssserver binary"
    assert_eq "1" "$RESTARTS" "restart running service after core upgrade"
}

test_install_shortcut() {
    SCRIPT_INSTALL_PATH="$TMP_ROOT/shortcut/bin/volss.sh"
    SHORTCUT="$TMP_ROOT/shortcut/bin/volss"
    mkdir -p "$(dirname "$SHORTCUT")"

    install_shortcut "$SCRIPT_DIR/volss.sh" >/dev/null || fail "install volss shortcut independently"
    assert_true "install fixed volss script" test -f "$SCRIPT_INSTALL_PATH"
    assert_true "make fixed volss script executable" test -x "$SCRIPT_INSTALL_PATH"
    assert_true "install volss shortcut" test -f "$SHORTCUT"
    assert_true "make volss shortcut executable" test -x "$SHORTCUT"
    assert_true "shortcut opens installed volss menu" grep -Fq "bash $SCRIPT_INSTALL_PATH --menu" "$SHORTCUT"

    printf '#!/usr/bin/env bash\necho occupied\n' > "$SHORTCUT"
    chmod +x "$SHORTCUT"
    BEFORE=$(sha256_file "$SHORTCUT")
    install_shortcut "$SCRIPT_DIR/volss.sh" >/dev/null || fail "preserve occupied shortcut"
    assert_eq "$BEFORE" "$(sha256_file "$SHORTCUT")" "do not overwrite another program"
}

test_add_user_custom_name() {
    CONFIG_DIR="$TMP_ROOT/add-name"
    CONFIG="$CONFIG_DIR/config.json"
    RUNTIME="$CONFIG_DIR/runtime.json"
    LINKS_FILE="$CONFIG_DIR/links.txt"
    SERVER_HOST_FILE="$CONFIG_DIR/server_host"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' 'example.com' > "$SERVER_HOST_FILE"
    printf '%s\n' '{"servers":[{"server":"::","server_port":30001,"method":"aes-256-gcm","password":"one","mode":"tcp_and_udp","name":"Existing"}]}' > "$CONFIG"

    check_installed() { return 0; }
    port_in_use() { return 1; }
    add_traffic_rules_for_new_ports() { :; }
    apply_config() { :; }
    show_links() { :; }
    secure_data_files() { :; }

    add_user_locked <<< $'1\n2\n31000\nAdded Node\n' >/dev/null || fail "add user with custom name"
    assert_eq "Added Node" "$(python3 -c "import json; print(json.load(open('$CONFIG'))['servers'][1]['name'])")" "persist added user name"
    assert_true "encode added user link name" grep -Fq ':31000#Added%20Node' "$LINKS_FILE"
}

test_port_selection() {
    port_in_use() { return 1; }
    shuf() { printf '40000\n40001\n'; }

    select_ports <<< $'1\n1\n65535\n' >/dev/null || fail "allocate port 65535"
    assert_eq "65535" "${PORT_LIST[0]}" "sequential upper port boundary"

    select_ports <<< $'2\n2\n40000\n40001\n' >/dev/null || fail "allocate complete random range"
    assert_eq "2" "${#PORT_LIST[@]}" "random allocation has no duplicate failure"
    assert_eq "40000 40001" "${PORT_LIST[*]}" "random allocation candidates"
}

test_acl_activation() {
    CONFIG_DIR="$TMP_ROOT/acl"
    CONFIG="$CONFIG_DIR/config.json"
    RUNTIME="$CONFIG_DIR/runtime.json"
    ACL_PATH="$CONFIG_DIR/blocklist.acl"
    ACL_RULESET_DIR="$CONFIG_DIR/rulesets"
    MANUAL_FILE="$CONFIG_DIR/manual.list"
    mkdir -p "$ACL_RULESET_DIR"
    printf '%s\n' '{"servers":[]}' > "$CONFIG"
    printf '%s\n' 'example.com' > "$MANUAL_FILE"
    APPLY_CALLED=0
    apply_config() { APPLY_CALLED=$((APPLY_CALLED + 1)); }
    secure_data_files() { :; }

    rebuild_acl >/dev/null || fail "rebuild ACL"
    assert_eq "$ACL_PATH" "$(python3 -c "import json; print(json.load(open('$CONFIG'))['acl'])")" "persist ACL path"
    assert_eq "1" "$APPLY_CALLED" "apply runtime after ACL activation"
    assert_true "write manual ACL rule" grep -Fqx '||example.com' "$ACL_PATH"
}

test_delete_user_state() {
    CONFIG_DIR="$TMP_ROOT/delete"
    CONFIG="$CONFIG_DIR/config.json"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    LINKS_FILE="$CONFIG_DIR/links.txt"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server_port":1001},{"server_port":1002},{"server_port":1003}]}' > "$CONFIG"
    printf '%s\n' '{"1001":{"tx":1},"1002":{"tx":2},"1003":{"tx":3}}' > "$TRAFFIC_FILE"

    SAVE_CALLED=0
    LINKS_REBUILT=0
    RULE_PORTS=""
    list_users() { :; }
    save_traffic() { SAVE_CALLED=$((SAVE_CALLED + 1)); }
    rebuild_traffic_rules() { RULE_PORTS=$1; }
    rebuild_links() { LINKS_REBUILT=$((LINKS_REBUILT + 1)); }
    apply_config() { :; }
    secure_data_files() { :; }

    delete_user_locked <<< $'2\ny\n' >/dev/null || fail "delete middle user"
    assert_eq "1" "$SAVE_CALLED" "save traffic before deletion"
    assert_eq "1001 1003" "$(config_ports)" "delete selected config entry"
    assert_eq "1001 1003" "$RULE_PORTS" "rebuild rules for remaining users"
    assert_eq "1" "$LINKS_REBUILT" "rebuild link labels"
    assert_eq "1001 1003" "$(python3 -c "import json; print(' '.join(sorted(json.load(open('$TRAFFIC_FILE')).keys())))")" "remove deleted traffic history"
}

test_dual_stack_traffic() {
    local FAKE_BIN="$TMP_ROOT/firewall-bin"
    local ORIGINAL_PATH=$PATH
    mkdir -p "$FAKE_BIN"
    cat > "$FAKE_BIN/iptables" << 'EOF'
#!/usr/bin/env bash
if [ "$*" = "-nvxL VOLSS_TRAFFIC -Z" ]; then
    if [ "$(basename "$0")" = "iptables" ]; then
        RX=100
        TX=200
    else
        RX=300
        TX=400
    fi
    printf 'Chain VOLSS_TRAFFIC\n'
    printf ' pkts bytes target prot opt in out source destination\n'
    printf ' 0 %s all tcp -- * * 0.0.0.0/0 0.0.0.0/0 dpt:30001\n' "$RX"
    printf ' 0 %s all tcp -- * * 0.0.0.0/0 0.0.0.0/0 spt:30001\n' "$TX"
fi
exit 0
EOF
    cp "$FAKE_BIN/iptables" "$FAKE_BIN/ip6tables"
    chmod +x "$FAKE_BIN/iptables" "$FAKE_BIN/ip6tables"

    CONFIG_DIR="$TMP_ROOT/traffic"
    CONFIG="$CONFIG_DIR/config.json"
    TRAFFIC_FILE="$CONFIG_DIR/traffic.json"
    TRAFFIC_CHAIN="VOLSS_TRAFFIC"
    mkdir -p "$CONFIG_DIR"
    printf '%s\n' '{"servers":[{"server_port":30001}]}' > "$CONFIG"
    printf '%s\n' '{"30001":{"tx":10,"rx":20}}' > "$TRAFFIC_FILE"

    PATH="$FAKE_BIN:$PATH"
    save_traffic_locked || fail "save dual-stack traffic"
    PATH=$ORIGINAL_PATH
    assert_eq "610" "$(python3 -c "import json; print(json.load(open('$TRAFFIC_FILE'))['30001']['tx'])")" "sum IPv4 and IPv6 upload"
    assert_eq "420" "$(python3 -c "import json; print(json.load(open('$TRAFFIC_FILE'))['30001']['rx'])")" "sum IPv4 and IPv6 download"
}

test_install_failure_stops() {
    INSTALL_CONTINUED=0
    check_installed() { return 1; }
    install_deps() { return 1; }
    install_ssrust() { INSTALL_CONTINUED=1; }

    if do_install_locked <<< $'\n' >/dev/null; then
        fail "installation reports success after dependency failure"
    fi
    assert_eq "0" "$INSTALL_CONTINUED" "stop installation after failed stage"
}

test_nonblocking_stop_hook() {
    STATE_LOCK_DIR="$TMP_ROOT/stop-lock"
    STOP_SAVES=0
    save_traffic() { STOP_SAVES=$((STOP_SAVES + 1)); }

    mkdir -p "$STATE_LOCK_DIR"
    printf '%s\n' "$$" > "$STATE_LOCK_DIR/pid"
    save_traffic_if_unlocked || fail "skip active state lock"
    assert_eq "0" "$STOP_SAVES" "stop hook does not wait on active config operation"

    printf '%s\n' '2147483647' > "$STATE_LOCK_DIR/pid"
    save_traffic_if_unlocked || fail "recover stale state lock"
    assert_eq "1" "$STOP_SAVES" "stop hook saves after stale lock cleanup"
}

test_host_helpers
test_port_selection
test_link_name_management
test_runtime_omits_link_names
test_add_user_custom_name
test_acl_activation
test_delete_user_state
test_dual_stack_traffic
test_install_failure_stops
test_nonblocking_stop_hook
test_client_exports_and_qr
test_backup_validation
test_nftables_traffic
test_user_policy_enforcement
test_port_listener_helper
test_health_check
test_ssserver_upgrade_preserves_config
test_install_shortcut

echo "PASS: $TESTS assertions"
