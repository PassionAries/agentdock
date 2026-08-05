//go:build !darwin && !windows

package selfupdate

import (
	"context"
	"errors"
	"strings"
)

func prepareDesktopUpdate(
	_ context.Context,
	targetPath string,
	stagedPath string,
	_ string,
) (desktopUpdateTransaction, error) {
	if strings.TrimSpace(targetPath) == "" && strings.TrimSpace(stagedPath) == "" {
		return nil, nil
	}
	return nil, errors.New("当前系统不支持 macOS 桌面更新")
}
