#!/usr/bin/env bash
# Safe Cockpit uninstaller with dry-run and bilingual output.

set -Eeuo pipefail

RESET="\033[0m"
RED="\033[31m\033[01m"
GREEN="\033[32m\033[01m"
YELLOW="\033[33m\033[01m"
BLUE="\033[36m\033[01m"

DRY_RUN=0
PURGE_CONFIG=0
REMOVE_VM=0
REMOVE_CONTAINER=0
REMOVE_ALL=0
LOG_FILE=""
PACKAGE_MANAGER=""
SYSTEM_FAMILY="unknown"
WARNINGS=()

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

usage() {
    cat <<'USAGE'
Cockpit uninstaller / Cockpit 卸载脚本

Usage:
  bash scripts/uninstall.sh [options]

Options:
  --all             Remove Cockpit, VM, and container modules / 卸载全部组件
  --vm              Remove VM management packages / 卸载虚拟机管理组件
  --ct              Remove container management packages / 卸载容器管理组件
  --purge-config    Remove installer-managed config files / 删除安装器管理的配置
  --dry-run         Print planned actions only / 只预览操作不执行
  --log-file PATH   Mirror all output to PATH / 同步输出日志到指定文件
  --help            Show this help / 显示帮助
USAGE
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

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --all) REMOVE_ALL=1; REMOVE_VM=1; REMOVE_CONTAINER=1 ;;
            --vm) REMOVE_VM=1 ;;
            --ct) REMOVE_CONTAINER=1 ;;
            --purge-config) PURGE_CONFIG=1 ;;
            --dry-run) DRY_RUN=1 ;;
            --log-file)
                [ "$#" -ge 2 ] || fatal "缺少 --log-file 的路径参数" "Missing PATH for --log-file"
                LOG_FILE="$2"
                shift
                ;;
            --log-file=*) LOG_FILE="${1#*=}" ;;
            --help|-h) usage; exit 0 ;;
            *) fatal "未知参数: $1" "Unknown argument: $1" ;;
        esac
        shift
    done
    if [ "$REMOVE_ALL" -eq 0 ] && [ "$REMOVE_VM" -eq 0 ] && [ "$REMOVE_CONTAINER" -eq 0 ]; then
        REMOVE_ALL=1
    fi
}

setup_logging() {
    [ -n "$LOG_FILE" ] || return 0
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    exec > >(tee -a "$LOG_FILE") 2>&1
    ok "日志文件: $LOG_FILE" "Log file: $LOG_FILE"
}

run_cmd() {
    local zh="$1"
    local en="$2"
    shift 2
    info "$zh" "$en"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "dry-run> %s\n" "$(quote_cmd "$@")"
        return 0
    fi
    "$@"
}

check_root() {
    if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" -ne 1 ]; then
        fatal "此脚本必须以 root 用户运行，dry-run 模式除外" "This script must run as root except in dry-run mode"
    fi
}

lower_text() {
    printf "%s" "$1" | tr '[:upper:]' '[:lower:]'
}

detect_package_manager() {
    local os_id="" os_like="" kernel
    kernel="$(uname -s 2>/dev/null || printf unknown)"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="$(lower_text "${ID:-}")"
        os_like="$(lower_text "${ID_LIKE:-}")"
    else
        os_id="$(lower_text "$kernel")"
    fi

    case "$os_id $os_like" in
        *debian*|*ubuntu*) SYSTEM_FAMILY="debian" ;;
        *fedora*|*centos*|*rhel*|*redhat*|*alma*|*rocky*|*oracle*|*amzn*|*amazon*) SYSTEM_FAMILY="rhel" ;;
        *arch*) SYSTEM_FAMILY="arch" ;;
        *alpine*) SYSTEM_FAMILY="alpine" ;;
        *opensuse*|*suse*) SYSTEM_FAMILY="suse" ;;
        *) case "$(lower_text "$kernel")" in freebsd|openbsd|netbsd|dragonfly) SYSTEM_FAMILY="bsd" ;; esac ;;
    esac

    if [ -f /run/ostree-booted ] && command -v rpm-ostree >/dev/null 2>&1; then
        PACKAGE_MANAGER="rpm-ostree"
    elif command -v apt-get >/dev/null 2>&1; then
        PACKAGE_MANAGER="apt"
    elif command -v dnf >/dev/null 2>&1; then
        PACKAGE_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PACKAGE_MANAGER="yum"
    elif command -v pacman >/dev/null 2>&1; then
        PACKAGE_MANAGER="pacman"
    elif command -v apk >/dev/null 2>&1; then
        PACKAGE_MANAGER="apk"
    elif command -v zypper >/dev/null 2>&1; then
        PACKAGE_MANAGER="zypper"
    elif command -v pkg >/dev/null 2>&1; then
        PACKAGE_MANAGER="pkg"
    else
        fatal "未检测到支持的包管理器" "No supported package manager detected"
    fi
    ok "包管理器: $PACKAGE_MANAGER" "Package manager: $PACKAGE_MANAGER"
}

package_installed() {
    local package="$1"
    case "$PACKAGE_MANAGER" in
        apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf|yum|zypper|rpm-ostree) rpm -q "$package" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$package" >/dev/null 2>&1 ;;
        apk) apk info -e "$package" >/dev/null 2>&1 ;;
        pkg) pkg info -e "$package" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

