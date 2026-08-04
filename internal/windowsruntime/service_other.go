//go:build !windows

package windowsruntime

import (
	"context"
	"errors"
)

var errWindowsServiceControlUnsupported = errors.New("agentdock service 当前只支持 Windows 桌面安装")

func platformServiceStatus(context.Context, string) (ServiceStatus, error) {
	return ServiceStatus{}, errWindowsServiceControlUnsupported
}

func platformServiceAction(context.Context, string, string) error {
	return errWindowsServiceControlUnsupported
}

func platformSetAutostart(context.Context, string, string, bool) error {
	return errWindowsServiceControlUnsupported
}

func platformPrepareCoreEnvironment(string) error {
	return errWindowsServiceControlUnsupported
}
