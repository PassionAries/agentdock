//go:build windows

package windowsruntime

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"unsafe"

	"golang.org/x/sys/windows"
)

var managedCoreEnvironment = []string{
	"AGENTDOCK_AUTH_TOKEN",
	"AGENTDOCK_HOST",
	"AGENTDOCK_PORT",
	"AGENTDOCK_LOG_LEVEL",
	"AGENTDOCK_NEXUS_ENDPOINT",
	"AGENTDOCK_NEXUS_TOKEN",
	"AGENTDOCK_BROWSER_ENABLED",
	"AGENTDOCK_BROWSER_RUNNER_DIR",
	"AGENTDOCK_BROWSER_NODE_PATH",
	"AGENTDOCK_SERVER_URL",
	"AGENTDOCK_OAUTH_ENABLED",
	"AGENTDOCK_OAUTH_PASSWORD",
	"AGENTDOCK_OAUTH_TOKEN_SECRET",
}

type controlPanelSettings struct {
	Port             int    `json:"port"`
	LogLevel         string `json:"log_level"`
	NexusEndpoint    string `json:"nexus_endpoint"`
	BrowserEnabled   bool   `json:"browser_enabled"`
	BrowserRunnerDir string `json:"browser_runner_dir"`
	BrowserNodePath  string `json:"browser_node_path"`
}

func platformPrepareCoreEnvironment(runtimeRoot string) error {
	manifest, root, err := loadDesktopManifest(runtimeRoot)
	if err != nil {
		return err
	}
	settings, err := loadControlPanelSettings(root, manifest.Port)
	if err != nil {
		return err
	}

	for _, name := range managedCoreEnvironment {
		if err := os.Unsetenv(name); err != nil {
			return fmt.Errorf("清理 %s 失败: %w", name, err)
		}
	}
	authToken, err := readProtectedText(filepath.Join(root, "auth-token.dpapi"), "agentdock.startup.v1")
	if err != nil {
		return fmt.Errorf("读取 Bearer Token 失败: %w", err)
	}
	if strings.TrimSpace(authToken) == "" {
		return errors.New("Bearer Token 为空，请运行 Setup.exe 修复安装")
	}

	managed := map[string]string{
		"AGENTDOCK_AUTH_TOKEN":      authToken,
		"AGENTDOCK_HOST":            "127.0.0.1",
		"AGENTDOCK_PORT":            strconv.Itoa(settings.Port),
		"AGENTDOCK_LOG_LEVEL":       settings.LogLevel,
		"AGENTDOCK_BROWSER_ENABLED": strconv.FormatBool(settings.BrowserEnabled),
	}
	if settings.NexusEndpoint != "" {
		managed["AGENTDOCK_NEXUS_ENDPOINT"] = settings.NexusEndpoint
		if token, tokenErr := readOptionalProtectedText(filepath.Join(root, "nexus-token.dpapi"), "agentdock.nexus.token.v1"); tokenErr != nil {
			return fmt.Errorf("读取 Nexus Token 失败: %w", tokenErr)
		} else if token != "" {
			managed["AGENTDOCK_NEXUS_TOKEN"] = token
		}
	}
	if settings.BrowserRunnerDir != "" {
		managed["AGENTDOCK_BROWSER_RUNNER_DIR"] = settings.BrowserRunnerDir
	}
	if settings.BrowserNodePath != "" {
		managed["AGENTDOCK_BROWSER_NODE_PATH"] = settings.BrowserNodePath
	}

	serverURL, err := readTrimmedText(filepath.Join(root, "server-url.txt"))
	if err != nil {
		return err
	}
	if serverURL != "" {
		oauthPassword, passwordErr := readProtectedText(filepath.Join(root, "oauth-password.dpapi"), "agentdock.oauth.password.v1")
		if passwordErr != nil {
			return fmt.Errorf("读取 OAuth 密码失败: %w", passwordErr)
		}
		oauthSecret, secretErr := readProtectedText(filepath.Join(root, "oauth-token-secret.dpapi"), "agentdock.oauth.secret.v1")
		if secretErr != nil {
			return fmt.Errorf("读取 OAuth 签名密钥失败: %w", secretErr)
		}
		managed["AGENTDOCK_SERVER_URL"] = serverURL
		managed["AGENTDOCK_OAUTH_ENABLED"] = "true"
		managed["AGENTDOCK_OAUTH_PASSWORD"] = oauthPassword
		managed["AGENTDOCK_OAUTH_TOKEN_SECRET"] = oauthSecret
	}

	for name, value := range managed {
		if err := os.Setenv(name, value); err != nil {
			return fmt.Errorf("设置 %s 失败: %w", name, err)
		}
	}
	return nil
}

func loadControlPanelSettings(runtimeRoot string, fallbackPort int) (controlPanelSettings, error) {
	settings := controlPanelSettings{Port: fallbackPort, LogLevel: "info"}
	data, err := os.ReadFile(filepath.Join(runtimeRoot, "control-panel-settings.json"))
	if errors.Is(err, os.ErrNotExist) {
		return settings, nil
	}
	if err != nil {
		return controlPanelSettings{}, fmt.Errorf("读取控制面板设置失败: %w", err)
	}
	if err := json.Unmarshal(data, &settings); err != nil {
		return controlPanelSettings{}, fmt.Errorf("解析控制面板设置失败: %w", err)
	}
	if settings.Port < 1 || settings.Port > 65535 {
		return controlPanelSettings{}, fmt.Errorf("控制面板端口超出范围: %d", settings.Port)
	}
	settings.LogLevel = strings.ToLower(strings.TrimSpace(settings.LogLevel))
	if settings.LogLevel == "" {
		settings.LogLevel = "info"
	}
	if settings.LogLevel != "debug" && settings.LogLevel != "info" && settings.LogLevel != "warn" && settings.LogLevel != "error" {
		return controlPanelSettings{}, fmt.Errorf("不支持的日志级别: %s", settings.LogLevel)
	}
	settings.NexusEndpoint = strings.TrimSpace(settings.NexusEndpoint)
	settings.BrowserRunnerDir = strings.TrimSpace(settings.BrowserRunnerDir)
	settings.BrowserNodePath = strings.TrimSpace(settings.BrowserNodePath)
	return settings, nil
}

func readOptionalProtectedText(path, entropy string) (string, error) {
	if _, err := os.Stat(path); errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", err
	}
	return readProtectedText(path, entropy)
}

func readProtectedText(path, entropy string) (string, error) {
	encoded, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}
	ciphertext, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(encoded)))
	if err != nil {
		return "", fmt.Errorf("解析 DPAPI 数据失败: %w", err)
	}
	if len(ciphertext) == 0 {
		return "", errors.New("DPAPI 数据为空")
	}
	entropyBytes := []byte(entropy)
	input := windows.DataBlob{Size: uint32(len(ciphertext)), Data: &ciphertext[0]}
	optionalEntropy := windows.DataBlob{Size: uint32(len(entropyBytes)), Data: &entropyBytes[0]}
	var output windows.DataBlob
	if err := windows.CryptUnprotectData(&input, nil, &optionalEntropy, 0, nil, 0, &output); err != nil {
		return "", err
	}
	defer windows.LocalFree(windows.Handle(uintptr(unsafe.Pointer(output.Data))))
	plain := unsafe.Slice(output.Data, int(output.Size))
	return string(append([]byte(nil), plain...)), nil
}

func readTrimmedText(path string) (string, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", fmt.Errorf("读取 %s 失败: %w", path, err)
	}
	return strings.TrimSpace(string(data)), nil
}
