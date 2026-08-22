//go:build windows

package desktopruntime

import (
	"testing"
	"unicode/utf16"
)

func TestParseScheduledTaskXMLAcceptsUTF16LE(t *testing.T) {
	runes := utf16.Encode([]rune(`<?xml version="1.0" encoding="UTF-16"?><Task><Settings><Enabled>true</Enabled></Settings></Task>`))
	data := []byte{0xff, 0xfe}
	for _, value := range runes {
		data = append(data, byte(value), byte(value>>8))
	}
	task, err := parseScheduledTaskXML(data)
	if err != nil {
		t.Fatalf("parseScheduledTaskXML() error = %v", err)
	}
	if task.Settings.Enabled == nil || !*task.Settings.Enabled {
		t.Fatal("scheduled task should be enabled")
	}
}

func TestParseScheduledTaskXMLAcceptsUTF16BE(t *testing.T) {
	runes := utf16.Encode([]rune(`<?xml version="1.0" encoding="UTF-16"?><Task><Settings><Enabled>true</Enabled></Settings></Task>`))
	data := []byte{0xfe, 0xff}
	for _, value := range runes {
		data = append(data, byte(value>>8), byte(value))
	}
	task, err := parseScheduledTaskXML(data)
	if err != nil {
		t.Fatalf("parseScheduledTaskXML() error = %v", err)
	}
	if task.Settings.Enabled == nil || !*task.Settings.Enabled {
		t.Fatal("scheduled task should be enabled")
	}
}

func TestParseScheduledTaskXMLAcceptsUTF8(t *testing.T) {
	task, err := parseScheduledTaskXML([]byte(`<Task><Settings><Enabled>false</Enabled></Settings></Task>`))
	if err != nil {
		t.Fatalf("parseScheduledTaskXML() error = %v", err)
	}
	if task.Settings.Enabled == nil || *task.Settings.Enabled {
		t.Fatal("scheduled task should be disabled")
	}
}

func TestParseScheduledTaskXMLUsesEnabledDefault(t *testing.T) {
	task, err := parseScheduledTaskXML([]byte(`<Task><Settings></Settings></Task>`))
	if err != nil {
		t.Fatalf("parseScheduledTaskXML() error = %v", err)
	}
	if task.Settings.Enabled != nil {
		t.Fatal("scheduled task should preserve the missing Enabled element")
	}
}
