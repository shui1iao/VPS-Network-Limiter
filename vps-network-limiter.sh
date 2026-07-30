#!/usr/bin/env bash
set -uo pipefail

PROGRAM_NAME="VPS Network Limiter"
VERSION="1.0.0"
PATH="${PATH:-}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

CONFIG_FILE=${VPS_LIMITER_CONFIG_FILE:-/etc/vps-network-limiter.conf}
UNIT_FILE=${VPS_LIMITER_UNIT_FILE:-/etc/systemd/system/vps-network-limiter.service}
INSTALL_PATH=${VPS_LIMITER_INSTALL_PATH:-/usr/local/sbin/vps-network-limiter}
SERVICE_NAME="vps-network-limiter.service"
IFB_DEVICE="ifb-vpslimit"
CANONICAL_URL=${VPS_LIMITER_SOURCE_URL:-https://limit.shuijiao.de}

CONFIG_INTERFACE=""
CONFIG_UPLOAD=""
CONFIG_DOWNLOAD=""

info() {
    printf '%s\n' "$*"
}

warn() {
    printf '警告：%s\n' "$*" >&2
}

die() {
    printf '错误：%s\n' "$*" >&2
    return 1
}

require_root() {
    if [[ ${VPS_LIMITER_ALLOW_NON_ROOT:-0} != "1" && $(id -u) -ne 0 ]]; then
        die "请使用 root 权限运行。"
        return 1
    fi
}

require_command() {
    local command_name=$1
    if ! command -v "$command_name" >/dev/null 2>&1; then
        die "缺少命令 $command_name。Debian/Ubuntu 可执行：apt install -y iproute2 kmod"
        return 1
    fi
}

check_dependencies() {
    require_command ip || return 1
    require_command tc || return 1
    require_command systemctl || return 1
}

trim_whitespace() {
    local value=${1:-}
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "$value"
}

normalize_rate() {
    local raw=${1:-}
    local value number unit nonzero

    raw=$(trim_whitespace "$raw")
    [[ -n "$raw" ]] || return 1
    value=${raw,,}
    if [[ ! "$value" =~ ^([0-9]+([.][0-9]+)?)(kbit|mbit|gbit|kbps|mbps|gbps|k|m|g)?$ ]]; then
        return 1
    fi

    number=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[3]:-m}
    nonzero=${number//0/}
    nonzero=${nonzero//./}
    [[ -n "$nonzero" ]] || return 1

    case "$unit" in
        k|kbit|kbps) unit="kbit" ;;
        m|mbit|mbps) unit="mbit" ;;
        g|gbit|gbps) unit="gbit" ;;
        *) return 1 ;;
    esac

    printf '%s%s\n' "$number" "$unit"
}

