package main

import (
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"time"
)

const (
	stunBindingRequest  = 0x0001
	stunBindingResponse = 0x0101
	magicCookie         = 0x2112A442
	attrMappedAddress   = 0x0001
	attrXorMappedAddr   = 0x0020
)

// 1. SOCKS5 握手并建立 UDP Associate 通道
func socks5UDPAssociate(proxyAddr, user, pass string, timeout time.Duration) (net.Conn, *net.UDPAddr, error) {
	tcpConn, err := net.DialTimeout("tcp", proxyAddr, timeout)
	if err != nil {
		return nil, nil, fmt.Errorf("连接代理失败: %w", err)
	}
	_ = tcpConn.SetDeadline(time.Now().Add(timeout))

	// 协商认证方式
	if user != "" {
		_, err = tcpConn.Write([]byte{0x05, 0x02, 0x00, 0x02})
	} else {
		_, err = tcpConn.Write([]byte{0x05, 0x01, 0x00})
	}
	if err != nil {
		tcpConn.Close()
		return nil, nil, err
	}

	resp := make([]byte, 2)
	if _, err := io.ReadFull(tcpConn, resp); err != nil {
		tcpConn.Close()
		return nil, nil, err
	}
	if resp[0] != 0x05 {
		tcpConn.Close()
		return nil, nil, fmt.Errorf("非法的 SOCKS 版本: %d", resp[0])
	}

	// 处理账号密码认证 (RFC 1929)
	switch resp[1] {
	case 0x02:
		if user == "" {
			tcpConn.Close()
			return nil, nil, errors.New("代理需要账号密码认证")
		}
		authBuf := bytes.NewBuffer([]byte{0x01, byte(len(user))})
		authBuf.WriteString(user)
		authBuf.WriteByte(byte(len(pass)))
		authBuf.WriteString(pass)
		if _, err := tcpConn.Write(authBuf.Bytes()); err != nil {
			tcpConn.Close()
			return nil, nil, err
		}
		if _, err := io.ReadFull(tcpConn, resp); err != nil {
			tcpConn.Close()
			return nil, nil, err
		}
		if resp[1] != 0x00 {
			tcpConn.Close()
			return nil, nil, errors.New("SOCKS5 账号密码认证失败")
		}
	case 0x00:
		// 无需认证
	default:
		tcpConn.Close()
		return nil, nil, fmt.Errorf("不支持的 SOCKS5 认证方式: 0x%02x", resp[1])
	}

	// 发送 UDP ASSOCIATE 请求 (CMD = 0x03)
	req := []byte{0x05, 0x03, 0x00, 0x01, 0, 0, 0, 0, 0, 0}
	if _, err := tcpConn.Write(req); err != nil {
		tcpConn.Close()
		return nil, nil, err
	}

	hdr := make([]byte, 4)
	if _, err := io.ReadFull(tcpConn, hdr); err != nil {
		tcpConn.Close()
		return nil, nil, err
	}
	if hdr[1] != 0x00 {
		tcpConn.Close()
		if hdr[1] == 0x07 {
			return nil, nil, errors.New("代理不支持 UDP Associate (错误码 0x07)")
		}
		return nil, nil, fmt.Errorf("UDP Associate 失败，SOCKS5 错误码: 0x%02x", hdr[1])
	}

	// 解析代理返回的 UDP 中继地址
	var relayIP net.IP
	switch hdr[3] {
	case 0x01: // IPv4
		ipBuf := make([]byte, 4)
		if _, err := io.ReadFull(tcpConn, ipBuf); err != nil {
			tcpConn.Close()
			return nil, nil, err
		}
		relayIP = net.IP(ipBuf)
	case 0x03: // 域名
		lenBuf := make([]byte, 1)
		if _, err := io.ReadFull(tcpConn, lenBuf); err != nil {
			tcpConn.Close()
			return nil, nil, err
		}
		domainBuf := make([]byte, lenBuf[0])
		if _, err := io.ReadFull(tcpConn, domainBuf); err != nil {
			tcpConn.Close()
			return nil, nil, err
		}
		ips, err := net.LookupIP(string(domainBuf))
		if err != nil || len(ips) == 0 {
			tcpConn.Close()
			return nil, nil, fmt.Errorf("解析中继域名失败: %w", err)
		}
		relayIP = ips[0]
	case 0x04: // IPv6
		ipBuf := make([]byte, 16)
		if _, err := io.ReadFull(tcpConn, ipBuf); err != nil {
			tcpConn.Close()
			return nil, nil, err
		}
		relayIP = net.IP(ipBuf)
	default:
		tcpConn.Close()
		return nil, nil, fmt.Errorf("未知的地址类型: %d", hdr[3])
	}

	portBuf := make([]byte, 2)
	if _, err := io.ReadFull(tcpConn, portBuf); err != nil {
		tcpConn.Close()
		return nil, nil, err
	}
	relayPort := int(binary.BigEndian.Uint16(portBuf))

	// 如果返回 0.0.0.0 或 127.0.0.1，修正为连接代理时的远端 IP
	if relayIP.IsUnspecified() || relayIP.IsLoopback() {
		if tcpAddr, ok := tcpConn.RemoteAddr().(*net.TCPAddr); ok {
			relayIP = tcpAddr.IP
		}
	}

	// 取消 TCP 超时限制，保持控制连接存活
	_ = tcpConn.SetDeadline(time.Time{})
	return tcpConn, &net.UDPAddr{IP: relayIP, Port: relayPort}, nil
}

