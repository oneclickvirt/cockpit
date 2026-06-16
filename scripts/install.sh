#!/usr/bin/env bash
# https://github.com/oneclickvirt/cockpit
# Cockpit installer with safer defaults and bilingual output.
set -Eeuo pipefail
export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/runtime.sh
. "$SCRIPT_DIR/lib/runtime.sh"
SCRIPT_VERSION="2026.06.05"
INSTALL_VM=0
INSTALL_CONTAINER=0
DRY_RUN=0
TELEMETRY=1
NON_INTERACTIVE=0
SKIP_UPDATE=0
LOG_FILE=""
INSTALL_MODE="auto"
SYSTEM="Unknown"
SYSTEM_FAMILY="unknown"
PACKAGE_MANAGER=""
OS_ID=""
OS_ID_LIKE=""
OS_VERSION_ID=""
VERSION_CODENAME=""
IS_COREOS=0
COREOS_REBOOT_REQUIRED=0
CREATED_BACKPORTS_FILE=""
WARNINGS=()
OPTIONAL_MISSING=()
if [ "${COCKPIT_INSTALL_NO_TELEMETRY:-0}" = "1" ] || [ "${NO_TELEMETRY:-0}" = "1" ]; then
    TELEMETRY=0
fi
usage() {
    cat <<'USAGE'
Cockpit installer / Cockpit 安装脚本

Usage:
  bash scripts/install.sh [options]

Options:
  --vm                    Install VM management packages / 安装虚拟机管理组件
  --ct                    Install container management packages / 安装容器管理组件
  --all                   Install base, VM, and container components / 安装全部组件
  --dry-run               Print planned actions only / 只预览操作不执行
  --no-telemetry          Disable anonymous run counter / 禁用匿名运行统计
  --log-file PATH         Mirror all output to PATH / 同步输出日志到指定文件
  --yes, --non-interactive
                         Do not prompt when Cockpit is already installed / 已安装时不交互
  --upgrade               Prefer package upgrade for existing Cockpit / 已安装时升级
  --reconfigure           Reapply service and security configuration / 已安装时重新配置
  --reinstall             Reinstall packages and then configure / 已安装时重装并配置
  --skip-update           Skip package metadata refresh / 跳过软件源刷新
  --help                  Show this help / 显示帮助

Environment:
  COCKPIT_INSTALL_NO_TELEMETRY=1 or NO_TELEMETRY=1 disables telemetry.
USAGE
}

parse_arguments() {
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --vm)
                INSTALL_VM=1
                ;;
            --ct)
                INSTALL_CONTAINER=1
                ;;
            --all)
                INSTALL_VM=1
                INSTALL_CONTAINER=1
                ;;
            --dry-run)
                DRY_RUN=1
                ;;
            --no-telemetry)
                TELEMETRY=0
                ;;
            --log-file)
                [ "$#" -ge 2 ] || fatal "缺少 --log-file 的路径参数" "Missing PATH for --log-file"
                LOG_FILE="$2"
                shift
                ;;
            --log-file=*)
                LOG_FILE="${1#*=}"
                ;;
            --yes|--non-interactive)
                NON_INTERACTIVE=1
                ;;
            --upgrade)
                INSTALL_MODE="upgrade"
                ;;
            --reconfigure)
                INSTALL_MODE="reconfigure"
                ;;
            --reinstall)
                INSTALL_MODE="reinstall"
                ;;
            --skip-update)
                SKIP_UPDATE=1
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                fatal "未知参数: $1" "Unknown argument: $1"
                ;;
        esac
        shift
    done
}

setup_logging() {
    [ -n "$LOG_FILE" ] || return 0
    if [ "$DRY_RUN" -eq 1 ]; then
        mkdir -p "$(dirname "$LOG_FILE")"
    else
        mkdir -p "$(dirname "$LOG_FILE")"
        touch "$LOG_FILE"
    fi
    exec > >(tee -a "$LOG_FILE") 2>&1
    ok "日志文件: $LOG_FILE" "Log file: $LOG_FILE"
}

cleanup() {
    local status=$?
    if [ -n "$CREATED_BACKPORTS_FILE" ] && [ -f "$CREATED_BACKPORTS_FILE" ]; then
        if [ "$DRY_RUN" -eq 1 ]; then
            info "dry-run: 将移除临时 backports 源 $CREATED_BACKPORTS_FILE" "dry-run: would remove temporary backports source $CREATED_BACKPORTS_FILE"
        else
            rm -f "$CREATED_BACKPORTS_FILE"
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update >/dev/null 2>&1 || warn "临时 backports 源已移除，但 apt-get update 失败" "Temporary backports source removed, but apt-get update failed"
            fi
        fi
    fi
    return "$status"
}
trap cleanup EXIT

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
backup_file() {
    local path="$1"
    [ -e "$path" ] || return 0
    local backup
    backup="${path}.bak.$(date +%Y%m%d%H%M%S)"
    run_cmd "备份配置文件 $path 到 $backup" "Backing up $path to $backup" cp -p "$path" "$backup"
}

