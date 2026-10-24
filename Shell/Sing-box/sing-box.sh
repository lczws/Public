#!/usr/bin/env bash
# ==============================================================================
# Sing-box 多协议服务端配置文件与用户管理工具
# 说明:
#   - 专用于在当前目录下生成与管理 Sing-box 服务端配置 (config.json) 及节点分享
#   - 核心功能:
#       1. 生成全新配置文件与节点分享信息 (带有专属生成标注注释)
#       2. 查看已生成的默认节点分享链接
#       3. 入站用户管理:
#          - 识别配置文件是否为本工具生成 (专属生成标注检测)
#          - 为指定入站添加用户 (例如: 给 Reality 增加 user 和 uuid)
#          - 为所有协议一键同步添加通用用户
#          - 自由删除指定入站的用户 (带安全保护与防误删提示)
#          - 自动生成并导出新增用户的专属客户端节点分享链接
#   - 导出路径固定为当前运行目录，不进行任何系统服务注册与软件安装
# 端口分配规范:
#   - 基础端口 (PORT):       TCP -> VLESS + Reality (偷 AMD SNI) | UDP -> Hysteria 2
#   - 偏移端口 1 (PORT+1):   TCP -> 普通 VLESS (无加密直连)      | UDP -> Hysteria 1 (HY1)
#   - 偏移端口 2 (PORT+2):   TCP + UDP -> Shadowsocks (2022-blake3-aes-128-gcm)
#   - 可选端口 (默认 2095):  TCP -> VLESS + WS (WebSocket 协议，支持自定义端口)
# ==============================================================================

set -o pipefail

# 脚本与配置版本
GENERATOR_TAG="SING-BOX.SH"
GENERATOR_VER="1.1.0"

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
HY2_CERT="${CONFIG_DIR}/hy_cert.pem"
HY2_KEY="${CONFIG_DIR}/hy_key.pem"

# 默认网络与伪装参数
DEFAULT_BASE_PORT=10086
DEFAULT_WS_PORT=2095
DEFAULT_REALITY_DEST="www.amd.com:443"
DEFAULT_REALITY_SNI="www.amd.com"

# 检测基础依赖工具 (curl, openssl, python3)
check_dependencies() {
    local missing=()
    command -v openssl >/dev/null 2>&1 || missing+=("openssl")
    command -v curl >/dev/null 2>&1 || missing+=("curl")
    command -v python3 >/dev/null 2>&1 || missing+=("python3")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${YELLOW}[提示] 检测到系统中缺少以下基础工具: ${missing[*]}${PLAIN}"
        echo -e "建议先安装所需工具以确保配置生成与用户管理正常运行，例如:"
        echo -e "  - Debian/Ubuntu: ${CYAN}apt-get update && apt-get install -y openssl curl python3${PLAIN}"
        echo -e "  - CentOS/RHEL:   ${CYAN}dnf install -y openssl curl python3${PLAIN}"
        echo -e "  - Alpine Linux:  ${CYAN}apk add --no-cache openssl curl python3 bash coreutils${PLAIN}"
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

# 验证生成的/修改后的配置文件合法性
validate_config_with_singbox() {
    local s_bin
    s_bin=$(find_singbox_bin)
    if [[ -n "$s_bin" && -f "$CONFIG_FILE" ]]; then
        local check_output
        check_output=$("$s_bin" check -c "$CONFIG_FILE" 2>&1)
        if [[ $? -ne 0 ]]; then
            echo -e "${RED}[错误] sing-box 配置校验失败:${PLAIN}\n${check_output}"
            return 1
        fi
    fi
    return 0
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
    HY2_PASS=$(openssl rand -base64 16 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)

    HY1_AUTH=$(openssl rand -base64 16 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ -z "$HY1_AUTH" ]] && HY1_AUTH=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)

    openssl req -x509 -nodes -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -days 3650 -subj "/CN=localhost" >/dev/null 2>&1 || \
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout "$HY2_KEY" -out "$HY2_CERT" \
        -days 3650 -subj "/CN=localhost" >/dev/null 2>&1

    chmod 644 "$HY2_CERT" 2>/dev/null || true
    chmod 600 "$HY2_KEY" 2>/dev/null || true
}

# ==============================================================================
# 配置文件状态与专属生成标注检测
# ==============================================================================

# 获取当前配置状态: MISSING | CORRUPTED | GENERATED | LEGACY | CUSTOM
get_config_status() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "MISSING"
        return
    fi

    # 检查第一部分是否包含本脚本专属标注
    if grep -q "GENERATED BY SING-BOX.SH" "$CONFIG_FILE" 2>/dev/null; then
        echo "GENERATED"
        return
    fi

    if [[ -f "$INFO_FILE" ]]; then
        echo "LEGACY"
        return
    fi

    if command -v python3 >/dev/null 2>&1; then
        python3 -c '
import sys, re, json

cfg = sys.argv[1]
try:
    with open(cfg, "r", encoding="utf-8") as f:
        c = f.read()
    clean = re.sub(r"^\s*//.*$", "", c, flags=re.MULTILINE)
    data = json.loads(clean)
    tags = [ib.get("tag", "") for ib in data.get("inbounds", []) if isinstance(ib, dict)]
    if "vless-reality-in" in tags:
        print("LEGACY")
    else:
        print("CUSTOM")
except Exception:
    print("CORRUPTED")
' "$CONFIG_FILE" 2>/dev/null || echo "CUSTOM"
    else
        if grep -q '"vless-reality-in"' "$CONFIG_FILE" 2>/dev/null; then
            echo "LEGACY"
        else
            echo "CUSTOM"
        fi
    fi
}

# 格式化展示配置文件状态文字
format_config_status_label() {
    local st
    st=$(get_config_status)
    case "$st" in
        GENERATED)
            echo -e "${GREEN}● 已生成 (本工具专属配置，已标注)${PLAIN}"
            ;;
        LEGACY)
            echo -e "${YELLOW}● 已生成 (旧版本配置，未标注，建议升级标注)${PLAIN}"
            ;;
        CUSTOM)
            echo -e "${BLUE}● 存在配置 (非本工具生成或第三方配置，未标注)${PLAIN}"
            ;;
        CORRUPTED)
            echo -e "${RED}● 配置文件格式异常 (JSON 解析错误)${PLAIN}"
            ;;
        MISSING|*)
            echo -e "${WHITE}○ 未生成 (当前目录下未找到 config.json)${PLAIN}"
            ;;
    esac
}

