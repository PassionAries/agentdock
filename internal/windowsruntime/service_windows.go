//go:build windows

package windowsruntime

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

func platformServiceStatus(ctx context.Context, runtimeRoot string) (ServiceStatus, error) {
	manifest, _, err := loadDesktopManifest(runtimeRoot)
	if err != nil {
		return ServiceStatus{}, err
	}
	running, err := processRunningAtPath(manifest.AgentDockBinary)
	if err != nil {
		return ServiceStatus{}, err
	}
	healthy := testHealth(ctx, manifest.HealthURL())
	startupEnabled, err := coreAutostartEnabled(ctx, manifest)
	if err != nil {
		return ServiceStatus{}, fmt.Errorf("读取 AgentDock 开机启动状态失败: %w", err)
	}
	return ServiceStatus{Running: running || healthy, Healthy: healthy, StartupEnabled: startupEnabled}, nil
}

func platformServiceAction(ctx context.Context, runtimeRoot, action string) error {
	manifest, root, err := loadDesktopManifest(runtimeRoot)
	if err != nil {
		return err
	}

	switch action {
	case "start":
		return startCore(ctx, manifest, root)
	case "stop":
		return stopCore(ctx, manifest)
	case "restart":
		if err := stopCore(ctx, manifest); err != nil {
			return err
		}
		return startCore(ctx, manifest, root)
	default:
		return fmt.Errorf("不支持的 Windows 服务操作：%s", action)
	}
}

func loadDesktopManifest(runtimeRoot string) (Manifest, string, error) {
	root, err := filepath.Abs(strings.TrimSpace(runtimeRoot))
	if err != nil {
		return Manifest{}, "", fmt.Errorf("解析 Windows 运行目录失败: %w", err)
	}
	manifest, err := Load(filepath.Join(root, "runtime.json"))
	if err != nil {
		return Manifest{}, "", fmt.Errorf("读取 Windows 运行清单失败: %w", err)
	}
	return manifest, root, nil
}

func startCore(ctx context.Context, manifest Manifest, runtimeRoot string) error {
	if testHealth(ctx, manifest.HealthURL()) {
		return nil
	}
	if manifest.UsesScheduledTask() {
		if err := runScheduledTaskCommand(ctx, "/Run", "/TN", scheduledTaskPath(manifest.AgentDockTaskName)); err != nil {
			return err
		}
	} else if err := startDetachedCore(manifest, runtimeRoot); err != nil {
		return err
	}
	return waitForHealth(ctx, manifest.HealthURL(), 45*time.Second)
}

func stopCore(ctx context.Context, manifest Manifest) error {
	if manifest.UsesScheduledTask() {
		// /End 在任务未运行时可能返回非零；后续按真实进程路径核对即可。
		_ = runScheduledTaskCommand(ctx, "/End", "/TN", scheduledTaskPath(manifest.AgentDockTaskName))
	}
	if err := StopBinaryProcesses(ctx, manifest.AgentDockBinary, 15*time.Second); err != nil {
		return fmt.Errorf("停止 AgentDock 核心失败: %w", err)
	}
	return nil
}

func startDetachedCore(manifest Manifest, runtimeRoot string) error {
	if info, err := os.Stat(manifest.AgentDockBinary); err != nil || info.IsDir() {
		return fmt.Errorf("找不到 AgentDock 核心程序: %s", manifest.AgentDockBinary)
	}
	logDir := filepath.Join(runtimeRoot, "logs")
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return fmt.Errorf("创建日志目录失败: %w", err)
	}
	stdout, err := os.OpenFile(filepath.Join(logDir, "agentdock.out.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("打开 AgentDock 输出日志失败: %w", err)
	}
	defer stdout.Close()
	stderr, err := os.OpenFile(filepath.Join(logDir, "agentdock.err.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return fmt.Errorf("打开 AgentDock 错误日志失败: %w", err)
	}
	defer stderr.Close()

	command := exec.Command(manifest.AgentDockBinary, "service", "launch-core", "--runtime-root", runtimeRoot)
	command.Stdout = stdout
	command.Stderr = stderr
	command.Dir = defaultWindowsWorkDir()
	command.SysProcAttr = &syscall.SysProcAttr{
		HideWindow:    true,
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS,
	}
	if err := command.Start(); err != nil {
		return fmt.Errorf("启动 AgentDock 核心失败: %w", err)
	}
	if err := command.Process.Release(); err != nil {
		return fmt.Errorf("释放 AgentDock 后台进程句柄失败: %w", err)
	}
	return nil
}

func defaultWindowsWorkDir() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	workDir := filepath.Join(home, "AgentDock")
	if err := os.MkdirAll(workDir, 0o700); err != nil {
		return home
	}
	return workDir
}

func waitForHealth(ctx context.Context, url string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if testHealth(ctx, url) {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(500 * time.Millisecond):
		}
	}
	return fmt.Errorf("AgentDock 健康检查失败: %s", url)
}

func testHealth(ctx context.Context, url string) bool {
	requestCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, url, nil)
	if err != nil {
		return false
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return false
	}
	defer response.Body.Close()
	return response.StatusCode >= 200 && response.StatusCode < 300
}
