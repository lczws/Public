#!/usr/bin/env bash
set -euo pipefail

SB_VER="1.14.3"
CONFIG_DIR="/etc/sing-box"
CONFIG="$CONFIG_DIR/config.json"
BACKUP_DIR="$CONFIG_DIR/backup"
PARSER="$CONFIG_DIR/parser.py"
BIN="/usr/local/bin/sing-box"
CMD="/usr/local/bin/out"
VPS_CMD="/usr/local/bin/vps-out"
LOG_FILE="/var/log/sing-box.log"
SERVICE="sing-box"

if [ "$(id -u)" != "0" ]; then
    echo "请使用 root 运行。"
    exit 1
fi

mkdir -p "$CONFIG_DIR" "$BACKUP_DIR"

# ============================================================
# 环境与架构检测 (支持 systemd / OpenRC & x86_64 / ARM)
# ============================================================

is_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)   ARCH="amd64" ;;
        aarch64|arm64)  ARCH="arm64" ;;
        armv7l|armv7*)  ARCH="armv7" ;;
        i386|i686)      ARCH="386"   ;;
        *) echo "不支持的 CPU 架构: $(uname -m)"; exit 1 ;;
    esac

    if [ -f /etc/alpine-release ] || ldd --version 2>&1 | grep -qi musl; then
        LIBC="musl"
    else
        LIBC="glibc"
    fi
}

# ============================================================
# 依赖与 sing-box v1.14.3 安装
# ============================================================

install_dependencies() {
    echo "正在检查并安装系统依赖..."
    if command -v apk >/dev/null 2>&1; then
        apk update
        apk add --no-cache bash curl wget ca-certificates python3 iproute2 procps tar gzip unzip openrc
    elif command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y
        apt-get install -y curl wget ca-certificates python3 iproute2 procps tar gzip unzip
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y curl wget ca-certificates python3 iproute procps-ng tar gzip unzip
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget ca-certificates python3 iproute procps-ng tar gzip unzip
    else
        echo "无法识别包管理器，请手动安装 curl、python3、iproute2、tar。"
        exit 1
    fi
}

install_singbox() {
    if [ -x "$BIN" ]; then
        CUR_VER="$("$BIN" version 2>/dev/null | awk '/sing-box version/{print $3}' || true)"
        if [ "$CUR_VER" = "$SB_VER" ]; then
            echo "检测到 sing-box 已是目标版本: v$SB_VER"
            return 0
        fi
    fi

    detect_arch
    echo "正在下载 sing-box v${SB_VER} (${ARCH}-${LIBC})..."

    TMP_DIR="$(mktemp -d)"
    TAR_NAME="sing-box-${SB_VER}-linux-${ARCH}-${LIBC}.tar.gz"
    URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${TAR_NAME}"

    if ! curl -fL --connect-timeout 10 --retry 3 -o "$TMP_DIR/sb.tar.gz" "$URL"; then
        echo "尝试下载通用静态包..."
        TAR_NAME="sing-box-${SB_VER}-linux-${ARCH}.tar.gz"
        URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VER}/${TAR_NAME}"
        curl -fL --connect-timeout 10 --retry 3 -o "$TMP_DIR/sb.tar.gz" "$URL"
    fi

    tar -xzf "$TMP_DIR/sb.tar.gz" -C "$TMP_DIR" --strip-components=1
    svc_stop || true
    install -m 755 "$TMP_DIR/sing-box" "$BIN"
    rm -rf "$TMP_DIR"

    echo "sing-box 安装完成: $("$BIN" version | head -n 1)"
}

# ============================================================
# 服务管理封装 (兼容 systemd 与 Alpine OpenRC)
# ============================================================

svc_install() {
    if is_systemd; then
        cat > /etc/systemd/system/sing-box.service <<EOF
[Unit]
Description=sing-box Global Outbound Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN run -c $CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable "$SERVICE" >/dev/null 2>&1 || true
    else
        cat > /etc/init.d/sing-box <<EOF
#!/sbin/openrc-run
name="sing-box"
description="sing-box Global Outbound Service"
supervisor="supervise-daemon"
command="$BIN"
command_args="run -c $CONFIG"
output_log="$LOG_FILE"
error_log="$LOG_FILE"
rc_ulimit="-n 1048576"

depend() {
    need net
    after firewall
}

start_pre() {
    modprobe tun 2>/dev/null || true
    checkpath -f -m 0644 -o root:root "$LOG_FILE"
}
EOF
        chmod +x /etc/init.d/sing-box
        rc-update add "$SERVICE" default >/dev/null 2>&1 || true
    fi
}

