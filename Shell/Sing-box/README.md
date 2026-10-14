# Sing-box 多协议服务端配置与节点生成器使用指南

本项目是一个专为 Linux VPS 设计的 **Sing-box 多协议配置与节点生成工具**。
脚本专注于**纯配置生成**，不执行任何软件安装、修改系统防火墙或注册系统服务，导出路径固定为当前运行目录。

---

## 目录
- [核心设计与特性](#核心设计与特性)
- [架构设计与端口分配](#架构设计与端口分配)
- [快速开始](#快速开始)
  - [1. 交互式菜单运行](#1-交互式菜单运行)
  - [2. 命令行/环境变量直接生成](#2-命令行环境变量直接生成)
- [生成产物说明](#生成产物说明)
- [协议说明与客户端配置](#协议说明与客户端配置)

---

## 核心设计与特性

1. **导出路径固定为当前目录**：
   - 所有的生成产物（`config.json`、`hy2_cert.pem`、`hy2_key.pem`、`nodes.txt`、`info.env`）均直接保存在**脚本执行时所在的当前目录**中，绝不向系统其它目录随意写入。
2. **极简两大核心功能**：
   - **功能 1**：生成全新配置文件与节点分享信息（交互式或命令行）；
   - **功能 2**：查看已生成的节点链接与客户端配置（Clash Meta / Mihomo）；
   - **功能 0**：退出。
3. **完全无系统级改动**：
   - 不调用 `apt`/`yum`/`dnf`/`apk` 安装任何软件包；
   - 不修改系统服务、不注入守护进程、不触碰防火墙规则，安装与运维控制权完全在您手中。
4. **安全凭据自给自足**：
   - 优先通过本地已安装的 `sing-box` 生成 Reality 密钥对；若尚未安装，则自动调用 `openssl` 生成合法的 X25519 密钥对、UUID、SS-2022 强密钥以及 10 年期自签证书。

---

## 架构设计与端口分配

脚本采用 **基准端口（`PORT`）+ 偏移量** 的设计理念，充分利用 TCP 与 UDP 独立套接字特性，实现端口极致复用：

| 端口号 | 传输层 | 运行协议 | 核心机制 / 特性 | 推荐使用场景 |
| :--- | :--- | :--- | :--- | :--- |
| **`PORT`** (基础端口) | **TCP** | **VLESS + Reality** | 偷 `www.amd.com` 域名，伪装真实 TLS 1.3，XTLS-Vision 流控 | 晚高峰防封锁主力、日常主力节点 |
| **`PORT`** (基础端口) | **UDP** | **Hysteria 2** | 基于 QUIC / UDP 暴力发包，自签证书，BBR 拥塞控制 | 弱网对抗、游戏加速、超低延迟高清视频 |
| **`PORT + 1`** | **TCP** | **普通 VLESS** | 无 TLS 加密直连协议，仅 UUID 验证 | 国内前置机/中转机端口转发、内网隧道级联 |
| **`PORT + 1`** | **UDP** | **Hysteria 1 (HY1)** | 基于 QUIC，自定义上行/下行速率限制 (口子大小)，抗丢包 | 传统 HY1 客户端兼容、大带宽测速/下载 |
| **`PORT + 2`** | **TCP + UDP** | **Shadowsocks 2022** | `2022-blake3-aes-128-gcm` 规范加密，防重放与主动探测 | 多设备路由器翻墙、高并发请求 |
| **自定义** (默认 `2095`) | **TCP** | **VLESS + WS** | WebSocket 传输协议，支持自定义端口，直接使用本机 IP | 备用穿透协议、多层代理连接 |

---

## 快速开始

### 1. 交互式菜单运行

直接在想要保存配置的目录下运行：

```bash
chmod +x singbox.sh
./singbox.sh
```

菜单仅提供两个功能：
- **`1`**：根据提示输入：
  1. 基础起始端口 `PORT`（默认 `10086`）
  2. Hysteria 1 带宽口子大小（单位 Mbps，默认 `100`，支持输入单个数值如 `200` 或 `上行,下行`）
  3. 是否开启 VLESS + WS 协议（可选自定义端口，默认 `2095`，直接使用本机 IP）
  即刻在当前目录生成全套配置；
- **`2`**：随时重新输出当前目录已生成的节点分享链接与客户端配置片段。

### 2. 命令行/环境变量直接生成

适用于非交互或一句话自动化调用：

```bash
# 示例 1: 基础端口 20000，HY1 口子 200M，直接生成到当前目录
PORT=20000 HY1_SPEED=200 bash singbox.sh -g

# 示例 2: 开启 VLESS+WS 并指定端口为 8080
PORT=18888 HY1_SPEED=100 ENABLE_WS=y WS_PORT=8080 bash singbox.sh -g

# 示例 3: 随时直接查看当前目录下的节点信息
bash singbox.sh -v
```

---

## 生成产物说明

在当前目录下将生成以下 5 个文件：

| 文件名 | 说明 |
| :--- | :--- |
| **`config.json`** | Sing-box 服务端主配置文件，包含所有入站协议配置与证书路径 |
| **`hy2_cert.pem`** | Hysteria 1/2 共用的自签名证书公钥（10年有效期，CN=www.amd.com） |
| **`hy2_key.pem`** | Hysteria 1/2 共用的私钥文件（权限 600） |
| **`nodes.txt`** | 节点分享链接汇总表与 Clash Meta (Mihomo) 客户端配置片段 |
| **`info.env`** | 记录本次生成的 UUID、密钥、端口与带宽参数，供功能 2 查看读取 |

---

## 协议说明与客户端配置

配置生成完成后，节点信息将保存在当前目录下的 `nodes.txt`，控制台也会直接打印：

### 1. VLESS + Reality (TCP `PORT`)
- **协议机制**：复用 `www.amd.com` 的证书完成 TLS 1.3 握手，配合 XTLS-Vision 流控。
- **链接格式**：
  ```text
  vless://<UUID>@<VPS_IP>:<PORT>?security=reality&encryption=none&pbk=<PUBLIC_KEY>&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=www.amd.com&sid=<SHORT_ID>#Singbox-VLESS-Reality
  ```

### 2. Hysteria 2 (UDP `PORT`)
- **协议机制**：基于 UDP/QUIC 协议，抗丢包能力强。
- **客户端注意**：由于采用内置自签证书，客户端**必须开启允许不安全证书 / 跳过证书校验**（`insecure=1` 或 `skip-cert-verify: true`）。
- **链接格式**：
  ```text
  hysteria2://<PASSWORD>@<VPS_IP>:<PORT>/?insecure=1&sni=www.amd.com#Singbox-Hysteria2
  ```

### 3. 普通 VLESS (TCP `PORT + 1`)
- **协议机制**：纯明文 TCP 传输，资源消耗极低，适合前置机/中转机端口转发。
- **链接格式**：
  ```text
  vless://<UUID>@<VPS_IP>:<PORT+1>?encryption=none&security=none&type=tcp#Singbox-VLESS-Plain
  ```

### 4. Hysteria 1 (UDP `PORT + 1`)
- **协议机制**：Hysteria 1 代 QUIC 协议，支持用户自定义口子带宽上限（`upmbps` / `downmbps`）。
- **链接格式**：
  ```text
  hysteria://<VPS_IP>:<PORT+1>?protocol=udp&auth=<AUTH>&upmbps=<UP>&downmbps=<DOWN>&insecure=1&peer=www.amd.com#Singbox-Hysteria1
  ```

### 5. Shadowsocks 2022 (TCP + UDP `PORT + 2`)
- **协议机制**：采用 `2022-blake3-aes-128-gcm` 现代对称加密，彻底解决重放探测问题。
- **链接格式**：
  ```text
  ss://<Base64(method:password)>@<VPS_IP>:<PORT+2>#Singbox-SS-2022
  ```

### 6. VLESS + WS (TCP 自定义端口，默认 `2095`)
- **协议机制**：WebSocket 明文传输协议，直接使用本机公网 IP，端口可自定义（默认 2095）。
- **链接格式**：
  ```text
  vless://<UUID>@<VPS_IP>:<WS_PORT>?encryption=none&security=none&type=ws&host=<VPS_IP>&path=%2F<PATH>#Singbox-VLESS-WS
  ```
