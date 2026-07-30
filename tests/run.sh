#!/usr/bin/env bash
set -u

PROJECT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$PROJECT_DIR/vps-network-limiter.sh"
PASS=0
FAIL=0
CASE_DIR=""
OUTPUT=""
STATUS=0

cleanup_case() {
    if [[ -n "$CASE_DIR" && -d "$CASE_DIR" ]]; then
        rm -rf "$CASE_DIR"
    fi
    CASE_DIR=""
}
trap cleanup_case EXIT

setup_case() {
    cleanup_case
    CASE_DIR=$(mktemp -d)
    mkdir -p "$CASE_DIR/mockbin" "$CASE_DIR/etc/systemd/system" "$CASE_DIR/usr/local/sbin"
    export MOCK_LOG="$CASE_DIR/commands.log"
    export MOCK_IFB_STATE="$CASE_DIR/ifb.exists"
    export MOCK_TC_MODE="default"
    export MOCK_FILTER_PRESENT="1"
    export MOCK_DEFAULT_INTERFACE="eth0"
    export MOCK_SYSTEMCTL_FAIL_ONCE_FILE=""
    : >"$MOCK_LOG"

    cat >"$CASE_DIR/mockbin/mock-command" <<'MOCK'
#!/usr/bin/env bash
set -u
cmd=$(basename "$0")
printf '%s %s\n' "$cmd" "$*" >>"$MOCK_LOG"

case "$cmd" in
    ip)
        case "$*" in
            "-4 route show default")
                printf 'default via 192.0.2.1 dev %s proto static\n' "$MOCK_DEFAULT_INTERFACE"
                ;;
            "-6 route show default")
                ;;
            "link show dev eth0"|"-o link show dev eth0")
                printf '%s\n' '2: eth0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'
                ;;
            "link show dev eth1"|"-o link show dev eth1")
                printf '%s\n' '3: eth1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500'
                ;;
            "link show dev ifb-vpslimit"|"-o link show dev ifb-vpslimit")
                [[ -f "$MOCK_IFB_STATE" ]] || exit 1
                printf '%s\n' '9: ifb-vpslimit: <BROADCAST,NOARP,UP,LOWER_UP> mtu 1500'
                ;;
            "link add ifb-vpslimit type ifb")
                : >"$MOCK_IFB_STATE"
                ;;
            "link delete ifb-vpslimit type ifb")
                rm -f "$MOCK_IFB_STATE"
                ;;
            *)
                ;;
        esac
        ;;
    tc)
        if [[ "$*" == "qdisc show dev eth0" ]]; then
            case "$MOCK_TC_MODE" in
                default)
                    printf '%s\n' 'qdisc fq_codel 0: root refcnt 2 limit 10240p'
                    ;;
                conflict-ingress)
                    printf '%s\n' 'qdisc fq_codel 0: root refcnt 2 limit 10240p'
                    printf '%s\n' 'qdisc ingress ffff: parent ffff:fff1 ----------------'
                    ;;
                ours)
                    printf '%s\n' 'qdisc tbf 1: root refcnt 2 rate 100Mbit burst 125000b lat 50ms'
                    printf '%s\n' 'qdisc ingress ffff: parent ffff:fff1 ----------------'
                    ;;
            esac
        elif [[ "$*" == "qdisc show dev eth1" ]]; then
            printf '%s\n' 'qdisc fq_codel 0: root refcnt 2 limit 10240p'
        elif [[ "$*" == "qdisc show dev ifb-vpslimit" ]]; then
            [[ -f "$MOCK_IFB_STATE" ]] && printf '%s\n' 'qdisc tbf 2: root refcnt 2 rate 50Mbit burst 62500b lat 50ms'
        elif [[ "$*" == "filter show dev eth0 parent ffff:" && "$MOCK_FILTER_PRESENT" == "1" ]]; then
            printf '%s\n' 'action order 1: mirred (Egress Redirect to device ifb-vpslimit) stolen'
        fi
        ;;
    modprobe)
        ;;
    systemctl)
        if [[ "$1" == "restart" && -n "$MOCK_SYSTEMCTL_FAIL_ONCE_FILE" && ! -f "$MOCK_SYSTEMCTL_FAIL_ONCE_FILE" ]]; then
            : >"$MOCK_SYSTEMCTL_FAIL_ONCE_FILE"
            exit 1
        fi
        if [[ "$1" == "restart" ]]; then
            "$VPS_LIMITER_INSTALL_PATH" --apply
        fi
        ;;
