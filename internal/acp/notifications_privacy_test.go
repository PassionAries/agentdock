package acp

import (
	"encoding/json"
	"testing"
)

func TestHandleNotificationDropsAgentThoughtChunks(t *testing.T) {
	run := newRun("acpr_privacy", "acps_privacy")
	manager := &Manager{
		remoteToLocal:      map[string]string{"remote-session": run.SessionID},
		activeRunBySession: map[string]string{run.SessionID: run.ID},
		runs:               map[string]*Run{run.ID: run},
	}

	thought := json.RawMessage(`{"sessionId":"remote-session","update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"private reasoning"}}}`)
	manager.handleNotification("session/update", thought)
	page, err := run.eventsAfter(0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Events) != 0 || page.LatestSeq != 0 {
		t.Fatalf("private thought reached public event ring: %#v", page)
	}

	message := json.RawMessage(`{"sessionId":"remote-session","update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"public answer"}}}`)
	manager.handleNotification("session/update", message)
	page, err = run.eventsAfter(0, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Events) != 1 || page.Events[0].Type != "agent_message_chunk" {
		t.Fatalf("public agent message was not retained: %#v", page)
	}
}
