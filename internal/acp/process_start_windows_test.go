//go:build windows

package acp

import (
	"os/exec"
	"syscall"
	"testing"

	"golang.org/x/sys/windows"
)

func TestConfigureAgentCommandKeepsConsoleSemanticsHidden(t *testing.T) {
	cmd := exec.Command("cmd.exe")

	configureAgentCommand(cmd)

	if cmd.SysProcAttr == nil {
		t.Fatal("configureAgentCommand did not initialize Windows process attributes")
	}
	if !cmd.SysProcAttr.HideWindow {
		t.Fatal("configureAgentCommand did not hide the adapter window")
	}
	if cmd.SysProcAttr.CreationFlags&windows.CREATE_NO_WINDOW != 0 {
		t.Fatalf("creation flags = %#x, CREATE_NO_WINDOW must stay disabled for ACP adapters", cmd.SysProcAttr.CreationFlags)
	}
}

func TestConfigureAgentCommandPreservesExistingCreationFlags(t *testing.T) {
	existingFlags := uint32(windows.CREATE_NEW_PROCESS_GROUP)
	cmd := exec.Command("cmd.exe")
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: existingFlags}

	configureAgentCommand(cmd)

	if cmd.SysProcAttr.CreationFlags != existingFlags {
		t.Fatalf("creation flags = %#x, want %#x", cmd.SysProcAttr.CreationFlags, existingFlags)
	}
}