esac
MOCK
    chmod +x "$CASE_DIR/mockbin/mock-command"
    for cmd in ip tc modprobe systemctl; do
        ln -s mock-command "$CASE_DIR/mockbin/$cmd"
    done

    export PATH="$CASE_DIR/mockbin:/usr/bin:/bin:/usr/sbin:/sbin"
    export VPS_LIMITER_ALLOW_NON_ROOT=1
    export VPS_LIMITER_CONFIG_FILE="$CASE_DIR/etc/vps-network-limiter.conf"
    export VPS_LIMITER_UNIT_FILE="$CASE_DIR/etc/systemd/system/vps-network-limiter.service"
    export VPS_LIMITER_INSTALL_PATH="$CASE_DIR/usr/local/sbin/vps-network-limiter"
}

run_cmd() {
    set +e
    OUTPUT=$("$@" 2>&1)
    STATUS=$?
    set -e 2>/dev/null || true
}

assert_status() {
    local expected=$1
    if [[ "$STATUS" -ne "$expected" ]]; then
        printf '    expected status %s, got %s\n    output: %s\n' "$expected" "$STATUS" "$OUTPUT"
        return 1
    fi
}

assert_contains() {
    local haystack=$1 needle=$2
    if [[ "$haystack" != *"$needle"* ]]; then
        printf '    expected to contain: %s\n    actual: %s\n' "$needle" "$haystack"
        return 1
    fi
}

assert_file_contains() {
    local file=$1 needle=$2
    if [[ ! -f "$file" ]]; then
        printf '    missing file: %s\n' "$file"
        return 1
    fi
    local content
    content=$(<"$file")
    assert_contains "$content" "$needle"
}

assert_not_contains() {
    local haystack=$1 needle=$2
    if [[ "$haystack" == *"$needle"* ]]; then
        printf '    expected not to contain: %s\n    actual: %s\n' "$needle" "$haystack"
        return 1
    fi
}