# 为现有配置文件添加本工具专属标注注释
tag_existing_config() {
    local st
    st=$(get_config_status)
    if [[ "$st" == "MISSING" ]]; then
        echo -e "${RED}[错误] 当前目录下不存在 config.json，无法添加标注！${PLAIN}"
        return 1
    fi
    if [[ "$st" == "CORRUPTED" ]]; then
        echo -e "${RED}[错误] 当前 config.json 存在格式错误，无法解析！${PLAIN}"
        return 1
    fi

    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

    local current_time
    current_time=$(date '+%Y-%m-%d %H:%M:%S')

    local res
    res=$(python3 -c '
import sys, re, json

cfg = sys.argv[1]
ver = sys.argv[2]
t = sys.argv[3]

try:
    with open(cfg, "r", encoding="utf-8") as f:
        c = f.read()
    clean = re.sub(r"^\s*//.*$", "", c, flags=re.MULTILINE)
    data = json.loads(clean)

    # 清除旧的未知属性避免 sing-box 报错
    data.pop("_generator", None)
    data.pop("_generator_version", None)
    data.pop("_created_at", None)
    if "log" in data and isinstance(data["log"], dict):
        data["log"].pop("_generator", None)
        data["log"].pop("_generator_version", None)
        data["log"].pop("_created_at", None)

    header = (
        "// ==============================================================================\n"
        "// [GENERATED BY SING-BOX.SH] - Sing-box 多协议服务端配置文件\n"
        f"// 标注时间: {t} | 工具版本: {ver}\n"
        "// ==============================================================================\n"
    )

    with open(cfg, "w", encoding="utf-8") as f:
        f.write(header)
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print("SUCCESS")
except Exception as e:
    print(f"ERROR: {e}")
    sys.exit(1)
' "$CONFIG_FILE" "$GENERATOR_VER" "$current_time" 2>&1)

    if [[ "$res" == "SUCCESS" ]]; then
        if validate_config_with_singbox; then
            echo -e "${GREEN}[成功] 已为配置文件添加专属标注注释 (版本: ${GENERATOR_VER})！${PLAIN}"
            rm -f "${CONFIG_FILE}.bak"
            return 0
        else
            mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
            echo -e "${RED}[错误] 添加标注后校验失败，已自动回滚！${PLAIN}"
            return 1
        fi
    else
        echo -e "${RED}[错误] 添加标注失败: ${res}${PLAIN}"
        [[ -f "${CONFIG_FILE}.bak" ]] && mv "${CONFIG_FILE}.bak" "$CONFIG_FILE"
        return 1
    fi
}

# ==============================================================================
# 功能 1: 生成全新配置文件与节点分享信息
# ==============================================================================

generate_all_configurations() {
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${WHITE}            Sing-box 服务端配置生成向导             ${PLAIN}"
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

    # 组装 config.json (包含专属生成标注注释)
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

    local current_time
    current_time=$(date '+%Y-%m-%d %H:%M:%S')

    cat <<EOF > "$CONFIG_FILE"
// ==============================================================================
// [GENERATED BY SING-BOX.SH] - Sing-box 多协议服务端配置文件
// 生成时间: ${current_time} | 脚本版本: ${GENERATOR_VER}
// ==============================================================================
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
GENERATOR="${GENERATOR_TAG}"
GENERATOR_VERSION="${GENERATOR_VER}"
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

    validate_config_with_singbox

    # 生成节点分享链接并输出
    generate_and_display_nodes
}

# ==============================================================================
# 功能 2: 查看已生成的节点分享链接
# ==============================================================================

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
    local hy2_link="hysteria2://${HY2_PASS}@${host_ip}:${PORT_REALITY_HY2}/?insecure=1#Hysteria2"

    # 3. 普通 VLESS 直连链接 (TCP PORT+1)
    local vless_plain_link="vless://${UUID}@${host_ip}:${PORT_PLAIN_HY1}?encryption=none&security=none&type=tcp#Vless"

    # 4. Hysteria 1 链接 (UDP PORT+1)
    local hy1_link="hysteria://${host_ip}:${PORT_PLAIN_HY1}?protocol=udp&auth=${HY1_AUTH}&upmbps=${HY1_UP_MBPS}&downmbps=${HY1_DOWN_MBPS}&insecure=1#Hysteria1"

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
密    钥: ${SS_PASSWORD}
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
    echo -e "${GREEN}====================================================================${PLAIN}\n"
}

# ==============================================================================
# 功能 3: 入站用户管理核心逻辑 (增、删、查、导出链接)
# ==============================================================================

# 全部用户的节点链接导出文件 (每行一条，可整体复制导入 v2rayN)
LINKS_FILE="${CONFIG_DIR}/links.txt"

# 内嵌 Python 助手: 统一负责 config.json 的读取、修改、写回与分享链接生成
# 用法: sb_py <命令> [参数...]
sb_py() {
    python3 - "$CONFIG_FILE" "$GENERATOR_VER" "$@" <<'PYEOF'
import sys, re, json, os, base64, datetime, uuid as uuidlib
from urllib.parse import quote

CFG, VER, CMD = sys.argv[1], sys.argv[2], sys.argv[3]
ARGS = sys.argv[4:]

Y = "\033[1;33m"; G = "\033[0;32m"; C = "\033[0;36m"; W = "\033[1;37m"; P = "\033[0;35m"; N = "\033[0m"


def die(msg):
    print(f"ERROR: {msg}")
    sys.exit(1)


def load():
    try:
        with open(CFG, "r", encoding="utf-8") as f:
            content = f.read()
        return json.loads(re.sub(r"^\s*//.*$", "", content, flags=re.MULTILINE))
    except Exception as e:
        die(f"读取配置失败: {e}")


def save(data):
    t = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    line = "// " + "=" * 78 + "\n"
    header = (line
              + "// [GENERATED BY SING-BOX.SH] - Sing-box 多协议服务端配置文件\n"
              + f"// 更新时间: {t} | 工具版本: {VER}\n"
              + line)
    tmp = CFG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(header)
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, CFG)


