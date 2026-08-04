package desktopruntime

import "testing"

func TestValidateConfigUpdate(t *testing.T) {
	valid := ConfigUpdateRequest{
		RuntimeRoot: "runtime",
		Port:        8765,
		LogLevel:    "info",
	}
	if err := validateConfigUpdate(valid); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}

	cases := []ConfigUpdateRequest{
		{Port: 8765, LogLevel: "info"},
		{RuntimeRoot: "runtime", Port: 0, LogLevel: "info"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "verbose"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", NexusEndpoint: "bad\nvalue"},
	}
	for _, request := range cases {
		if err := validateConfigUpdate(request); err == nil {
			t.Fatalf("invalid config accepted: %#v", request)
		}
	}
}