stop_service_candidate() {
    local service="$1"
    if command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
        if systemctl list-unit-files "$service" --no-legend 2>/dev/null | awk 'NF { found=1 } END { exit !found }' || systemctl status "$service" >/dev/null 2>&1; then
            run_cmd "停止并禁用 $service" "Stopping and disabling $service" systemctl disable --now "$service"
            return 0
        fi
    elif command -v rc-service >/dev/null 2>&1; then
        if rc-service "$service" status >/dev/null 2>&1 || [ -f "/etc/init.d/$service" ]; then
            run_cmd "停止 $service" "Stopping $service" rc-service "$service" stop
            if command -v rc-update >/dev/null 2>&1; then
                run_cmd "移除 $service 开机启动" "Removing $service from boot" rc-update del "$service" default
            fi
            return 0
        fi
    elif command -v service >/dev/null 2>&1; then
        if service "$service" status >/dev/null 2>&1 || [ -f "/etc/init.d/$service" ] || [ -f "/usr/local/etc/rc.d/$service" ]; then
            run_cmd "停止 $service" "Stopping $service" service "$service" stop
            return 0
        fi
    fi
    return 1
}

remove_packages() {
    [ "$#" -gt 0 ] || return 0
    local selected=()
    local package
    for package in "$@"; do
        if [ "$DRY_RUN" -eq 1 ] || package_installed "$package"; then
            selected+=("$package")
        else
            info "包未安装，跳过: $package" "Package not installed, skipping: $package"
        fi
    done
    [ "${#selected[@]}" -gt 0 ] || return 0
    case "$PACKAGE_MANAGER" in
        apt) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" apt-get -y remove "${selected[@]}" ;;
        dnf) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" dnf -y remove "${selected[@]}" ;;
        yum) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" yum -y remove "${selected[@]}" ;;
        pacman) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" pacman -Rns --noconfirm "${selected[@]}" ;;
        apk) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" apk del "${selected[@]}" ;;
        zypper) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" zypper --non-interactive remove "${selected[@]}" ;;
        pkg) run_cmd "卸载包: ${selected[*]}" "Removing packages: ${selected[*]}" pkg delete -y "${selected[@]}" ;;
        rpm-ostree) run_cmd "移除 ostree 包: ${selected[*]}" "Removing ostree packages: ${selected[*]}" rpm-ostree uninstall "${selected[@]}" ;;
        *) fatal "不支持的包管理器: $PACKAGE_MANAGER" "Unsupported package manager: $PACKAGE_MANAGER" ;;
    esac
}

remove_cockpit_packages() {
    local base=(cockpit)
    local vm=()
    local ct=(cockpit-podman)
    case "$SYSTEM_FAMILY" in
        debian) vm=(cockpit-machines qemu-system qemu-utils libvirt-daemon libvirt-clients bridge-utils) ;;
        rhel) vm=(cockpit-machines qemu-kvm qemu-img libvirt virt-install libvirt-client bridge-utils) ;;
        suse) vm=(cockpit-machines qemu libvirt virt-install bridge-utils) ;;
        arch) vm=(cockpit-machines qemu libvirt bridge-utils) ;;
        alpine) vm=(cockpit-machines qemu-img libvirt libvirt-daemon libvirt-client bridge-utils) ;;
        bsd) vm=(cockpit-machines) ;;
    esac
    if [ "$PACKAGE_MANAGER" = "rpm-ostree" ]; then
        base=(cockpit-system cockpit-ostree)
    fi
    if [ "$REMOVE_ALL" -eq 1 ]; then
        remove_packages "${base[@]}" "${ct[@]}" "${vm[@]}"
    else
        [ "$REMOVE_CONTAINER" -eq 1 ] && remove_packages "${ct[@]}"
        [ "$REMOVE_VM" -eq 1 ] && [ "${#vm[@]}" -gt 0 ] && remove_packages "${vm[@]}"
    fi
}

purge_config() {
    [ "$PURGE_CONFIG" -eq 1 ] || return 0
    warn "将删除安装器管理的 Cockpit 配置文件" "Removing installer-managed Cockpit configuration files"
    local paths=(/etc/sudoers.d/cockpit-admins)
    local path
    for path in /etc/apt/sources.list.d/cockpit-install-backports*.list; do
        [ -e "$path" ] && paths+=("$path")
    done
    for path in "${paths[@]}"; do
        if [ -e "$path" ]; then
            run_cmd "删除 $path" "Removing $path" rm -f "$path"
        fi
    done
    warn "保留 /etc/cockpit 和 libvirt 配置备份，避免删除用户自定义数据" "Keeping /etc/cockpit and libvirt backups to avoid deleting user custom data"
}

main() {
    parse_arguments "$@"
    setup_logging
    check_root
    detect_package_manager
    for service in cockpit.socket cockpit.service cockpit cockpit-ws; do
        if ! stop_service_candidate "$service"; then
            info "未检测到可停止的服务: $service" "No stoppable service detected: $service"
        fi
    done
    remove_cockpit_packages
    purge_config
    if [ "$PACKAGE_MANAGER" = "apt" ]; then
        run_cmd "清理不再需要的依赖" "Removing unused dependencies" apt-get -y autoremove
    fi
    ok "卸载流程完成" "Uninstall flow completed"
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        info "执行完成，但存在警告，请检查上方日志" "Completed with warnings; review the log above"
    fi
}

main "$@"