svc_active() {
    if is_systemd; then
        systemctl is-active --quiet "$SERVICE"
    else
        rc-service "$SERVICE" status >/dev/null 2>&1
    fi
}

svc_stop() {
    if is_systemd; then
        systemctl stop "$SERVICE" >/dev/null 2>&1 || true
    else
        rc-service "$SERVICE" stop >/dev/null 2>&1 || true
    fi
    pkill -9 -x sing-box >/dev/null 2>&1 || true
    if command -v ip >/dev/null 2>&1; then
        ip link set singtun0 down >/dev/null 2>&1 || true
        ip link delete singtun0 >/dev/null 2>&1 || true
    fi
}

svc_start() {
    [ ! -f "$CONFIG" ] && { echo "暂无配置文件。"; return 1; }
    if ! "$BIN" check -c "$CONFIG"; then
        echo "配置检查失败，请检查节点参数。"
        return 1
    fi

    svc_stop
    svc_install

    if is_systemd; then
        systemctl reset-failed "$SERVICE" >/dev/null 2>&1 || true
        systemctl start "$SERVICE"
    else
        modprobe tun 2>/dev/null || true
        rc-service "$SERVICE" start
    fi

    sleep 2
    if svc_active; then
        echo "全局出口已开启。"
        return 0
    else
        echo "sing-box 启动失败，近期日志如下："
        svc_log
        return 1
    fi
}

svc_status() {
    if is_systemd; then
        systemctl status "$SERVICE" --no-pager || true
    else
        rc-service "$SERVICE" status || true
    fi
}

svc_log() {
    if is_systemd; then
        journalctl -u "$SERVICE" -n 60 --no-pager
    else
        [ -f "$LOG_FILE" ] && tail -n 60 "$LOG_FILE" || echo "暂无日志文件。"
    fi
}

# ============================================================
# 写入 Python 自动识别与配置生成器
# ============================================================

