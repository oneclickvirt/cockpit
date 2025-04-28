#!/bin/bash
# https://github.com/oneclickvirt/cockpit
# 2025.04.28
set -e
export DEBIAN_FRONTEND=noninteractive
cd /root >/dev/null 2>&1

_red() { echo -e "\033[31m\033[01m$@\033[0m"; }
_green() { echo -e "\033[32m\033[01m$@\033[0m"; }
_yellow() { echo -e "\033[33m\033[01m$@\033[0m"; }
_blue() { echo -e "\033[36m\033[01m$@\033[0m"; }
reading() { read -rp "$(_green "$1")" "$2"; }

setup_locale() {
    _blue "配置UTF-8语言环境..."
    utf8_locale=$(locale -a 2>/dev/null | grep -i -m 1 -E "UTF-8|utf8")
    if [[ -z "$utf8_locale" ]]; then
        _yellow "未找到UTF-8语言环境"
    else
        export LC_ALL="$utf8_locale"
        export LANG="$utf8_locale"
        export LANGUAGE="$utf8_locale"
        _green "语言环境设置为 $utf8_locale"
    fi
}

check_root() {
    if [ "$(id -u)" != "0" ]; then
        _red "此脚本必须以root用户运行" 1>&2
        exit 1
    fi
}

init_system_vars() {
    _blue "初始化系统变量..."
    temp_file_apt_fix="/tmp/apt_fix.txt"
    REGEX=("debian" "ubuntu" "centos|red hat|kernel|oracle linux|alma|rocky" "'amazon linux'" "fedora" "arch")
    RELEASE=("Debian" "Ubuntu" "CentOS" "CentOS" "Fedora" "Arch")
    PACKAGE_UPDATE=("! apt-get update && apt-get --fix-broken install -y && apt-get update" "apt-get update" "yum -y update" "yum -y update" "yum -y update" "pacman -Sy")
    PACKAGE_INSTALL=("apt-get -y install" "apt-get -y install" "yum -y install" "yum -y install" "yum -y install" "pacman -Sy --noconfirm --needed")
    PACKAGE_REMOVE=("apt-get -y remove" "apt-get -y remove" "yum -y remove" "yum -y remove" "yum -y remove" "pacman -Rsc --noconfirm")
    PACKAGE_UNINSTALL=("apt-get -y autoremove" "apt-get -y autoremove" "yum -y autoremove" "yum -y autoremove" "yum -y autoremove" "")
    CMD=("$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)" "$(hostnamectl 2>/dev/null | grep -i system | cut -d : -f2)" "$(lsb_release -sd 2>/dev/null)" "$(grep -i description /etc/lsb-release 2>/dev/null | cut -d \" -f2)" "$(grep . /etc/redhat-release 2>/dev/null)" "$(grep . /etc/issue 2>/dev/null | cut -d \\ -f1 | sed '/^[ ]*$/d')" "$(grep -i pretty_name /etc/os-release 2>/dev/null | cut -d \" -f2)")
    SYS="${CMD[0]}"
    [[ -n $SYS ]] || exit 1
    for ((int = 0; int < ${#REGEX[@]}; int++)); do
        if [[ $(echo "$SYS" | tr '[:upper:]' '[:lower:]') =~ ${REGEX[int]} ]]; then
            SYSTEM="${RELEASE[int]}"
            [[ -n $SYSTEM ]] && break
        fi
    done
    PACKAGE_UPDATE_CMD=${PACKAGE_UPDATE[$int]}
    PACKAGE_INSTALL_CMD=${PACKAGE_INSTALL[$int]}
    PACKAGE_REMOVE_CMD=${PACKAGE_REMOVE[$int]}
    PACKAGE_UNINSTALL_CMD=${PACKAGE_UNINSTALL[$int]}
    _green "检测到系统: $SYSTEM"
}

is_private_ipv4() {
    local ip_address=$1
    local ip_parts
    if [[ -z $ip_address ]]; then
        return 0 # 输入为空
    fi
    IFS='.' read -r -a ip_parts <<<"$ip_address"
    # 检查IP地址是否符合内网IP地址的范围
    # 去除回环，RFC 1918，多播，RFC 6598地址
    if [[ ${ip_parts[0]} -eq 10 ]] ||
        [[ ${ip_parts[0]} -eq 172 && ${ip_parts[1]} -ge 16 && ${ip_parts[1]} -le 31 ]] ||
        [[ ${ip_parts[0]} -eq 192 && ${ip_parts[1]} -eq 168 ]] ||
        [[ ${ip_parts[0]} -eq 127 ]] ||
        [[ ${ip_parts[0]} -eq 0 ]] ||
        [[ ${ip_parts[0]} -eq 100 && ${ip_parts[1]} -ge 64 && ${ip_parts[1]} -le 127 ]] ||
        [[ ${ip_parts[0]} -ge 224 ]]; then
        return 0 # 是内网IP地址
    else
        return 1 # 不是内网IP地址
    fi
}

check_ipv4() {
    _blue "获取服务器IP地址..."
    IPV4=$(ip -4 addr show | grep global | awk '{print $2}' | cut -d '/' -f1 | head -n 1)
    if is_private_ipv4 "$IPV4"; then # 由于是内网IPv4地址，需要通过API获取外网地址
        _yellow "检测到内网IP，尝试获取公网IP..."
        IPV4=""
        local API_NET=("ipv4.ip.sb" "ipget.net" "ip.ping0.cc" "https://ip4.seeip.org" "https://api.my-ip.io/ip" "https://ipv4.icanhazip.com" "api.ipify.org")
        for p in "${API_NET[@]}"; do
            _blue "正在尝试从 $p 获取IP..."
            response=$(curl -s4m8 "$p")
            sleep 1
            if [ $? -eq 0 ] && ! echo "$response" | grep -q "error"; then
                IP_API="$p"
                IPV4="$response"
                _green "成功获取公网IP: $IPV4"
                break
            fi
        done
    else
        _green "检测到IP地址: $IPV4"
    fi
    export IPV4
}

parse_arguments() {
    _blue "解析命令行参数..."
    INSTALL_VM=0
    INSTALL_CONTAINER=0
    for arg in "$@"; do
        case "$arg" in
            --vm)
                INSTALL_VM=1
                _green "将安装虚拟机管理功能"
                ;;
            --ct)
                INSTALL_CONTAINER=1
                _green "将安装容器管理功能"
                ;;
            --all)
                INSTALL_VM=1
                INSTALL_CONTAINER=1
                _green "将安装全部功能"
                ;;
        esac
    done
}