validate_interface_name() {
    local interface=${1:-}
    [[ -n "$interface" ]] || return 1
    [[ ${#interface} -le 15 ]] || return 1
    [[ "$interface" =~ ^[a-zA-Z0-9_.:-]+$ ]] || return 1
    [[ "$interface" != "lo" ]]
}

validate_saved_rate() {
    local rate=${1:-}
    [[ "$rate" == "none" ]] && return 0
    [[ $(normalize_rate "$rate" 2>/dev/null) == "$rate" ]]
}

detect_default_interface() {
    local interface=""
    interface=$(ip -4 route show default 2>/dev/null | awk '
        $1 == "default" {
            for (i = 1; i <= NF; i++) {
                if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); exit }
            }
        }
    ')
    if [[ -z "$interface" ]]; then
        interface=$(ip -6 route show default 2>/dev/null | awk '
            $1 == "default" {
                for (i = 1; i <= NF; i++) {
                    if ($i == "dev" && (i + 1) <= NF) { print $(i + 1); exit }
                }
            }
        ')
    fi
    validate_interface_name "$interface" || return 1
    printf '%s\n' "$interface"
}

interface_exists() {
    ip link show dev "$1" >/dev/null 2>&1
}

read_config() {
    local line key value
    CONFIG_INTERFACE=""
    CONFIG_UPLOAD=""
    CONFIG_DOWNLOAD=""

    [[ -f "$CONFIG_FILE" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == *=* ]] || {
            die "配置文件格式错误：$CONFIG_FILE"
            return 1
        }
        key=${line%%=*}
        value=${line#*=}
        case "$key" in
            INTERFACE)
                [[ -z "$CONFIG_INTERFACE" ]] || return 1
                CONFIG_INTERFACE=$value
                ;;
            UPLOAD_RATE)
                [[ -z "$CONFIG_UPLOAD" ]] || return 1
                CONFIG_UPLOAD=$value
                ;;
            DOWNLOAD_RATE)
                [[ -z "$CONFIG_DOWNLOAD" ]] || return 1
                CONFIG_DOWNLOAD=$value
                ;;
            *)
                die "配置文件包含未知字段：$key"
                return 1
                ;;
        esac
    done <"$CONFIG_FILE"

    validate_interface_name "$CONFIG_INTERFACE" || {
        die "配置中的网卡名无效。"
        return 1
    }
    validate_saved_rate "$CONFIG_UPLOAD" || {
        die "配置中的上传速率无效。"
        return 1
    }
    validate_saved_rate "$CONFIG_DOWNLOAD" || {
        die "配置中的下载速率无效。"
        return 1
    }
    [[ "$CONFIG_UPLOAD" != "none" || "$CONFIG_DOWNLOAD" != "none" ]] || {
        die "上传和下载不能同时设为不限速。"
        return 1
    }
}

write_config() {
    local interface=$1 upload=$2 download=$3
    local directory temporary
    directory=$(dirname "$CONFIG_FILE")
    mkdir -p "$directory" || return 1
    temporary="${CONFIG_FILE}.tmp.$$"
    (
        umask 077
        printf 'INTERFACE=%s\nUPLOAD_RATE=%s\nDOWNLOAD_RATE=%s\n' \
            "$interface" "$upload" "$download" >"$temporary"
    ) || {
        rm -f "$temporary"
        return 1
    }
    chmod 600 "$temporary" || {
        rm -f "$temporary"
        return 1
    }
    mv -f "$temporary" "$CONFIG_FILE"
}

rate_to_bps() {
    local rate=$1 number unit multiplier
    number=${rate%kbit}
    if [[ "$number" != "$rate" ]]; then
        multiplier=1000
    else
        number=${rate%mbit}
        if [[ "$number" != "$rate" ]]; then
            multiplier=1000000
        else
            number=${rate%gbit}
            multiplier=1000000000
        fi
    fi
    awk -v number="$number" -v multiplier="$multiplier" 'BEGIN { printf "%.0f\n", number * multiplier }'
}

calculate_burst_bytes() {
    local rate=$1 bps
    bps=$(rate_to_bps "$rate") || return 1
    awk -v bps="$bps" 'BEGIN {
        burst = bps / 8 / 100
        if (burst < 16000) burst = 16000
        printf "%.0f\n", burst
    }'
}

qdisc_state() {
    tc qdisc show dev "$1" 2>/dev/null || true
}

has_managed_upload_qdisc() {
    qdisc_state "$1" | grep -Eq '^qdisc tbf 1: root([[:space:]]|$)'
}

has_ingress_qdisc() {
    qdisc_state "$1" | grep -Eq '^qdisc (ingress|clsact) '
}

has_managed_ingress_qdisc() {
    qdisc_state "$1" | grep -Eq '^qdisc ingress ffff: '
}

has_managed_ingress_filter() {
    tc filter show dev "$1" parent ffff: 2>/dev/null | \
        grep -Eqi "mirred.*redirect.*${IFB_DEVICE}"
}