def inbounds(data):
    return [ib for ib in data.get("inbounds", []) if isinstance(ib, dict)]


def find(data, tag):
    for ib in inbounds(data):
        if ib.get("tag") == tag:
            return ib
    die(f"未找到入站 \"{tag}\"")


def users_of(ib):
    u = ib.get("users")
    return u if isinstance(u, list) else None


def is_ss(ib):
    return ib.get("type") == "shadowsocks"


def is_ss2022(ib):
    return is_ss(ib) and str(ib.get("method", "")).startswith("2022-")


def ss_keylen(ib):
    return 16 if "aes-128" in str(ib.get("method", "")) else 32


def is_reality(ib):
    tls = ib.get("tls")
    if not isinstance(tls, dict):
        return False
    r = tls.get("reality")
    return isinstance(r, dict) and bool(r.get("enabled", False))


def is_ws(ib):
    tr = ib.get("transport")
    return isinstance(tr, dict) and tr.get("type") == "ws"


def manageable(ib):
    return ib.get("type") in ("vless", "hysteria", "hysteria2") or is_ss2022(ib)


def cred_of(ib, u):
    t = ib.get("type")
    if t == "vless":
        return u.get("uuid", "")
    if t == "hysteria":
        return u.get("auth_str", "")
    return u.get("password", "")


def genkey(n):
    return base64.b64encode(os.urandom(n)).decode()


def label_of(ib):
    t = ib.get("type")
    if t == "vless":
        if is_reality(ib):
            return "Reality"
        if is_ws(ib):
            return "Vless-WS"
        return "Vless"
    return {"hysteria2": "Hysteria2", "hysteria": "Hysteria1", "shadowsocks": "SS"}.get(t, t or "Node")


def fmt_host(h):
    return f"[{h}]" if ":" in h and not h.startswith("[") else h


def make_link(ib, name, cred, host, pbk, flow=None):
    t = ib.get("type")
    port = ib.get("listen_port", "")
    h = fmt_host(host)
    remark = quote(f"{label_of(ib)}-{name}", safe="")
    if t == "vless":
        if is_reality(ib):
            tls = ib["tls"]
            r = tls["reality"]
            hs = r.get("handshake") if isinstance(r.get("handshake"), dict) else {}
            sni = tls.get("server_name") or hs.get("server", "")
            sids = r.get("short_id") or [""]
            sid = sids[0] if isinstance(sids, list) and sids else (sids if isinstance(sids, str) else "")
            fl = "xtls-rprx-vision" if flow is None else flow
            q = (f"encryption=none&security=reality&sni={sni}&fp=chrome&pbk={pbk}"
                 f"&sid={sid}&spx=%2F&type=tcp&headerType=none")
            if fl:
                q += f"&flow={fl}"
            return f"vless://{cred}@{h}:{port}?{q}#{remark}"
        if is_ws(ib):
            tr = ib["transport"]
            path = quote(tr.get("path", "/") or "/", safe="")
            hdrs = tr.get("headers") if isinstance(tr.get("headers"), dict) else {}
            whost = hdrs.get("Host") or host
            return f"vless://{cred}@{h}:{port}?encryption=none&security=none&type=ws&host={whost}&path={path}#{remark}"
        return f"vless://{cred}@{h}:{port}?encryption=none&security=none&type=tcp#{remark}"
    if t == "hysteria2":
        return f"hysteria2://{quote(cred, safe='')}@{h}:{port}/?insecure=1#{remark}"
    if t == "hysteria":
        up = ib.get("up_mbps", 100)
        down = ib.get("down_mbps", 100)
        return (f"hysteria://{h}:{port}?protocol=udp&auth={quote(cred, safe='')}"
                f"&upmbps={up}&downmbps={down}&insecure=1#{remark}")
    if is_ss(ib):
        method = ib.get("method", "")
        # 多用户模式: 客户端密码为 ServerKey:UserKey；单用户模式: 直接使用 ServerKey
        pwd = f"{ib.get('password', '')}:{cred}" if users_of(ib) else cred
        userinfo = base64.b64encode(f"{method}:{pwd}".encode()).decode()
        return f"ss://{userinfo}@{h}:{port}#{remark}"
    return ""


def add_user(ib, name, cred, created):
    """向入站追加用户，返回最终凭据；created 收集自动创建的默认用户 (SS 单用户转多用户时)"""
    t = ib.get("type")
    us = users_of(ib)
    if us and any(u.get("name") == name for u in us):
        die(f"用户名 \"{name}\" 在入站 \"{ib.get('tag')}\" 中已存在")

    if is_ss(ib):
        if not is_ss2022(ib):
            die("仅 2022-blake3-* 加密方式的 Shadowsocks 支持多用户")
        kl = ss_keylen(ib)
        if not cred:
            cred = genkey(kl)
        try:
            raw = base64.b64decode(cred, validate=True)
        except Exception:
            raw = b""
        if len(raw) != kl:
            die(f"SS UserKey 必须是 {kl} 字节随机数据的 Base64 编码 (可用: openssl rand -base64 {kl})")
        if cred == ib.get("password") or any(u.get("password") == cred for u in (us or [])):
            die("该 UserKey 与 ServerKey 或已有用户重复")
        if not us:
            dname = "ss-user" if name != "ss-user" else "ss-user-0"
            dkey = genkey(kl)
            ib["users"] = [{"name": dname, "password": dkey}]
            created.append((dname, dkey))
        ib["users"].append({"name": name, "password": cred})
        return cred

    if us is None:
        ib["users"] = []
    if t == "vless":
        if not cred:
            cred = str(uuidlib.uuid4())
        try:
            uuidlib.UUID(cred)
        except Exception:
            die(f"UUID 格式不正确: {cred}")
        nu = {"name": name, "uuid": cred}
        if is_reality(ib):
            nu["flow"] = "xtls-rprx-vision"
    elif t == "hysteria2":
        cred = cred or os.urandom(8).hex()
        nu = {"name": name, "password": cred}
    elif t == "hysteria":
        cred = cred or os.urandom(8).hex()
        nu = {"name": name, "auth_str": cred}
    else:
        die("不支持的入站类型")
    ib["users"].append(nu)
    return cred


