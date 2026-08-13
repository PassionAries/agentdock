//go:build darwin || linux

package acp

import (
	"os/exec"

	processcontrol "github.com/uvwt/agentdock/internal/process"
)

func configureAgentCommand(cmd *exec.Cmd) {
	processcontrol.Configure(cmd)
}
