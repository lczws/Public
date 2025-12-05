package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/disk"
	"github.com/shirou/gopsutil/v4/host"
	"github.com/shirou/gopsutil/v4/mem"
)

func systemInfoHandler(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/html; charset=utf-8")

	// 获取内存信息
	memory, err := mem.VirtualMemory()
	if err != nil {
		http.Error(w, fmt.Sprintf("获取内存信息失败: %v", err), http.StatusInternalServerError)
		return
	}

	// 获取主机信息
	hostinfo, err := host.Info()
	if err != nil {
		http.Error(w, fmt.Sprintf("获取主机信息失败: %v", err), http.StatusInternalServerError)
		return
	}

	// 获取CPU信息
	cpuinfo, err := cpu.Info()
	if err != nil {
		http.Error(w, fmt.Sprintf("获取CPU信息失败: %v", err), http.StatusInternalServerError)
		return
	}

	// 获取磁盘信息
	diskinfo, err := disk.Usage("/")
	if err != nil {
		http.Error(w, fmt.Sprintf("获取磁盘信息失败: %v", err), http.StatusInternalServerError)
		return
	}

	// 构建HTML响应
	html := `
<!DOCTYPE html>
<html>
<head>
    <title>系统信息</title>
    <style>
        body { font-family: Arial, sans-serif; margin: 40px; }
        h1 { color: #333; }
        .info-section { 
            border: 1px solid #ddd; 
            border-radius: 5px; 
            padding: 20px; 
            margin-bottom: 20px; 
            background-color: #f9f9f9;
        }
        .info-item { margin: 10px 0; }
        .label { font-weight: bold; }
    </style>
</head>
<body>
    <h1>系统信息</h1>
`

	// 内存信息
	if memory.Total/1024/1024 > 1024 {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>内存信息</h2>
        <div class="info-item"><span class="label">总内存:</span> %.2f GB</div>
        <div class="info-item"><span class="label">已用内存:</span> %.2f GB</div>
        <div class="info-item"><span class="label">使用率:</span> %.2f%%</div>
    </div>
`, float64(memory.Total)/1024/1024/1024, float64(memory.Used)/1024/1024/1024, memory.UsedPercent)
	} else {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>内存信息</h2>
        <div class="info-item"><span class="label">总内存:</span> %.2f MB</div>
        <div class="info-item"><span class="label">已用内存:</span> %.2f MB</div>
        <div class="info-item"><span class="label">使用率:</span> %.2f%%</div>
    </div>
`, float64(memory.Total)/1024/1024, float64(memory.Used)/1024/1024, memory.UsedPercent)
	}

	// 主机信息
	// 主机信息
	if hostinfo.Uptime/60/60 > 24 {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>主机信息</h2>
        <div class="info-item"><span class="label">运行时间:</span> %.2f 天</div>
        <div class="info-item"><span class="label">启动时间:</span> %.2f 天</div>
        <div class="info-item"><span class="label">平台:</span> %s</div>
        <div class="info-item"><span class="label">平台版本:</span> %s</div>
        <div class="info-item"><span class="label">内核版本:</span> %s</div>
        <div class="info-item"><span class="label">架构:</span> %s</div>
        <div class="info-item"><span class="label">虚拟化系统:</span> %s</div>
    </div>
`, float64(hostinfo.Uptime)/60/60/24, float64(hostinfo.BootTime)/60/60/24, hostinfo.Platform, hostinfo.PlatformVersion, hostinfo.KernelVersion, hostinfo.KernelArch, hostinfo.VirtualizationSystem)
	} else if hostinfo.Uptime/60 > 60 {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>主机信息</h2>
        <div class="info-item"><span class="label">运行时间:</span> %.2f 小时</div>
        <div class="info-item"><span class="label">启动时间:</span> %.2f 小时</div>
        <div class="info-item"><span class="label">平台:</span> %s</div>
        <div class="info-item"><span class="label">平台版本:</span> %s</div>
        <div class="info-item"><span class="label">内核版本:</span> %s</div>
        <div class="info-item"><span class="label">架构:</span> %s</div>
        <div class="info-item"><span class="label">虚拟化系统:</span> %s</div>
    </div>
`, float64(hostinfo.Uptime)/60/60, float64(hostinfo.BootTime)/60/60, hostinfo.Platform, hostinfo.PlatformVersion, hostinfo.KernelVersion, hostinfo.KernelArch, hostinfo.VirtualizationSystem)
	} else {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>主机信息</h2>
        <div class="info-item"><span class="label">运行时间:</span> %.2f 分钟</div>
        <div class="info-item"><span class="label">启动时间:</span> %.2f 分钟</div>
        <div class="info-item"><span class="label">平台:</span> %s</div>
        <div class="info-item"><span class="label">平台版本:</span> %s</div>
        <div class="info-item"><span class="label">内核版本:</span> %s</div>
        <div class="info-item"><span class="label">架构:</span> %s</div>
        <div class="info-item"><span class="label">虚拟化系统:</span> %s</div>
    </div>
`, float64(hostinfo.Uptime)/60, float64(hostinfo.BootTime)/60, hostinfo.Platform, hostinfo.PlatformVersion, hostinfo.KernelVersion, hostinfo.KernelArch, hostinfo.VirtualizationSystem)
	}

	// CPU信息
	if len(cpuinfo) > 0 {
		info := cpuinfo[0]
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>CPU信息</h2>
        <div class="info-item"><span class="label">型号:</span> %s</div>
        <div class="info-item"><span class="label">核心数:</span> %d</div>
    </div>
`, info.ModelName, len(cpuinfo))
	}

	// 磁盘信息
	if diskinfo.Total/1024/1024 > 1024 {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>磁盘信息</h2>
        <div class="info-item"><span class="label">总容量:</span> %.2f GB</div>
        <div class="info-item"><span class="label">已使用:</span> %.2f GB</div>
        <div class="info-item"><span class="label">使用率:</span> %.2f%%</div>
    </div>
`, float64(diskinfo.Total)/1024/1024/1024, float64(diskinfo.Used)/1024/1024/1024, diskinfo.UsedPercent)
	} else {
		html += fmt.Sprintf(`
    <div class="info-section">
        <h2>磁盘信息</h2>
        <div class="info-item"><span class="label">总容量:</span> %.2f MB</div>
        <div class="info-item"><span class="label">已使用:</span> %.2f MB</div>
        <div class="info-item"><span class="label">使用率:</span> %.2f%%</div>
    </div>
`, float64(diskinfo.Total)/1024/1024, float64(diskinfo.Used)/1024/1024, diskinfo.UsedPercent)
	}

	html += `
</body>
</html>
`

	fmt.Fprint(w, html)
}

func main() {
	http.HandleFunc("/", systemInfoHandler)
	port := flag.Int("port", 8080, "端口号")
	flag.Parse()

	fmt.Printf("服务器启动在 localhost:%d\n", *port)
	log.Fatal(http.ListenAndServe(fmt.Sprintf(":%d", *port), nil))
}
