// 使用方法:
//
//	main -ports 80,8080              # 通过命令行参数指定端口
//	LISTEN_PORTS=80,8080 ./main      # 通过环境变量指定端口
//	./main                            # 默认监听 80,8080
package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"strings"
)

func helloHandler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, "Hello world!!!")
}

func main() {
	portsFlag := flag.String("ports", "", "监听端口，多个端口用逗号分隔，如: 80,8080")
	flag.Parse()

	// 优先级: flag > 环境变量 > 默认值
	portsStr := *portsFlag
	if portsStr == "" {
		portsStr = os.Getenv("LISTEN_PORTS")
	}
	if portsStr == "" {
		portsStr = "80,8080"
	}

	ports := strings.Split(portsStr, ",")

	http.HandleFunc("/", helloHandler)

	for _, port := range ports {
		port = strings.TrimSpace(port)
		go func(p string) {
			addr := ":" + p
			log.Printf("监听端口 %s", p)
			if err := http.ListenAndServe(addr, nil); err != nil {
				log.Fatalf("端口 %s 启动失败: %v", p, err)
			}
		}(port)
	}

	// 阻塞主协程
	select {}
}