run_test() {
    local name=$1
    shift
    if "$@"; then
        printf 'ok - %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf 'not ok - %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

test_normalizes_supported_rates() {
    setup_case
    local pair input expected
    for pair in '100:100mbit' '100M:100mbit' ' 100M :100mbit' '1.5G:1.5gbit' '800kbit:800kbit' '25Mbps:25mbit'; do
        input=${pair%%:*}
        expected=${pair#*:}
        run_cmd "$SCRIPT" --normalize-rate "$input"
        assert_status 0 || return 1
        [[ "$OUTPUT" == "$expected" ]] || {
            printf '    input %s: expected %s, got %s\n' "$input" "$expected" "$OUTPUT"
            return 1
        }
    done
}

test_rejects_invalid_rates() {
    setup_case
    local input
    for input in '0' '-1' 'abc' '100 MB' '1e3' '100mbit;reboot'; do
        run_cmd "$SCRIPT" --normalize-rate "$input"
        [[ "$STATUS" -ne 0 ]] || {
            printf '    invalid input unexpectedly accepted: %s\n' "$input"
            return 1
        }
    done
}

test_set_accepts_only_one_plain_mbps_number() {
    setup_case
    local input
    for input in '100M' '100mbit' 'none' '-1' 'abc' '100;reboot'; do
        run_cmd "$SCRIPT" set "$input"
        [[ "$STATUS" -ne 0 ]] || {
            printf '    non-numeric public input unexpectedly accepted: %s\n' "$input"
            return 1
        }
        [[ ! -e "$VPS_LIMITER_CONFIG_FILE" ]] || return 1
    done
    run_cmd "$SCRIPT" set 100 50
    [[ "$STATUS" -ne 0 ]] || return 1
    assert_contains "$OUTPUT" '只需输入一个 Mbps 数字' || return 1
}

test_set_applies_both_directions_and_persists() {
    setup_case
    run_cmd "$SCRIPT" set 100
    assert_status 0 || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'INTERFACE=eth0' || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'UPLOAD_RATE=100mbit' || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'DOWNLOAD_RATE=100mbit' || return 1
    assert_file_contains "$VPS_LIMITER_UNIT_FILE" 'ExecStart='"$VPS_LIMITER_INSTALL_PATH"' --apply' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc replace dev eth0 root handle 1: tbf rate 100mbit' || return 1
    assert_file_contains "$MOCK_LOG" 'tc filter add dev eth0 parent ffff: protocol all u32 match u32 0 0 action mirred egress redirect dev ifb-vpslimit' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc replace dev ifb-vpslimit root handle 2: tbf rate 100mbit' || return 1
    assert_file_contains "$MOCK_LOG" 'systemctl enable vps-network-limiter.service' || return 1
    assert_file_contains "$MOCK_LOG" 'systemctl restart vps-network-limiter.service' || return 1
    assert_contains "$OUTPUT" '限速已生效' || return 1
}

test_interactive_set_accepts_one_mbps_number_for_both_directions() {
    setup_case
    set +e
    OUTPUT=$(printf '100\n' | "$SCRIPT" set 2>&1)
    STATUS=$?
    set -e 2>/dev/null || true
    assert_status 0 || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'INTERFACE=eth0' || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'UPLOAD_RATE=100mbit' || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'DOWNLOAD_RATE=100mbit' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc replace dev eth0 root handle 1: tbf rate 100mbit' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc replace dev ifb-vpslimit root handle 2: tbf rate 100mbit' || return 1
}

test_existing_ingress_rule_is_not_overwritten() {
    setup_case
    export MOCK_TC_MODE=conflict-ingress
    run_cmd "$SCRIPT" set 100
    [[ "$STATUS" -ne 0 ]] || return 1
    [[ ! -e "$VPS_LIMITER_CONFIG_FILE" ]] || return 1
    assert_contains "$OUTPUT" '已有入站流量规则' || return 1
    local log
    log=$(<"$MOCK_LOG")
    assert_not_contains "$log" 'tc qdisc del dev eth0 ingress' || return 1
}

test_restore_removes_only_managed_rules_and_disables_boot_service() {
    setup_case
    cat >"$VPS_LIMITER_CONFIG_FILE" <<'CONF'
INTERFACE=eth0
UPLOAD_RATE=100mbit
DOWNLOAD_RATE=50mbit
CONF
    : >"$MOCK_IFB_STATE"
    export MOCK_TC_MODE=ours
    run_cmd "$SCRIPT" restore
    assert_status 0 || return 1
    [[ ! -e "$VPS_LIMITER_CONFIG_FILE" ]] || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc del dev eth0 root handle 1:' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc del dev eth0 ingress' || return 1
    assert_file_contains "$MOCK_LOG" 'ip link delete ifb-vpslimit type ifb' || return 1
    assert_file_contains "$MOCK_LOG" 'systemctl disable vps-network-limiter.service' || return 1
    assert_contains "$OUTPUT" '已恢复不限速' || return 1
}

test_failed_restart_rolls_back_previous_configuration() {
    setup_case
    cat >"$VPS_LIMITER_CONFIG_FILE" <<'CONF'
INTERFACE=eth0
UPLOAD_RATE=20mbit
DOWNLOAD_RATE=none
CONF
    export MOCK_SYSTEMCTL_FAIL_ONCE_FILE="$CASE_DIR/systemctl.failed-once"
    run_cmd "$SCRIPT" set 100
    [[ "$STATUS" -ne 0 ]] || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'UPLOAD_RATE=20mbit' || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'DOWNLOAD_RATE=none' || return 1
    assert_contains "$OUTPUT" '已回滚到原配置' || return 1
    local restart_count
    restart_count=$(grep -c '^systemctl restart vps-network-limiter.service$' "$MOCK_LOG")
    [[ "$restart_count" -eq 2 ]] || {
        printf '    expected two restart attempts, got %s\n' "$restart_count"
        return 1
    }
}

test_change_of_interface_cleans_old_managed_qdisc() {
    setup_case
    cat >"$VPS_LIMITER_CONFIG_FILE" <<'CONF'
INTERFACE=eth0
UPLOAD_RATE=20mbit
DOWNLOAD_RATE=none
CONF
    export MOCK_TC_MODE=ours
    export MOCK_DEFAULT_INTERFACE=eth1
    run_cmd "$SCRIPT" set 100
    assert_status 0 || return 1
    assert_file_contains "$VPS_LIMITER_CONFIG_FILE" 'INTERFACE=eth1' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc del dev eth0 root handle 1:' || return 1
    assert_file_contains "$MOCK_LOG" 'tc qdisc replace dev eth1 root handle 1: tbf rate 100mbit' || return 1
}

test_status_rejects_malformed_config() {
    setup_case
    cat >"$VPS_LIMITER_CONFIG_FILE" <<'CONF'
INTERFACE=eth0
UPLOAD_RATE=100mbit;reboot
DOWNLOAD_RATE=none
CONF
    run_cmd "$SCRIPT" status
    [[ "$STATUS" -ne 0 ]] || return 1
    assert_contains "$OUTPUT" '配置中的上传速率无效' || return 1
    assert_not_contains "$OUTPUT" '状态：未配置限速' || return 1
}

test_status_detects_missing_ingress_filter() {
    setup_case
    cat >"$VPS_LIMITER_CONFIG_FILE" <<'CONF'
INTERFACE=eth0
UPLOAD_RATE=100mbit
DOWNLOAD_RATE=50mbit
CONF
    : >"$MOCK_IFB_STATE"
    export MOCK_TC_MODE=ours
    export MOCK_FILTER_PRESENT=0
    run_cmd "$SCRIPT" status
    [[ "$STATUS" -ne 0 ]] || return 1
    assert_contains "$OUTPUT" '内核规则未完整生效' || return 1
}

test_status_reports_configuration_and_kernel_state() {
    setup_case
    cat >"$VPS_LIMITER_CONFIG_FILE" <<'CONF'
INTERFACE=eth0
UPLOAD_RATE=100mbit
DOWNLOAD_RATE=100mbit
CONF
    : >"$MOCK_IFB_STATE"
    export MOCK_TC_MODE=ours
    run_cmd "$SCRIPT" status
    assert_status 0 || return 1
    assert_contains "$OUTPUT" '网卡：eth0' || return 1
    assert_contains "$OUTPUT" '限速：100 Mbps（上下行）' || return 1
    assert_contains "$OUTPUT" '运行状态：已生效' || return 1
}

run_test 'normalizes supported rate formats' test_normalizes_supported_rates
run_test 'rejects malformed and unsafe rates' test_rejects_invalid_rates
run_test 'public set accepts only one plain Mbps number' test_set_accepts_only_one_plain_mbps_number
run_test 'applies upload/download limits and persists them' test_set_applies_both_directions_and_persists
run_test 'interactive set accepts one Mbps number for both directions' test_interactive_set_accepts_one_mbps_number_for_both_directions
run_test 'refuses to overwrite an existing ingress rule' test_existing_ingress_rule_is_not_overwritten
run_test 'restore removes managed rules and disables persistence' test_restore_removes_only_managed_rules_and_disables_boot_service
run_test 'failed service restart restores previous configuration' test_failed_restart_rolls_back_previous_configuration
run_test 'changing interface removes the old managed qdisc' test_change_of_interface_cleans_old_managed_qdisc
run_test 'status rejects a malformed saved configuration' test_status_rejects_malformed_config
run_test 'status detects a missing ingress redirect filter' test_status_detects_missing_ingress_filter
run_test 'status reports saved and active state' test_status_reports_configuration_and_kernel_state

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
