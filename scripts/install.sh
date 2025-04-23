#!/bin/bash

set -e

INSTALL_VM=0
INSTALL_CONTAINER=0

for arg in "$@"; do
    case "$arg" in
        --vm)
            INSTALL_VM=1
            ;;
        --container)
            INSTALL_CONTAINER=1
            ;;
    esac
done

ID_LIKE=""
if [ -f /etc/os-release ]; then
    . /etc/os-release
    ID_LIKE="${ID_LIKE,,}"
    ID="${ID,,}"
    VERSION_ID="${VERSION_ID,,}"
fi

case "$ID" in
    debian|ubuntu)
        echo "deb http://deb.debian.org/debian ${VERSION_CODENAME}-backports main" > /etc/apt/sources.list.d/backports.list
        apt update
        apt install -t ${VERSION_CODENAME}-backports cockpit -y
        [[ $INSTALL_VM -eq 1 ]] && apt install -t ${VERSION_CODENAME}-backports cockpit-machines -y
        [[ $INSTALL_CONTAINER -eq 1 ]] && apt install -t ${VERSION_CODENAME}-backports cockpit-docker -y
        systemctl enable --now cockpit.socket
        ;;
    fedora)
        dnf install cockpit -y
        [[ $INSTALL_VM -eq 1 ]] && dnf install cockpit-machines -y
        [[ $INSTALL_CONTAINER -eq 1 ]] && dnf install cockpit-docker -y
        systemctl enable --now cockpit.socket
        firewall-cmd --add-service=cockpit || true
        firewall-cmd --add-service=cockpit --permanent || true
        ;;
    rhel|centos)
        yum install cockpit -y
        [[ $INSTALL_VM -eq 1 ]] && yum install cockpit-machines -y
        [[ $INSTALL_CONTAINER -eq 1 ]] && yum install cockpit-docker -y
        systemctl enable --now cockpit.socket
        firewall-cmd --add-service=cockpit || true
        firewall-cmd --add-service=cockpit --permanent || true
        firewall-cmd --reload || true
        ;;
    arch)
        pacman -Sy --noconfirm cockpit
        [[ $INSTALL_VM -eq 1 ]] && pacman -S --noconfirm cockpit-machines
        [[ $INSTALL_CONTAINER -eq 1 ]] && pacman -S --noconfirm cockpit-docker
        systemctl enable --now cockpit.socket
        ;;
    clear-linux-os)
        swupd bundle-add sysadmin-remote
        [[ $INSTALL_VM -eq 1 ]] && swupd bundle-add virtualization-host
        [[ $INSTALL_CONTAINER -eq 1 ]] && swupd bundle-add containers-basic
        systemctl enable --now cockpit.socket
        ;;
    opensuse*|suse)
        zypper --non-interactive in cockpit
        [[ $INSTALL_VM -eq 1 ]] && zypper --non-interactive in cockpit-machines
        [[ $INSTALL_CONTAINER -eq 1 ]] && zypper --non-interactive in cockpit-docker
        systemctl enable --now cockpit.socket
        firewall-cmd --permanent --zone=public --add-service=cockpit || true
        firewall-cmd --reload || true
        ;;
    *)
        if grep -qi "coreos" /etc/os-release; then
            rpm-ostree install cockpit-system cockpit-ostree
            [[ $INSTALL_CONTAINER -eq 1 ]] && rpm-ostree install cockpit-docker
            echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/02-enable-passwords.conf
            systemctl try-restart sshd
            podman container runlabel --name cockpit-ws RUN quay.io/cockpit/ws
            podman container runlabel INSTALL quay.io/cockpit/ws
            systemctl enable cockpit.service
        else
            echo "不支持的发行版：$ID"
            exit 1
        fi
        ;;
esac

if [ -f "/etc/cockpit/disallowed-users" ]; then
    sed -i '/^[[:space:]]*root[[:space:]]*$/s/^/# /' /etc/cockpit/disallowed-users
fi
