package app

import (
	"testing"

	"github.com/uvwt/agentdock/internal/config"
)

func TestServerInfoOutputSchemaDescribesPublishedResult(t *testing.T) {
	cfg := config.Config{
		AgentDockHome:       t.TempDir(),
		AgentDockDefaultDir: t.TempDir(),
	}
	if err := cfg.Normalize(); err != nil {
		t.Fatalf("Normalize() error = %v", err)
	}
	runtime, err := NewRuntime(cfg)
	if err != nil {
		t.Fatalf("NewRuntime() error = %v", err)
	}
	t.Cleanup(func() {
		if err := runtime.Close(); err != nil {
			t.Errorf("Close() error = %v", err)
		}
	})

	result := runtime.serverInfo()
	schema := OutputSchema("server_info")
	properties, ok := schema["properties"].(map[string]any)
	if !ok {
		t.Fatalf("server_info properties = %#v, want map[string]any", schema["properties"])
	}

	published := []string{
		"server", "title", "version", "protocol_version",
		"os", "arch", "go_version",
		"agentdock_home", "agentdock_default_dir", "default_cwd", "path_model",
		"recall_enabled", "nexus_endpoint", "recall_bootstrap_recommended", "recall_bootstrap_tool", "recall_bootstrap_args",
		"task_state_dir", "command_session_limits",
		"browser_enabled", "acp_enabled", "acp_agent", "trusted_proxy_cidrs",
		"auth_enabled", "endpoint_path", "tools", "tool_count",
	}
	for _, name := range published {
		if _, exists := properties[name]; !exists {
			t.Errorf("server_info output schema missing published field %q", name)
		}
		if _, exists := result[name]; !exists {
			t.Errorf("server_info runtime result missing published field %q", name)
		}
	}

	// OutputSchema 允许运行时返回额外诊断字段，但它自己声明的字段必须真实存在，
	// 防止旧契约留在 schema 中误导 MCP 客户端。
	for name := range properties {
		if _, exists := result[name]; !exists {
			t.Errorf("server_info output schema declares absent runtime field %q", name)
		}
	}

	for _, stale := range []string{"workspace", "workflow_dir", "sandbox"} {
		if _, exists := properties[stale]; exists {
			t.Errorf("server_info output schema still exposes stale field %q", stale)
		}
	}
}