def user_flow(ib):
    return "xtls-rprx-vision" if is_reality(ib) else ""


data = load()

if CMD == "inbounds":
    # 输出: tag|type|port|备注；mode=del 时仅列出有用户的入站
    mode = ARGS[0] if ARGS else "all"
    for ib in inbounds(data):
        if not manageable(ib):
            continue
        us = users_of(ib)
        cnt = len(us) if us else 0
        if mode == "del" and cnt == 0:
            continue
        if is_ss(ib):
            note = f"多用户模式, 用户数: {cnt}" if cnt else "单用户模式"
        else:
            note = f"现有用户: {cnt}"
        print(f"{ib.get('tag', '')}|{ib.get('type', '')}|{ib.get('listen_port', '?')}|{note}")

elif CMD == "users":
    ib = find(data, ARGS[0])
    us = users_of(ib)
    if us:
        for u in us:
            print(f"{u.get('name', '未命名')}|{cred_of(ib, u)}")
    elif is_ss(ib):
        print(f"default|{ib.get('password', '')}")

elif CMD == "genkey":
    ib = find(data, ARGS[0])
    print(genkey(ss_keylen(ib)))

elif CMD == "ss_multi":
    for ib in inbounds(data):
        if is_ss(ib) and users_of(ib):
            print(ib.get("tag", ""))

elif CMD == "link":
    tag, name, cred, host, pbk = ARGS[:5]
    ib = find(data, tag)
    flow = None
    for u in users_of(ib) or []:
        if u.get("name") == name:
            flow = u.get("flow", "")
            break
    print(make_link(ib, name, cred, host, pbk, flow))

elif CMD == "add":
    tag, name, cred, host, pbk = ARGS[:5]
    ib = find(data, tag)
    if not manageable(ib):
        die("该入站不支持用户管理")
    created = []
    cred = add_user(ib, name, cred, created)
    save(data)
    print("SUCCESS")
    for dn, dk in created:
        print(f"CONVERTED|{dn}|{dk}")
        print(f"LINK|{dn}|{make_link(ib, dn, dk, host, pbk)}")
    print(f"CRED|{name}|{cred}")
    print(f"LINK|{name}|{make_link(ib, name, cred, host, pbk, user_flow(ib))}")

elif CMD == "add_all":
    name, uid, hy2, hy1, host, pbk = ARGS[:6]
    targets = [ib for ib in inbounds(data) if manageable(ib)]
    if not targets:
        die("没有找到任何支持多用户的入站")
    for ib in targets:
        if any(u.get("name") == name for u in (users_of(ib) or [])):
            die(f"用户名 \"{name}\" 在入站 \"{ib.get('tag')}\" 中已存在")
    results = []
    for ib in targets:
        c = {"vless": uid, "hysteria2": hy2, "hysteria": hy1}.get(ib.get("type"), "")
        created = []
        c = add_user(ib, name, c, created)
        results.append((ib, c, created))
    save(data)
    print("SUCCESS")
    for ib, c, created in results:
        tag = ib.get("tag", "")
        for dn, dk in created:
            print(f"CONVERTED|{tag}|{dn}|{dk}|{make_link(ib, dn, dk, host, pbk)}")
        print(f"LINK|{tag}|{c}|{make_link(ib, name, c, host, pbk, user_flow(ib))}")

elif CMD == "del":
    tag, idx, host, pbk = ARGS[:4]
    ib = find(data, tag)
    us = users_of(ib)
    if not us:
        die("该入站没有可删除的用户")
    i = int(idx) - 1
    if not 0 <= i < len(us):
        die("序号超出范围")
    removed = us.pop(i)
    reverted = False
    if is_ss(ib) and not us:
        # SS 多用户全部删除后，恢复为单用户 (ServerKey 直连) 模式
        ib.pop("users", None)
        reverted = True
    save(data)
    print(f"SUCCESS|{removed.get('name', '')}")
    if reverted:
        print(f"REVERTED|{make_link(ib, 'default', ib.get('password', ''), host, pbk)}")

elif CMD == "show":
    host, pbk = ARGS[0], ARGS[1]
    outfile = ARGS[2] if len(ARGS) > 2 else ""
    all_links = []
    ibs = inbounds(data)
    if not ibs:
        print("未在配置文件中找到任何入站 (inbounds)！")
    for i, ib in enumerate(ibs, 1):
        tag = ib.get("tag", f"inbound-{i}")
        t = ib.get("type", "unknown")
        port = ib.get("listen_port", "未知")
        us = users_of(ib)
        if is_ss(ib):
            mode = f"多用户 ServerKey:UserKey, 用户数: {len(us)}" if us else "单用户模式"
            print(f"{Y}[入站 #{i}] 标签: {tag} | 协议: shadowsocks ({ib.get('method', '')}) | 端口: {port} | {mode}{N}")
            print(f"   ServerKey: {C}{ib.get('password', '')}{N}")
            if us:
                entries = [(u.get("name", f"user-{k}"), u.get("password", ""), None) for k, u in enumerate(us, 1)]
            else:
                entries = [("default", ib.get("password", ""), None)]
            keyname = "UserKey" if us else "Key"
        elif us is not None:
            print(f"{Y}[入站 #{i}] 标签: {tag} | 协议: {t} | 端口: {port} | 用户数: {len(us)}{N}")
            entries = [(u.get("name", f"user-{k}"), cred_of(ib, u), u.get("flow", "")) for k, u in enumerate(us, 1)]
            keyname = {"vless": "UUID", "hysteria": "Auth", "hysteria2": "Password"}.get(t, "Cred")
        else:
            print(f"{Y}[入站 #{i}] 标签: {tag} | 协议: {t} | 端口: {port} | (无用户列表){N}\n")
            continue
        if not entries:
            print("   (暂无用户)")
        for k, (name, cred, flow) in enumerate(entries, 1):
            extra = f" | Flow: {G}{flow}{N}" if flow else ""
            print(f"   {G}{k}.{N} 用户名: {W}{name}{N} | {keyname}: {C}{cred}{N}{extra}")
            lk = make_link(ib, name, cred, host, pbk, flow)
            if lk:
                print(f"      {P}链接:{N} {lk}")
                all_links.append(lk)
        print("")
    if all_links:
        bar = "-" * 68
        print(f"{G}{bar}{N}")
        print(f"{W} 全部节点链接 (共 {len(all_links)} 条): 整体复制后在 v2rayN 主界面按 Ctrl+V{N}")
        print(f"{W} 或「服务器 -> 从剪贴板导入批量URL」即可一次性导入{N}")
        print(f"{G}{bar}{N}")
        for lk in all_links:
            print(lk)
        if outfile:
            with open(outfile, "w", encoding="utf-8") as f:
                f.write("\n".join(all_links) + "\n")
            print(f"\n{G}[提示] 以上链接已同时保存至: {outfile}{N}")

