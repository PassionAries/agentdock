//go:build !windows && !darwin && !linux

package desktopruntime

import (
	"context"
	"errors"
)

var errServiceControlUnsupported = errors.New("当前平台不支持 AgentDock 桌面服务管理")

func platformServiceStatus(context.Context, string) (ServiceStatus, error) {
	return ServiceStatus{}, errServiceControlUnsupported
}
func platformServiceAction(context.Context, string, string) error {
	return errServiceControlUnsupported
}
func platformSetAutostart(context.Context, string, string, bool) error {
	return errServiceControlUnsupported
}
func platformPrepareCoreEnvironment(string) error { return errServiceControlUnsupported }
