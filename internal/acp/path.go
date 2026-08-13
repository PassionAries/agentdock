package acp

import (
	"os"
	"path/filepath"
	"strings"
)

func (m *Manager) resolveCWD(raw string) (string, error) {
	candidate := strings.TrimSpace(raw)
	if candidate == "" {
		candidate = m.opts.DefaultCWD
	} else if !filepath.IsAbs(candidate) {
		candidate = filepath.Join(m.opts.DefaultCWD, candidate)
	}
	candidate = filepath.Clean(candidate)
	realPath, err := filepath.EvalSymlinks(candidate)
	if err != nil {
		return "", newError("ACP_CWD_INVALID", "resolve ACP working directory", false, map[string]any{"cwd": raw}, err)
	}
	info, err := os.Stat(realPath)
	if err != nil {
		return "", newError("ACP_CWD_INVALID", "stat ACP working directory", false, map[string]any{"cwd": raw}, err)
	}
	if !info.IsDir() {
		return "", newError("ACP_CWD_INVALID", "ACP working directory is not a directory", false, map[string]any{"cwd": raw}, nil)
	}
	return realPath, nil
}

func (m *Manager) resolveAdditionalDirectories(values []string, cwd string) ([]string, error) {
	if len(values) == 0 {
		return nil, nil
	}
	if len(values) > 16 {
		return nil, newError("ACP_ADDITIONAL_DIRECTORIES_INVALID", "ACP additional directories exceed the limit", false, map[string]any{"count": len(values), "limit": 16}, nil)
	}
	result := make([]string, 0, len(values))
	infos := make([]os.FileInfo, 0, len(values))
	for _, raw := range values {
		resolved, err := m.resolveCWD(raw)
		if err != nil {
			return nil, err
		}
		if resolved == cwd {
			continue
		}
		info, err := os.Stat(resolved)
		if err != nil {
			return nil, newError("ACP_CWD_INVALID", "stat ACP additional directory", false, map[string]any{"path": resolved}, err)
		}
		duplicate := false
		for _, existing := range infos {
			if os.SameFile(existing, info) {
				duplicate = true
				break
			}
		}
		if duplicate {
			continue
		}
		infos = append(infos, info)
		result = append(result, resolved)
	}
	return result, nil
}
