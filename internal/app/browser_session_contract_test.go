package app

import (
	"context"
	"testing"

	toolbrowser "github.com/uvwt/agentdock/internal/tool/browser"
)

func TestBrowserSessionAcceptsAdvertisedTimeoutForCloseAndCleanup(t *testing.T) {
	service := toolbrowser.New(toolbrowser.Config{AgentDockHome: t.TempDir()})
	t.Cleanup(func() { _ = service.Close() })
	runtime := &Runtime{browser: service}

	closed, err := runtime.browserSession(context.Background(), map[string]any{
		"action": "close", "session_id": "missing", "timeout_ms": 1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	if closed["code"] != toolbrowser.ErrSessionNotFound {
		t.Fatalf("close result = %#v", closed)
	}

	cleaned, err := runtime.browserSession(context.Background(), map[string]any{
		"action": "cleanup_stale", "max_age_ms": 1000, "timeout_ms": 1000,
	})
	if err != nil {
		t.Fatal(err)
	}
	if cleaned["browser_ok"] != true {
		t.Fatalf("cleanup result = %#v", cleaned)
	}
}
