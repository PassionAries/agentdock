//go:build windows

package selfupdate

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"syscall"
	"time"

	"golang.org/x/sys/windows"
)

const windowsDesktopRepairCommand = "__repair-desktop-runtime"

const windowsDesktopRepairMutexName = `Local\AgentDockDesktopRepair`

// RepairDesktopRuntimeIfNeeded 修复“旧 updater 先把 core 升到新版本、但仍留下旧控制面板”的过渡状态。
// 这里只允许修复与当前 core 同版本的桌面组件，绝不在服务启动时顺带升级 core。
func RepairDesktopRuntimeIfNeeded(_ context.Context, output io.Writer) error {
	opts, err := runtimeOptions(output)
	if err != nil {
		return err
	}
	if opts.DesktopTargetPath == "" || normalizeVersion(opts.CurrentVersion) == "vdev" {
		return nil
	}
	if normalizeVersion(opts.DesktopCurrentVersion) == normalizeVersion(opts.CurrentVersion) {
		return nil
	}

	// 首个修复版本会由旧 updater 先替换 core；旧 helper 随即等待新 core 的健康端点。
	// 因此这里只启动独立修复进程，不能在 core 启动路径同步下载 Release，否则慢网络会触发旧 helper 回滚。
	if windows.GetCurrentProcessToken().IsElevated() {
		return launchWindowsDesktopRepairViaShell(opts.ExecutablePath)
	}
	return launchWindowsDesktopRepair(opts.ExecutablePath)
}

func runDesktopRepair(ctx context.Context, output io.Writer) error {
	opts, inspection, err := inspectDesktopRepair(ctx, output)
	if err != nil || opts.DesktopTargetPath == "" || !inspection.Result.DesktopUpdateAvailable {
		return err
	}
	return runDesktopOnlyUpdate(ctx, opts, inspection)
}

func inspectDesktopRepair(ctx context.Context, output io.Writer) (options, updateInspection, error) {
	opts, err := runtimeOptions(output)
	if err != nil {
		return options{}, updateInspection{}, err
	}
	if opts.DesktopTargetPath == "" || normalizeVersion(opts.CurrentVersion) == "vdev" {
		return opts, updateInspection{}, nil
	}
	if normalizeVersion(opts.DesktopCurrentVersion) == normalizeVersion(opts.CurrentVersion) {
		return opts, updateInspection{}, nil
	}

	repairCtx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	inspection, err := inspectUpdate(repairCtx, opts)
	if err != nil {
		return options{}, updateInspection{}, err
	}
	if normalizeVersion(inspection.Result.CurrentVersion) != normalizeVersion(inspection.Result.LatestVersion) {
		return opts, updateInspection{}, nil
	}
	return opts, inspection, nil
}

func launchWindowsDesktopRepair(executable string) error {
	command := exec.Command(executable, windowsDesktopRepairCommand)
	command.SysProcAttr = &syscall.SysProcAttr{
		CreationFlags: windows.CREATE_NEW_PROCESS_GROUP | windows.DETACHED_PROCESS,
	}
	if err := command.Start(); err != nil {
		return errors.New("启动 Windows 控制面板修复进程失败: " + err.Error())
	}
	_ = command.Process.Release()
	return nil
}

func launchWindowsDesktopRepairViaShell(executable string) error {
	// Elevated core 运行在旧版 tray supervisor 创建的 KILL_ON_JOB_CLOSE Job 内；
	// 直接 CreateProcess 的子进程会继承这个 Job。通过 Explorer 承载的 Shell.Application
	// 发起 ShellExecute，可让修复进程使用当前桌面用户的 medium-integrity shell token，
	// 同时脱离 supervisor Job。随后修复进程才可以安全结束主计划任务并替换 tray。
	const shellScript = `$ErrorActionPreference='Stop'; $shell=New-Object -ComObject Shell.Application; $shell.ShellExecute($env:AGENTDOCK_DESKTOP_REPAIR_EXE, $env:AGENTDOCK_DESKTOP_REPAIR_ARGS, '', 'open', 0)`
	launchCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	command := exec.CommandContext(
		launchCtx,
		"powershell.exe",
		"-NoLogo",
		"-NoProfile",
		"-NonInteractive",
		"-WindowStyle", "Hidden",
		"-Command", shellScript,
	)
	command.Env = append(
		os.Environ(),
		"AGENTDOCK_DESKTOP_REPAIR_EXE="+executable,
		"AGENTDOCK_DESKTOP_REPAIR_ARGS="+windowsDesktopRepairCommand,
	)
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_NO_WINDOW}
	if output, err := command.CombinedOutput(); err != nil {
		return errors.New("通过 Windows Shell 启动标准权限控制面板修复失败: " + err.Error() + ": " + string(output))
	}
	return nil
}

func handleWindowsDesktopRepairCommand(ctx context.Context, args []string) (bool, error) {
	if len(args) != 1 || args[0] != windowsDesktopRepairCommand {
		return false, nil
	}
	mutexName, err := windows.UTF16PtrFromString(windowsDesktopRepairMutexName)
	if err != nil {
		return true, err
	}
	mutex, err := windows.CreateMutex(nil, true, mutexName)
	if err == windows.ERROR_ALREADY_EXISTS {
		if mutex != 0 {
			_ = windows.CloseHandle(mutex)
		}
		return true, nil
	}
	if err != nil {
		return true, fmt.Errorf("创建 Windows 控制面板修复互斥锁失败: %w", err)
	}
	defer func() {
		_ = windows.ReleaseMutex(mutex)
		_ = windows.CloseHandle(mutex)
	}()
	return true, runDesktopRepair(ctx, os.Stdout)
}
