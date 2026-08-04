//go:build windows

package desktopruntime

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type desktopACPAdapter struct {
	Command string
	Args    []string
}

func resolveDesktopACPAdapter(agent, runtimeRoot, configuredCommand string) (desktopACPAdapter, error) {
	var executableNames []string
	var args []string
	switch strings.ToLower(strings.TrimSpace(agent)) {
	case "codex":
		executableNames = []string{"codex-acp.exe", "codex-acp"}
	case "claude":
		executableNames = []string{"claude-agent-acp.exe", "claude-agent-acp"}
	case "grok":
		executableNames = []string{"grok.exe", "grok"}
		args = []string{"agent", "stdio"}
	default:
		return desktopACPAdapter{}, fmt.Errorf("不支持的 Coding Agent: %s", agent)
	}

	var candidates []string
	if strings.TrimSpace(configuredCommand) != "" {
		candidates = append(candidates, configuredCommand)
	}
	for _, name := range executableNames {
		if path, err := exec.LookPath(name); err == nil {
			candidates = append(candidates, path)
		}
	}
	if userHome, err := os.UserHomeDir(); err == nil {
		for _, name := range executableNames {
			candidates = append(candidates, filepath.Join(userHome, ".local", "bin", name))
		}
	}
	if localAppData := strings.TrimSpace(os.Getenv("LOCALAPPDATA")); localAppData != "" {
		for _, name := range executableNames {
			candidates = append(candidates,
				filepath.Join(localAppData, "Programs", "Grok", name),
				filepath.Join(localAppData, "Microsoft", "WinGet", "Links", name),
			)
		}
	}
	for _, name := range executableNames {
		candidates = append(candidates, filepath.Join(runtimeRoot, "bin", name))
	}

	seen := map[string]struct{}{}
	for _, candidate := range candidates {
		absolute, err := filepath.Abs(candidate)
		if err != nil {
			continue
		}
		absolute = filepath.Clean(absolute)
		key := strings.ToLower(absolute)
		if _, exists := seen[key]; exists {
			continue
		}
		seen[key] = struct{}{}
		info, err := os.Stat(absolute)
		if err != nil || !info.Mode().IsRegular() {
			continue
		}
		switch strings.ToLower(filepath.Ext(absolute)) {
		case ".cmd", ".bat", ".ps1":
			// ACP stdout 必须完全保留给 NDJSON 协议，首版不通过命令解释器包装脚本入口。
			continue
		}
		return desktopACPAdapter{Command: absolute, Args: append([]string(nil), args...)}, nil
	}

	name := executableNames[0]
	return desktopACPAdapter{}, errors.New("未找到可直接执行的 Coding Agent：" + name)
}
