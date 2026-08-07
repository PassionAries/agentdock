//go:build darwin

package desktopruntime

import (
	"os"
	"path/filepath"
)

// DefaultRuntimeRoot 返回 macOS 桌面版固定的当前用户运行目录。
// LaunchAgent plist 位于 App Bundle 内，不能在构建时写入具体用户名，因此由 Core 自己解析。
func DefaultRuntimeRoot() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, "Library", "Application Support", "AgentDock")
}
