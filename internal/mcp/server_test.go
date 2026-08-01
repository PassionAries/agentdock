package mcp

import (
	"path/filepath"
	"testing"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/uvwt/agentdock/internal/app"
	"github.com/uvwt/agentdock/internal/config"
)

func TestToolDescriptorsDoNotExposePermissionAnnotations(t *testing.T) {
	descriptors := toolDescriptorsForNames([]string{"read_file", "skill_package"})
	byName := map[string]map[string]any{}
	for _, descriptor := range descriptors {
		name, _ := descriptor["name"].(string)
		byName[name] = descriptor
	}
	for _, tool := range []string{"read_file", "skill_package"} {
		if _, ok := byName[tool]["annotations"]; ok {
			t.Fatalf("%s should not expose permission annotations", tool)
		}
	}
}

func TestFilePublishDescriptorExposesFileRewritePath(t *testing.T) {
	descriptors := toolDescriptorsForNames([]string{"file_publish"})
	byName := map[string]map[string]any{}
	for _, descriptor := range descriptors {
		name, _ := descriptor["name"].(string)
		byName[name] = descriptor
	}
	args, ok := byName["file_publish"]["file_arg_rewrite_paths"].([]string)
	if !ok || len(args) != 1 || args[0] != "file" {
		t.Fatalf("file_publish file_arg_rewrite_paths = %#v", byName["file_publish"]["file_arg_rewrite_paths"])
	}
	meta, ok := byName["file_publish"]["_meta"].(map[string]any)
	if !ok || meta["file_arg_rewrite_paths"] == nil || meta["openai/fileParams"] == nil {
		t.Fatalf("file_publish _meta missing: %#v", meta)
	}
}

func TestToolEnvelopeMCPImageStripsInternalBase64FromStructuredContent(t *testing.T) {
	response := toolEnvelope("view_image", map[string]any{
		"ok":                   true,
		"source":               map[string]any{"type": "artifact", "artifact_id": "artifact-1"},
		"_mcp_image_base64":    "abc123",
		"_mcp_image_mime_type": "image/png",
	}, nil)
	content := response["content"].([]map[string]any)
	if content[0]["type"] != "image" || content[0]["data"] != "abc123" || content[0]["mimeType"] != "image/png" {
		t.Fatalf("content = %#v", content)
	}
	structured := response["structuredContent"].(map[string]any)
	if _, ok := structured["_mcp_image_base64"]; ok {
		t.Fatalf("structuredContent leaked internal base64: %#v", structured)
	}
	if _, ok := structured["_mcp_image_mime_type"]; ok {
		t.Fatalf("structuredContent leaked internal mime type: %#v", structured)
	}
}

func TestToolEnvelopePassesThroughDynamicMCPContent(t *testing.T) {
	response := toolEnvelope("mcp_tool_call", map[string]any{
		"ok":   true,
		"name": "figma:get_screenshot",
		"result": map[string]any{
			"content": []any{
				map[string]any{"type": "text", "text": "done"},
				map[string]any{"type": "image", "data": "abc123", "mimeType": "image/png"},
			},
			"structuredContent": map[string]any{"node_id": "1:2"},
		},
	}, nil)
	content, ok := response["content"].([]any)
	if !ok || len(content) != 2 {
		t.Fatalf("dynamic MCP content = %#v", response["content"])
	}
	image, _ := content[1].(map[string]any)
	if image["type"] != "image" || image["data"] != "abc123" || image["mimeType"] != "image/png" {
		t.Fatalf("dynamic MCP image content = %#v", image)
	}
	structured, _ := response["structuredContent"].(map[string]any)
	if structured["name"] != "figma:get_screenshot" {
		t.Fatalf("structuredContent = %#v", structured)
	}
}

func TestOfficialSDKServerListsAndCallsAgentDockTools(t *testing.T) {
	root := t.TempDir()
	cfg := config.Config{AgentDockDefaultDir: root, AgentDockHome: filepath.Join(root, ".agentdock")}
	if err := cfg.Normalize(); err != nil {
		t.Fatalf("Normalize() error = %v", err)
	}
	runtime, err := app.NewRuntime(cfg)
	if err != nil {
		t.Fatalf("NewRuntime() error = %v", err)
	}
	defer runtime.Close()

	serverTransport, clientTransport := mcpsdk.NewInMemoryTransports()
	server := NewServer(runtime, cfg)
	serverDone := make(chan error, 1)
	go func() { serverDone <- server.sdk.Run(t.Context(), serverTransport) }()

	client := mcpsdk.NewClient(
		&mcpsdk.Implementation{Name: "agentdock-test", Version: "1.0.0"},
		&mcpsdk.ClientOptions{Capabilities: &mcpsdk.ClientCapabilities{}},
	)
	session, err := client.Connect(t.Context(), clientTransport, nil)
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}

	foundServerInfo := false
	foundFilePublishMetadata := false
	for tool, err := range session.Tools(t.Context(), nil) {
		if err != nil {
			t.Fatalf("Tools() error = %v", err)
		}
		switch tool.Name {
		case "server_info":
			foundServerInfo = true
		case "file_publish":
			paths, _ := tool.Meta["openai/fileParams"].([]any)
			foundFilePublishMetadata = len(paths) == 1 && paths[0] == "file"
		}
	}
	if !foundServerInfo || !foundFilePublishMetadata {
		t.Fatalf("tool discovery incomplete: server_info=%v file_publish_meta=%v", foundServerInfo, foundFilePublishMetadata)
	}

	result, err := session.CallTool(t.Context(), &mcpsdk.CallToolParams{Name: "server_info", Arguments: map[string]any{}})
	if err != nil {
		t.Fatalf("CallTool() error = %v", err)
	}
	structured, ok := result.StructuredContent.(map[string]any)
	if !ok || structured["server"] != config.ServerName || result.IsError {
		t.Fatalf("CallTool() result = %#v", result)
	}

	if err := session.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}
	if err := <-serverDone; err != nil {
		t.Fatalf("Server.Run() error = %v", err)
	}
}
