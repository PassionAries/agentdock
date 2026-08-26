package nexusbridge

import "testing"

func TestConnectionStateTracksCurrentConnection(t *testing.T) {
	state := &ConnectionState{}
	if state.Connected() {
		t.Fatal("new connection state should start disconnected")
	}

	state.SetConnected(true)
	if !state.Connected() {
		t.Fatal("connected state was not recorded")
	}

	state.SetConnected(false)
	if state.Connected() {
		t.Fatal("disconnected state was not recorded")
	}
}