else:
    die(f"未知命令: {CMD}")
PYEOF
}

# 检查配置文件是否可用于用户管理
ensure_config_ready() {
    if ! command -v python3 >/dev/null 2>&1; then
        echo -e "${RED}[错误] 用户管理功能依赖 python3，请先安装！${PLAIN}"
        return 1
    fi
    local st
    st=$(get_config_status)
    if [[ "$st" == "MISSING" ]]; then
        echo -e "${RED}[错误] 未找到配置文件 (${CONFIG_FILE})，请先生成配置！${PLAIN}"
        return 1
    elif [[ "$st" == "CORRUPTED" ]]; then
        echo -e "${RED}[错误] 配置文件 JSON 格式异常，无法解析！${PLAIN}"
        return 1
    fi
    return 0
}

# 准备生成分享链接所需的上下文 (服务器 IP 与 Reality 公钥)，同一次运行内只探测一次 IP
prepare_link_context() {
    # shellcheck disable=SC1090
    [[ -f "$INFO_FILE" ]] && source "$INFO_FILE"
    if [[ -z "$HOST_IP" ]]; then
        detect_public_ip
        HOST_IP="${SERVER_IP:-YOUR_SERVER_IP}"
    fi
    LINK_PBK="${REALITY_PUBKEY:-}"
    if [[ -z "$LINK_PBK" ]]; then
        echo -e "${YELLOW}[提示] info.env 中缺少 REALITY_PUBKEY，Reality 链接中的 pbk 将为空，请手动补全。${PLAIN}"
    fi
}

# 生成 16 位随机字符串 (Hysteria 密码)
gen_rand_str() {
    local s
    s=$(openssl rand -base64 24 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c 16)
    [[ -z "$s" ]] && s=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n' | head -c 16)
    echo "$s"
}

# 配置备份 / 回滚 / 校验提交
backup_config() { cp -f "$CONFIG_FILE" "${CONFIG_FILE}.bak"; }
restore_config() { [[ -f "${CONFIG_FILE}.bak" ]] && mv -f "${CONFIG_FILE}.bak" "$CONFIG_FILE"; }
commit_config() {
    if ! validate_config_with_singbox; then
        restore_config
        echo -e "${RED}[校验失败] 修改后的配置未通过 sing-box 校验，已自动回滚！${PLAIN}"
        return 1
    fi
    rm -f "${CONFIG_FILE}.bak"
    return 0
}

# 读取并校验新用户名，结果写入 NEW_USERNAME
read_username() {
    local def="$1" input
    read -r -p " 请输入新用户名 [默认: ${def}]: " input
    input="${input:-$def}"
    if [[ "$input" == *"|"* || "$input" =~ [[:space:]] ]]; then
        echo -e "${RED}[错误] 用户名不能包含空格或 '|' 字符！${PLAIN}"
        return 1
    fi
    NEW_USERNAME="$input"
}

# 交互式选择入站，结果写入 SEL_TAG / SEL_TYPE / SEL_PORT / SEL_NOTE
# 参数: $1 = all | add | del，$2 = 提示语
select_inbound() {
    local mode="$1" prompt="$2" raw
    raw=$(sb_py inbounds "$mode" 2>/dev/null)
    if [[ -z "$raw" ]]; then
        echo -e "${YELLOW}[提示] 当前没有可操作的入站！${PLAIN}"
        return 1
    fi

    echo -e "\n${CYAN}${prompt}${PLAIN}"
    local tags=() types=() ports=() notes=() count=0
    local t_tag t_type t_port t_note
    while IFS='|' read -r t_tag t_type t_port t_note; do
        [[ -z "$t_tag" ]] && continue
        count=$((count + 1))
        tags+=("$t_tag"); types+=("$t_type"); ports+=("$t_port"); notes+=("$t_note")
        echo -e " ${GREEN}${count}.${PLAIN} ${WHITE}${t_tag}${PLAIN} (类型: ${CYAN}${t_type}${PLAIN}, 端口: ${YELLOW}${t_port}${PLAIN}, ${t_note})"
    done <<< "$raw"
    echo -e " ${GREEN}0.${PLAIN} 取消返回"

    local choice
    read -r -p " 请输入序号 [1-${count}]: " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "已取消操作。"
        return 1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo -e "${RED}[错误] 无效序号！${PLAIN}"
        return 1
    fi
    local i=$((choice - 1))
    SEL_TAG="${tags[$i]}"; SEL_TYPE="${types[$i]}"; SEL_PORT="${ports[$i]}"; SEL_NOTE="${notes[$i]}"
    return 0
}

