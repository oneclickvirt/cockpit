#!/usr/bin/env bash
# Shared runtime helpers for cockpit install/uninstall scripts.

RESET="${RESET:-\033[0m}"
RED="${RED:-\033[31m\033[01m}"
GREEN="${GREEN:-\033[32m\033[01m}"
YELLOW="${YELLOW:-\033[33m\033[01m}"
BLUE="${BLUE:-\033[36m\033[01m}"

msg() {
    local color="$1"
    local zh="$2"
    local en="$3"
    printf "%b%s%b\n%b%s%b\n" "$color" "$zh" "$RESET" "$color" "$en" "$RESET"
}

info() { msg "$BLUE" "$1" "$2"; }
ok() { msg "$GREEN" "$1" "$2"; }
warn() {
    msg "$YELLOW" "$1" "$2"
    WARNINGS+=("$1 / $2")
}
fatal() {
    msg "$RED" "$1" "$2" >&2
    exit 1
}

quote_cmd() {
    local out=""
    local arg
    for arg in "$@"; do
        printf -v arg "%q" "$arg"
        out+="$arg "
    done
    printf "%s" "${out% }"
}

lower_text() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

systemctl_ready() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

systemd_unit_exists() {
    local unit="$1"
    if systemctl list-unit-files "$unit" --no-legend 2>/dev/null | awk 'NF { found=1 } END { exit !found }'; then
        return 0
    fi
    systemctl status "$unit" >/dev/null 2>&1
}

start_systemd_unit() {
    local unit="$1"
    if ! systemd_unit_exists "$unit"; then
        return 1
    fi
    run_cmd "启用并启动 $unit" "Enabling and starting $unit" systemctl enable --now "$unit"
    if [ "$DRY_RUN" -eq 0 ] && ! systemctl is-active --quiet "$unit"; then
        fatal "服务未能保持活动状态: $unit" "Service did not stay active: $unit"
    fi
    ok "服务已启动: $unit" "Service started: $unit"
    return 0
}

start_service_candidate() {
    local service="$1"
    if [ "${DRY_RUN:-0}" -eq 1 ]; then
        info "dry-run: 将尝试启用并启动 $service" "dry-run: would try to enable and start $service"
        return 0
    fi
    if systemctl_ready; then
        start_systemd_unit "$service" && return 0
        return 1
    fi
    if command -v rc-service >/dev/null 2>&1; then
        if rc-service "$service" status >/dev/null 2>&1 || [ -f "/etc/init.d/$service" ]; then
            if command -v rc-update >/dev/null 2>&1; then
                run_cmd "设置 $service 开机启动" "Enabling $service at boot" rc-update add "$service" default
            fi
            run_cmd "启动 $service" "Starting $service" rc-service "$service" start
            return 0
        fi
    fi
    if command -v service >/dev/null 2>&1; then
        if service "$service" status >/dev/null 2>&1 || [ -f "/etc/init.d/$service" ] || [ -f "/usr/local/etc/rc.d/$service" ]; then
            if command -v sysrc >/dev/null 2>&1; then
                run_cmd "设置 $service 开机启动" "Enabling $service at boot" sysrc "${service}_enable=YES"
            fi
            run_cmd "启动 $service" "Starting $service" service "$service" start
            return 0
        fi
    fi
    return 1
}

valid_ipv4() {
    local ip="$1"
    printf "%s" "$ip" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
    local a b c d
    IFS=. read -r a b c d <<EOF
$ip
EOF
    [ "$a" -le 255 ] && [ "$b" -le 255 ] && [ "$c" -le 255 ] && [ "$d" -le 255 ]
}

is_private_ipv4() {
    local ip="$1"
    valid_ipv4 "$ip" || return 0
    local a b c d
    IFS=. read -r a b c d <<EOF
$ip
EOF
    [ "$a" -eq 10 ] && return 0
    [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 0
    [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 0
    [ "$a" -eq 127 ] && return 0
    [ "$a" -eq 0 ] && return 0
    [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 0
    [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 0
    [ "$a" -ge 224 ] && return 0
    return 1
}

is_global_ipv6() {
    local ip
    ip="$(lower_text "$1")"
    [ -n "$ip" ] || return 1
    case "$ip" in
        ::1|::|fe80:*|fc*|fd*) return 1 ;;
    esac
    printf "%s" "$ip" | grep -q ':' || return 1
}

get_local_ipv4() {
    if command -v ip >/dev/null 2>&1; then
        ip -4 addr show scope global 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="inet") {split($(i+1), a, "/"); print a[1]}}' | while read -r ipaddr; do
            if ! is_private_ipv4 "$ipaddr"; then
                printf "%s\n" "$ipaddr"
                break
            fi
        done
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet / {print $2}' | while read -r ipaddr; do
            if ! is_private_ipv4 "$ipaddr"; then
                printf "%s\n" "$ipaddr"
                break
            fi
        done
    fi
}

get_local_ipv6() {
    if command -v ip >/dev/null 2>&1; then
        ip -6 addr show scope global 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="inet6") {split($(i+1), a, "/"); print a[1]}}' | while read -r ipaddr; do
            if is_global_ipv6 "$ipaddr"; then
                printf "%s\n" "$ipaddr"
                break
            fi
        done
    elif command -v ifconfig >/dev/null 2>&1; then
        ifconfig 2>/dev/null | awk '/inet6 / {print $2}' | while read -r ipaddr; do
            if is_global_ipv6 "$ipaddr"; then
                printf "%s\n" "$ipaddr"
                break
            fi
        done
    fi
}

get_external_ip() {
    local family="$1"
    [ "$DRY_RUN" -eq 0 ] || return 1
    command -v curl >/dev/null 2>&1 || return 1
    local apis=()
    if [ "$family" = "4" ]; then
        apis=("https://ipv4.icanhazip.com" "https://api.ipify.org" "https://ip4.seeip.org" "https://api.my-ip.io/ip")
    else
        apis=("https://ipv6.icanhazip.com" "https://api6.ipify.org" "https://ip6.seeip.org")
    fi
    local api response
    for api in "${apis[@]}"; do
        if response="$(curl "-${family}" -ksm5 "$api" 2>/dev/null | tr -d '[:space:]')"; then
            :
        else
            response=""
        fi
        if [ "$family" = "4" ] && valid_ipv4 "$response" && ! is_private_ipv4 "$response"; then
            printf "%s\n" "$response"
            return 0
        fi
        if [ "$family" = "6" ] && is_global_ipv6 "$response"; then
            printf "%s\n" "$response"
            return 0
        fi
    done
    return 1
}

check_port_listening() {
    if command -v ss >/dev/null 2>&1; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:|\])9090$'
    elif command -v netstat >/dev/null 2>&1; then
        netstat -an 2>/dev/null | grep -E '[\.:]9090[[:space:]].*LISTEN'
    elif command -v sockstat >/dev/null 2>&1; then
        sockstat -l 2>/dev/null | awk '{print $6}' | grep -Eq '(^|:|\])9090$'
    else
        return 2
    fi
}
