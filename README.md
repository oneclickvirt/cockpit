# cockpit

[![hits](https://hits.spiritlhl.net/cockpit.svg?action=hit&title=hits&title_bg=%23555555&count_bg=%233aebee&edge_flat=false)](https://hits.spiritlhl.net)

## 说明

中文：

https://www.spiritlhl.net/incomplete/cockpit.html

English:

https://www.spiritlhl.net/en/incomplete/cockpit.html

## 安装 / Install

```bash
bash scripts/install.sh --all
```

常用选项 / Common options:

```bash
bash scripts/install.sh --vm                 # 安装虚拟机管理 / install VM management
bash scripts/install.sh --ct                 # 安装容器管理 / install container management
bash scripts/install.sh --dry-run --all      # 预览操作 / preview actions
bash scripts/install.sh --all --no-telemetry # 禁用匿名统计 / disable anonymous telemetry
bash scripts/install.sh --all --log-file /var/log/cockpit-install.log
```

也可以通过环境变量禁用匿名统计 / Anonymous telemetry can also be disabled with:

```bash
COCKPIT_INSTALL_NO_TELEMETRY=1 bash scripts/install.sh --all
```

## 安全默认值 / Security Defaults

- 不允许 root 直接登录 Cockpit，改为通过普通用户和 sudo/wheel/cockpit-admin 组提权。
- QEMU 不再被配置为 root 运行，会优先使用系统已有的 libvirt-qemu/qemu 非特权用户和 kvm/qemu 组。
- 修改 `/etc/cockpit/disallowed-users`、`/etc/sudoers.d/cockpit-admins`、`/etc/libvirt/qemu.conf` 前会自动备份。
- 关键服务、防火墙、包安装和健康检查失败会明确报错，不再静默忽略。

- Direct root login to Cockpit stays disabled. Use a normal user with sudo/wheel/cockpit-admin privileges.
- QEMU is not configured to run as root. The installer prefers existing unprivileged libvirt-qemu/qemu users and kvm/qemu groups.
- Managed Cockpit, sudoers, and libvirt configuration files are backed up before modification.
- Critical package, service, firewall, and health-check failures are reported explicitly.

## 卸载 / Uninstall

```bash
bash scripts/uninstall.sh --all
```

默认卸载包并保留用户配置。需要删除安装器管理的 sudoers/backports 配置时使用：

By default packages are removed while user configuration is kept. To remove installer-managed sudoers/backports files:

```bash
bash scripts/uninstall.sh --all --purge-config
```