# 交互式选择入站下的用户，结果写入 SEL_USER_IDX / SEL_USER_NAME / SEL_USER_CRED / SEL_USER_COUNT
select_user() {
    local tag="$1" raw
    raw=$(sb_py users "$tag" 2>/dev/null)
    if [[ -z "$raw" ]]; then
        echo -e "${YELLOW}[提示] 该入站下没有用户！${PLAIN}"
        return 1
    fi

    echo -e "\n${CYAN}入站 [${tag}] 用户列表:${PLAIN}"
    local names=() creds=() count=0 u_n u_c
    while IFS='|' read -r u_n u_c; do
        [[ -z "$u_n" ]] && continue
        count=$((count + 1))
        names+=("$u_n"); creds+=("$u_c")
        echo -e " ${GREEN}${count}.${PLAIN} 用户名: ${WHITE}${u_n}${PLAIN} (凭据: ${u_c})"
    done <<< "$raw"
    echo -e " ${GREEN}0.${PLAIN} 取消返回"

    local choice
    read -r -p " 请选择用户序号 [1-${count}]: " choice
    if [[ -z "$choice" || "$choice" == "0" ]]; then
        echo -e "已取消操作。"
        return 1
    fi
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "$count" ]; then
        echo -e "${RED}[错误] 无效序号！${PLAIN}"
        return 1
    fi
    SEL_USER_IDX="$choice"
    SEL_USER_NAME="${names[$((choice - 1))]}"
    SEL_USER_CRED="${creds[$((choice - 1))]}"
    SEL_USER_COUNT="$count"
    return 0
}

# 询问是否将链接追加到 nodes.txt
ask_append_nodes() {
    local title="$1" content="$2" ans
    read -r -p " 是否将以上节点链接追加记录到 nodes.txt？默认Y [Y/N]: " ans
    if [[ ! "$ans" =~ ^[Nn]$ ]]; then
        {
            echo ""
            echo "--------------------------------------------------------------------------------"
            echo "${title}"
            echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
            printf "%s" "$content"
        } >> "$NODES_FILE"
        echo -e "${GREEN}[提示] 已追加到 ${NODES_FILE}${PLAIN}"
    fi
}

# 查看所有入站与用户 (附带每个用户可直接导入 v2rayN 的分享链接)
list_all_inbounds_and_users() {
    ensure_config_ready || return 1
    prepare_link_context

    echo -e "\n${CYAN}====================================================================${PLAIN}"
    echo -e "${WHITE}             当前入站与用户详细清单 (含客户端分享链接)              ${PLAIN}"
    echo -e "${CYAN}====================================================================${PLAIN}"
    echo -e " 服务器地址: ${CYAN}${HOST_IP}${PLAIN}\n"

    sb_py show "$HOST_IP" "$LINK_PBK" "$LINKS_FILE"

    echo -e "${CYAN}====================================================================${PLAIN}\n"
}

# 为指定入站添加用户 (Reality / HY2 / VLESS / HY1 / VLESS-WS / SS 2022 多用户)
add_user_to_specific_inbound() {
    ensure_config_ready || return 1
    select_inbound add "请选择要添加用户的入站:" || return 0

    echo -e "\n已选定入站: ${GREEN}${SEL_TAG}${PLAIN} (类型: ${CYAN}${SEL_TYPE}${PLAIN}, 端口: ${YELLOW}${SEL_PORT}${PLAIN})"

    if [[ "$SEL_TYPE" == "shadowsocks" && "$SEL_NOTE" == *"单用户"* ]]; then
        echo -e "\n${YELLOW}[注意] 该 SS 入站当前为单用户模式，添加用户后将切换为多用户 (ServerKey:UserKey) 模式:${PLAIN}"
        echo -e "  - 原有的单用户 SS 链接将${RED}失效${PLAIN}"
        echo -e "  - 脚本会自动创建默认用户 ${WHITE}ss-user${PLAIN} 并输出其新链接，用于替换旧链接"
        local go
        read -r -p " 是否继续？[Y/N]: " go
        if [[ ! "$go" =~ ^[Yy]$ ]]; then
            echo -e "已取消操作。"
            return 0
        fi
    fi

    read_username "${SEL_TAG%-in}-user-$((RANDOM % 900 + 100))" || return 1
    local uname="$NEW_USERNAME" cred="" input auto

    case "$SEL_TYPE" in
        vless)
            auto=$(generate_uuid)
            read -r -p " 请输入该用户的 UUID [回车使用随机: ${auto}]: " input
            cred="${input:-$auto}"
            ;;
        hysteria2)
            auto=$(gen_rand_str)
            read -r -p " 请输入该用户的 Hysteria2 密码 [回车使用随机: ${auto}]: " input
            cred="${input:-$auto}"
            ;;
        hysteria)
            auto=$(gen_rand_str)
            read -r -p " 请输入该用户的 Hysteria1 认证串 auth_str [回车使用随机: ${auto}]: " input
            cred="${input:-$auto}"
            ;;
        shadowsocks)
            auto=$(sb_py genkey "$SEL_TAG" 2>/dev/null)
            echo -e " ${CYAN}SS 2022 多用户: 客户端密码格式为 ServerKey:UserKey，UserKey 长度需与加密方式匹配${PLAIN}"
            read -r -p " 请输入该用户的 UserKey [回车使用随机: ${auto}]: " input
            cred="${input:-$auto}"
            ;;
    esac

    echo -e "\n${CYAN}[+] 正在将新用户 [${uname}] 写入配置...${PLAIN}"
    prepare_link_context
    backup_config
    local res
    res=$(sb_py add "$SEL_TAG" "$uname" "$cred" "$HOST_IP" "$LINK_PBK" 2>&1)
    if [[ "$(head -n 1 <<< "$res")" != "SUCCESS" ]]; then
        restore_config
        echo -e "${RED}[添加失败] ${res#ERROR: }${PLAIN}"
        return 1
    fi
    commit_config || return 1

    echo -e "${GREEN}[成功] 用户 [${uname}] 已添加到入站 [${SEL_TAG}]！${PLAIN}"
    echo -e "\n${PURPLE}====================================================================${PLAIN}"
    echo -e "${WHITE}                     客户端节点链接 (可导入 v2rayN)                 ${PLAIN}"
    echo -e "${PURPLE}====================================================================${PLAIN}"

    local kind f1 f2 block=""
    while IFS='|' read -r kind f1 f2; do
        case "$kind" in
            CONVERTED)
                echo -e "${YELLOW} [SS 已切换为多用户模式] 自动创建默认用户 ${WHITE}${f1}${YELLOW} (UserKey: ${f2})，旧单用户链接已失效${PLAIN}"
                ;;
            CRED)
                echo -e " 用户: ${WHITE}${f1}${PLAIN} | 凭据: ${GREEN}${f2}${PLAIN}"
                ;;
            LINK)
                echo -e "${CYAN} [${f1}]${PLAIN}"
                echo -e "${WHITE}${f2}${PLAIN}"
                block+="[${f1}] ${f2}"$'\n'
                ;;
        esac
    done <<< "$res"
    echo -e "${PURPLE}====================================================================${PLAIN}"

    [[ -n "$block" ]] && ask_append_nodes "[新增用户] ${uname} (${SEL_TAG} / ${SEL_TYPE})" "$block"
}

