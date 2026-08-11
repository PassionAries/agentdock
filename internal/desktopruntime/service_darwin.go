//go:build darwin

package desktopruntime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"
)

func launchdDomain() string { return "gui/" + strconv.Itoa(os.Getuid()) }

func launchctlBinary() string {
	if configured := strings.TrimSpace(os.Getenv("AGENTDOCK_LAUNCHCTL_BIN")); configured != "" {
		return configured
	}
	return "/bin/launchctl"
}

func launchdTarget(label string) string { return launchdDomain() + "/" + label }

func launchdLoaded(ctx context.Context, label string) bool {
	_, err := runCommand(ctx, launchctlBinary(), "print", launchdTarget(label))
	return err == nil
}

func kickstartRegisteredLaunchAgent(ctx context.Context, label string) error {
	if !launchdLoaded(ctx, label) {
		return fmt.Errorf("后台服务 %s 尚未由 AgentDock.app 注册", label)
	}
	_, err := runCommand(ctx, launchctlBinary(), "kickstart", "-k", launchdTarget(label))
	return err
}

func platformServiceStatus(ctx context.Context, runtimeRoot string) (ServiceStatus, error) {
	manifest, _, values, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return ServiceStatus{}, err
	}
	loaded := launchdLoaded(ctx, manifest.ServiceName)
	return ServiceStatus{
		Running:        loaded,
		Healthy:        loaded && healthy(ctx, values),
		StartupEnabled: loaded,
	}, nil
}

func platformServiceAction(ctx context.Context, runtimeRoot, action string) error {
	manifest, _, values, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return err
	}

	// SMAppService 是 macOS 桌面后台服务的唯一注册入口。Go 只允许重启已经注册的
	// Core；这样 Quick Tunnel 可以在写入新公网地址后刷新 Core，又不会重新引入
	// ~/Library/LaunchAgents 或 launchctl bootstrap 这套第二生命周期。
	switch action {
	case "start", "restart":
		if err := kickstartRegisteredLaunchAgent(ctx, manifest.ServiceName); err != nil {
			return err
		}
		return waitHealthy(ctx, values, 30*time.Second)
	case "stop":
		return errors.New("macOS 后台服务停用由 AgentDock.app 的 SMAppService 管理")
	default:
		return errors.New("不支持的 AgentDock 服务操作")
	}
}

func platformSetAutostart(context.Context, string, string, bool) error {
	return errors.New("macOS 后台服务启停由 AgentDock.app 的 SMAppService 管理")
}
