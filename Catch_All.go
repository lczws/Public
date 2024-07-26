package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"flag"
	"fmt"
	"github.com/gin-gonic/gin"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
	"io/ioutil"
	"math/rand"
	"net/http"
	"time"
)

func main() {
	var random_int int

	flag.IntVar(&random_int, "l", 10, "random int long")

	// 创建一个默认的路由引擎
	r := gin.Default()

	r.Any("/", func(c *gin.Context) {
		randomString := randomString(random_int)
		c.Redirect(http.StatusFound, "/"+randomString)
	})
	// 连接到 MongoDB
	client, err := mongo.Connect(context.TODO(), options.Client().ApplyURI("***"))
	if err != nil {
		fmt.Println("MongoDB connection error:", err)
		return
	}
	defer client.Disconnect(context.TODO())

	collection := client.Database("Http").Collection("requests")

	r.Any("/data/:path", func(c *gin.Context) {
		path := c.Param("path")

		// 从 MongoDB 中读取数据
		cursor, err := collection.Find(context.TODO(), bson.M{"path": path})
		if err != nil {
			c.String(http.StatusInternalServerError, "Error finding documents in MongoDB")
			return
		}
		defer cursor.Close(context.TODO())

		var results []bson.M
		if err = cursor.All(context.TODO(), &results); err != nil {
			c.String(http.StatusInternalServerError, "Error decoding documents from MongoDB")
			return
		}

		if len(results) == 0 {
			c.String(http.StatusNotFound, "No documents found with the given path")
			return
		}

		// 返回成功的响应
		c.JSON(http.StatusOK, results)
	})

	r.Any("/:path", func(c *gin.Context) {
		// 读取请求的内容
		body, _ := ioutil.ReadAll(c.Request.Body)
		headers := c.Request.Header
		clientIP := c.ClientIP()
		method := c.Request.Method
		path := c.Param("path")
		targetUrl := c.Query("url")

		if targetUrl != "" {
			// 如果存在 url 查询参数，则进行请求转发
			payload := bytes.NewReader(body)
			req, _ := http.NewRequest(method, targetUrl, payload)

			// 添加请求头
			for key, values := range headers {
				for _, value := range values {
					req.Header.Add(key, value)
				}
			}

			response, err := http.DefaultClient.Do(req)
			if err != nil {
				c.String(http.StatusInternalServerError, "Error forwarding the request")
				return
			}
			defer response.Body.Close()

			var respBody []byte
			if response.Header.Get("Content-Encoding") == "gzip" {
				gz, err := gzip.NewReader(response.Body)
				if err != nil {
					c.String(http.StatusInternalServerError, "Error decompressing gzip response")
					return
				}
				defer gz.Close()
				respBody, err = ioutil.ReadAll(gz)
				if err != nil {
					c.String(http.StatusInternalServerError, "Error reading decompressed response body")
					return
				}
			} else {
				respBody, err = ioutil.ReadAll(response.Body)
				if err != nil {
					c.String(http.StatusInternalServerError, "Error reading response body")
					return
				}
			}

			// 返回转发后的响应
			c.Data(response.StatusCode, response.Header.Get("Content-Type"), respBody)

			// 记录请求和响应
			doc := bson.M{
				"method":    method,
				"path":      path,
				"body":      string(body),
				"headers":   headers,
				"clientIP":  clientIP,
				"targetUrl": targetUrl,
				"response":  string(respBody),
				"createdAt": time.Now(),
			}

			_, err = collection.InsertOne(context.TODO(), doc)
			if err != nil {
				fmt.Println("Error inserting document into MongoDB:", err)
			}
		} else {
			// 如果没有 url 查询参数，则正常处理请求
			doc := bson.M{
				"method":    method,
				"path":      path,
				"body":      string(body),
				"headers":   headers,
				"clientIP":  clientIP,
				"createdAt": time.Now(),
			}

			_, err := collection.InsertOne(context.TODO(), doc)
			if err != nil {
				c.String(http.StatusInternalServerError, "Error inserting document into MongoDB")
				return
			}

			// 设置 TTL 索引
			indexModel := mongo.IndexModel{
				Keys:    bson.M{"createdAt": 1},
				Options: options.Index().SetExpireAfterSeconds(1800), // 30 分钟
			}
			_, err = collection.Indexes().CreateOne(context.TODO(), indexModel)
			if err != nil {
				c.String(http.StatusInternalServerError, "Error creating TTL index")
				return
			}

			// 返回成功的响应
			c.JSON(http.StatusOK, gin.H{
				"IP":      clientIP,
				"headers": headers,
				"body":    string(body),
			})
		}
	})

	var port string

	flag.StringVar(&port, "p", ":80", "port to listen on")

	flag.Parse()

	r.Run(port)
}

func randomString(length int) string {
	const charset = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
	b := make([]byte, length)
	for i := range b {
		b[i] = charset[rand.Intn(len(charset))]
	}
	return string(b)
}