install_parser() {
    cat > "$PARSER" <<'PY'
#!/usr/bin/env python3
import sys, os, json, base64, urllib.parse

def uq(v):
    return urllib.parse.unquote(v or "")

def qget(q, k, d=""):
    return q.get(k, [d])[0]

def b64dec(s):
    s = urllib.parse.unquote(s.strip())
    s += "=" * ((4 - len(s) % 4) % 4)
    for fn in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return fn(s).decode("utf-8")
        except Exception:
            pass
    return ""

def build_tls(q, server, enabled=True):
    tls = {"enabled": enabled, "server_name": qget(q, "sni") or qget(q, "peer") or server}
    if qget(q, "insecure", qget(q, "allowInsecure", "0")).lower() in ("1", "true", "yes", "on"):
        tls["insecure"] = True
    alpn = [x.strip() for x in qget(q, "alpn").split(",") if x.strip()]
    if alpn:
        tls["alpn"] = alpn
    fp = qget(q, "fp")
    if fp:
        tls["utls"] = {"enabled": True, "fingerprint": fp}
    return tls

def parse_vless(p, q):
    if not (p.username and p.hostname and p.port):
        raise ValueError("VLESS 链接缺少 UUID/地址/端口")
    sec = qget(q, "security").lower()
    net = qget(q, "type", "tcp").lower() or "tcp"
    fp = qget(q, "fp") or "chrome"
    sni = qget(q, "sni")
    out = {"type": "vless", "server": p.hostname, "server_port": p.port, "uuid": uq(p.username)}
    if qget(q, "flow"):
        out["flow"] = qget(q, "flow")

    if sec == "reality":
        pbk = qget(q, "pbk")
        if not pbk:
            raise ValueError("VLESS Reality 缺少 pbk")
        out["tls"] = {
            "enabled": True, "server_name": sni or p.hostname,
            "utls": {"enabled": True, "fingerprint": fp},
            "reality": {"enabled": True, "public_key": pbk, "short_id": qget(q, "sid")}
        }
        return out, "VLESS + Reality"

    if net == "ws":
        host = qget(q, "host")
        out["transport"] = {"type": "ws", "path": uq(qget(q, "path", "/")) or "/", "headers": {"Host": host} if host else {}}
        if sec == "tls":
            out["tls"] = build_tls(q, host or p.hostname)
            out["tls"].setdefault("utls", {"enabled": True, "fingerprint": fp})
            return out, "VLESS + WS + TLS"
        return out, "VLESS + WS"

    if sec == "tls":
        out["tls"] = build_tls(q, p.hostname)
        out["tls"].setdefault("utls", {"enabled": True, "fingerprint": fp})
        return out, "VLESS + TLS"
    return out, "VLESS + TCP"

def parse_trojan(p, q):
    pwd = uq(p.username) or uq(qget(q, "password"))
    if not (p.hostname and p.port and pwd):
        raise ValueError("Trojan 缺少服务器/端口/密码")
    out = {"type": "trojan", "server": p.hostname, "server_port": p.port, "password": pwd, "tls": build_tls(q, p.hostname)}
    if qget(q, "type").lower() == "ws":
        host = qget(q, "host")
        out["transport"] = {"type": "ws", "path": uq(qget(q, "path", "/")) or "/", "headers": {"Host": host} if host else {}}
    return out, "Trojan"

def parse_hy2(p, q):
    pwd = uq(p.username) or uq(p.password) or uq(qget(q, "password"))
    if not (p.hostname and p.port and pwd):
        raise ValueError("Hysteria2 缺少服务器/端口/密码")
    out = {"type": "hysteria2", "server": p.hostname, "server_port": p.port, "password": pwd, "tls": build_tls(q, p.hostname)}
    obfs = qget(q, "obfs").lower()
    if obfs in ("salamander", "gecko"):
        opwd = qget(q, "obfs-password") or qget(q, "obfs_password")
        if not opwd:
            raise ValueError("Hysteria2 缺少 obfs-password")
        out["obfs"] = {"type": obfs, "password": opwd}
    for k in ("up_mbps", "down_mbps"):
        if qget(q, k).isdigit():
            out[k] = int(qget(q, k))
    return out, "Hysteria2"

def parse_tuic(p, q):
    uuid = uq(p.username) or uq(qget(q, "uuid"))
    pwd = uq(p.password) or uq(qget(q, "password"))
    if not (p.hostname and p.port and uuid and pwd):
        raise ValueError("TUIC 缺少 UUID/密码/服务器/端口")
    out = {
        "type": "tuic", "server": p.hostname, "server_port": p.port, "uuid": uuid, "password": pwd,
        "congestion_control": qget(q, "congestion_control", "bbr"),
        "udp_relay_mode": qget(q, "udp_relay_mode", "native"),
        "tls": build_tls(q, p.hostname)
    }
    return out, "TUIC"

def parse_anytls(p, q):
    pwd = uq(p.username) or uq(p.password) or uq(qget(q, "password"))
    if not (p.hostname and p.port and pwd):
        raise ValueError("AnyTLS 缺少服务器/端口/密码")
    return {"type": "anytls", "server": p.hostname, "server_port": p.port, "password": pwd, "tls": build_tls(q, p.hostname)}, "AnyTLS"

def parse_socks_or_http(p, q, is_http=False):
    if not (p.hostname and p.port):
        raise ValueError("缺少服务器或端口")
    out = {"type": "http" if is_http else "socks", "server": p.hostname, "server_port": p.port}
    if not is_http:
        out["version"] = "5"
    if p.username:
        out["username"] = uq(p.username)
    if p.password:
        out["password"] = uq(p.password)
    if is_http and (p.scheme.lower() in ("https", "http+tls") or qget(q, "tls").lower() in ("1", "true")):
        out["tls"] = build_tls(q, p.hostname)
        return out, "HTTPS"
    return out, "HTTP" if is_http else "SOCKS5"

def parse_naive(p, q):
    user = uq(p.username or qget(q, "username"))
    pwd = uq(p.password or qget(q, "password"))
    if not (p.hostname and p.port and user and pwd):
        raise ValueError("NaiveProxy 缺少认证或地址信息")
    out = {"type": "naive", "server": p.hostname, "server_port": p.port, "username": user, "password": pwd, "tls": build_tls(q, p.hostname)}
    if p.scheme.lower() == "naive+quic" or qget(q, "quic").lower() in ("1", "true"):
        out["quic"] = True
    return out, "NaiveProxy"

def parse_ss(url, p, q):
    method = pwd = ""
    server, port = p.hostname, p.port
    if p.username:
        u, pw = uq(p.username), uq(p.password or "")
        if ":" in u:
            method, pwd = u.split(":", 1)
        else:
            dec = b64dec(u)
            if ":" in dec:
                method, pwd = dec.split(":", 1)
            else:
                method, pwd = u, pw
    if not server:
        dec = b64dec(url.split("://", 1)[1].split("#", 1)[0]).split("?", 1)[0]
        if "@" in dec:
            ui, hp = dec.rsplit("@", 1)
            if ":" in ui:
                method, pwd = ui.split(":", 1)
            if hp.startswith("[") and "]:" in hp:
                server, port_s = hp[1:].rsplit("]:", 1)
                port = int(port_s)
            elif ":" in hp:
                server, port_s = hp.rsplit(":", 1)
                port = int(port_s)
    if not (server and port and method and pwd != ""):
        raise ValueError("Shadowsocks 链接解析不完整")
    return {"type": "shadowsocks", "server": server, "server_port": port, "method": method, "password": pwd}, "Shadowsocks"

def parse_url(url):
    url = url.strip()
    p = urllib.parse.urlsplit(url)
    q = urllib.parse.parse_qs(p.query, keep_blank_values=True)
    s = p.scheme.lower()
    if s == "vless": return parse_vless(p, q)
    if s == "trojan": return parse_trojan(p, q)
    if s in ("hysteria2", "hy2"): return parse_hy2(p, q)
    if s == "tuic": return parse_tuic(p, q)
    if s == "anytls": return parse_anytls(p, q)
    if s in ("socks", "socks5", "socks5h"): return parse_socks_or_http(p, q, False)
    if s in ("http", "https", "http+tls"): return parse_socks_or_http(p, q, True)
    if s in ("naive", "naive+https", "naive+quic"): return parse_naive(p, q)
    if s == "ss": return parse_ss(url, p, q)

    dec = b64dec(url)
    if dec:
        for line in dec.splitlines():
            if line.strip():
                try: return parse_url(line.strip())
                except Exception: continue
    raise ValueError("无法识别链接协议类型")

def main():
    link, cfg_path = sys.argv[1], sys.argv[2]
    outbound, proto_name = parse_url(link)
    outbound["tag"] = "proxy"
    outbound["domain_resolver"] = "dns-bootstrap"

    # config = {
    #     "log": {"disabled": False, "level": "warn"},
    #     "dns": {
    #         "servers": [
    #             {"type": "udp", "tag": "dns-bootstrap", "server": "1.1.1.1", "server_port": 53},
    #             {"type": "udp", "tag": "dns-proxy", "server": "1.1.1.1", "server_port": 53, "detour": "proxy"}
    #         ],
    #         "final": "dns-proxy"
    #     },
    #     "inbounds": [{
    #         "type": "tun", "tag": "tun-in", "interface_name": "singtun0",
    #         "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
    #         "mtu": 1500, "auto_route": True, "strict_route": True
    #     }],
    #     "outbounds": [
    #         outbound,
    #         {"type": "direct", "tag": "direct"},
    #         {"type": "block", "tag": "block"}
    #     ],
    #     "route": {
    #         "auto_detect_interface": True,
    #         "default_domain_resolver": "dns-bootstrap",
    #         "rules": [{"protocol": "dns", "action": "hijack-dns"}],
    #         "final": "proxy"
    #     }
    # }
    
    #V4-Only
    config = {
        "log": {"disabled": False, "level": "warn"},
        "dns": {
            "servers": [
                {"type": "udp", "tag": "dns-bootstrap", "server": "1.1.1.1", "server_port": 53},
                {"type": "udp", "tag": "dns-proxy", "server": "1.1.1.1", "server_port": 53, "detour": "proxy"}
            ],
            "strategy": "ipv4_only",
            "final": "dns-proxy"
        },
        "inbounds": [{
            "type": "tun", "tag": "tun-in", "interface_name": "singtun0",
            "address": ["172.19.0.1/30"],
            "mtu": 1500, "auto_route": True, "strict_route": True
        }],
        "outbounds": [
            outbound,
            {"type": "direct", "tag": "direct"},
            {"type": "block", "tag": "block"}
        ],
        "route": {
            "auto_detect_interface": True,
            "default_domain_resolver": "dns-bootstrap",
            "rules": [{"protocol": "dns", "action": "hijack-dns"}],
            "final": "proxy"
        }
    }

    tmp = cfg_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(config, f, ensure_ascii=False, indent=2)
        f.write("\n")
    os.replace(tmp, cfg_path)
    print(proto_name)

if __name__ == "__main__":
    main()
PY
    chmod +x "$PARSER"
}

