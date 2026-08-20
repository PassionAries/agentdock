//go:build windows

package desktopruntime

import "testing"

func TestNormalizeHTTPSOriginAcceptsMCPURL(t *testing.T) {
	for _, input := range []string{
		"https://yc.188166.top:18443",
		"https://yc.188166.top:18443/",
		"https://yc.188166.top:18443/mcp",
		"https://yc.188166.top:18443/MCP/",
	} {
		origin, err := normalizeHTTPSOrigin(input)
		if err != nil {
			t.Fatalf("normalizeHTTPSOrigin(%q) error = %v", input, err)
		}
		if origin != "https://yc.188166.top:18443" {
			t.Fatalf("normalizeHTTPSOrigin(%q) = %q", input, origin)
		}
	}
}

func TestNormalizeHTTPSOriginRejectsOtherPaths(t *testing.T) {
	if _, err := normalizeHTTPSOrigin("https://yc.188166.top:18443/oauth/token"); err == nil {
		t.Fatal("normalizeHTTPSOrigin() should reject non-MCP paths")
	}
}
