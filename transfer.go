package main

import (
        "net/http"
)

func main() {
        // 设置文件服务器
        fs := http.FileServer(http.Dir("/"))

        // 将所有请求重定向到文件服务器
        http.Handle("/", http.StripPrefix("/", fs))

        // 启动服务器
        err := http.ListenAndServe(":8080", nil)
        if err != nil {
                panic(err)
        }
}
