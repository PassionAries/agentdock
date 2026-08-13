//go:build windows

package acp

import (
	"os/exec"
	"syscall"
)

// configureAgentCommand 隐藏 adapter 窗口，但保留正常的 Windows console 进程语义。
// Codex 的 Windows sandbox 启动失败时，CREATE_NO_WINDOW 会让 tool call 长期停在
// in_progress；仅使用 HideWindow 可让真实 sandbox 错误正常返回，同时避免弹窗。
func configureAgentCommand(cmd *exec.Cmd) {
	if cmd == nil {
		return
	}
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.HideWindow = true
}