has_managed_download_qdisc() {
    interface_exists "$IFB_DEVICE" && \
        qdisc_state "$IFB_DEVICE" | grep -Eq '^qdisc tbf 2: root([[:space:]]|$)'
}

has_custom_root_qdisc() {
    local state root_line
    state=$(qdisc_state "$1")
    root_line=$(printf '%s\n' "$state" | grep ' root' | head -n 1 || true)
    [[ -n "$root_line" ]] || return 1
    [[ "$root_line" =~ ^qdisc[[:space:]]+tbf[[:space:]]+1:[[:space:]]+root ]] && return 1
    [[ "$root_line" =~ ^qdisc[[:space:]]+[^[:space:]]+[[:space:]]+0:[[:space:]]+root ]] && return 1
    return 0
}

preflight_conflicts() {
    local interface=$1 download=$2 allow_existing_managed=${3:-0}

    interface_exists "$interface" || {
        die "网卡 $interface 不存在。"
        return 1
    }

    if has_custom_root_qdisc "$interface"; then
        die "网卡 $interface 已有自定义出站流量规则，为避免覆盖已停止。"
        return 1
    fi

    if [[ "$download" != "none" ]] && has_ingress_qdisc "$interface"; then
        if [[ "$allow_existing_managed" != "1" ]] || \
            ! has_managed_ingress_qdisc "$interface" || \
            ! has_managed_download_qdisc; then
            die "网卡 $interface 已有入站流量规则，为避免覆盖已停止。"
            return 1
        fi
    fi
}

cleanup_managed_rules() {
    local interface=$1
    local had_managed_download=0

    if has_managed_download_qdisc; then
        had_managed_download=1
    fi

    if has_managed_upload_qdisc "$interface"; then
        tc qdisc del dev "$interface" root handle 1: >/dev/null 2>&1 || \
            warn "未能删除 $interface 上的出站限速规则。"
    fi

    if [[ "$had_managed_download" -eq 1 ]]; then
        if has_managed_ingress_qdisc "$interface"; then
            tc qdisc del dev "$interface" ingress >/dev/null 2>&1 || \
                warn "未能删除 $interface 上的入站重定向规则。"
        fi
        tc qdisc del dev "$IFB_DEVICE" root handle 2: >/dev/null 2>&1 || \
            warn "未能删除 $IFB_DEVICE 上的下载限速规则。"
        ip link set "$IFB_DEVICE" down >/dev/null 2>&1 || true
        ip link delete "$IFB_DEVICE" type ifb >/dev/null 2>&1 || \
            warn "未能删除虚拟网卡 $IFB_DEVICE。"
    fi
}