detect_os() {
    _blue "检测操作系统详细信息..."
    ID_LIKE=""
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        ID_LIKE="${ID_LIKE,,}"
        ID="${ID,,}"
        VERSION_ID="${VERSION_ID,,}"
        _green "操作系统: $ID $VERSION_ID"
    else
        _red "无法读取OS信息，将尝试使用通用方法安装"
    fi
}

update_system() {
    _blue "更新系统包..."
    if [ "$SYSTEM" = "Debian" ] || [ "$SYSTEM" = "Ubuntu" ]; then
        apt-get update
        apt-get --fix-broken install -y
    elif [ "$SYSTEM" = "CentOS" ] || [ "$SYSTEM" = "Fedora" ]; then
        yum -y update
    elif [ "$SYSTEM" = "Arch" ]; then
        pacman -Sy
    else
        _yellow "未知系统，跳过更新"
    fi
}

statistics_of_run_times() {
    COUNT=$(curl -4 -ksm1 "https://hits.spiritlhl.net/cockpit?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null ||
        curl -6 -ksm1 "https://hits.spiritlhl.net/cockpit?action=hit&title=Hits&title_bg=%23555555&count_bg=%2324dde1&edge_flat=false" 2>/dev/null)
    TODAY=$(echo "$COUNT" | grep -oP '"daily":\s*[0-9]+' | sed 's/"daily":\s*\([0-9]*\)/\1/')
    TOTAL=$(echo "$COUNT" | grep -oP '"total":\s*[0-9]+' | sed 's/"total":\s*\([0-9]*\)/\1/')
}

