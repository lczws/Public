package main

import (
	"bytes"
	"encoding/binary"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"time"
)

func main() {
	// 定义命令行参数
	host := flag.String("host", "127.0.0.1", "SOCKS5 服务器地址")
	port := flag.Int("port", 1080, "SOCKS5 端口")
	user := flag.String("user", "", "用户名（留空则不进行密码认证）")
	pass := flag.String("pass", "", "密码")
	timeoutSec := flag.Int("timeout", 5, "超时时间（秒）")
	dnsTarget := flag.String("dns", "8.8.8.8", "用于探测的目标 DNS 服务器 IP (仅支持 IPv4)")
	flag.Parse()

	timeout := time.Duration(*timeoutSec) * time.Second

	// 1. 建立 TCP 控制连接
	serverAddr := fmt.Sprintf("%s:%d", *host, *port)
	tcpConn, err := net.DialTimeout("tcp", serverAddr, timeout)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[-] 连接 SOCKS5 服务端失败: %v\n", err)
		os.Exit(1)
	}
	defer tcpConn.Close()
	_ = tcpConn.SetDeadline(time.Now().Add(timeout))

	// 2. 认证协商 (自动根据是否提供 user 决定认证方法)
	useAuth := *user != ""
	if useAuth {
		// METHOD=0x02 (User/Pass)
		if _, err := tcpConn.Write([]byte{0x05, 0x01, 0x02}); err != nil {
			fmt.Fprintf(os.Stderr, "[-] 发送认证握手失败: %v\n", err)
			os.Exit(1)
		}
		res := make([]byte, 2)
		if _, err := io.ReadFull(tcpConn, res); err != nil || res[0] != 0x05 || res[1] != 0x02 {
			fmt.Fprintf(os.Stderr, "[-] 服务端拒绝用户名密码认证: %x\n", res)
			os.Exit(1)
		}

		// RFC 1929 用户名/密码认证
		var authBuf bytes.Buffer
		authBuf.WriteByte(0x01)
		authBuf.WriteByte(byte(len(*user)))
		authBuf.WriteString(*user)
		authBuf.WriteByte(byte(len(*pass)))
		authBuf.WriteString(*pass)

		if _, err := tcpConn.Write(authBuf.Bytes()); err != nil {
			fmt.Fprintf(os.Stderr, "[-] 发送认证凭据失败: %v\n", err)
			os.Exit(1)
		}
		authRes := make([]byte, 2)
		if _, err := io.ReadFull(tcpConn, authRes); err != nil || authRes[0] != 0x01 || authRes[1] != 0x00 {
			fmt.Fprintf(os.Stderr, "[-] SOCKS5 认证失败: %x\n", authRes)
			os.Exit(1)
		}
	} else {
		// METHOD=0x00 (No Auth)
		if _, err := tcpConn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
			fmt.Fprintf(os.Stderr, "[-] 发送免密握手失败: %v\n", err)
			os.Exit(1)
		}
		res := make([]byte, 2)
		if _, err := io.ReadFull(tcpConn, res); err != nil || res[0] != 0x05 || res[1] != 0x00 {
			fmt.Fprintf(os.Stderr, "[-] 服务端要求认证或不支持免密: %x\n", res)
			os.Exit(1)
		}
	}

	// 3. 发起 UDP ASSOCIATE (RFC 1928)
	if _, err := tcpConn.Write([]byte{0x05, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00}); err != nil {
		fmt.Fprintf(os.Stderr, "[-] 发起 UDP Associate 请求失败: %v\n", err)
		os.Exit(1)
	}

	head := make([]byte, 4)
	if _, err := io.ReadFull(tcpConn, head); err != nil || head[1] != 0x00 {
		fmt.Fprintf(os.Stderr, "[-] SOCKS5 拒绝 UDP 请求，错误码: %d\n", head[1])
		os.Exit(1)
	}

	// 解析中继地址
	var relayIP net.IP
	switch head[3] {
	case 0x01: // IPv4
		buf := make([]byte, 4)
		if _, err := io.ReadFull(tcpConn, buf); err != nil {
			fmt.Fprintf(os.Stderr, "[-] 读取中继 IPv4 失败: %v\n", err)
			os.Exit(1)
		}
		relayIP = net.IP(buf)
	case 0x03: // 域名
		var dLen byte
		_ = binary.Read(tcpConn, binary.BigEndian, &dLen)
		buf := make([]byte, dLen)
		if _, err := io.ReadFull(tcpConn, buf); err != nil {
			fmt.Fprintf(os.Stderr, "[-] 读取中继域名失败: %v\n", err)
			os.Exit(1)
		}
		ips, _ := net.LookupIP(string(buf))
		if len(ips) > 0 {
			relayIP = ips[0]
		}
	case 0x04: // IPv6
		buf := make([]byte, 16)
		if _, err := io.ReadFull(tcpConn, buf); err != nil {
			fmt.Fprintf(os.Stderr, "[-] 读取中继 IPv6 失败: %v\n", err)
			os.Exit(1)
		}
		relayIP = net.IP(buf)
	}

	var relayPort uint16
	if err := binary.Read(tcpConn, binary.BigEndian, &relayPort); err != nil {
		fmt.Fprintf(os.Stderr, "[-] 解析中继端口失败: %v\n", err)
		os.Exit(1)
	}

	// 中继 IP 为 0.0.0.0 时回退使用 SOCKS5 主机 IP
	targetIP := *host
	if relayIP != nil && !relayIP.IsUnspecified() {
		targetIP = relayIP.String()
	}
	relayAddr := fmt.Sprintf("%s:%d", targetIP, relayPort)

	// 4. 建立 UDP Socket 并发送测试查询
	udpConn, err := net.Dial("udp", relayAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[-] 无法连接中继 UDP 端口: %v\n", err)
		os.Exit(1)
	}
	defer udpConn.Close()
	_ = udpConn.SetDeadline(time.Now().Add(timeout))

	dstIP := net.ParseIP(*dnsTarget).To4()
	if dstIP == nil {
		fmt.Fprintf(os.Stderr, "[-] 目标 DNS IP 无效: %s\n", *dnsTarget)
		os.Exit(1)
	}

	// 封装 SOCKS5 UDP 请求头
	var packet bytes.Buffer
	packet.Write([]byte{0x00, 0x00, 0x00, 0x01})
	packet.Write(dstIP)
	_ = binary.Write(&packet, binary.BigEndian, uint16(53))

	// DNS 查询报文 (example.com，事务 ID: 0xaabb)
	dnsQuery := []byte{
		0xaa, 0xbb, 0x01, 0x00, 0x00, 0x01, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x07, 'e', 'x', 'a',
		'm', 'p', 'l', 'e', 0x03, 'c', 'o', 'm',
		0x00, 0x00, 0x01, 0x00, 0x01,
	}
	packet.Write(dnsQuery)

	startTime := time.Now()
	if _, err := udpConn.Write(packet.Bytes()); err != nil {
		fmt.Fprintf(os.Stderr, "[-] 发送 UDP 探测报文失败: %v\n", err)
		os.Exit(1)
	}

	// 5. 等待响应并校验
	recvBuf := make([]byte, 4096)
	n, err := udpConn.Read(recvBuf)
	if err != nil {
		fmt.Fprintf(os.Stderr, "[-] UDP 探测超时或无响应: %v\n", err)
		os.Exit(1)
	}
	rtt := time.Since(startTime)

	if n > 10 && recvBuf[10] == 0xaa && recvBuf[11] == 0xbb {
		fmt.Printf("[OK] UDP 通畅 | 中继: %s | 目标: %s:53 | 延迟: %v\n", relayAddr, *dnsTarget, rtt.Round(time.Millisecond))
		os.Exit(0)
	}

	fmt.Fprintf(os.Stderr, "[-] 收到异常数据包 (长度: %d)\n", n)
	os.Exit(1)
}
