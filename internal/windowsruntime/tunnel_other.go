//go:build !windows

package windowsruntime

import (
	"context"
	"errors"
)

func platformTunnelStatus(context.Context, string) (TunnelStatus, error) {
	return TunnelStatus{}, errors.New("Windows Tunnel 管理仅支持 Windows")
}

func platformTunnelAction(context.Context, string, string) error {
	return errors.New("Windows Tunnel 管理仅支持 Windows")
}

func platformConfigureTunnel(context.Context, TunnelConfigureRequest) error {
	return errors.New("Windows Tunnel 管理仅支持 Windows")
}

func platformSetTunnelAutostart(context.Context, string, bool) error {
	return errors.New("Windows Tunnel 管理仅支持 Windows")
}
