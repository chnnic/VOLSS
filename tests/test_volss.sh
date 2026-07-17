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
    generate_config >/dev/null || fail "generate IPv6 configuration"
    assert_true "generate bracketed IPv6 link" grep -Fq '@[2001:db8::3]:30001#用户1' "$LINKS_FILE"
    assert_true "generate supported bind address" grep -Eq '"server":"(::|0\.0\.0\.0)"' "$CONFIG"
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
test_acl_activation
test_delete_user_state
test_dual_stack_traffic
test_install_failure_stops
test_nonblocking_stop_hook

echo "PASS: $TESTS assertions"