setup_locale() {
    info "配置 UTF-8 语言环境" "Configuring UTF-8 locale"
    if ! command -v locale >/dev/null 2>&1; then
        warn "未找到 locale 命令，跳过语言环境设置" "locale command not found, skipping locale setup"
        return 0
    fi
    local utf8_locale
    if utf8_locale="$(locale -a 2>/dev/null | grep -i -m 1 -E 'utf-?8')"; then
        :
    else
        utf8_locale=""
    fi
    if [ -n "$utf8_locale" ]; then
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        ok "语言环境设置为 $utf8_locale" "Locale set to $utf8_locale"
    else
        warn "未找到 UTF-8 语言环境，继续执行" "No UTF-8 locale found, continuing"
    fi
}

check_root() {
    if [ "$(id -u)" != "0" ] && [ "$DRY_RUN" -ne 1 ]; then
        fatal "此脚本必须以 root 用户运行，dry-run 模式除外" "This script must run as root except in dry-run mode"
    fi
}

detect_os() {
    info "检测操作系统和包管理器" "Detecting operating system and package manager"
    local kernel
    kernel="$(uname -s 2>/dev/null || printf unknown)"

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        OS_ID="$(lower_text "${ID:-}")"
        OS_ID_LIKE="$(lower_text "${ID_LIKE:-}")"
        OS_VERSION_ID="${VERSION_ID:-}"
        VERSION_CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    else
        OS_ID="$(lower_text "$kernel")"
        OS_ID_LIKE=""
        OS_VERSION_ID=""
        VERSION_CODENAME=""
    fi

    if [ -f /run/ostree-booted ] || printf "%s %s %s" "$OS_ID" "$OS_ID_LIKE" "${VARIANT_ID:-}" | grep -qiE 'coreos|rhcos|ostree'; then
        IS_COREOS=1
    fi

    case "$OS_ID $OS_ID_LIKE" in
        *debian*) SYSTEM="Debian"; SYSTEM_FAMILY="debian" ;;
        *ubuntu*) SYSTEM="Ubuntu"; SYSTEM_FAMILY="debian" ;;
        *fedora*) SYSTEM="Fedora"; SYSTEM_FAMILY="rhel" ;;
        *centos*|*rhel*|*redhat*|*alma*|*rocky*|*oracle*|*amzn*|*amazon*) SYSTEM="CentOS"; SYSTEM_FAMILY="rhel" ;;
        *arch*) SYSTEM="Arch"; SYSTEM_FAMILY="arch" ;;
        *alpine*) SYSTEM="Alpine"; SYSTEM_FAMILY="alpine" ;;
        *opensuse*|*suse*) SYSTEM="openSUSE"; SYSTEM_FAMILY="suse" ;;
        *)
            case "$(lower_text "$kernel")" in
                freebsd|openbsd|netbsd|dragonfly)
                    SYSTEM="BSD"
                    SYSTEM_FAMILY="bsd"
                    ;;
                darwin)
                    SYSTEM="macOS"
                    SYSTEM_FAMILY="darwin"
                    ;;
                linux)
                    SYSTEM="Linux"
                    SYSTEM_FAMILY="linux"
                    ;;
                *)
                    SYSTEM="$kernel"
                    SYSTEM_FAMILY="unknown"
                    ;;
            esac
            ;;
    esac

    if [ "$IS_COREOS" -eq 1 ]; then
        SYSTEM="CoreOS"
        SYSTEM_FAMILY="coreos"
    fi

    if [ "$SYSTEM_FAMILY" = "coreos" ] && command -v rpm-ostree >/dev/null 2>&1; then
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
        PACKAGE_MANAGER=""
    fi

    ok "检测到系统: $SYSTEM ${OS_VERSION_ID}" "Detected system: $SYSTEM ${OS_VERSION_ID}"
    if [ -n "$PACKAGE_MANAGER" ]; then
        ok "包管理器: $PACKAGE_MANAGER" "Package manager: $PACKAGE_MANAGER"
    else
        fatal "未检测到支持的包管理器" "No supported package manager detected"
    fi
}

preflight_checks() {
    info "执行安装前资源预检" "Running preflight resource checks"
    local arch
    arch="$(uname -m 2>/dev/null || printf unknown)"
    case "$arch" in
        x86_64|amd64|aarch64|arm64|armv7l|ppc64le|s390x|riscv64)
            ok "CPU 架构受支持: $arch" "CPU architecture is supported: $arch"
            ;;
        *)
            fatal "不支持的 CPU 架构: $arch" "Unsupported CPU architecture: $arch"
            ;;
    esac

    local available_kb
    available_kb="$(df -Pk / 2>/dev/null | awk 'NR==2 {print $4}')"
    if [ -n "$available_kb" ] && [ "$available_kb" -lt 512000 ]; then
        fatal "根分区可用空间不足 500MB" "Root filesystem has less than 500MB available"
    fi
    ok "磁盘空间预检通过" "Disk space preflight passed"

    local mem_kb=""
    if [ -r /proc/meminfo ]; then
        mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
    elif command -v sysctl >/dev/null 2>&1; then
        local mem_bytes
        if mem_bytes="$(sysctl -n hw.memsize 2>/dev/null)"; then
            :
        elif mem_bytes="$(sysctl -n hw.physmem 2>/dev/null)"; then
            :
        else
            mem_bytes=""
        fi
        if [ -n "$mem_bytes" ]; then
            mem_kb=$((mem_bytes / 1024))
        fi
    fi
    if [ -n "$mem_kb" ] && [ "$mem_kb" -lt 1048576 ]; then
        fatal "内存不足 1GB" "System memory is less than 1GB"
    fi
    ok "内存预检通过" "Memory preflight passed"

    case "$SYSTEM_FAMILY" in
        linux|debian|rhel|arch|suse|alpine)
            if [ "$INSTALL_VM" -eq 1 ] && [ ! -e /dev/kvm ]; then
                warn "未检测到 /dev/kvm，VM 功能可能只能使用软件虚拟化" "No /dev/kvm found; VM support may fall back to software emulation"
            fi
            ;;
    esac
}