// 2. 封装 SOCKS5 UDP 头部
func packSocks5UDP(dstIP net.IP, dstPort int, payload []byte) ([]byte, error) {
	buf := bytes.NewBuffer([]byte{0x00, 0x00, 0x00}) // RSV(2), FRAG(1)
	if ip4 := dstIP.To4(); ip4 != nil {
		buf.WriteByte(0x01)
		buf.Write(ip4)
	} else if ip6 := dstIP.To16(); ip6 != nil {
		buf.WriteByte(0x04)
		buf.Write(ip6)
	} else {
		return nil, errors.New("无效的目标 IP")
	}
	portBytes := make([]byte, 2)
	binary.BigEndian.PutUint16(portBytes, uint16(dstPort))
	buf.Write(portBytes)
	buf.Write(payload)
	return buf.Bytes(), nil
}

// 3. 剥离 SOCKS5 UDP 头部
func unpackSocks5UDP(pkt []byte) ([]byte, error) {
	if len(pkt) < 10 {
		return nil, errors.New("UDP 响应过短")
	}
	if pkt[2] != 0x00 {
		return nil, errors.New("不支持分片的 SOCKS5 UDP 包")
	}
	var hdrLen int
	switch pkt[3] {
	case 0x01:
		hdrLen = 10
	case 0x03:
		hdrLen = 4 + 1 + int(pkt[4]) + 2
	case 0x04:
		hdrLen = 22
	default:
		return nil, fmt.Errorf("未知的 SOCKS5 UDP 地址类型: %d", pkt[3])
	}
	if len(pkt) < hdrLen {
		return nil, errors.New("UDP 包长度异常")
	}
	return pkt[hdrLen:], nil
}

// 4. 构造 STUN Binding Request
func buildStunRequest() ([]byte, []byte, error) {
	tid := make([]byte, 12)
	if _, err := rand.Read(tid); err != nil {
		return nil, nil, err
	}
	pkt := make([]byte, 20)
	binary.BigEndian.PutUint16(pkt[0:2], stunBindingRequest)
	binary.BigEndian.PutUint16(pkt[2:4], 0)
	binary.BigEndian.PutUint32(pkt[4:8], magicCookie)
	copy(pkt[8:20], tid)
	return pkt, tid, nil
}

// 5. 解析 STUN Binding Response
func parseStunResponse(data []byte, expectedTID []byte) (string, int, error) {
	if len(data) < 20 {
		return "", 0, errors.New("STUN 响应过短")
	}
	msgType := binary.BigEndian.Uint16(data[0:2])
	msgLen := int(binary.BigEndian.Uint16(data[2:4]))
	cookie := binary.BigEndian.Uint32(data[4:8])

	if msgType != stunBindingResponse || cookie != magicCookie {
		return "", 0, fmt.Errorf("非法的 STUN 响应头: 0x%04x", msgType)
	}
	if !bytes.Equal(data[8:20], expectedTID) {
		return "", 0, errors.New("Transaction ID 不匹配")
	}

	offset := 20
	for offset < 20+msgLen && offset+4 <= len(data) {
		attrType := binary.BigEndian.Uint16(data[offset : offset+2])
		attrLen := int(binary.BigEndian.Uint16(data[offset+2 : offset+4]))
		if offset+4+attrLen > len(data) {
			break
		}
		val := data[offset+4 : offset+4+attrLen]

		if attrType == attrXorMappedAddr && attrLen >= 8 {
			family := val[1]
			xorPort := binary.BigEndian.Uint16(val[2:4])
			port := int(xorPort ^ uint16(magicCookie>>16))

			if family == 0x01 { // IPv4
				xorIP := binary.BigEndian.Uint32(val[4:8])
				ipBytes := make([]byte, 4)
				binary.BigEndian.PutUint32(ipBytes, xorIP^magicCookie)
				return net.IP(ipBytes).String(), port, nil
			} else if family == 0x02 && attrLen >= 20 { // IPv6
				mask := make([]byte, 16)
				binary.BigEndian.PutUint32(mask[0:4], magicCookie)
				copy(mask[4:16], expectedTID)
				ipBytes := make([]byte, 16)
				for i := 0; i < 16; i++ {
					ipBytes[i] = val[4+i] ^ mask[i]
				}
				return net.IP(ipBytes).String(), port, nil
			}
		} else if attrType == attrMappedAddress && attrLen >= 8 {
			if val[1] == 0x01 {
				port := int(binary.BigEndian.Uint16(val[2:4]))
				return net.IP(val[4:8]).String(), port, nil
			}
		}

		padding := (4 - (attrLen % 4)) % 4
		offset += 4 + attrLen + padding
	}
	return "", 0, errors.New("未在 STUN 响应中找到映射地址")
}

