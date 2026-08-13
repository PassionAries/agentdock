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

	validACP := valid
	validACP.ACPEnabled = true
	validACP.ACPAgent = "grok"
	if err := validateConfigUpdate(validACP); err != nil {
		t.Fatalf("valid ACP config rejected: %v", err)
	}

	cases := []ConfigUpdateRequest{
		{Port: 8765, LogLevel: "info"},
		{RuntimeRoot: "runtime", Port: 0, LogLevel: "info"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "verbose"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", NexusEndpoint: "bad\nvalue"},
		{RuntimeRoot: "runtime", Port: 8765, LogLevel: "info", ACPEnabled: true, ACPAgent: "other"},
	}
	for _, request := range cases {
		if err := validateConfigUpdate(request); err == nil {
			t.Fatalf("invalid config accepted: %#v", request)
		}
	}
}