apply_limits() {
    local interface=$1 upload=$2 download=$3 allow_existing_managed=${4:-1}
    local burst

    validate_interface_name "$interface" || {
        die "网卡名无效。"
        return 1
    }
    validate_saved_rate "$upload" || {
        die "上传速率无效。"
        return 1
    }
    validate_saved_rate "$download" || {
        die "下载速率无效。"
        return 1
    }
    [[ "$upload" != "none" || "$download" != "none" ]] || {
        die "上传和下载不能同时设为不限速。"
        return 1
    }

    preflight_conflicts "$interface" "$download" "$allow_existing_managed" || return 1
    cleanup_managed_rules "$interface"

    if [[ "$upload" != "none" ]]; then
        burst=$(calculate_burst_bytes "$upload") || {
            die "无法计算上传限速参数。"
            return 1
        }
        if ! tc qdisc replace dev "$interface" root handle 1: tbf \
            rate "$upload" burst "$burst" latency 50ms; then
            cleanup_managed_rules "$interface"
            die "应用上传限速失败，已清理本次变更。"
            return 1
        fi
    fi

    if [[ "$download" != "none" ]]; then
        if command -v modprobe >/dev/null 2>&1; then
            modprobe ifb numifbs=0 >/dev/null 2>&1 || true
        fi
        if ! interface_exists "$IFB_DEVICE"; then
            if ! ip link add "$IFB_DEVICE" type ifb; then
                cleanup_managed_rules "$interface"
                die "创建 IFB 虚拟网卡失败，已清理本次变更。"
                return 1
            fi
        fi
        if ! ip link set "$IFB_DEVICE" up; then
            cleanup_managed_rules "$interface"
            die "启用 IFB 虚拟网卡失败，已清理本次变更。"
            return 1
        fi

        burst=$(calculate_burst_bytes "$download") || {
            cleanup_managed_rules "$interface"
            die "无法计算下载限速参数，已清理本次变更。"
            return 1
        }
        if ! tc qdisc replace dev "$IFB_DEVICE" root handle 2: tbf \
            rate "$download" burst "$burst" latency 50ms; then
            cleanup_managed_rules "$interface"
            die "创建下载限速队列失败，已清理本次变更。"
            return 1
        fi
        if ! tc qdisc add dev "$interface" handle ffff: ingress; then
            cleanup_managed_rules "$interface"
            die "创建入站重定向队列失败，已清理本次变更。"
            return 1
        fi
        if ! tc filter add dev "$interface" parent ffff: protocol all u32 \
            match u32 0 0 action mirred egress redirect dev "$IFB_DEVICE"; then
            cleanup_managed_rules "$interface"
            die "创建入站重定向规则失败，已清理本次变更。"
            return 1
        fi
    fi
}

install_self() {
    local source_path install_directory temporary
    source_path=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
    install_directory=$(dirname "$INSTALL_PATH")
    mkdir -p "$install_directory" || return 1

    if [[ -n "$source_path" && "$source_path" == "$INSTALL_PATH" ]]; then
        chmod 755 "$INSTALL_PATH"
        return
    fi

    temporary="${INSTALL_PATH}.tmp.$$"
    rm -f "$temporary"
    if [[ -n "$source_path" && -f "$source_path" ]]; then
        cp -- "$source_path" "$temporary" || return 1
    else
        if ! command -v curl >/dev/null 2>&1; then
            die "通过短链运行时需要 curl 才能安装持久化脚本。"
            return 1
        fi
        if ! curl -fLsS --retry 3 --connect-timeout 10 --max-time 60 \
            -o "$temporary" "$CANONICAL_URL"; then
            rm -f "$temporary"
            return 1
        fi
    fi
    if [[ ! -s "$temporary" ]] || ! bash -n "$temporary"; then
        rm -f "$temporary"
        return 1
    fi
    chmod 755 "$temporary" || {
        rm -f "$temporary"
        return 1
    }
    mv -f "$temporary" "$INSTALL_PATH"
}

write_service_unit() {
    local unit_directory temporary
    unit_directory=$(dirname "$UNIT_FILE")
    mkdir -p "$unit_directory" || return 1
    temporary="${UNIT_FILE}.tmp.$$"
    cat >"$temporary" <<UNIT
[Unit]
Description=VPS Network Limiter
Wants=network-online.target
After=network-online.target
ConditionPathExists=$CONFIG_FILE

[Service]
Type=oneshot
ExecStart=$INSTALL_PATH --apply
ExecStop=$INSTALL_PATH --clear-runtime
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
    chmod 644 "$temporary" || {
        rm -f "$temporary"
        return 1
    }
    mv -f "$temporary" "$UNIT_FILE"
}

format_rate() {
    if [[ "$1" == "none" ]]; then
        printf '不限速'
    else
        printf '%s' "$1"
    fi
}

command_apply() {
    require_root || return 1
    check_dependencies || return 1
    read_config || {
        die "未找到有效配置：$CONFIG_FILE"
        return 1
    }
    apply_limits "$CONFIG_INTERFACE" "$CONFIG_UPLOAD" "$CONFIG_DOWNLOAD" 1
}

