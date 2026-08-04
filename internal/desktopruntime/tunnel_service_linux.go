//go:build linux

package desktopruntime

import "context"

func platformTunnelServiceActive(ctx context.Context, manifest unixRuntimeManifest) bool {
	return linuxServiceActive(ctx, linuxServiceManager(manifest), manifest.TunnelServiceName)
}
func platformTunnelServiceEnabled(ctx context.Context, manifest unixRuntimeManifest) bool {
	return linuxServiceEnabled(ctx, linuxServiceManager(manifest), manifest.TunnelServiceName)
}
func platformTunnelServiceAction(ctx context.Context, manifest unixRuntimeManifest, action string) error {
	return linuxServiceAction(ctx, linuxServiceManager(manifest), manifest.TunnelServiceName, action)
}
func platformTunnelServiceSetEnabled(ctx context.Context, manifest unixRuntimeManifest, enabled bool) error {
	manager := linuxServiceManager(manifest)
	if manager == "systemd" {
		action := "disable"
		if enabled {
			action = "enable"
		}
		_, err := runCommand(ctx, "systemctl", action, manifest.TunnelServiceName)
		return err
	}
	action := "del"
	if enabled {
		action = "add"
	}
	_, err := runCommand(ctx, "rc-update", action, manifest.TunnelServiceName, "default")
	return err
}