# ============================================================
# 交互功能函数
# ============================================================

change_outbound() {
    echo
    echo "请直接粘贴完整节点链接（自动识别 VLESS / Reality / HY2 / TUIC / Trojan / SS / SOCKS5 / HTTP / AnyTLS / Naive）："
    read -r -p "> " LINK
    [ -z "$LINK" ] && { echo "链接不能为空。"; return; }

    [ -f "$CONFIG" ] && cp -f "$CONFIG" "$BACKUP_DIR/config-$(date +%Y%m%d-%H%M%S).json"

    if PROTO_NAME="$(python3 "$PARSER" "$LINK" "$CONFIG" 2>&1)"; then
        echo
        echo "已自动识别协议：$PROTO_NAME"
        echo "配置已生成，正在启动服务..."
        svc_start
    else
        echo
        echo "解析失败：$PROTO_NAME"
    fi
}

test_outbound() {
    echo
    echo "正在测试当前出口 IP..."
    echo "IPv4: $(curl -4 -s --connect-timeout 5 --max-time 10 https://api.ipify.org || echo '获取失败')"
    echo "IPv6: $(curl -6 -s --connect-timeout 5 --max-time 10 https://api64.ipify.org || echo '未启用或获取失败')"
}

menu() {
    while true; do
        clear
        echo "=========================================="
        echo "       VPS 全局出口管理 (sing-box v$SB_VER)"
        echo "=========================================="
        if svc_active; then
            echo "当前状态：[运行中]"
        else
            echo "当前状态：[已停止]"
        fi
        echo "------------------------------------------"
        echo "1. 更换/设置出口 (自动识别协议)"
        echo "2. 开启全局出口"
        echo "3. 关闭全局出口"
        echo "4. 查看服务状态"
        echo "5. 测试当前出口 IP"
        echo "6. 查看当前配置"
        echo "7. 查看运行日志"
        echo "8. 退出"
        echo "=========================================="
        read -r -p "请选择 [1-8]：" CHOICE

        case "${CHOICE:-}" in
            1) change_outbound ;;
            2) svc_start ;;
            3) svc_stop; echo "全局出口已关闭。" ;;
            4) echo; svc_status ;;
            5) test_outbound ;;
            6) echo; [ -f "$CONFIG" ] && cat "$CONFIG" || echo "暂无配置。" ;;
            7) echo; svc_log ;;
            8) clear; exit 0 ;;
            *) echo "无效选择。" ;;
        esac
        echo
        read -r -p "按 Enter 返回菜单..." _
    done
}

# ============================================================
# 入口判定：首次运行自动部署命令 out，后续直接进菜单
# ============================================================

if [ "${1:-}" != "--menu" ]; then
    install_dependencies
    install_singbox
    install_parser

    if [ -f "$0" ]; then
        install -m 755 "$0" "$VPS_CMD"
    fi

    cat > "$CMD" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/bin/vps-out --menu "$@"
EOF
    chmod +x "$CMD"

    echo
    echo "安装完成！后续随时输入 out 即可呼出管理菜单。"
    sleep 1
fi

menu
