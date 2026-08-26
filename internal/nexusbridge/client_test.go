package nexusbridge

import "testing"

func TestNexusToolDescriptorsMarkOnlyAgentDockAppResources(t *testing.T) {
	descriptors := []map[string]any{
		{
			"name":  "file_edit",
			"_meta": map[string]any{"ui": map[string]any{"resourceUri": "ui://agentdock/file-change"}},
		},
		{
			"name":  "foreign_ui",
			"_meta": map[string]any{"ui": map[string]any{"resourceUri": "https://example.test/widget"}},
		},
		{"name": "read_file"},
	}

	marked := nexusToolDescriptors(descriptors)
	if marked[0]["nexus_resource_relay"] != true {
		t.Fatalf("AgentDock app descriptor = %#v", marked[0])
	}
	for _, index := range []int{1, 2} {
		if marked[index]["nexus_resource_relay"] != nil {
			t.Fatalf("non-AgentDock resource descriptor %d was marked: %#v", index, marked[index])
		}
	}
}
