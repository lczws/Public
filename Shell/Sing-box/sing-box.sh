#!/usr/bin/env bash
# ==============================================================================
# Sing-box 多协议服务端配置文件与节点生成器
# 说明:
#   - 专用于在当前目录下生成 Sing-box 服务端配置 (config.json)、证书密钥及节点分享
#   - 仅保留两个核心功能:
#       1. 生成全新配置文件与节点分享信息
#       2. 查看已生成的节点链接与客户端配置
#   - 导出路径固定为当前运行目录，不进行任何系统服务注册与软件安装
# 端口分配规范:
#   - 基础端口 (PORT):       TCP -> VLESS + Reality (偷 AMD SNI) | UDP -> Hysteria 2
#   - 偏移端口 1 (PORT+1):   TCP -> 普通 VLESS (无加密直连)     | UDP -> Hysteria 1 (HY1)
#   - 偏移端口 2 (PORT+2):   TCP + UDP -> Shadowsocks (2022-blake3-aes-128-gcm)
#   - 可选端口 (默认 2095):  TCP -> VLESS + WS (WebSocket 协议，支持自定义端口)
# ==============================================================================

set -o pipefail

# 终端输出高亮颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
PLAIN='\033[0m'

# 导出路径固定为当前工作目录
CONFIG_DIR="$(pwd)"
CONFIG_FILE="${CONFIG_DIR}/config.json"
INFO_FILE="${CONFIG_DIR}/info.env"
NODES_FILE="${CONFIG_DIR}/nodes.txt"
HY2_CERT="${CONFIG_DIR}/hy2_cert.pem"
HY2_KEY="${CONFIG_DIR}/hy2_key.pem"

# 默认网络与伪装参数
DEFAULT_BASE_PORT=10086
DEFAULT_WS_PORT=2095
DEFAULT_REALITY_DEST="www.amd.com:443"
DEFAULT_REALITY_SNI="www.amd.com"

# 检测基础依赖工具 (curl 与 openssl)
check_dependencies() {
    local missing=()
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v curl >/dev/null 2>&1 || missing+=("curl")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[提示] 检测到系统中缺少以下基础工具: ${missing[*]}${PLAIN}"
        echo -e "建议先安装所需工具以确保密钥与证书能正常生成，例如:"
        echo -e "  - Debian/Ubuntu: ${CYAN}apt-get update && apt-get install -y openssl curl${PLAIN}"
        echo -e "  - CentOS/RHEL:   ${CYAN}dnf install -y openssl curl${PLAIN}"
        echo -e "  - Alpine Linux:  ${CYAN}apk add --no-cache openssl curl bash coreutils${PLAIN}"
        echo ""
    fi
}

