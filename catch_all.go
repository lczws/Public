package main

import (
        "fmt"
        "github.com/gin-gonic/gin"
        "io/ioutil"
        "strings"
)

func main() {
        router := gin.Default()

        router.POST("/", func(c *gin.Context) {
                // 获取所有Headers
                headers := c.Request.Header
                fmt.Println("Headers:")
                for key, value := range headers {
                        fmt.Printf("%s: %s\n", key, strings.Join(value, ", "))
                }

                // 读取Body
                body, err := c.GetRawData()
                if err != nil {
                        fmt.Println("Error reading body:", err)
                } else {
                        fmt.Println("Body:")
                        fmt.Println(string(body))
                }

                // 重新写回Body，以便后续处理
                c.Request.Body = ioutil.NopCloser(strings.NewReader(string(body)))

        })

        // 启动服务
        router.Run(":8080")
}