# 一键为所有可管理入站同步添加通用用户
add_universal_user_to_all_inbounds() {
    ensure_config_ready || return 1

    echo -e "\n${CYAN}====================================================================${PLAIN}"
    echo -e "${WHITE}              一键为所有协议入站同步添加新用户                      ${PLAIN}"
    echo -e "${CYAN}====================================================================${PLAIN}"

    if sb_py inbounds add 2>/dev/null | grep -q "shadowsocks|.*单用户模式"; then
        echo -e "${YELLOW}[注意] 存在单用户模式的 SS 入站，本次操作会将其切换为多用户 (ServerKey:UserKey) 模式，${PLAIN}"
        echo -e "${YELLOW}       原单用户 SS 链接将失效，脚本会自动创建默认用户 ss-user 并输出其新链接。${PLAIN}"
        local go
        read -r -p " 是否继续？[Y/N]: " go
        if [[ ! "$go" =~ ^[Yy]$ ]]; then
            echo -e "已取消操作。"
            return 0
        fi
    fi

    local input_uname
    read -r -p " 请输入统一的用户名 (例如: alice, user2): " input_uname
    if [[ -z "$input_uname" || "$input_uname" == *"|"* || "$input_uname" =~ [[:space:]] ]]; then
        echo -e "${RED}[错误] 用户名不能为空，且不能包含空格或 '|' 字符！${PLAIN}"
        return 1
    fi

    local gen_uuid gen_hy2 gen_hy1
    gen_uuid=$(generate_uuid)
    gen_hy2=$(gen_rand_str)
    gen_hy1=$(gen_rand_str)

    echo -e "\n${CYAN}[+] 正在为 [${input_uname}] 生成全套凭据并写入配置...${PLAIN}"
    prepare_link_context
    backup_config
    local res
    res=$(sb_py add_all "$input_uname" "$gen_uuid" "$gen_hy2" "$gen_hy1" "$HOST_IP" "$LINK_PBK" 2>&1)
    if [[ "$(head -n 1 <<< "$res")" != "SUCCESS" ]]; then
        restore_config
        echo -e "${RED}[添加失败] ${res#ERROR: }${PLAIN}"
        return 1
    fi
    commit_config || return 1

    echo -e "${GREEN}[成功] 用户 [${input_uname}] 已同步添加到所有可管理入站！${PLAIN}"
    echo -e "\n${PURPLE}====================================================================${PLAIN}"
    echo -e "${WHITE}         用户 [${input_uname}] 全套节点链接 (可整体复制导入 v2rayN)        ${PLAIN}"
    echo -e "${PURPLE}====================================================================${PLAIN}"

    local kind a b c d block=""
    while IFS='|' read -r kind a b c d; do
        case "$kind" in
            CONVERTED)
                echo -e "${YELLOW}--- [${a}] 已切换为多用户模式，自动创建默认用户 ${b} (UserKey: ${c}) ---${PLAIN}"
                echo -e "${WHITE}${d}${PLAIN}\n"
                block+="[${a} / ${b}] ${d}"$'\n'
                ;;
            LINK)
                echo -e "${CYAN}--- [${a}] 凭据: ${b} ---${PLAIN}"
                echo -e "${WHITE}${c}${PLAIN}\n"
                block+="[${a}] ${c}"$'\n'
                ;;
        esac
    done <<< "$res"
    echo -e "${PURPLE}====================================================================${PLAIN}"

    [[ -n "$block" ]] && ask_append_nodes "[新用户全套节点] ${input_uname}" "$block"
}

# 删除指定入站的用户
delete_user_from_inbound() {
    ensure_config_ready || return 1
    select_inbound del "请选择要删除用户的入站:" || return 0
    select_user "$SEL_TAG" || return 0

    local confirm_del
    if [[ "$SEL_USER_COUNT" -le 1 ]]; then
        if [[ "$SEL_TYPE" == "shadowsocks" ]]; then
            echo -e "\n${YELLOW}[提示] 这是该 SS 入站的最后一个用户，删除后将恢复为单用户模式 (客户端直接使用 ServerKey)。${PLAIN}"
        else
            echo -e "\n${RED}⚠️ [危险警告] 当前入站仅剩最后 1 个用户！${PLAIN}"
            echo -e "${YELLOW}删除后该入站将没有合法用户，客户端将无法连接！${PLAIN}"
        fi
        read -r -p " 是否仍要删除用户 [${SEL_USER_NAME}]？[Y/N]: " confirm_del
    else
        read -r -p " 确认删除用户 [${SEL_USER_NAME}] 吗？[Y/N]: " confirm_del
    fi
    if [[ ! "$confirm_del" =~ ^[Yy]$ ]]; then
        echo -e "已取消删除。"
        return 0
    fi

    prepare_link_context
    backup_config
    local res
    res=$(sb_py del "$SEL_TAG" "$SEL_USER_IDX" "$HOST_IP" "$LINK_PBK" 2>&1)
    if [[ "$(head -n 1 <<< "$res")" != SUCCESS* ]]; then
        restore_config
        echo -e "${RED}[删除失败] ${res#ERROR: }${PLAIN}"
        return 1
    fi
    commit_config || return 1

    local first rem_name
    first=$(head -n 1 <<< "$res")
    rem_name="${first#SUCCESS|}"
    echo -e "${GREEN}[成功] 已从入站 [${SEL_TAG}] 中移除用户 [${rem_name}]！${PLAIN}"

    local reverted
    reverted=$(grep '^REVERTED|' <<< "$res")
    if [[ -n "$reverted" ]]; then
        echo -e "${YELLOW}[提示] SS 入站已恢复为单用户模式，新的单用户链接:${PLAIN}"
        echo -e "${WHITE}${reverted#REVERTED|}${PLAIN}"
    fi
}

