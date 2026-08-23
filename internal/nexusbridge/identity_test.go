package nexusbridge

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

func TestPairPersistsOnlyNexusDeviceIdentity(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/nodes/pair" || r.Method != http.MethodPost {
			t.Fatalf("unexpected request: %s %s", r.Method, r.URL.Path)
		}
		var request map[string]string
		if err := json.NewDecoder(r.Body).Decode(&request); err != nil {
			t.Fatal(err)
		}
		if request["code"] != "pair_test" || request["device_id"] == "" {
			t.Fatalf("request = %#v", request)
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		_, _ = w.Write([]byte(`{"node":{"id":"node_test"},"device_token":"device-secret"}`))
	}))
	defer server.Close()

	home := t.TempDir()
	identity, err := Pair(t.Context(), home, PairOptions{Endpoint: server.URL, Code: "pair_test", Name: "DockMini"})
	if err != nil {
		t.Fatal(err)
	}
	if identity.NodeID != "node_test" || identity.DeviceToken != "device-secret" {
		t.Fatalf("identity = %#v", identity)
	}
	loaded, err := Load(home)
	if err != nil || loaded != identity {
		t.Fatalf("loaded = %#v err=%v", loaded, err)
	}
	info, err := os.Stat(filepath.Join(home, "nexus", "device.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("identity permissions = %o", info.Mode().Perm())
	}
}

func TestPublicEndpointRequiresHTTPS(t *testing.T) {
	if _, err := normalizeEndpoint("http://nexus.example.com"); err == nil {
		t.Fatal("public HTTP endpoint was accepted")
	}
	if endpoint, err := normalizeEndpoint("http://127.0.0.1:8080/"); err != nil || endpoint != "http://127.0.0.1:8080" {
		t.Fatalf("loopback endpoint=%q err=%v", endpoint, err)
	}
}
