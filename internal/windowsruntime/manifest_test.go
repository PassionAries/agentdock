package windowsruntime

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadForBinary(t *testing.T) {
	root := t.TempDir()
	binary := filepath.Join(root, "bin", "agentdock.exe")
	if err := os.MkdirAll(filepath.Dir(binary), 0o755); err != nil {
		t.Fatal(err)
	}
	manifest := `{
  "schema_version": 1,
  "agentdock_binary": "` + filepath.ToSlash(binary) + `",
  "tray_binary": "` + filepath.ToSlash(filepath.Join(root, "bin", "agentdock-tray.exe")) + `",
  "agentdock_launcher": "` + filepath.ToSlash(filepath.Join(root, "start-agentdock.ps1")) + `",
  "cloudflared_binary": "` + filepath.ToSlash(filepath.Join(root, "bin", "cloudflared.exe")) + `",
  "startup_value_name": "AgentDockCore",
  "tray_startup_value_name": "AgentDockTray",
  "cloudflared_startup_value_name": "AgentDockCloudflared",
  "host": "127.0.0.1",
  "port": 8765,
  "local_mcp_url": "http://127.0.0.1:8765/mcp",
  "tunnel_mode": "none",
  "install_channel": "setup"
}`
	if err := os.WriteFile(PathForBinary(binary), []byte(manifest), 0o600); err != nil {
		t.Fatal(err)
	}
	loaded, err := LoadForBinary(binary)
	if err != nil {
		t.Fatal(err)
	}
	if got := loaded.HealthURL(); got != "http://127.0.0.1:8765/healthz" {
		t.Fatalf("unexpected health URL: %s", got)
	}
	if loaded.StartupValueName != "AgentDockCore" || loaded.TrayStartupValueName != "AgentDockTray" {
		t.Fatalf("startup names were not loaded: %#v", loaded)
	}
	if got := filepath.Base(loaded.CloudflaredBinary); got != "cloudflared.exe" {
		t.Fatalf("unexpected cloudflared binary: %s", got)
	}
}

func TestManifestRejectsPublicURLInLocalMode(t *testing.T) {
	manifest := Manifest{
		SchemaVersion:   SchemaVersion,
		AgentDockBinary: filepath.Join(t.TempDir(), "agentdock.exe"),
		Host:            "127.0.0.1",
		Port:            8765,
		LocalMCPURL:     "http://127.0.0.1:8765/mcp",
		TunnelMode:      "none",
		PublicURL:       "https://example.com",
	}
	if err := manifest.Validate(); err == nil {
		t.Fatal("expected local mode with public URL to fail")
	}
}

func TestManifestElevatedModeRequiresScheduledTask(t *testing.T) {
	manifest := Manifest{
		SchemaVersion:   SchemaVersion,
		AgentDockBinary: filepath.Join(t.TempDir(), "agentdock.exe"),
		PrivilegeMode:   "elevated",
		Host:            "127.0.0.1",
		Port:            8765,
		LocalMCPURL:     "http://127.0.0.1:8765/mcp",
		TunnelMode:      "none",
	}
	if err := manifest.Validate(); err == nil {
		t.Fatal("expected elevated mode without a scheduled task to fail")
	}

	manifest.AgentDockTaskName = "AgentDock"
	if err := manifest.Validate(); err != nil {
		t.Fatalf("elevated manifest should be valid: %v", err)
	}
	if !manifest.UsesScheduledTask() {
		t.Fatal("elevated manifest should use Task Scheduler")
	}
}

func TestManifestKeepsLegacyStandardModeCompatible(t *testing.T) {
	manifest := Manifest{
		SchemaVersion:   SchemaVersion,
		AgentDockBinary: filepath.Join(t.TempDir(), "agentdock.exe"),
		Host:            "127.0.0.1",
		Port:            8765,
		LocalMCPURL:     "http://127.0.0.1:8765/mcp",
		TunnelMode:      "none",
	}
	if err := manifest.Validate(); err != nil {
		t.Fatalf("legacy manifest without privilege fields should remain valid: %v", err)
	}
	if manifest.UsesScheduledTask() {
		t.Fatal("legacy manifest must remain a standard launcher installation")
	}
}