# 检测服务器公网 IP 地址 (优先 IPv4，备选 IPv6)
detect_public_ip() {
    SERVER_IP=$(curl -s4m 4 https://api.ipify.org 2>/dev/null || \
                curl -s4m 4 https://icanhazip.com 2>/dev/null || \
                curl -s4m 4 https://ip.sb 2>/dev/null || echo "")
    if [[ -z "$SERVER_IP" ]]; then
        SERVER_IP=$(curl -s6m 4 https://api64.ipify.org 2>/dev/null || \
                    curl -s6m 4 https://icanhazip.com 2>/dev/null || echo "YOUR_SERVER_IP")
    fi
}

# 检测系统中已安装的 sing-box 可执行文件路径
find_singbox_bin() {
    if command -v sing-box >/dev/null 2>&1; then
        command -v sing-box
    elif [[ -x "/usr/bin/sing-box" ]]; then
        echo "/usr/bin/sing-box"
    elif [[ -x "/usr/local/bin/sing-box" ]]; then
        echo "/usr/local/bin/sing-box"
    else
        echo ""
    fi
}

# 生成 UUID (优先通过 sing-box，其次系统 uuid，最后通过 openssl)
generate_uuid() {
    local s_bin
    s_bin=$(find_singbox_bin)
    if [[ -n "$s_bin" ]]; then
        local u
        u=$("$s_bin" generate uuid 2>/dev/null)
        if [[ -n "$u" ]]; then
            echo "$u"
            return
        fi
    fi

    if [[ -f /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return
    fi

    openssl rand -hex 16 | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/'
}

# 生成 Reality X25519 密钥对与 Short ID
generate_reality_keys() {
    local s_bin
    s_bin=$(find_singbox_bin)

    # 1. 优先使用本地已安装的 sing-box 内核生成
    if [[ -n "$s_bin" ]]; then
        local kp
        kp=$("$s_bin" generate reality-keypair 2>/dev/null)
        if [[ -n "$kp" ]]; then
            REALITY_PRIVKEY=$(echo "$kp" | grep -i "PrivateKey" | awk '{print $2}' | tr -d '\r\n')
            REALITY_PUBKEY=$(echo "$kp" | grep -i "PublicKey" | awk '{print $2}' | tr -d '\r\n')
        fi
    fi

    # 2. 若无 sing-box，则调用 openssl 生成标准 X25519 密钥对
    if [[ -z "$REALITY_PRIVKEY" || -z "$REALITY_PUBKEY" ]]; then
        local tmp_key
        tmp_key=$(mktemp 2>/dev/null || echo "/tmp/x25519.$$.key")
        if openssl genpkey -algorithm X25519 -out "$tmp_key" 2>/dev/null; then
            REALITY_PRIVKEY=$(openssl pkey -in "$tmp_key" -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\r\n=')
            REALITY_PUBKEY=$(openssl pkey -in "$tmp_key" -pubout -outform DER 2>/dev/null | tail -c 32 | base64 | tr -d '\r\n=')
        fi
        rm -f "$tmp_key"
    fi

    # 3. 随机生成 8 字节 (16 位十六进制) 的 Short ID
    REALITY_SID=$(head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || openssl rand -hex 8)

    if [[ -z "$REALITY_PRIVKEY" || -z "$REALITY_PUBKEY" ]]; then
        echo -e "${RED}[错误] Reality 密钥对生成失败，请确认系统已安装 openssl 或已安装 sing-box！${PLAIN}"
        exit 1
    fi
}

# 生成 Hysteria 1 / 2 凭据与 10 年期自签名证书
generate_hy_credentials() {
    # Hysteria 2 独立密码
    HY2_PASS=$(openssl rand -base64 16 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)

    # Hysteria 1 独立密码 (auth_str)
    HY1_AUTH=$(openssl rand -base64 16 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ -z "$HY1_AUTH" ]] && HY1_AUTH=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)

    # 优先生成高效 ECC (prime256v1) 证书，不支持时回退为 RSA 2048
    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -days 3650 -subj "/CN=${REALITY_SNI}" >/dev/null 2>&1 || \
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -days 3650 -subj "/CN=${REALITY_SNI}" >/dev/null 2>&1

    chmod 644 "$HY2_CERT" 2>/dev/null || true
    chmod 600 "$HY2_KEY" 2>/dev/null || true
}

# 功能 1: 生成全新配置文件与节点分享信息
generate_all_configurations() {
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${WHITE}           Sing-box 服务端配置生成向导              ${PLAIN}"
    echo -e "${WHITE}     导出路径: ${GREEN}${CONFIG_DIR}${WHITE} (当前目录)       ${PLAIN}"
    echo -e "${PURPLE}====================================================${PLAIN}"

    # 1. 基础起始端口设置
    if [[ -n "$PORT" ]]; then
        BASE_PORT="$PORT"
        echo -e " 基础端口 PORT (环境变量指定): ${GREEN}${BASE_PORT}${PLAIN}"
    else
        echo -e " 请输入基础起始端口 PORT (范围 1024 - 65530)"
        echo -e " 端口分配方案:"
        echo -e "   - 端口 1 (${CYAN}PORT${PLAIN}):     TCP -> VLESS + Reality (偷AMD) | UDP -> Hysteria 2"
        echo -e "   - 端口 2 (${CYAN}PORT + 1${PLAIN}): TCP -> 普通 VLESS (直连/中转)  | UDP -> Hysteria 1 (HY1)"
        echo -e "   - 端口 3 (${CYAN}PORT + 2${PLAIN}): TCP + UDP -> Shadowsocks 2022"
        read -r -p " [默认: ${DEFAULT_BASE_PORT}]: " input_port
        BASE_PORT="${input_port:-$DEFAULT_BASE_PORT}"
    fi

    if ! [[ "$BASE_PORT" =~ ^[0-9]+$ ]] || [ "$BASE_PORT" -lt 1024 ] || [ "$BASE_PORT" -gt 65530 ]; then
        echo -e "${RED}[错误] 端口号必须是 1024 到 65530 之间的数字！${PLAIN}"
        exit 1
    fi

    PORT_REALITY_HY2="$BASE_PORT"
    PORT_PLAIN_HY1=$((BASE_PORT + 1))
    PORT_SS=$((BASE_PORT + 2))

    # 2. Hysteria 1 (HY1) 带宽口子大小配置
    if [[ -n "$HY1_SPEED" ]]; then
        HY1_UP_MBPS="$HY1_SPEED"
        HY1_DOWN_MBPS="$HY1_SPEED"
        echo -e "\n Hysteria 1 口子大小 (环境变量指定): ${GREEN}${HY1_SPEED} Mbps${PLAIN}"
    elif [[ -n "$HY1_UP_MBPS" && -n "$HY1_DOWN_MBPS" ]]; then
        echo -e "\n Hysteria 1 口子大小 (环境变量指定): 上行 ${GREEN}${HY1_UP_MBPS} Mbps${PLAIN}, 下行 ${GREEN}${HY1_DOWN_MBPS} Mbps${PLAIN}"
    else
        echo -e "\n 请输入 Hysteria 1 (HY1) 的带宽口子大小 (单位: Mbps)"
        echo -e " 提示: 输入单个数字 (如 100) 表示上下行均为该带宽，也可输入 '上行,下行' (如 50,200)"
        read -r -p " [默认: 100]: " input_hy1_speed
        input_hy1_speed="${input_hy1_speed:-100}"
        local cleaned_speed="${input_hy1_speed//[\/ ]/,}"
        if [[ "$cleaned_speed" == *","* ]]; then
            local up_part="${cleaned_speed%%,*}"
            local down_part="${cleaned_speed##*,}"
            if [[ "$up_part" =~ ^[0-9]+$ && "$down_part" =~ ^[0-9]+$ && "$up_part" -gt 0 && "$down_part" -gt 0 ]]; then
                HY1_UP_MBPS="$up_part"
                HY1_DOWN_MBPS="$down_part"
            else
                echo -e "${YELLOW}[!] 输入数值不合法，默认设为 100 Mbps${PLAIN}"
                HY1_UP_MBPS=100
                HY1_DOWN_MBPS=100
            fi
        elif [[ "$input_hy1_speed" =~ ^[0-9]+$ && "$input_hy1_speed" -gt 0 ]]; then
            HY1_UP_MBPS="$input_hy1_speed"
            HY1_DOWN_MBPS="$input_hy1_speed"
        else
            echo -e "${YELLOW}[!] 输入不合规范，默认设为 100 Mbps${PLAIN}"
            HY1_UP_MBPS=100
            HY1_DOWN_MBPS=100
        fi
    fi

    # 3. VLESS + WS (WebSocket) 选项与自定义端口
    if [[ -n "$ENABLE_WS" || -n "$ENABLE_CF_WS" ]]; then
        INPUT_ENABLE_WS="${ENABLE_WS:-$ENABLE_CF_WS}"
        echo -e "\n 是否启用 VLESS + WS (环境变量指定): ${GREEN}${INPUT_ENABLE_WS}${PLAIN}"
    else
        echo -e "\n 是否开启 VLESS + WS (WebSocket 协议)？"
        read -r -p " 请选择 [y/N，默认: N]: " input_ws
        INPUT_ENABLE_WS="${input_ws:-N}"
    fi

    if [[ "$INPUT_ENABLE_WS" =~ ^[Yy]$ ]]; then
        USE_WS=true
        if [[ -n "$WS_PORT" || -n "$PORT_WS" ]]; then
            PORT_WS="${WS_PORT:-$PORT_WS}"
            echo -e " VLESS + WS 监听端口 (环境变量指定): ${GREEN}${PORT_WS}${PLAIN}"
        else
            echo -e " 请输入 VLESS + WS 监听端口 (范围 1 - 65535)"
            read -r -p " [默认: ${DEFAULT_WS_PORT}]: " input_ws_port
            PORT_WS="${input_ws_port:-$DEFAULT_WS_PORT}"
        fi

        if ! [[ "$PORT_WS" =~ ^[0-9]+$ ]] || [ "$PORT_WS" -lt 1 ] || [ "$PORT_WS" -gt 65535 ]; then
            echo -e "${YELLOW}[!] 端口输入不合规范，采用默认值: ${DEFAULT_WS_PORT}${PLAIN}"
            PORT_WS="$DEFAULT_WS_PORT"
        fi

        WS_PATH="vless-ws-$(head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n' 2>/dev/null || openssl rand -hex 4)"
    else
        USE_WS=false
        PORT_WS="$DEFAULT_WS_PORT"
        WS_PATH=""
    fi

    REALITY_DEST="${DEFAULT_REALITY_DEST}"
    REALITY_SNI="${DEFAULT_REALITY_SNI}"

    # 生成各协议凭据与自签名证书
    echo -e "\n${CYAN}[+] 正在自动生成安全密钥与证书...${PLAIN}"
    UUID=$(generate_uuid)
    generate_reality_keys
    generate_hy_credentials
    SS_PASSWORD=$(openssl rand -base64 16 2>/dev/null || head -c 16 /dev/urandom | base64)

    # 组装 config.json
    echo -e "${CYAN}[+] 正在组装 Sing-box 配置文件 (${CONFIG_FILE})...${PLAIN}"

    local ws_inbound=""
    if [[ "$USE_WS" = true ]]; then
        ws_inbound=$(cat <<EOF
    ,{
      "type": "vless",
      "tag": "vless-ws-in",
      "listen": "::",
      "listen_port": ${PORT_WS},
      "users": [
        {
          "name": "ws-user",
          "uuid": "${UUID}"
        }
      ],
      "transport": {
        "type": "ws",
        "path": "/${WS_PATH}",
        "max_early_data": 2048,
        "early_data_header_name": "Sec-WebSocket-Protocol"
      }
    }
EOF
)
    fi

    cat <<EOF > "$CONFIG_FILE"
{
  "log": {
    "disabled": false,
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "::",
      "listen_port": ${PORT_REALITY_HY2},
      "users": [
        {
          "name": "reality-user",
          "uuid": "${UUID}",
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SNI}",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "${REALITY_SNI}",
            "server_port": 443
          },
          "private_key": "${REALITY_PRIVKEY}",
          "short_id": [
            "${REALITY_SID}"
          ]
        }
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": ${PORT_REALITY_HY2},
      "users": [
        {
          "name": "hy2-user",
          "password": "${HY2_PASS}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${HY2_CERT}",
        "key_path": "${HY2_KEY}"
      }
    },
    {
      "type": "vless",
      "tag": "vless-plain-in",
      "listen": "::",
      "listen_port": ${PORT_PLAIN_HY1},
      "users": [
        {
          "name": "plain-user",
          "uuid": "${UUID}"
        }
      ]
    },
    {
      "type": "hysteria",
      "tag": "hy1-in",
      "listen": "::",
      "listen_port": ${PORT_PLAIN_HY1},
      "up_mbps": ${HY1_UP_MBPS},
      "down_mbps": ${HY1_DOWN_MBPS},
      "users": [
        {
          "name": "hy1-user",
          "auth_str": "${HY1_AUTH}"
        }
      ],
      "tls": {
        "enabled": true,
        "certificate_path": "${HY2_CERT}",
        "key_path": "${HY2_KEY}"
      }
    },
    {
      "type": "shadowsocks",
      "tag": "ss-in",
      "listen": "::",
      "listen_port": ${PORT_SS},
      "method": "2022-blake3-aes-128-gcm",
      "password": "${SS_PASSWORD}"
    }${ws_inbound}
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    },
    {
      "type": "block",
      "tag": "block"
    }
  ],
  "route": {
    "rules": [
      {
        "outbound": "direct"
      }
    ]
  }
}
EOF

    # 保存环境参数到 info.env 便于查询复用
    cat <<EOF > "$INFO_FILE"
CONFIG_DIR="${CONFIG_DIR}"
PORT_REALITY_HY2="${PORT_REALITY_HY2}"
PORT_PLAIN_HY1="${PORT_PLAIN_HY1}"
PORT_SS="${PORT_SS}"
PORT_WS="${PORT_WS}"
USE_WS="${USE_WS}"
WS_PATH="${WS_PATH}"
HY1_UP_MBPS="${HY1_UP_MBPS}"
HY1_DOWN_MBPS="${HY1_DOWN_MBPS}"
HY1_AUTH="${HY1_AUTH}"
UUID="${UUID}"
REALITY_PRIVKEY="${REALITY_PRIVKEY}"
REALITY_PUBKEY="${REALITY_PUBKEY}"
REALITY_SID="${REALITY_SID}"
REALITY_SNI="${REALITY_SNI}"
HY2_PASS="${HY2_PASS}"
SS_PASSWORD="${SS_PASSWORD}"
EOF

    # 生成节点分享链接与客户端配置片段并输出
    generate_and_display_nodes
}

# 功能 2: 查看已生成的节点链接与客户端配置
generate_and_display_nodes() {
    if [[ ! -f "$INFO_FILE" ]]; then
        echo -e "${RED}[错误] 当前目录下未找到配置记录 (info.env)，请先执行功能 1 生成配置！${PLAIN}"
        return 1
    fi

    # shellcheck disable=SC1090
    source "$INFO_FILE"
    detect_public_ip

    local host_ip="${SERVER_IP:-YOUR_SERVER_IP}"
    USE_WS="${USE_WS:-$USE_CF_WS}"
    PORT_WS="${PORT_WS:-${PORT_CF_WS:-$DEFAULT_WS_PORT}}"

    # 1. VLESS + Reality 链接 (TCP PORT)
    local vless_reality_link="vless://${UUID}@${host_ip}:${PORT_REALITY_HY2}?security=reality&encryption=none&pbk=${REALITY_PUBKEY}&headerType=none&fp=chrome&spx=%2F&type=tcp&flow=xtls-rprx-vision&sni=${REALITY_SNI}&sid=${REALITY_SID}#Reality"

    # 2. Hysteria 2 链接 (UDP PORT)
    local hy2_link="hysteria2://${HY2_PASS}@${host_ip}:${PORT_REALITY_HY2}/?insecure=1&sni=${REALITY_SNI}#Hysteria2"

    # 3. 普通 VLESS 直连链接 (TCP PORT+1)
    local vless_plain_link="vless://${UUID}@${host_ip}:${PORT_PLAIN_HY1}?encryption=none&security=none&type=tcp#Vless"

    # 4. Hysteria 1 链接 (UDP PORT+1)
    local hy1_link="hysteria://${host_ip}:${PORT_PLAIN_HY1}?protocol=udp&auth=${HY1_AUTH}&upmbps=${HY1_UP_MBPS}&downmbps=${HY1_DOWN_MBPS}&insecure=1&peer=${REALITY_SNI}#Hysteria1"

    # 5. Shadowsocks 2022 链接 (TCP+UDP PORT+2)
    local ss_raw="2022-blake3-aes-128-gcm:${SS_PASSWORD}"
    local ss_encoded
    ss_encoded=$(printf "%s" "$ss_raw" | base64 | tr -d '\n')
    local ss_link="ss://${ss_encoded}@${host_ip}:${PORT_SS}#SS"

    # 6. VLESS + WS 链接 (直接使用本机 IP 与指定端口)
    local vless_ws_link=""
    if [[ "$USE_WS" = "true" ]]; then
        vless_ws_link="vless://${UUID}@${host_ip}:${PORT_WS}?encryption=none&security=none&type=ws&host=${host_ip}&path=%2F${WS_PATH}#Vless-WS"
    fi

    # 写入 nodes.txt
    cat <<EOF > "$NODES_FILE"
================================================================================
                    Sing-box 节点配置与分享链接信息
================================================================================
配置文件位置: ${CONFIG_FILE}
服务器公网 IP: ${host_ip}
用户通用 UUID: ${UUID}

[1] VLESS + Reality (偷 AMD 域名, TCP 端口 ${PORT_REALITY_HY2}):
--------------------------------------------------------------------------------
${vless_reality_link}

[2] Hysteria 2 (UDP 端口 ${PORT_REALITY_HY2}, 与 Reality 共用端口):
--------------------------------------------------------------------------------
${hy2_link}

[3] 普通 VLESS (TCP 端口 ${PORT_PLAIN_HY1}, 无加密直连/中转):
--------------------------------------------------------------------------------
${vless_plain_link}

[4] Hysteria 1 (UDP 端口 ${PORT_PLAIN_HY1}, 口子: 上行 ${HY1_UP_MBPS}M / 下行 ${HY1_DOWN_MBPS}M):
--------------------------------------------------------------------------------
${hy1_link}
认证密码 (auth): ${HY1_AUTH}

[5] Shadowsocks (SS 2022, 端口 ${PORT_SS}, TCP + UDP):
--------------------------------------------------------------------------------
${ss_link}
加密方式: 2022-blake3-aes-128-gcm
密  钥: ${SS_PASSWORD}
EOF

    if [[ "$USE_WS" = "true" ]]; then
        cat <<EOF >> "$NODES_FILE"

[6] VLESS + WS (TCP 端口 ${PORT_WS}, WebSocket 模式):
--------------------------------------------------------------------------------
${vless_ws_link}
Path: /${WS_PATH}
Host: ${host_ip}
EOF
    fi

    # 终端打印展示
    echo -e "\n${GREEN}====================================================================${PLAIN}"
    echo -e "${WHITE}                 Sing-box 节点配置与分享链接清单                     ${PLAIN}"
    echo -e "${GREEN}====================================================================${PLAIN}"
    echo -e " 配置文件: ${GREEN}${CONFIG_FILE}${PLAIN}"
    echo -e " 节点清单保存至: ${WHITE}${NODES_FILE}${PLAIN}"
    echo -e " 服务器 IP: ${CYAN}${host_ip}${PLAIN} | 客户端 UUID: ${YELLOW}${UUID}${PLAIN}\n"

    echo -e "${CYAN}--- [节点 1] VLESS + Reality (TCP ${PORT_REALITY_HY2} 端口, 偷 ${REALITY_SNI}) ---${PLAIN}"
    echo -e "${WHITE}${vless_reality_link}${PLAIN}\n"

    echo -e "${CYAN}--- [节点 2] Hysteria 2 (UDP ${PORT_REALITY_HY2} 端口, 与 Reality 复用端口) ---${PLAIN}"
    echo -e "${WHITE}${hy2_link}${PLAIN}\n"

    echo -e "${CYAN}--- [节点 3] 普通 VLESS (TCP ${PORT_PLAIN_HY1} 端口, 直连/中转) ---${PLAIN}"
    echo -e "${WHITE}${vless_plain_link}${PLAIN}\n"

    echo -e "${CYAN}--- [节点 4] Hysteria 1 (UDP ${PORT_PLAIN_HY1} 端口, 口子 ${HY1_UP_MBPS}M/${HY1_DOWN_MBPS}M) ---${PLAIN}"
    echo -e "${WHITE}${hy1_link}${PLAIN}\n"

    echo -e "${CYAN}--- [节点 5] Shadowsocks 2022 (TCP+UDP ${PORT_SS} 端口) ---${PLAIN}"
    echo -e "${WHITE}${ss_link}${PLAIN}\n"

    if [[ "$USE_WS" = "true" ]]; then
        echo -e "${PURPLE}--- [节点 6] VLESS + WS (TCP ${PORT_WS} 端口, WebSocket) ---${PLAIN}"
        echo -e "${WHITE}${vless_ws_link}${PLAIN}\n"
    fi

    echo -e "${PURPLE}====================================================================${PLAIN}"
    echo -e "${WHITE}           Clash Meta (Mihomo) 客户端配置参考片段                    ${PLAIN}"
    echo -e "${PURPLE}====================================================================${PLAIN}"
    cat <<EOF
proxies:
  - name: "Reality"
    type: vless
    server: ${host_ip}
    port: ${PORT_REALITY_HY2}
    uuid: ${UUID}
    network: tcp
    udp: true
    tls: true
    flow: xtls-rprx-vision
    servername: ${REALITY_SNI}
    reality-opts:
      public-key: ${REALITY_PUBKEY}
      short-id: ${REALITY_SID}
    client-fingerprint: chrome

  - name: "Hysteria2"
    type: hysteria2
    server: ${host_ip}
    port: ${PORT_REALITY_HY2}
    password: "${HY2_PASS}"
    sni: ${REALITY_SNI}
    skip-cert-verify: true

  - name: "Vless"
    type: vless
    server: ${host_ip}
    port: ${PORT_PLAIN_HY1}
    uuid: ${UUID}
    network: tcp
    udp: true

  - name: "Hysteria1"
    type: hysteria
    server: ${host_ip}
    port: ${PORT_PLAIN_HY1}
    auth_str: "${HY1_AUTH}"
    up: "${HY1_UP_MBPS} Mbps"
    down: "${HY1_DOWN_MBPS} Mbps"
    sni: ${REALITY_SNI}
    skip-cert-verify: true

  - name: "Shadowsocks"
    type: ss
    server: ${host_ip}
    port: ${PORT_SS}
    cipher: 2022-blake3-aes-128-gcm
    password: "${SS_PASSWORD}"
    udp: true
EOF

    if [[ "$USE_WS" = "true" ]]; then
        cat <<EOF

  - name: "Vless-WS"
    type: vless
    server: ${host_ip}
    port: ${PORT_WS}
    uuid: ${UUID}
    network: ws
    udp: true
    ws-opts:
      path: "/${WS_PATH}"
      headers:
        Host: ${host_ip}
EOF
    fi
    echo -e "${GREEN}====================================================================${PLAIN}\n"
}

# 交互式管理菜单
show_menu() {
    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${WHITE}       Sing-box 多协议配置文件生成与管理工具        ${PLAIN}"
    echo -e "${WHITE}  导出路径: ${CYAN}${CONFIG_DIR}${PLAIN} (当前目录)"
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 生成全新配置文件与节点分享信息"
    echo -e " ${GREEN}2.${PLAIN} 查看已生成的节点链接与客户端配置"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e "${PURPLE}====================================================${PLAIN}"

    read -r -p " 请输入选项 [0-2]: " choice
    case "$choice" in
        1)
            generate_all_configurations
            ;;
        2)
            generate_and_display_nodes
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}[错误] 输入无效，请输入数字 0-2！${PLAIN}"
            ;;
    esac
}

