# VPS 全局出口管理脚本使用说明

本脚本基于 **sing-box v1.14.3** 构建，通过虚拟网卡（TUN 模式）接管 VPS 的全局网络流量，实现一键将任意代理节点设置为当前 VPS 的全局出口。
## 运行前请检查节点是否有v6出口
---

## 一、支持环境与协议

* **支持系统**：Debian、Ubuntu、CentOS / AlmaLinux / Rocky Linux、Fedora、Alpine Linux（兼容 systemd 与 OpenRC）
* **支持架构**：`x86_64 (amd64)`、`aarch64 (arm64)`、`armv7`、`i386`
* **支持协议（自动识别）**：
  * `VLESS`（Reality / WS+TLS / WS / TLS / TCP）
  * `Hysteria2 (hy2)`
  * `TUIC`
  * `Trojan`
  * `Shadowsocks / SS2022`
  * `AnyTLS` / `NaiveProxy`
  * `SOCKS5` / `HTTP` / `HTTPS`
  * 单条或包含多条节点的 `Base64` 编码内容（默认取第一条可用节点）

---

## 二、快速安装与首次运行

> **前提条件**：请确保使用 `root` 用户登录，且 VPS 已开启 TUN/TAP 设备权限（可通过 `ls /dev/net/tun` 确认）。

### 1. 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/lczws/Public/main/Shell/Sing-box-TUN/proxy.sh)
```

### 2. 赋予执行权限并运行
```bash
chmod +x proxy.sh
./proxy.sh
```
首次运行时，脚本会自动完成以下操作：
1. 安装所需系统依赖（`curl`、`python3`、`iproute2` 等）。
2. 自动匹配当前 CPU 架构，下载并固定安装 `sing-box v1.14.3`。
3. 注册快捷管理命令 `out`，并自动进入管理菜单。

---

## 三、配置与更换全局出口

1. 进入管理菜单后，输入数字 `1` 并回车（**更换/设置出口**）。
2. 直接粘贴完整的节点分享链接（如 `vless://...`、`hy2://...`、`ss://...`），按回车确认。
3. 脚本会**自动识别协议类型**、备份旧配置、生成新配置并立即启动全局代理服务。
4. 完成后，可输入数字 `5`（**测试当前出口 IP**）验证 VPS 的公网 IPv4 / IPv6 是否已成功切换为目标节点 IP。

---

## 四、日常管理命令

安装完成后，后续登录 VPS 无需再次运行 `./proxy.sh`，在任意目录下直接输入以下命令即可呼出管理面板：

```bash
out
```

### 菜单功能一览
| 选项 | 功能说明 |
| :--- | :--- |
| **1. 更换/设置出口** | 粘贴新节点链接，自动识别协议并切换全局出口 |
| **2. 开启全局出口** | 启动 `sing-box` 服务并接管全局流量 |
| **3. 关闭全局出口** | 停止代理服务并清理虚拟网卡 `singtun0`，恢复 VPS 原生网络 |
| **4. 查看服务状态** | 查看 `systemd` 或 `OpenRC` 中的进程运行状态 |
| **5. 测试当前出口 IP** | 检测当前生效的 IPv4 与 IPv6 出口地址 |
| **6. 查看当前配置** | 打印 `/etc/sing-box/config.json` 配置文件内容 |
| **7. 查看运行日志** | 查看近期运行日志，方便排查节点连接或握手报错 |
| **8. 退出** | 退出管理菜单（不影响后台正在运行的代理服务） |

---

## 五、相关文件路径

* **核心程序**：`/usr/local/bin/sing-box`
* **快捷命令**：`/usr/local/bin/out`
* **当前配置**：`/etc/sing-box/config.json`
* **历史备份**：`/etc/sing-box/backup/`
* **Alpine 日志**：`/var/log/sing-box.log`（systemd 系统直接使用 `journalctl -u sing-box`）
