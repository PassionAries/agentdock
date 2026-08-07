//go:build darwin

package desktopruntime

import (
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func platformPrepareLaunchEnvironment(component string) error {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return fmt.Errorf("解析 macOS 用户目录失败: %w", err)
	}
	workDir := filepath.Join(home, "AgentDock")
	if err := os.MkdirAll(workDir, 0o755); err != nil {
		return fmt.Errorf("创建 AgentDock 工作目录失败: %w", err)
	}
	if err := os.Chdir(workDir); err != nil {
		return fmt.Errorf("进入 AgentDock 工作目录失败: %w", err)
	}

	logDir := filepath.Join(home, "Library", "Logs", "AgentDock")
	if err := os.MkdirAll(logDir, 0o700); err != nil {
		return fmt.Errorf("创建 AgentDock 日志目录失败: %w", err)
	}
	stdoutName, stderrName := "agentdock.out.log", "agentdock.err.log"
	if component == "tunnel" {
		stdoutName, stderrName = "cloudflared.out.log", "cloudflared.err.log"
	}
	if err := redirectDescriptor(syscall.Stdout, filepath.Join(logDir, stdoutName)); err != nil {
		return err
	}
	if err := redirectDescriptor(syscall.Stderr, filepath.Join(logDir, stderrName)); err != nil {
		return err
	}
	return nil
}

func redirectDescriptor(descriptor int, path string) error {
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return fmt.Errorf("打开 AgentDock 日志失败 %s: %w", path, err)
	}
	defer file.Close()
	if err := os.Chmod(path, 0o600); err != nil {
		return fmt.Errorf("设置 AgentDock 日志权限失败 %s: %w", path, err)
	}
	if err := syscall.Dup2(int(file.Fd()), descriptor); err != nil {
		return fmt.Errorf("重定向 AgentDock 日志失败 %s: %w", path, err)
	}
	return nil
}