command_clear_runtime() {
    require_root || return 1
    require_command ip || return 1
    require_command tc || return 1
    if read_config; then
        cleanup_managed_rules "$CONFIG_INTERFACE"
    fi
}

command_set() {
    local interface="" rate_input=""
    local upload download allow_existing_managed=0
    local backup="" had_old=0 old_interface="" old_download=""

    require_root || return 1
    check_dependencies || return 1

    interface=$(detect_default_interface) || {
        die "无法自动识别公网网卡。"
        return 1
    }
    info "检测到公网网卡：$interface"

    if [[ $# -eq 0 ]]; then
        read -r -p "请输入限速 Mbps：" rate_input || return 1
    elif [[ $# -eq 1 ]]; then
        rate_input=$1
    else
        die "只需输入一个 Mbps 数字，例如：$0 set 100"
        return 1
    fi

    interface_exists "$interface" || {
        die "网卡 $interface 不存在。"
        return 1
    }

    rate_input=$(trim_whitespace "$rate_input")
    if [[ ! "$rate_input" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        die "请输入大于 0 的纯数字，单位默认为 Mbps。"
        return 1
    fi
    upload=$(normalize_rate "${rate_input}mbit") || {
        die "请输入大于 0 的纯数字，单位默认为 Mbps。"
        return 1
    }
    download=$upload

    if [[ -f "$CONFIG_FILE" ]]; then
        if read_config; then
            had_old=1
            old_interface=$CONFIG_INTERFACE
            old_download=$CONFIG_DOWNLOAD
            [[ "$old_interface" == "$interface" && "$old_download" != "none" ]] && \
                allow_existing_managed=1
            backup="${CONFIG_FILE}.backup.$$"
            cp -p "$CONFIG_FILE" "$backup" || {
                die "无法备份原配置。"
                return 1
            }
        else
            die "现有配置无效，请先修复或移走：$CONFIG_FILE"
            return 1
        fi
    fi

    if ! preflight_conflicts "$interface" "$download" "$allow_existing_managed"; then
        [[ -n "$backup" ]] && rm -f "$backup"
        return 1
    fi

    if ! install_self || ! write_service_unit; then
        [[ -n "$backup" ]] && rm -f "$backup"
        die "安装脚本或 systemd 服务失败，未修改限速配置。"
        return 1
    fi
    if ! systemctl daemon-reload; then
        [[ -n "$backup" ]] && rm -f "$backup"
        die "systemd 重新加载失败，未修改限速配置。"
        return 1
    fi
    if ! systemctl enable "$SERVICE_NAME"; then
        [[ -n "$backup" ]] && rm -f "$backup"
        die "启用开机服务失败，未修改限速配置。"
        return 1
    fi
    if ! write_config "$interface" "$upload" "$download"; then
        [[ -n "$backup" ]] && rm -f "$backup"
        die "写入限速配置失败。"
        return 1
    fi

    if [[ "$had_old" -eq 1 && "$old_interface" != "$interface" ]]; then
        cleanup_managed_rules "$old_interface"
    fi

    if ! systemctl restart "$SERVICE_NAME"; then
        if [[ "$had_old" -eq 1 ]]; then
            mv -f "$backup" "$CONFIG_FILE"
            backup=""
            if systemctl restart "$SERVICE_NAME"; then
                die "新限速应用失败，已回滚到原配置。"
            else
                cleanup_managed_rules "$old_interface"
                die "新限速应用失败；原配置已恢复到文件，但服务重启失败，请检查 systemctl status $SERVICE_NAME。"
            fi
        else
            rm -f "$CONFIG_FILE"
            systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
            systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
            cleanup_managed_rules "$interface"
            die "限速应用失败，已清理本次配置。"
        fi
        [[ -n "$backup" ]] && rm -f "$backup"
        return 1
    fi

    [[ -n "$backup" ]] && rm -f "$backup"
    info "限速已生效，并已设置为重启后自动恢复。"
    info "网卡：$interface"
    info "限速：${upload%mbit} Mbps（上下行）"
}

command_restore() {
    local interface=""

    require_root || return 1
    check_dependencies || return 1

    if read_config; then
        interface=$CONFIG_INTERFACE
    else
        interface=$(detect_default_interface 2>/dev/null || true)
    fi

    systemctl stop "$SERVICE_NAME" >/dev/null 2>&1 || true
    if [[ -n "$interface" ]] && interface_exists "$interface"; then
        cleanup_managed_rules "$interface"
    fi
    systemctl disable "$SERVICE_NAME" >/dev/null 2>&1 || true
    rm -f "$CONFIG_FILE"
    rm -f "$UNIT_FILE"
    systemctl daemon-reload >/dev/null 2>&1 || true

    info "已恢复不限速，并已取消开机自动限速。"
}

command_status() {
    local upload_ok=1 download_ok=1

    require_root || return 1
    check_dependencies || return 1
    if [[ ! -f "$CONFIG_FILE" ]]; then
        info "状态：未配置限速"
        return 0
    fi
    read_config || return 1

    if [[ "$CONFIG_UPLOAD" != "none" ]] && ! has_managed_upload_qdisc "$CONFIG_INTERFACE"; then
        upload_ok=0
    fi
    if [[ "$CONFIG_DOWNLOAD" != "none" ]]; then
        if ! has_managed_ingress_qdisc "$CONFIG_INTERFACE" || \
            ! has_managed_ingress_filter "$CONFIG_INTERFACE" || \
            ! has_managed_download_qdisc; then
            download_ok=0
        fi
    fi

    info "网卡：$CONFIG_INTERFACE"
    if [[ "$CONFIG_UPLOAD" == "$CONFIG_DOWNLOAD" && "$CONFIG_UPLOAD" != "none" ]]; then
        info "限速：${CONFIG_UPLOAD%mbit} Mbps（上下行）"
    else
        info "上传：$(format_rate "$CONFIG_UPLOAD")"
        info "下载：$(format_rate "$CONFIG_DOWNLOAD")"
    fi
    if [[ "$upload_ok" -eq 1 && "$download_ok" -eq 1 ]]; then
        info "运行状态：已生效"
    else
        info "运行状态：配置存在，但内核规则未完整生效"
        return 1
    fi
}

show_help() {
    cat <<HELP
$PROGRAM_NAME v$VERSION

用法：
  $0                    打开交互菜单
  $0 set                自动识别网卡并输入一个 Mbps 数字
  $0 set <数字>         例如：$0 set 100
  $0 status             查看当前状态
  $0 restore            恢复不限速并取消开机自启

设置值会同时应用于上传和下载；只接受大于 0 的数字，单位固定为 Mbps。
HELP
}

interactive_menu() {
    local choice
    cat <<'MENU'

VPS 网卡限速
1. 设置或修改限速
2. 查看状态
3. 恢复不限速
0. 退出
MENU
    read -r -p "请选择 [0-3]：" choice || return 1
    case "$choice" in
        1) command_set ;;
        2) command_status ;;
        3) command_restore ;;
        0) return 0 ;;
        *) die "无效选项。" ;;
    esac
}

main() {
    local command=${1:-menu}
    case "$command" in
        menu)
            interactive_menu
            ;;
        set)
            shift
            command_set "$@"
            ;;
        status)
            command_status
            ;;
        restore|remove|clear)
            command_restore
            ;;
        --apply)
            command_apply
            ;;
        --clear-runtime)
            command_clear_runtime
            ;;
        --normalize-rate)
            [[ $# -eq 2 ]] || return 2
            normalize_rate "$2"
            ;;
        -h|--help|help)
            show_help
            ;;
        -V|--version)
            printf '%s\n' "$VERSION"
            ;;
        *)
            show_help >&2
            return 2
            ;;
    esac
}

main "$@"