refresh_package_metadata() {
    [ "$SKIP_UPDATE" -eq 0 ] || {
        warn "已跳过软件源刷新" "Package metadata refresh skipped"
        return 0
    }
    case "$PACKAGE_MANAGER" in
        apt)
            run_cmd "刷新 apt 软件源" "Refreshing apt metadata" apt-get update
            run_cmd "修复已知 apt 依赖问题" "Fixing known apt dependency issues" apt-get --fix-broken install -y
            ;;
        dnf)
            run_cmd "刷新 dnf 缓存" "Refreshing dnf cache" dnf -y makecache
            ;;
        yum)
            run_cmd "刷新 yum 缓存" "Refreshing yum cache" yum -y makecache
            ;;
        pacman)
            run_cmd "刷新 pacman 软件源" "Refreshing pacman metadata" pacman -Sy
            ;;
        apk)
            run_cmd "刷新 apk 索引" "Refreshing apk index" apk update
            ;;
        zypper)
            run_cmd "刷新 zypper 软件源" "Refreshing zypper repositories" zypper --non-interactive refresh
            ;;
        pkg)
            run_cmd "刷新 pkg 仓库" "Refreshing pkg repositories" pkg update -f
            ;;
        rpm-ostree)
            info "CoreOS/rpm-ostree 将在安装事务中解析包" "CoreOS/rpm-ostree resolves packages during the install transaction"
            ;;
        *)
            fatal "不支持的软件源刷新方式: $PACKAGE_MANAGER" "Unsupported package metadata refresh for $PACKAGE_MANAGER"
            ;;
    esac
}

package_installed() {
    local package="$1"
    case "$PACKAGE_MANAGER" in
        apt) dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' ;;
        dnf|yum|zypper) rpm -q "$package" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$package" >/dev/null 2>&1 ;;
        apk) apk info -e "$package" >/dev/null 2>&1 ;;
        pkg) pkg info -e "$package" >/dev/null 2>&1 ;;
        rpm-ostree) rpm -q "$package" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}
package_available() {
    local package="$1"
    [ "$DRY_RUN" -eq 1 ] && return 0
    if package_installed "$package"; then
        return 0
    fi
    case "$PACKAGE_MANAGER" in
        apt) apt-cache show "$package" >/dev/null 2>&1 ;;
        dnf) dnf -q list --available "$package" >/dev/null 2>&1 ;;
        yum) yum -q list available "$package" >/dev/null 2>&1 ;;
        zypper) zypper --non-interactive --quiet search --exact-match "$package" >/dev/null 2>&1 ;;
        pacman) pacman -Si "$package" >/dev/null 2>&1 ;;
        apk) apk search -x "$package" 2>/dev/null | grep -qx "$package" ;;
        pkg) pkg search -q "^${package}$" >/dev/null 2>&1 ;;
        rpm-ostree) return 0 ;;
        *) return 1 ;;
    esac
}

install_one_package() {
    local package="$1"
    local apt_target="${2:-}"
    if package_installed "$package"; then
        ok "包已安装: $package" "Package already installed: $package"
        return 0
    fi

    case "$PACKAGE_MANAGER" in
        apt)
            if [ -n "$apt_target" ]; then
                run_cmd "从 $apt_target 安装 $package" "Installing $package from $apt_target" apt-get -y install -t "$apt_target" "$package"
            else
                run_cmd "安装 $package" "Installing $package" apt-get -y install "$package"
            fi
            ;;
        dnf) run_cmd "安装 $package" "Installing $package" dnf -y install "$package" ;;
        yum) run_cmd "安装 $package" "Installing $package" yum -y install "$package" ;;
        pacman) run_cmd "安装 $package" "Installing $package" pacman -S --noconfirm --needed "$package" ;;
        apk) run_cmd "安装 $package" "Installing $package" apk add --no-cache "$package" ;;
        zypper) run_cmd "安装 $package" "Installing $package" zypper --non-interactive install "$package" ;;
        pkg) run_cmd "安装 $package" "Installing $package" pkg install -y "$package" ;;
        rpm-ostree)
            run_cmd "安装 $package" "Installing $package" rpm-ostree install --idempotent "$package"
            [ "$DRY_RUN" -eq 0 ] && COREOS_REBOOT_REQUIRED=1
            ;;
        *) fatal "不支持的包管理器: $PACKAGE_MANAGER" "Unsupported package manager: $PACKAGE_MANAGER" ;;
    esac
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: 实际执行后将验证包 $package" "dry-run: package $package will be verified after execution"
        return 0
    fi
    if ! package_installed "$package" && [ "$PACKAGE_MANAGER" != "rpm-ostree" ]; then
        fatal "包安装后验证失败: $package" "Package verification failed after install: $package"
    fi
    ok "包安装验证通过: $package" "Package install verified: $package"
}
install_packages() {
    local required="$1"
    shift
    local package
    local missing=()

    for package in "$@"; do
        if package_available "$package"; then
            install_one_package "$package"
        else
            missing+=("$package")
        fi
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        local joined="${missing[*]}"
        if [ "$required" = "required" ]; then
            fatal "缺少必需包，当前仓库不可用: $joined" "Required packages are unavailable in current repositories: $joined"
        fi
        warn "可选包不可用，已跳过: $joined" "Optional packages unavailable, skipped: $joined"
        OPTIONAL_MISSING+=("$joined")
    fi
}
validate_debian_codename() {
    local codename="$1"
    if [ -z "$codename" ]; then
        fatal "无法检测 Debian 版本代号，拒绝添加 backports 源" "Cannot detect Debian codename; refusing to add backports"
    fi
    case "$codename" in
        *[!a-z0-9-]*)
            fatal "Debian 版本代号不安全: $codename" "Unsafe Debian codename: $codename"
            ;;
    esac
}

