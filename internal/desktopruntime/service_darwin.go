//go:build darwin

package desktopruntime

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
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

func launchAgentPath(label string) string {
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "LaunchAgents", label+".plist")
}

func launchdLoaded(ctx context.Context, label string) bool {
	_, err := runCommand(ctx, launchctlBinary(), "print", launchdTarget(label))
	return err == nil
}

func launchdAutostartEnabled(ctx context.Context, label string) bool {
	output, err := runCommand(ctx, launchctlBinary(), "print-disabled", launchdDomain())
	if err != nil {
		return true
	}
	return !strings.Contains(output, `"`+label+`" => true`) && !strings.Contains(output, label+" => true")
}

func launchdSetDisabled(ctx context.Context, label string, disabled bool) error {
	action := "enable"
	if disabled {
		action = "disable"
	}
	_, err := runCommand(ctx, launchctlBinary(), action, launchdTarget(label))
	return err
}

func launchdStart(ctx context.Context, label string) error {
	if err := launchdSetDisabled(ctx, label, false); err != nil {
		return err
	}
	if !launchdLoaded(ctx, label) {
		path := launchAgentPath(label)
		if _, err := os.Stat(path); err != nil {
			return fmt.Errorf("LaunchAgent 不存在: %s", path)
		}
		if _, err := runCommand(ctx, launchctlBinary(), "bootstrap", launchdDomain(), path); err != nil {
			return err
		}
	}
	_, err := runCommand(ctx, launchctlBinary(), "kickstart", "-k", launchdTarget(label))
	return err
}

func launchdStop(ctx context.Context, label string) error {
	if !launchdLoaded(ctx, label) {
		return nil
	}
	_, err := runCommand(ctx, launchctlBinary(), "bootout", launchdTarget(label))
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
		StartupEnabled: launchdAutostartEnabled(ctx, manifest.ServiceName),
	}, nil
}

func platformServiceAction(ctx context.Context, runtimeRoot, action string) error {
	manifest, _, values, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return err
	}
	switch action {
	case "start":
		if err := launchdStart(ctx, manifest.ServiceName); err != nil {
			return err
		}
		return waitHealthy(ctx, values, 30*time.Second)
	case "stop":
		return launchdStop(ctx, manifest.ServiceName)
	case "restart":
		if err := launchdStart(ctx, manifest.ServiceName); err != nil {
			return err
		}
		return waitHealthy(ctx, values, 30*time.Second)
	default:
		return errors.New("不支持的 AgentDock 服务操作")
	}
}

func platformSetAutostart(ctx context.Context, runtimeRoot, component string, enabled bool) error {
	if component != "core" {
		return errors.New("macOS 菜单栏登录启动由 SMAppService 管理")
	}
	manifest, _, _, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return err
	}
	if enabled {
		return launchdStart(ctx, manifest.ServiceName)
	}
	if err := launchdSetDisabled(ctx, manifest.ServiceName, true); err != nil {
		return err
	}
	return launchdStop(ctx, manifest.ServiceName)
}
