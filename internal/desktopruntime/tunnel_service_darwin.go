//go:build darwin

package desktopruntime

import "context"

func platformTunnelServiceActive(ctx context.Context, manifest unixRuntimeManifest) bool {
	return launchdLoaded(ctx, manifest.TunnelServiceName)
}
func platformTunnelServiceEnabled(ctx context.Context, manifest unixRuntimeManifest) bool {
	return launchdAutostartEnabled(ctx, manifest.TunnelServiceName)
}
func platformTunnelServiceAction(ctx context.Context, manifest unixRuntimeManifest, action string) error {
	switch action {
	case "start", "restart":
		return launchdStart(ctx, manifest.TunnelServiceName)
	case "stop":
		return launchdStop(ctx, manifest.TunnelServiceName)
	default:
		return nil
	}
}
func platformTunnelServiceSetEnabled(ctx context.Context, manifest unixRuntimeManifest, enabled bool) error {
	if enabled {
		return launchdStart(ctx, manifest.TunnelServiceName)
	}
	if err := launchdSetDisabled(ctx, manifest.TunnelServiceName, true); err != nil {
		return err
	}
	return launchdStop(ctx, manifest.TunnelServiceName)
}
