//go:build windows

package windowsruntime

import (
	"context"
	"encoding/xml"
	"errors"
	"fmt"
	"os/exec"
	"strings"

	"golang.org/x/sys/windows/registry"
)

const windowsRunKey = `Software\Microsoft\Windows\CurrentVersion\Run`

type scheduledTaskXML struct {
	Settings struct {
		Enabled bool `xml:"Enabled"`
	} `xml:"Settings"`
}

func platformSetAutostart(ctx context.Context, runtimeRoot, component string, enabled bool) error {
	manifest, root, err := loadDesktopManifest(runtimeRoot)
	if err != nil {
		return err
	}

	switch component {
	case "core":
		if manifest.UsesScheduledTask() {
			action := "/Disable"
			if enabled {
				action = "/Enable"
			}
			return runScheduledTaskCommand(ctx, "/Change", "/TN", scheduledTaskPath(manifest.AgentDockTaskName), action)
		}
		name := defaultString(manifest.StartupValueName, "AgentDock")
		if !enabled {
			return removeRunValue(name)
		}
		return setRunValue(name, coreStartupCommand(manifest, root))
	case "tray":
		name := defaultString(manifest.TrayStartupValueName, "AgentDockTray")
		if !enabled {
			return removeRunValue(name)
		}
		if strings.TrimSpace(manifest.TrayBinary) == "" {
			return errors.New("Windows runtime manifest 缺少 tray_binary")
		}
		return setRunValue(name, quoteWindowsArgument(manifest.TrayBinary)+" --background")
	default:
		return fmt.Errorf("不支持的开机启动组件：%s", component)
	}
}

func coreAutostartEnabled(ctx context.Context, manifest Manifest) (bool, error) {
	if manifest.UsesScheduledTask() {
		output, err := exec.CommandContext(ctx, "schtasks.exe", "/Query", "/TN", scheduledTaskPath(manifest.AgentDockTaskName), "/XML").Output()
		if err != nil {
			return false, err
		}
		var task scheduledTaskXML
		if err := xml.Unmarshal(output, &task); err != nil {
			return false, err
		}
		return task.Settings.Enabled, nil
	}
	return runValuePresent(defaultString(manifest.StartupValueName, "AgentDock"))
}

func runScheduledTaskCommand(ctx context.Context, args ...string) error {
	output, err := exec.CommandContext(ctx, "schtasks.exe", args...).CombinedOutput()
	if err != nil {
		message := strings.TrimSpace(string(output))
		if message == "" {
			return fmt.Errorf("schtasks %s 失败: %w", strings.Join(args, " "), err)
		}
		return fmt.Errorf("schtasks %s 失败: %w: %s", strings.Join(args, " "), err, message)
	}
	return nil
}

func scheduledTaskPath(name string) string {
	return `\` + strings.TrimLeft(defaultString(name, "AgentDock"), `\`)
}

func coreStartupCommand(manifest Manifest, runtimeRoot string) string {
	if strings.TrimSpace(manifest.TrayBinary) != "" {
		return quoteWindowsArgument(manifest.TrayBinary) + " --start-core --runtime-root " + quoteWindowsArgument(runtimeRoot)
	}
	return quoteWindowsArgument(manifest.AgentDockBinary) + " service start --runtime-root " + quoteWindowsArgument(runtimeRoot)
}

func quoteWindowsArgument(value string) string {
	return `"` + strings.ReplaceAll(value, `"`, `\"`) + `"`
}

func setRunValue(name, value string) error {
	key, _, err := registry.CreateKey(registry.CURRENT_USER, windowsRunKey, registry.SET_VALUE)
	if err != nil {
		return fmt.Errorf("打开 Windows 开机启动注册表失败: %w", err)
	}
	defer key.Close()
	if err := key.SetStringValue(name, value); err != nil {
		return fmt.Errorf("写入 Windows 开机启动注册表失败: %w", err)
	}
	return nil
}

func removeRunValue(name string) error {
	key, err := registry.OpenKey(registry.CURRENT_USER, windowsRunKey, registry.SET_VALUE)
	if errors.Is(err, registry.ErrNotExist) {
		return nil
	}
	if err != nil {
		return fmt.Errorf("打开 Windows 开机启动注册表失败: %w", err)
	}
	defer key.Close()
	if err := key.DeleteValue(name); err != nil && !errors.Is(err, registry.ErrNotExist) {
		return fmt.Errorf("删除 Windows 开机启动注册表失败: %w", err)
	}
	return nil
}

func runValuePresent(name string) (bool, error) {
	key, err := registry.OpenKey(registry.CURRENT_USER, windowsRunKey, registry.QUERY_VALUE)
	if errors.Is(err, registry.ErrNotExist) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	defer key.Close()
	value, _, err := key.GetStringValue(name)
	if errors.Is(err, registry.ErrNotExist) {
		return false, nil
	}
	return strings.TrimSpace(value) != "", err
}

func defaultString(value, fallback string) string {
	if strings.TrimSpace(value) == "" {
		return fallback
	}
	return strings.TrimSpace(value)
}