install_packages() {
    local packages=("$@")
    case "$SYSTEM" in
        Debian|Ubuntu)
            apt-get update
            for package in "${packages[@]}"; do
                if apt-cache show "$package" >/dev/null 2>&1; then
                    _green "安装 $package..."
                    $PACKAGE_INSTALL_CMD "$package"
                else
                    _yellow "包 $package 不存在，跳过安装"
                fi
            done
            ;;
        CentOS|Fedora)
            yum makecache fast
            for package in "${packages[@]}"; do
                if yum list available "$package" >/dev/null 2>&1; then
                    _green "安装 $package..."
                    $PACKAGE_INSTALL_CMD "$package"
                else
                    _yellow "包 $package 不存在，跳过安装"
                fi
            done
            ;;
        Arch)
            pacman -Sy
            for package in "${packages[@]}"; do
                if pacman -Si "$package" >/dev/null 2>&1; then
                    _green "安装 $package..."
                    $PACKAGE_INSTALL_CMD "$package"
                else
                    _yellow "包 $package 不存在，跳过安装"
                fi
            done
            ;;
        *)
            _yellow "未知系统，尝试直接安装所有包..."
            $PACKAGE_INSTALL_CMD "${packages[@]}" || _yellow "安装遇到问题，请检查手动处理"
            ;;
    esac
}

install_vm_packages() {
    if [ $INSTALL_VM -eq 1 ]; then
        _blue "安装QEMU/KVM虚拟化软件包..."
        case "$SYSTEM" in
            Debian|Ubuntu)
                install_packages qemu-system qemu-utils qemu-kvm libvirt-daemon libvirt-clients bridge-utils
                ;;
            CentOS)
                install_packages qemu-kvm qemu-img libvirt virt-install libvirt-client bridge-utils
                ;;
            Fedora)
                install_packages qemu-kvm qemu-img libvirt virt-install libvirt-client bridge-utils
                ;;
            Arch)
                install_packages qemu libvirt bridge-utils
                ;;
            *)
                _red "无法为当前发行版安装虚拟化包，请手动安装"
                ;;
        esac
        if systemctl list-unit-files | grep -q libvirtd; then
            systemctl enable --now libvirtd
            _green "已启用libvirtd服务"
        elif systemctl list-unit-files | grep -q libvirt-daemon; then
            systemctl enable --now libvirt-daemon
            _green "已启用libvirt-daemon服务"
        fi
    fi
}

install_cockpit_base() {
    _blue "安装Cockpit基本组件..."
    case "$SYSTEM" in
        Debian|Ubuntu)
            if [ -n "$VERSION_CODENAME" ]; then
                echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main" > /etc/apt/sources.list.d/backports.list
                apt-get update
                apt-get install -t ${VERSION_CODENAME}-backports cockpit -y
            else
                install_packages cockpit
            fi
            ;;
        CentOS)
            install_packages cockpit
            ;;
        Fedora)
            install_packages cockpit
            ;;
        Arch)
            install_packages cockpit
            ;;
        *)
            if grep -qi "coreos" /etc/os-release; then
                rpm-ostree install cockpit-system cockpit-ostree
                echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/02-enable-passwords.conf
                systemctl try-restart sshd
                podman container runlabel --name cockpit-ws RUN quay.io/cockpit/ws
                podman container runlabel INSTALL quay.io/cockpit/ws
                systemctl enable cockpit.service
                return
            else
                _red "不支持的发行版：$SYSTEM"
                exit 1
            fi
            ;;
    esac
    _green "Cockpit基本组件安装完成"
}