# 查看/导出指定用户的节点分享链接
view_specific_user_link() {
    ensure_config_ready || return 1
    select_inbound all "请选择目标入站:" || return 0
    select_user "$SEL_TAG" || return 0

    prepare_link_context
    local u_link
    u_link=$(sb_py link "$SEL_TAG" "$SEL_USER_NAME" "$SEL_USER_CRED" "$HOST_IP" "$LINK_PBK" 2>/dev/null)

    echo -e "\n${PURPLE}====================================================================${PLAIN}"
    echo -e "${WHITE}                    节点分享链接 (可导入 v2rayN)                    ${PLAIN}"
    echo -e "${PURPLE}====================================================================${PLAIN}"
    echo -e " 入站: ${CYAN}${SEL_TAG}${PLAIN} | 用户: ${YELLOW}${SEL_USER_NAME}${PLAIN}"
    echo -e "${WHITE}${u_link}${PLAIN}"
    echo -e "${PURPLE}====================================================================${PLAIN}\n"
}

# 入站多用户管理子菜单
manage_inbound_users_menu() {
    while true; do
        echo -e "${PURPLE}====================================================${PLAIN}"
        echo -e "${WHITE}           Sing-box 入站多用户配置管理向导          ${PLAIN}"
        echo -e " 配置文件: ${CYAN}${CONFIG_FILE}${PLAIN}"
        echo -e " 配置状态: $(format_config_status_label)"
        echo -e "${PURPLE}====================================================${PLAIN}"
        echo -e " ${GREEN}1.${PLAIN} 查看所有入站与用户 (含 v2rayN 可直接导入的链接)"
        echo -e " ${GREEN}2.${PLAIN} 为指定入站添加用户 (Reality/HY2/VLESS/HY1/SS 多用户)"
        echo -e " ${GREEN}3.${PLAIN} 为所有协议入站同步添加通用新用户"
        echo -e " ${GREEN}4.${PLAIN} 删除指定入站的用户 (带安全保护)"
        echo -e " ${GREEN}5.${PLAIN} 查看/导出指定用户的节点分享链接"
        echo -e " ${GREEN}6.${PLAIN} 为当前配置文件添加本脚本专属标注注释"
        echo -e " ${GREEN}0.${PLAIN} 返回上一级菜单"
        echo -e "${PURPLE}====================================================${PLAIN}"

        local u_choice
        read -r -p " 请输入选项 [0-6]: " u_choice
        case "$u_choice" in
            1) list_all_inbounds_and_users ;;
            2) add_user_to_specific_inbound ;;
            3) add_universal_user_to_all_inbounds ;;
            4) delete_user_from_inbound ;;
            5) view_specific_user_link ;;
            6) tag_existing_config ;;
            0) return 0 ;;
            *) echo -e "${RED}[错误] 输入无效，请输入数字 0-6！${PLAIN}" ;;
        esac
        echo ""
    done
}

# ==============================================================================
# 交互式主菜单与命令行入口
# ==============================================================================

show_menu() {
    clear
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e "${WHITE}        Sing-box 多协议配置文件生成与管理工具        ${PLAIN}"
    echo -e "${WHITE}  工作目录: ${CYAN}${CONFIG_DIR}${PLAIN}"
    echo -e "  配置状态: $(format_config_status_label)"
    echo -e "${PURPLE}====================================================${PLAIN}"
    echo -e " ${GREEN}1.${PLAIN} 生成全新配置文件与节点分享信息"
    echo -e " ${GREEN}2.${PLAIN} 查看已生成的默认节点分享链接"
    echo -e " ${GREEN}3.${PLAIN} 入站用户管理 (添加/删除/查看用户及专属分享链接)"
    echo -e " ${GREEN}0.${PLAIN} 退出"
    echo -e "${PURPLE}====================================================${PLAIN}"

    read -r -p " 请输入选项 [0-3]: " choice
    case "$choice" in
        1)
            generate_all_configurations
            ;;
        2)
            generate_and_display_nodes
            ;;
        3)
            manage_inbound_users_menu
            ;;
        0)
            exit 0
            ;;
        *)
            echo -e "${RED}[错误] 输入无效，请输入数字 0-3！${PLAIN}"
            ;;
    esac
}

# 命令行帮助信息
show_help() {
    cat <<EOF
Sing-box 多协议配置文件生成与用户管理工具

说明:
  文件将直接在当前工作目录下读写与管理 (包括 config.json, hy_cert.pem, hy_key.pem, nodes.txt)。

用法:
  $0 [选项]

选项:
  -g, --generate       直接执行配置生成 (可配合环境变量)
  -v, --view           查看已生成的默认节点分享链接
  -u, --users          直接进入入站用户管理菜单 (添加/删除/查看用户)
  -u, --users          直接进入入站用户管理菜单 (添加/删除/查看用户)
  -l, --list-users     直接列出当前所有入站及用户清单
  -t, --tag            为当前配置文件添加本脚本专属标注注释
  -h, --help           显示此帮助信息

支持的环境变量 (适用于非交互式脚本生成):
  PORT                 基础起始端口号 (默认: 10086)
  HY1_SPEED            Hysteria 1 上下行带宽口子大小 (如: 100, 200, 500)
  HY1_UP_MBPS          Hysteria 1 上行带宽限制 (如: 50)
  HY1_DOWN_MBPS        Hysteria 1 下行带宽限制 (如: 200)
  ENABLE_WS            是否开启 VLESS + WS (y 或 n)
  WS_PORT              VLESS + WS 端口号 (默认: 2095)

示例:
  # 交互式主菜单
  ./sing-box.sh

  # 直接进入用户管理 (添加/删除用户)
  ./sing-box.sh -u

  # 快速查看当前配置中的所有用户
  ./sing-box.sh -l

  # 为当前配置补充添加专属标注
  ./sing-box.sh -t

  # 非交互式指定端口生成
  PORT=20000 HY1_SPEED=200 ENABLE_WS=y WS_PORT=8080 bash sing-box.sh -g
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
        -u|--users)
            manage_inbound_users_menu
            ;;
        -l|--list-users)
            list_all_inbounds_and_users
            ;;
        -t|--tag)
            tag_existing_config
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