# 命令行帮助信息
show_help() {
    cat <<EOF
Sing-box 多协议配置文件生成器

说明:
  文件将直接生成在当前运行目录下 (包括 config.json, hy2_cert.pem, hy2_key.pem, nodes.txt)。

用法:
  $0 [选项]

选项:
  -g, --generate       直接执行配置生成 (可配合环境变量)
  -v, --view           查看已生成的节点信息与客户端配置
  -h, --help           显示此帮助信息

支持的环境变量 (适用于非交互式脚本生成):
  PORT                 基础起始端口号 (默认: 10086)
  HY1_SPEED            Hysteria 1 上下行带宽口子大小 (如: 100, 200, 500)
  HY1_UP_MBPS          Hysteria 1 上行带宽限制 (如: 50)
  HY1_DOWN_MBPS        Hysteria 1 下行带宽限制 (如: 200)
  ENABLE_WS            是否开启 VLESS + WS (y 或 n)
  WS_PORT              VLESS + WS 端口号 (默认: 2095)

示例:
  # 交互式运行
  ./singbox.sh

  # 非交互式指定端口生成
  PORT=20000 HY1_SPEED=200 ENABLE_WS=y WS_PORT=8080 bash singbox.sh -g
EOF
}

# 主程序入口
main() {
    check_dependencies

    case "$1" in
        -g|--generate)
            generate_all_configurations
            ;;
        -v|--view)
            generate_and_display_nodes
            ;;
        -h|--help)
            show_help
            ;;
        "")
            if [[ -n "$PORT" ]]; then
                generate_all_configurations
            else
                show_menu
            fi
            ;;
        *)
            echo -e "${RED}[错误] 未知参数: $1${PLAIN}"
            show_help
            exit 1
            ;;
    esac
}

main "$@"
