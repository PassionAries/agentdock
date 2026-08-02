package windowsruntime

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"os"
	"path/filepath"
	"strings"
)

const SchemaVersion = 1

type Manifest struct {
	SchemaVersion       int    `json:"schema_version"`
	AgentDockBinary     string `json:"agentdock_binary"`
	TrayBinary          string `json:"tray_binary,omitempty"`
	AgentDockLauncher   string `json:"agentdock_launcher,omitempty"`
	AgentDockTaskName   string `json:"agentdock_task_name,omitempty"`
	PrivilegeMode       string `json:"privilege_mode,omitempty"`
	CloudflaredLauncher string `json:"cloudflared_launcher,omitempty"`
	Host                string `json:"host"`
	Port                int    `json:"port"`
	LocalMCPURL         string `json:"local_mcp_url"`
	TunnelMode          string `json:"tunnel_mode"`
	PublicURL           string `json:"public_url,omitempty"`
	InstallChannel      string `json:"install_channel"`
}

func PathForBinary(binaryPath string) string {
	return filepath.Join(filepath.Dir(filepath.Dir(binaryPath)), "runtime.json")
}

func Load(path string) (Manifest, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return Manifest{}, err
	}
	var manifest Manifest
	if err := json.Unmarshal(data, &manifest); err != nil {
		return Manifest{}, fmt.Errorf("parse Windows runtime manifest: %w", err)
	}
	if err := manifest.Validate(); err != nil {
		return Manifest{}, err
	}
	return manifest, nil
}

func LoadForBinary(binaryPath string) (Manifest, error) {
	manifest, err := Load(PathForBinary(binaryPath))
	if err != nil {
		return Manifest{}, err
	}
	if !samePath(manifest.AgentDockBinary, binaryPath) {
		return Manifest{}, errors.New("Windows runtime manifest belongs to another AgentDock binary")
	}
	return manifest, nil
}

func (manifest Manifest) Validate() error {
	if manifest.SchemaVersion != SchemaVersion {
		return fmt.Errorf("unsupported Windows runtime manifest schema: %d", manifest.SchemaVersion)
	}
	if strings.TrimSpace(manifest.AgentDockBinary) == "" || !filepath.IsAbs(manifest.AgentDockBinary) {
		return errors.New("Windows runtime manifest requires an absolute agentdock_binary")
	}
	if manifest.PrivilegeMode != "" && manifest.PrivilegeMode != "standard" && manifest.PrivilegeMode != "elevated" {
		return fmt.Errorf("unsupported Windows privilege mode: %s", manifest.PrivilegeMode)
	}
	if manifest.PrivilegeMode == "elevated" && strings.TrimSpace(manifest.AgentDockTaskName) == "" {
		return errors.New("elevated Windows runtime requires agentdock_task_name")
	}
	if manifest.Port < 1 || manifest.Port > 65535 {
		return errors.New("Windows runtime manifest port must be between 1 and 65535")
	}
	if strings.TrimSpace(manifest.Host) == "" {
		return errors.New("Windows runtime manifest host is required")
	}
	if err := validateHTTPURL(manifest.LocalMCPURL, false); err != nil {
		return fmt.Errorf("invalid local_mcp_url: %w", err)
	}
	if manifest.TunnelMode != "none" && manifest.TunnelMode != "quick" && manifest.TunnelMode != "named" {
		return fmt.Errorf("unsupported Windows tunnel mode: %s", manifest.TunnelMode)
	}
	if manifest.TunnelMode == "none" && strings.TrimSpace(manifest.PublicURL) != "" {
		return errors.New("public_url must be empty when tunnel_mode is none")
	}
	if manifest.TunnelMode != "none" {
		if err := validateHTTPURL(manifest.PublicURL, true); err != nil {
			return fmt.Errorf("invalid public_url: %w", err)
		}
	}
	return nil
}

func (manifest Manifest) UsesScheduledTask() bool {
	return manifest.PrivilegeMode == "elevated" && strings.TrimSpace(manifest.AgentDockTaskName) != ""
}

func (manifest Manifest) HealthURL() string {
	return fmt.Sprintf("http://%s:%d/healthz", manifest.Host, manifest.Port)
}

func validateHTTPURL(raw string, requireHTTPS bool) error {
	parsed, err := url.Parse(strings.TrimSpace(raw))
	if err != nil {
		return err
	}
	if parsed.Host == "" || parsed.User != nil || parsed.Fragment != "" {
		return errors.New("URL must contain only a valid HTTP origin and path")
	}
	if requireHTTPS && parsed.Scheme != "https" {
		return errors.New("URL must use https")
	}
	if !requireHTTPS && parsed.Scheme != "http" && parsed.Scheme != "https" {
		return errors.New("URL must use http or https")
	}
	return nil
}

func samePath(left, right string) bool {
	left = strings.TrimRight(filepath.Clean(left), `\/`)
	right = strings.TrimRight(filepath.Clean(right), `\/`)
	return strings.EqualFold(left, right)
}
