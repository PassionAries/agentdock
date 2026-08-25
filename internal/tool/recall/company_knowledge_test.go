package recall

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/uvwt/agentdock/internal/config"
)

func TestCompanyKnowledgeFetchRequiresRawContent(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet || r.URL.Path != "/v1/recall/projects/agentdock/summary-only.md" {
			http.NotFound(w, r)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{
			"ok": true,
			"recall": map[string]any{
				"path":  "projects/agentdock/summary-only.md",
				"title": "Summary only",
				"body":  "This is only a summarized body, not the source Markdown.",
			},
		})
	}))
	defer server.Close()

	svc := New(func() config.Config {
		return config.Config{NexusEndpoint: server.URL, NexusDeviceToken: "test-token"}
	})
	_, err := svc.CompanyKnowledgeFetch(t.Context(), map[string]any{"id": "projects/agentdock/summary-only.md"})
	if err == nil {
		t.Fatal("fetch should fail when Recall cannot provide raw_content")
	}
}
