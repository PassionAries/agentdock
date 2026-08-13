//go:build windows

package process

import (
	"fmt"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// Controller owns a Windows Job Object. Closing the job terminates any descendants
// that outlive the direct child, which keeps command, Skill and browser process trees bounded.
type Controller struct {
	mu  sync.Mutex
	job windows.Handle
}

// Configure 在后台子进程启动前禁用控制台窗口，同时保留调用方已有的创建标志。
// 标准命令、WSL 文件辅助进程和 stdio MCP 通过该入口启动；ACP 为兼容 Windows sandbox 使用独立启动策略。
func Configure(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
	cmd.SysProcAttr.CreationFlags |= windows.CREATE_NO_WINDOW
}

func Attach(cmd *exec.Cmd) (*Controller, error) {
	if cmd == nil || cmd.Process == nil {
		return nil, fmt.Errorf("attach process controller: command has not started")
	}
	return AttachPID(cmd.Process.Pid)
}

func AttachPID(pid int) (*Controller, error) {
	if pid <= 0 {
		return nil, fmt.Errorf("attach process controller: invalid pid %d", pid)
	}
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return nil, fmt.Errorf("create Windows Job Object: %w", err)
	}
	closeJob := true
	defer func() {
		if closeJob {
			_ = windows.CloseHandle(job)
		}
	}()

	limits := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	limits.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(
		job,
		windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&limits)),
		uint32(unsafe.Sizeof(limits)),
	); err != nil {
		return nil, fmt.Errorf("configure Windows Job Object: %w", err)
	}

	process, err := windows.OpenProcess(
		windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE,
		false,
		uint32(pid),
	)
	if err != nil {
		return nil, fmt.Errorf("open child process for Job Object: %w", err)
	}
	defer windows.CloseHandle(process)
	if err := windows.AssignProcessToJobObject(job, process); err != nil {
		return nil, fmt.Errorf("assign child process to Job Object: %w", err)
	}
	closeJob = false
	return &Controller{job: job}, nil
}

func (c *Controller) Terminate() error {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.job == 0 {
		return nil
	}
	if err := windows.TerminateJobObject(c.job, 1); err != nil {
		return fmt.Errorf("terminate Windows Job Object: %w", err)
	}
	return nil
}

func (c *Controller) Close() error {
	if c == nil {
		return nil
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.job == 0 {
		return nil
	}
	err := windows.CloseHandle(c.job)
	c.job = 0
	if err != nil {
		return fmt.Errorf("close Windows Job Object: %w", err)
	}
	return nil
}
