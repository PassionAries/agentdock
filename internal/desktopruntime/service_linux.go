//go:build linux

package desktopruntime

import (
	"context"
	"errors"
	"os"
	"os/exec"
	"time"
)

func linuxServiceManager(manifest unixRuntimeManifest) string {
	if manifest.ServiceManager != "" {
		return manifest.ServiceManager
	}
	if _, err := os.Stat("/run/systemd/system"); err == nil {
		return "systemd"
	}
	if _, err := exec.LookPath("rc-service"); err == nil {
		return "openrc"
	}
	return "none"
}

func linuxServiceActive(ctx context.Context, manager, name string) bool {
	switch manager {
	case "systemd":
		_, err := runCommand(ctx, "systemctl", "is-active", "--quiet", name)
		return err == nil
	case "openrc":
		_, err := runCommand(ctx, "rc-service", name, "status")
		return err == nil
	default:
		return false
	}
}

func linuxServiceEnabled(ctx context.Context, manager, name string) bool {
	switch manager {
	case "systemd":
		_, err := runCommand(ctx, "systemctl", "is-enabled", "--quiet", name)
		return err == nil
	case "openrc":
		_, err := runCommand(ctx, "rc-update", "show", "default")
		return err == nil
	default:
		return false
	}
}

func linuxServiceAction(ctx context.Context, manager, name, action string) error {
	switch manager {
	case "systemd":
		_, err := runCommand(ctx, "systemctl", action, name)
		return err
	case "openrc":
		_, err := runCommand(ctx, "rc-service", name, action)
		return err
	default:
		return errors.New("未检测到 systemd 或 OpenRC")
	}
}

func platformServiceStatus(ctx context.Context, runtimeRoot string) (ServiceStatus, error) {
	manifest, _, values, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return ServiceStatus{}, err
	}
	manager := linuxServiceManager(manifest)
	running := linuxServiceActive(ctx, manager, manifest.ServiceName)
	return ServiceStatus{Running: running, Healthy: running && healthy(ctx, values), StartupEnabled: linuxServiceEnabled(ctx, manager, manifest.ServiceName)}, nil
}

func platformServiceAction(ctx context.Context, runtimeRoot, action string) error {
	manifest, _, values, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return err
	}
	manager := linuxServiceManager(manifest)
	if err := linuxServiceAction(ctx, manager, manifest.ServiceName, action); err != nil {
		return err
	}
	if action == "start" || action == "restart" {
		return waitHealthy(ctx, values, 30*time.Second)
	}
	return nil
}

func platformSetAutostart(ctx context.Context, runtimeRoot, component string, enabled bool) error {
	if component != "core" {
		return errors.New("Linux 不支持桌面托盘开机启动组件")
	}
	manifest, _, _, err := loadCoreEnvironment(runtimeRoot)
	if err != nil {
		return err
	}
	manager := linuxServiceManager(manifest)
	switch manager {
	case "systemd":
		action := "disable"
		if enabled {
			action = "enable"
		}
		_, err = runCommand(ctx, "systemctl", action, manifest.ServiceName)
		return err
	case "openrc":
		action := "del"
		if enabled {
			action = "add"
		}
		_, err = runCommand(ctx, "rc-update", action, manifest.ServiceName, "default")
		return err
	default:
		return errors.New("未检测到 systemd 或 OpenRC")
	}
}
