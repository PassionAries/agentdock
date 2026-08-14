//go:build !darwin && !windows

package selfupdate

import (
	"context"
	"errors"
)

func detectDesktopUpdateTarget() string {
	return ""
}

func desktopUpdateVersion(string) string {
	return ""
}

func desktopUpdateOwnsExecutable(string, string) bool {
	return false
}

func extractDesktopUpdateArchive(context.Context, []byte, string, string) (string, error) {
	return "", errors.New("当前系统不支持 macOS 桌面更新")
}