ensure_debian_backports_temp() {
    [ "$PACKAGE_MANAGER" = "apt" ] || return 1
    [ "$SYSTEM" = "Debian" ] || return 1
    validate_debian_codename "$VERSION_CODENAME"
    [ -n "$CREATED_BACKPORTS_FILE" ] && return 0

    local source_line="deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main"
    CREATED_BACKPORTS_FILE="/etc/apt/sources.list.d/cockpit-install-backports.$(date +%s).list"
    info "临时启用 Debian backports: ${VERSION_CODENAME}-backports" "Temporarily enabling Debian backports: ${VERSION_CODENAME}-backports"
    if [ "$DRY_RUN" -eq 1 ]; then
        printf "dry-run> printf '%s\\n' %q > %q\n" "$source_line" "$source_line" "$CREATED_BACKPORTS_FILE"
        return 0
    fi
    printf "%s\n" "$source_line" > "$CREATED_BACKPORTS_FILE"
    if ! apt-get update; then
        rm -f "$CREATED_BACKPORTS_FILE"
        CREATED_BACKPORTS_FILE=""
        fatal "Debian backports 源不可用，请检查版本代号: $VERSION_CODENAME" "Debian backports is unavailable; check codename: $VERSION_CODENAME"
    fi
}

install_apt_package_with_backports_fallback() {
    local required="$1"
    local package="$2"
    if [ "$PACKAGE_MANAGER" != "apt" ] || [ "$SYSTEM" != "Debian" ]; then
        install_packages "$required" "$package"
        return 0
    fi
    if package_available "$package"; then
        install_one_package "$package"
        return 0
    fi
    ensure_debian_backports_temp
    local target="${VERSION_CODENAME}-backports"
    if apt-cache show "$package" >/dev/null 2>&1; then
        install_one_package "$package" "$target"
    elif [ "$required" = "required" ]; then
        fatal "Debian backports 中也未找到必需包: $package" "Required package not found in Debian backports either: $package"
    else
        warn "Debian backports 中未找到可选包: $package" "Optional package not found in Debian backports: $package"
        OPTIONAL_MISSING+=("$package")
    fi
}
detect_existing_installation() {
    if command -v cockpit-bridge >/dev/null 2>&1 || package_installed cockpit || [ -d /etc/cockpit ]; then
        ok "检测到已有 Cockpit 安装或配置" "Existing Cockpit installation or configuration detected"
        if [ "$INSTALL_MODE" != "auto" ]; then
            ok "已选择模式: $INSTALL_MODE" "Selected mode: $INSTALL_MODE"
            return 0
        fi
        if [ "$NON_INTERACTIVE" -eq 0 ] && [ -t 0 ]; then
            printf "%b%s%b\n%s\n" "$GREEN" "请选择处理方式: [u]升级 / [r]重新配置 / [i]重装，默认 r" "$RESET" "Choose action: [u] upgrade / [r] reconfigure / [i] reinstall, default r"
            local answer
            read -r answer
            case "$answer" in
                u|U) INSTALL_MODE="upgrade" ;;
                i|I) INSTALL_MODE="reinstall" ;;
                *) INSTALL_MODE="reconfigure" ;;
            esac
        else
            INSTALL_MODE="reconfigure"
            ok "非交互环境默认重新配置已有安装" "Non-interactive mode defaults to reconfigure existing installation"
        fi
    else
        INSTALL_MODE="install"
    fi
}
upgrade_or_reinstall_existing() {
    case "$INSTALL_MODE" in
        upgrade)
            case "$PACKAGE_MANAGER" in
                apt) run_cmd "升级 Cockpit 相关包" "Upgrading Cockpit packages" apt-get -y install --only-upgrade cockpit ;;
                dnf) run_cmd "升级 Cockpit 相关包" "Upgrading Cockpit packages" dnf -y upgrade cockpit ;;
                yum) run_cmd "升级 Cockpit 相关包" "Upgrading Cockpit packages" yum -y update cockpit ;;
                pacman) run_cmd "升级系统包以更新 Cockpit" "Upgrading packages to refresh Cockpit" pacman -Syu --noconfirm ;;
                apk) run_cmd "升级 Cockpit 相关包" "Upgrading Cockpit packages" apk upgrade cockpit ;;
                zypper) run_cmd "升级 Cockpit 相关包" "Upgrading Cockpit packages" zypper --non-interactive update cockpit ;;
                pkg) run_cmd "升级 Cockpit 相关包" "Upgrading Cockpit packages" pkg upgrade -y cockpit ;;
                rpm-ostree) run_cmd "升级 ostree 系统" "Upgrading ostree deployment" rpm-ostree upgrade ;;
            esac
            ;;
        reinstall)
            case "$PACKAGE_MANAGER" in
                apt) run_cmd "重装 Cockpit 包并保留配置" "Reinstalling Cockpit while keeping configuration" apt-get -y install --reinstall cockpit ;;
                dnf) run_cmd "重装 Cockpit 包并保留配置" "Reinstalling Cockpit while keeping configuration" dnf -y reinstall cockpit ;;
                yum) run_cmd "重装 Cockpit 包并保留配置" "Reinstalling Cockpit while keeping configuration" yum -y reinstall cockpit ;;
                pacman) run_cmd "重装 Cockpit 包并保留配置" "Reinstalling Cockpit while keeping configuration" pacman -S --noconfirm cockpit ;;
                apk) run_cmd "修复 Cockpit 包并保留配置" "Repairing Cockpit while keeping configuration" apk fix cockpit ;;
                zypper) run_cmd "重装 Cockpit 包并保留配置" "Reinstalling Cockpit while keeping configuration" zypper --non-interactive install --force cockpit ;;
                pkg) run_cmd "重装 Cockpit 包并保留配置" "Reinstalling Cockpit while keeping configuration" pkg install -fy cockpit ;;
                rpm-ostree) run_cmd "重新应用 Cockpit ostree 包" "Reapplying Cockpit ostree packages" rpm-ostree install --idempotent cockpit-system cockpit-ostree ;;
            esac
            ;;
        reconfigure|install|auto)
            info "继续安装缺失组件并重新应用配置" "Continuing to install missing components and reapply configuration"
            ;;
    esac
}
install_cockpit_base() {
    info "安装 Cockpit 基础组件" "Installing Cockpit base components"
    case "$SYSTEM_FAMILY" in
        debian)
            install_apt_package_with_backports_fallback required cockpit
            ;;
        rhel|arch|suse|alpine|bsd)
            install_packages required cockpit
            ;;
        coreos)
            install_packages required cockpit-system cockpit-ostree
            ;;
        darwin)
            fatal "macOS 不支持 Cockpit 服务端安装" "macOS is not supported for Cockpit server installation"
            ;;
        *)
            install_packages required cockpit
            ;;
    esac
}
install_vm_packages() {
    [ "$INSTALL_VM" -eq 1 ] || return 0
    info "安装 QEMU/KVM 和 libvirt 组件" "Installing QEMU/KVM and libvirt components"
    case "$SYSTEM_FAMILY" in
        debian)
            install_packages required qemu-system qemu-utils libvirt-daemon libvirt-clients bridge-utils
            ;;
        rhel)
            install_packages required qemu-kvm qemu-img libvirt virt-install libvirt-client bridge-utils
            ;;
        suse)
            install_packages required qemu libvirt virt-install bridge-utils
            ;;
        arch)
            install_packages required qemu libvirt bridge-utils
            ;;
        alpine)
            install_packages required qemu-img libvirt libvirt-daemon libvirt-client bridge-utils
            ;;
        coreos)
            fatal "CoreOS/rpm-ostree 环境不支持此脚本自动配置 VM 管理模块" "CoreOS/rpm-ostree is not supported for automatic VM module setup by this script"
            ;;
        bsd|darwin)
            fatal "当前类 Unix 平台不支持 Cockpit VM 管理模块自动安装" "This Unix platform is not supported for automatic Cockpit VM module installation"
            ;;
        *)
            fatal "无法为当前发行版安装虚拟化包" "Cannot install virtualization packages for this distribution"
            ;;
    esac
    verify_vm_tools
    enable_libvirt_service
}
install_cockpit_machines() {
    [ "$INSTALL_VM" -eq 1 ] || return 0
    info "安装 Cockpit 虚拟机管理模块" "Installing Cockpit machines module"
    case "$SYSTEM_FAMILY" in
        debian) install_apt_package_with_backports_fallback optional cockpit-machines ;;
        rhel|arch|suse|alpine|bsd) install_packages optional cockpit-machines ;;
        coreos) warn "CoreOS 上跳过 cockpit-machines" "Skipping cockpit-machines on CoreOS" ;;
        *) install_packages optional cockpit-machines ;;
    esac
}
install_cockpit_containers() {
    [ "$INSTALL_CONTAINER" -eq 1 ] || return 0
    info "安装 Cockpit 容器管理模块" "Installing Cockpit container module"
    case "$SYSTEM_FAMILY" in
        debian) install_apt_package_with_backports_fallback optional cockpit-podman ;;
        rhel|arch|suse|alpine|bsd) install_packages optional cockpit-podman ;;
        coreos) install_packages optional cockpit-podman ;;
        *) install_packages optional cockpit-podman ;;
    esac
}
verify_vm_tools() {
    [ "$INSTALL_VM" -eq 1 ] || return 0
    info "验证 QEMU/libvirt 命令可用性" "Verifying QEMU/libvirt commands"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: 跳过命令实际验证" "dry-run: skipping command verification"
        return 0
    fi
    command -v qemu-img >/dev/null 2>&1 || fatal "未找到 qemu-img，虚拟化包安装不完整" "qemu-img not found; virtualization package install is incomplete"
    command -v virsh >/dev/null 2>&1 || fatal "未找到 virsh，libvirt 客户端安装不完整" "virsh not found; libvirt client install is incomplete"
    ok "QEMU/libvirt 命令验证通过" "QEMU/libvirt command verification passed"
}
enable_libvirt_service() {
    [ "$INSTALL_VM" -eq 1 ] || return 0
    info "启用 libvirt 服务" "Enabling libvirt service"
    local candidate
    for candidate in libvirtd.service virtqemud.service libvirt-daemon.service libvirtd virtqemud libvirt; do
        if start_service_candidate "$candidate"; then
            verify_libvirt_service "$candidate"
            return 0
        fi
    done
    fatal "未找到可启动的 libvirt 服务单元" "No startable libvirt service unit was found"
}
verify_libvirt_service() {
    local service="$1"
    if [ "$DRY_RUN" -eq 1 ]; then
        return 0
    fi
    if command -v virsh >/dev/null 2>&1; then
        if virsh -c qemu:///system list >/dev/null 2>&1; then
            ok "libvirt 系统连接验证通过" "libvirt system connection verified"
            return 0
        fi
    fi
    fatal "libvirt 服务启动后验证失败: $service" "libvirt verification failed after starting: $service"
}
configure_firewall() {
    info "配置防火墙放行 Cockpit 9090 端口" "Configuring firewall access for Cockpit port 9090"
    if command -v firewall-cmd >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 0 ] && ! firewall-cmd --state >/dev/null 2>&1; then
            warn "firewalld 未运行，跳过 firewall-cmd 配置" "firewalld is not running; skipping firewall-cmd configuration"
            return 0
        fi
        run_cmd "临时允许 Cockpit 服务" "Allowing Cockpit service for current firewalld runtime" firewall-cmd --add-service=cockpit
        run_cmd "永久允许 Cockpit 服务" "Allowing Cockpit service permanently in firewalld" firewall-cmd --add-service=cockpit --permanent
        run_cmd "重新加载 firewalld" "Reloading firewalld" firewall-cmd --reload
    elif command -v ufw >/dev/null 2>&1; then
        if [ "$DRY_RUN" -eq 0 ] && ! ufw status 2>/dev/null | grep -qi '^Status: active'; then
            warn "ufw 未启用，跳过 ufw 配置" "ufw is not active; skipping ufw configuration"
            return 0
        fi
        run_cmd "允许 9090/tcp" "Allowing 9090/tcp" ufw allow 9090/tcp
    elif command -v iptables >/dev/null 2>&1; then
        warn "检测到 iptables，但不自动写入持久规则，请手动确认 9090/tcp 已放行" "iptables detected, but persistent rules are not modified automatically; ensure 9090/tcp is allowed"
    else
        warn "未检测到支持的防火墙工具，跳过防火墙配置" "No supported firewall tool detected; skipping firewall configuration"
    fi
}
set_root_login_policy() {
    info "配置 Cockpit root 登录策略" "Configuring Cockpit root login policy"
    local disallowed="/etc/cockpit/disallowed-users"
    if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p /etc/cockpit
    else
        info "dry-run: 将确保 /etc/cockpit 存在" "dry-run: would ensure /etc/cockpit exists"
    fi

    if [ -f "$disallowed" ]; then
        backup_file "$disallowed"
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: 将确保 root 保持在 $disallowed 中" "dry-run: would ensure root remains in $disallowed"
    else
        touch "$disallowed"
        if grep -qE '^[[:space:]]*#?[[:space:]]*root[[:space:]]*$' "$disallowed"; then
            local tmp
            tmp="$(mktemp)"
            awk '
                /^[[:space:]]*#?[[:space:]]*root[[:space:]]*$/ {
                    if (!seen) {
                        print "root"
                        seen=1
                    }
                    next
                }
                { print }
                END {
                    if (!seen) print "root"
                }
            ' "$disallowed" > "$tmp"
            cat "$tmp" > "$disallowed"
            rm -f "$tmp"
        else
            printf "root\n" >> "$disallowed"
        fi
    fi
    ok "root 直接登录 Cockpit 已保持禁用" "Direct root login to Cockpit remains disabled"
    configure_sudoers_for_cockpit
}
configure_sudoers_for_cockpit() {
    if ! command -v visudo >/dev/null 2>&1; then
        warn "未找到 visudo，跳过 sudoers 配置" "visudo not found; skipping sudoers configuration"
        return 0
    fi
    local sudoers="/etc/sudoers.d/cockpit-admins"
    local tmp
    tmp="$(mktemp)"
    cat > "$tmp" <<'SUDOERS'
# Managed by oneclickvirt cockpit installer.
# Users should log in with a normal account and elevate through sudo, not root.
%sudo ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL
%cockpit-admin ALL=(ALL:ALL) ALL
SUDOERS
    if [ -f "$sudoers" ]; then
        backup_file "$sudoers"
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: 将写入并验证 $sudoers" "dry-run: would write and validate $sudoers"
        rm -f "$tmp"
        return 0
    fi
    chmod 0440 "$tmp"
    visudo -cf "$tmp" >/dev/null
    install -m 0440 "$tmp" "$sudoers"
    rm -f "$tmp"
    ok "已配置 sudoers 管理组 sudo/wheel/cockpit-admin" "Configured sudoers admin groups sudo/wheel/cockpit-admin"
}
select_qemu_identity() {
    QEMU_USER=""
    QEMU_GROUP=""
    local user
    for user in libvirt-qemu qemu qemuuser; do
        if getent passwd "$user" >/dev/null 2>&1; then
            QEMU_USER="$user"
            break
        fi
    done
    local group
    for group in kvm libvirt-qemu qemu libvirt; do
        if getent group "$group" >/dev/null 2>&1; then
            QEMU_GROUP="$group"
            break
        fi
    done
}
set_conf_key() {
    local file="$1"
    local key="$2"
    local value="$3"
    local tmp
    tmp="$(mktemp)"
    awk -v key="$key" -v value="$value" '
        BEGIN { done=0 }
        $0 ~ "^[[:space:]]*#?[[:space:]]*" key "[[:space:]]*=" {
            if (!done) {
                print key " = \"" value "\""
                done=1
            }
            next
        }
        { print }
        END {
            if (!done) print key " = \"" value "\""
        }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
fix_qemu_conf() {
    [ "$INSTALL_VM" -eq 1 ] || return 0
    local conf="/etc/libvirt/qemu.conf"
    if [ ! -f "$conf" ]; then
        warn "未找到 $conf，跳过 QEMU 用户配置" "$conf not found; skipping QEMU user configuration"
        return 0
    fi
    select_qemu_identity
    if [ -z "$QEMU_USER" ] || [ -z "$QEMU_GROUP" ]; then
        warn "未找到非特权 qemu/libvirt 用户或组，拒绝设置 root 运行 QEMU" "No unprivileged qemu/libvirt user or group found; refusing to configure QEMU as root"
        return 0
    fi
    backup_file "$conf"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: 将设置 QEMU 运行身份为 $QEMU_USER:$QEMU_GROUP" "dry-run: would set QEMU runtime identity to $QEMU_USER:$QEMU_GROUP"
    else
        set_conf_key "$conf" user "$QEMU_USER"
        set_conf_key "$conf" group "$QEMU_GROUP"
    fi
    restart_libvirt_after_qemu_change
}
restart_libvirt_after_qemu_change() {
    local candidate
    for candidate in libvirtd.service virtqemud.service libvirt-daemon.service libvirtd virtqemud libvirt; do
        if systemctl_ready && systemd_unit_exists "$candidate"; then
            run_cmd "重启 $candidate 以应用 QEMU 配置" "Restarting $candidate to apply QEMU configuration" systemctl restart "$candidate"
            return 0
        fi
        if command -v rc-service >/dev/null 2>&1 && { rc-service "$candidate" status >/dev/null 2>&1 || [ -f "/etc/init.d/$candidate" ]; }; then
            run_cmd "重启 $candidate 以应用 QEMU 配置" "Restarting $candidate to apply QEMU configuration" rc-service "$candidate" restart
            return 0
        fi
        if command -v service >/dev/null 2>&1 && { service "$candidate" status >/dev/null 2>&1 || [ -f "/etc/init.d/$candidate" ] || [ -f "/usr/local/etc/rc.d/$candidate" ]; }; then
            run_cmd "重启 $candidate 以应用 QEMU 配置" "Restarting $candidate to apply QEMU configuration" service "$candidate" restart
            return 0
        fi
    done
    warn "未找到可重启的 libvirt 服务，QEMU 配置将在服务下次启动时生效" "No restartable libvirt service found; QEMU configuration will apply on next service start"
}
enable_cockpit_service() {
    info "启用 Cockpit 服务" "Enabling Cockpit service"
    if [ "$SYSTEM_FAMILY" = "coreos" ]; then
        warn "CoreOS 的 rpm-ostree 安装可能需要重启后再启用 cockpit.socket" "CoreOS rpm-ostree installation may require a reboot before enabling cockpit.socket"
    fi
    if [ "$SYSTEM_FAMILY" = "coreos" ] && [ "$COREOS_REBOOT_REQUIRED" -eq 1 ] && ! systemd_unit_exists cockpit.socket; then
        warn "rpm-ostree 已创建新部署，请重启后再启用 Cockpit 服务" "rpm-ostree created a new deployment; reboot before enabling Cockpit"
        return 0
    fi
    local candidate
    for candidate in cockpit.socket cockpit.service cockpit cockpit-ws; do
        if start_service_candidate "$candidate"; then
            ok "Cockpit 服务已启用" "Cockpit service enabled"
            return 0
        fi
    done
    if [ "$SYSTEM_FAMILY" = "coreos" ] && command -v podman >/dev/null 2>&1; then
        run_cmd "使用 podman runlabel 安装 cockpit/ws" "Installing cockpit/ws through podman runlabel" podman container runlabel INSTALL quay.io/cockpit/ws
        run_cmd "使用 podman runlabel 启动 cockpit/ws" "Starting cockpit/ws through podman runlabel" podman container runlabel --name cockpit-ws RUN quay.io/cockpit/ws
        return 0
    fi
    fatal "未找到可启动的 Cockpit 服务" "No startable Cockpit service found"
}
statistics_of_run_times() {
    if [ "$TELEMETRY" -eq 0 ]; then
        ok "匿名统计已禁用" "Anonymous telemetry disabled"
        return 0
    fi
    if [ "$DRY_RUN" -eq 1 ]; then
        ok "dry-run 模式跳过匿名统计" "dry-run mode skips anonymous telemetry"
        return 0
    fi
    if ! command -v curl >/dev/null 2>&1; then
        warn "未找到 curl，跳过匿名统计" "curl not found; skipping anonymous telemetry"
        return 0
    fi
    local count today total
    if count="$(curl -4 -ksm1 'https://hits.spiritlhl.net/cockpit?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false' 2>/dev/null)"; then
        :
    elif count="$(curl -6 -ksm1 'https://hits.spiritlhl.net/cockpit?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false' 2>/dev/null)"; then
        :
    else
        count=""
    fi
    today="$(printf "%s" "$count" | sed -nE 's/.*"daily":[[:space:]]*([0-9]+).*/\1/p')"
    total="$(printf "%s" "$count" | sed -nE 's/.*"total":[[:space:]]*([0-9]+).*/\1/p')"
    if [ -n "$today" ] || [ -n "$total" ]; then
        ok "脚本当天运行次数: ${today:-unknown}，累计运行次数: ${total:-unknown}" "Script runs today: ${today:-unknown}, total runs: ${total:-unknown}"
    else
        warn "匿名统计请求未返回可解析结果" "Anonymous telemetry did not return a parseable result"
    fi
}
health_check() {
    info "执行安装后健康检查" "Running post-install health check"
    if [ "$DRY_RUN" -eq 1 ]; then
        info "dry-run: 跳过实际健康检查" "dry-run: skipping actual health check"
        return 0
    fi
    if [ "$SYSTEM_FAMILY" = "coreos" ] && [ "$COREOS_REBOOT_REQUIRED" -eq 1 ]; then
        warn "CoreOS 新部署需重启后才能完成 Cockpit 健康检查" "CoreOS needs a reboot before Cockpit health checks can complete"
        return 0
    fi
    if check_port_listening; then
        ok "检测到 9090 端口正在监听" "Port 9090 is listening"
    else
        local rc=$?
        if [ "$rc" -eq 2 ]; then
            warn "缺少 ss/netstat/sockstat，无法检查监听端口" "Missing ss/netstat/sockstat; cannot check listening port"
        else
            fatal "未检测到 Cockpit 9090 监听端口" "Cockpit port 9090 is not listening"
        fi
    fi
    if command -v curl >/dev/null 2>&1; then
        local code
        if code="$(curl -ksS --max-time 8 -o /dev/null -w '%{http_code}' https://127.0.0.1:9090/ 2>/dev/null)"; then
            :
        else
            code=""
        fi
        case "$code" in
            2*|3*|4*)
                ok "Cockpit HTTP 健康检查通过，状态码 $code" "Cockpit HTTP health check passed with status $code"
                ;;
            *)
                fatal "Cockpit HTTP 健康检查失败，状态码 ${code:-none}" "Cockpit HTTP health check failed with status ${code:-none}"
                ;;
        esac
    else
        warn "未找到 curl，跳过 HTTP 健康检查" "curl not found; skipping HTTP health check"
    fi
}
show_completion_info() {
    local ipv4 ipv6 external4 external6
    ipv4="$(get_local_ipv4 | awk 'NR == 1 { print; exit }')"
    ipv6="$(get_local_ipv6 | awk 'NR == 1 { print; exit }')"
    if [ -z "$ipv4" ]; then
        if external4="$(get_external_ip 4)"; then
            ipv4="$external4"
        fi
    fi
    if [ -z "$ipv6" ]; then
        if external6="$(get_external_ip 6)"; then
            ipv6="$external6"
        fi
    fi

    ok "Cockpit 安装和配置完成" "Cockpit installation and configuration completed"
    ok "访问地址 / Access URLs:" "Access URLs / 访问地址:"
    if [ -n "$ipv4" ]; then
        ok "https://${ipv4}:9090/" "https://${ipv4}:9090/"
    fi
    if [ -n "$ipv6" ]; then
        ok "https://[${ipv6}]:9090/" "https://[${ipv6}]:9090/"
    fi
    if [ -z "$ipv4" ] && [ -z "$ipv6" ]; then
        warn "未能自动检测公网地址，请使用服务器实际 IP 访问 https://<IP>:9090/" "Could not detect a public address; use the server IP manually at https://<IP>:9090/"
    fi
    if [ "$SYSTEM_FAMILY" = "coreos" ] && [ "$COREOS_REBOOT_REQUIRED" -eq 1 ]; then
        warn "CoreOS/rpm-ostree 安装已排队，请重启后再次运行 --reconfigure 完成服务启用和健康检查" "CoreOS/rpm-ostree install is queued; reboot and rerun --reconfigure to enable the service and health checks"
    fi
    if [ "${#OPTIONAL_MISSING[@]}" -gt 0 ]; then
        warn "部分可选模块未安装: ${OPTIONAL_MISSING[*]}" "Some optional modules were not installed: ${OPTIONAL_MISSING[*]}"
    fi
    if [ "${#WARNINGS[@]}" -gt 0 ]; then
        info "执行完成，但存在警告，请检查上方日志" "Completed with warnings; review the log above"
    fi
}
main() {
    parse_arguments "$@"
    setup_logging
    ok "Cockpit 安装器版本: $SCRIPT_VERSION" "Cockpit installer version: $SCRIPT_VERSION"
    setup_locale
    check_root
    detect_os
    preflight_checks
    detect_existing_installation
    refresh_package_metadata
    statistics_of_run_times
    upgrade_or_reinstall_existing
    install_cockpit_base
    install_vm_packages
    install_cockpit_machines
    install_cockpit_containers
    set_root_login_policy
    fix_qemu_conf
    configure_firewall
    enable_cockpit_service
    health_check
    show_completion_info
}

main "$@"
