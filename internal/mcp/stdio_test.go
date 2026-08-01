package mcp

import (
	"context"
	"io"
	"testing"
	"time"

	mcpsdk "github.com/modelcontextprotocol/go-sdk/mcp"
	"github.com/uvwt/agentdock/internal/config"
)

func TestServeStdioUsesOfficialSDKTransport(t *testing.T) {
	server := NewServer(nil, config.Config{})
	clientInput, serverOutput := io.Pipe()
	serverInput, clientOutput := io.Pipe()
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- server.ServeStdio(serverInput, serverOutput)
	}()

	client := mcpsdk.NewClient(
		&mcpsdk.Implementation{Name: "agentdock-test", Version: "1.0.0"},
		&mcpsdk.ClientOptions{Capabilities: &mcpsdk.ClientCapabilities{}},
	)
	ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
	defer cancel()
	session, err := client.Connect(ctx, &mcpsdk.IOTransport{Reader: clientInput, Writer: clientOutput}, nil)
	if err != nil {
		t.Fatalf("Connect() error = %v", err)
	}
	if result := session.InitializeResult(); result == nil || result.ProtocolVersion == "" {
		t.Fatalf("InitializeResult() = %#v", result)
	}
	if err := session.Ping(ctx, nil); err != nil {
		t.Fatalf("Ping() error = %v", err)
	}
	if err := session.Close(); err != nil {
		t.Fatalf("Close() error = %v", err)
	}

	select {
	case err := <-serverDone:
		if err != nil {
			t.Fatalf("ServeStdio() error = %v", err)
		}
	case <-ctx.Done():
		t.Fatal("ServeStdio() did not stop after client close")
	}
}

func TestServeStdioRejectsUninitializedServer(t *testing.T) {
	var server *Server
	if err := server.ServeStdio(nil, nil); err == nil {
		t.Fatal("ServeStdio() accepted an uninitialized server")
	}
}
