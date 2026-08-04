package desktopruntime

import (
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestValidateConfigUpdate(t *testing.T) {
	valid := ConfigUpdateRequest{
		RuntimeRoot: "runtime",
		Port:        8765,
		LogLevel:    "info",
	}
	if err := validateConfigUpdate(valid); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}

	workspace := t.TempDir()
	validACP := valid
	validACP.ACPEnabled = true
	validACP.ACPAgent = "grok"
	validACP.ACPAllowedRoots = []string{workspace}
	if err := validateConfigUpdate(validACP); err != nil {
		t.Fatalf("valid ACP config rejected: %v", err)
	}

	fileRoot := filepath.Join(t.TempDir(), "file")
	if err := os.WriteFile(fileRoot, []byte("not a directory"), 0o600); err != nil {
		t.Fatal(err)
	}
	cases := []ConfigUpdateRequest{
		{Port: 8765, LogLevel: "info"},
		{RuntimeRoot: "runtime", Port: 0, LogLevel: "info"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "verbose"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", NexusEndpoint: "bad\nvalue"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", ACPEnabled: true, ACPAgent: "other", ACPAllowedRoots: []string{workspace}},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", ACPEnabled: true, ACPAgent: "grok"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", ACPEnabled: true, ACPAgent: "grok", ACPAllowedRoots: []string{"relative"}},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", ACPEnabled: true, ACPAgent: "grok", ACPAllowedRoots: []string{string(filepath.Separator)}},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", ACPEnabled: true, ACPAgent: "grok", ACPAllowedRoots: []string{fileRoot}},
	}
	for _, request := range cases {
		if err := validateConfigUpdate(request); err == nil {
			t.Fatalf("invalid config accepted: %#v", request)
		}
	}
}

func TestDecodeConfigStringSlice(t *testing.T) {
	values, err := decodeConfigStringSlice(`["/one", " /two "]`)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(values, []string{"/one", "/two"}) {
		t.Fatalf("decoded values = %#v", values)
	}
	if _, err := decodeConfigStringSlice(`{"root":"/one"}`); err == nil {
		t.Fatal("object accepted as string slice")
	}
}