install_cockpit_machines() {
    if [ $INSTALL_VM -eq 1 ]; then
        _blue "安装Cockpit虚拟机管理模块..."
        case "$SYSTEM" in
            Debian|Ubuntu)
                if [ -n "$VERSION_CODENAME" ]; then
                    apt-get install -t ${VERSION_CODENAME}-backports cockpit-machines -y
                else
                    install_packages cockpit-machines
                fi
                ;;
            CentOS)
                install_packages cockpit-machines
                ;;
            Fedora)
                install_packages cockpit-machines
                ;;
            Arch)
                install_packages cockpit-machines
                ;;
            *)
                if ! grep -qi "coreos" /etc/os-release; then
                    _yellow "不支持在此发行版上安装cockpit-machines"
                fi
                ;;
        esac
        _green "Cockpit虚拟机管理模块安装完成"
    fi
}

install_cockpit_containers() {
    if [ $INSTALL_CONTAINER -eq 1 ]; then
        _blue "安装Cockpit容器管理模块..."
        case "$SYSTEM" in
            Debian|Ubuntu)
                if [ -n "$VERSION_CODENAME" ]; then
                    apt-get install -t ${VERSION_CODENAME}-backports cockpit-podman -y
                else
                    install_packages cockpit-podman
                fi
                ;;
            CentOS)
                install_packages cockpit-podman
                ;;
            Fedora)
                install_packages cockpit-podman
                ;;
            Arch)
                install_packages cockpit-podman
                ;;
            *)
                if grep -qi "coreos" /etc/os-release; then
                    rpm-ostree install cockpit-podman
                else
                    _yellow "不支持在此发行版上安装cockpit-podman"
                fi
                ;;
        esac
        _green "Cockpit容器管理模块安装完成"
    fi
}

configure_firewall() {
    _blue "配置防火墙..."
    if command -v firewall-cmd &> /dev/null; then
        firewall-cmd --add-service=cockpit || true
        firewall-cmd --add-service=cockpit --permanent || true
        if [ "$SYSTEM" = "CentOS" ] || [[ "$SYSTEM" =~ ^"opensuse" ]] || [ "$SYSTEM" = "Fedora" ]; then
            firewall-cmd --reload || true
            _green "已配置防火墙允许Cockpit服务"
        fi
    else
        _yellow "未检测到firewall-cmd，跳过防火墙配置"
    fi
}

allow_root_access() {
    _blue "配置root用户访问权限..."
    if [ -f "/etc/cockpit/disallowed-users" ]; then
        sed -i '/^[[:space:]]*root[[:space:]]*$/s/^/# /' /etc/cockpit/disallowed-users
        _green "已允许root用户访问Cockpit"
    fi
}

enable_cockpit_service() {
    _blue "启用Cockpit服务..."
    if ! grep -qi "coreos" /etc/os-release; then
        systemctl enable --now cockpit.socket
        systemctl status cockpit.socket --no-pager
        _green "Cockpit服务已启用并启动"
    fi
}

fix_qemu_conf() {
    local conf="/etc/libvirt/qemu.conf"
    if [ ! -f "$conf" ]; then
        return 1
    fi
    if ! grep -qE '^ *user *= *"root"' "$conf"; then
        echo 'user = "root"' >> "$conf"
    fi
    if ! grep -qE '^ *group *= *"root"' "$conf"; then
        echo 'group = "root"' >> "$conf"
    fi
    systemctl restart libvirtd
}


show_completion_info() {
    check_ipv4
    _green "Cockpit安装完成！"
    _green "通过以下地址访问Cockpit界面："
    _green "https://${IPV4}:9090/"
    if [ -z "$IPV4" ]; then
        _yellow "警告: 未能获取IP地址，请使用服务器IP手动访问"
    fi
}

main() {
    check_root
    setup_locale
    init_system_vars
    parse_arguments "$@"
    detect_os
    update_system
    statistics_of_run_times
    _green "Script run count today: ${TODAY}, total run count: ${TOTAL}"
    _green "脚本当天运行次数:${TODAY}，累计运行次数:${TOTAL}"
    if [ $INSTALL_VM -eq 1 ]; then
        install_vm_packages
    fi
    install_cockpit_base
    install_cockpit_machines
    install_cockpit_containers
    fix_qemu_conf
    configure_firewall
    allow_root_access
    enable_cockpit_service
    show_completion_info
}

main "$@"