func main() {
	proxyAddr := flag.String("proxy", "127.0.0.1:1080", "SOCKS5 代理地址 (host:port)")
	user := flag.String("user", "", "SOCKS5 用户名 (可选)")
	pass := flag.String("pass", "", "SOCKS5 密码 (可选)")
	stunAddr := flag.String("stun", "stun.cloudflare.com:3478", "STUN 服务器地址 (host:port)")
	timeoutSec := flag.Int("timeout", 5, "超时时间 (秒)")
	flag.Parse()

	timeout := time.Duration(*timeoutSec) * time.Second

	stunHost, stunPortStr, err := net.SplitHostPort(*stunAddr)
	if err != nil {
		fmt.Printf("[-] STUN 地址格式错误: %v\n", err)
		os.Exit(1)
	}
	stunPort, _ := strconv.Atoi(stunPortStr)

	ips, err := net.LookupIP(stunHost)
	if err != nil || len(ips) == 0 {
		fmt.Printf("[-] 无法解析 STUN 域名 (%s): %v\n", stunHost, err)
		os.Exit(1)
	}
	var targetIP net.IP
	for _, ip := range ips {
		if ip4 := ip.To4(); ip4 != nil {
			targetIP = ip4
			break
		}
	}
	if targetIP == nil {
		targetIP = ips[0]
	}

	fmt.Printf("[*] 目标 STUN 节点: %s (%s:%d)\n", stunHost, targetIP.String(), stunPort)
	fmt.Printf("[*] 正在连接 SOCKS5 代理 (%s) 协商 UDP Associate...\n", *proxyAddr)

	tcpConn, relayAddr, err := socks5UDPAssociate(*proxyAddr, *user, *pass, timeout)
	if err != nil {
		fmt.Printf("[-] SOCKS5 握手失败: %v\n", err)
		os.Exit(1)
	}
	defer tcpConn.Close()
	fmt.Printf("[*] UDP 中继分配成功: %s\n", relayAddr.String())

	udpConn, err := net.DialUDP("udp", nil, relayAddr)
	if err != nil {
		fmt.Printf("[-] 创建本地 UDP 失败: %v\n", err)
		os.Exit(1)
	}
	defer udpConn.Close()
	_ = udpConn.SetDeadline(time.Now().Add(timeout))

	stunReq, tid, err := buildStunRequest()
	if err != nil {
		fmt.Printf("[-] 构造 STUN 请求失败: %v\n", err)
		os.Exit(1)
	}

	socksPkt, err := packSocks5UDP(targetIP, stunPort, stunReq)
	if err != nil {
		fmt.Printf("[-] 封装 SOCKS5 UDP 失败: %v\n", err)
		os.Exit(1)
	}

	if _, err := udpConn.Write(socksPkt); err != nil {
		fmt.Printf("[-] 发送 UDP 数据失败: %v\n", err)
		os.Exit(1)
	}

	respBuf := make([]byte, 2048)
	n, err := udpConn.Read(respBuf)
	if err != nil {
		fmt.Printf("[-] 接收响应超时或失败 (请确认代理支持 UDP 转发): %v\n", err)
		os.Exit(1)
	}

	stunResp, err := unpackSocks5UDP(respBuf[:n])
	if err != nil {
		fmt.Printf("[-] 解包 SOCKS5 UDP 失败: %v\n", err)
		os.Exit(1)
	}

	pubIP, pubPort, err := parseStunResponse(stunResp, tid)
	if err != nil {
		fmt.Printf("[-] 解析 STUN 响应失败: %v\n", err)
		os.Exit(1)
	}

	fmt.Printf("[+] 测试成功！WebRTC (UDP) 出口 IP: %s (映射端口: %d)\n", pubIP, pubPort)
}