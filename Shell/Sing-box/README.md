# Sing-box 多协议服务端配置与用户管理工具

专用于在当前目录下生成并管理 **Sing-box** 多协议服务端配置 (`config.json`) 及客户端节点分享链接。绿色独立运行，不污染系统服务。

---

## 核心特性

- **多协议集成**：一套脚本整合 Reality、Hysteria 1/2、Shadowsocks 2022 及可选 WebSocket。
- **配置标注与安全校验**：自动添加专属配置标注头；修改配置前后自动调用 `sing-box check` 严格语法校验，出错自动回滚。
- **入站多用户管理**：
  - 支持为指定协议（VLESS Reality、Hysteria 2、普通 VLESS、Hysteria 1、WS）增删用户。
  - **Shadowsocks 2022 多用户**：支持从单用户自动无缝升级为多用户（`ServerKey:UserKey` 模式）。
  - 支持一键为所有协议同步开通通用新用户。
- **客户端一键导入**：查看用户列表时实时生成**可直接导入 v2rayN / Clash.Meta** 的链接，并自动汇总到 `links.txt` 支持批量复制。

---

## 端口与协议规范

| 端口偏移 | 协议 | 传输 / 加密 | 说明 |
| :--- | :--- | :--- | :--- |
| **PORT** (默认 `10086`) | **VLESS** (TCP) | Reality (`www.amd.com`) | 偷大厂 SNI 伪装 |
| **PORT** (默认 `10086`) | **Hysteria 2** (UDP) | 自签 ECC 证书 | 与 Reality 复用基础端口 |
| **PORT + 1** (默认 `10087`) | **VLESS** (TCP) | 无加密直连 | 适用于前置中转落地 |
| **PORT + 1** (默认 `10087`) | **Hysteria 1** (UDP) | 自签 ECC 证书 | 暴力 UDP，支持自定义带宽 |
| **PORT + 2** (默认 `10088`) | **Shadowsocks** (TCP+UDP) | `2022-blake3-aes-128-gcm` | 支持单用户或多用户子密钥 |
| **WS_PORT** (默认 `2095`) | **VLESS + WS** (TCP) | WebSocket (`path` 随机) | 可选开启，适合 CDN 回源 |

---

## 快速使用

### 1. 运行交互式菜单
```bash
chmod +x sing-box.sh
./sing-box.sh
```

### 2. 快捷命令行选项
```bash
./sing-box.sh -l          # 查看所有入站与现有用户列表 (输出可导入 v2rayN 的链接汇总)
./sing-box.sh -u          # 直接进入入站多用户管理向导 (添加/删除/多用户配置)
./sing-box.sh -v          # 查看默认节点配置清单
./sing-box.sh -t          # 为已有配置文件补充添加本脚本专属标注
./sing-box.sh -h          # 查看帮助信息
```

### 3. 非交互式快速生成
可配合环境变量一键自动生成：
```bash
PORT=10086 HY1_SPEED=100 ENABLE_WS=y WS_PORT=2095 ./sing-box.sh -g
```

---

## 生成文件说明

- `config.json`：Sing-box 服务端主配置文件（直接用于 `sing-box run -c config.json`）。
- `links.txt`：当前所有用户的有效节点链接集合，每行一条，**直接全选复制即可在 v2rayN 界面按 `Ctrl+V` 批量导入**。
- `nodes.txt`：详细的节点说明与配置记录文本。
- `info.env`：保存当前服务的各项参数与密钥（供后续增删用户快速复用）。
- `hy_cert.pem` / `hy_key.pem`：Hysteria 协议所用的自签 ECC 证书与密钥文件。
