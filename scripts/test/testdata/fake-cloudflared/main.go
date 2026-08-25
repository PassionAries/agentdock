package main

import (
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
)

func main() {
	if len(os.Args) > 1 && os.Args[1] == "--version" {
		fmt.Println("cloudflared version agentdock-test")
		return
	}

	executable, err := os.Executable()
	if err != nil {
		fmt.Fprintln(os.Stderr, "resolve fake cloudflared executable:", err)
		os.Exit(1)
	}
	urlFile := filepath.Join(filepath.Dir(executable), "quick-url-source.txt")
	data, err := os.ReadFile(urlFile)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read fake Quick Tunnel URL:", err)
		os.Exit(1)
	}
	publicURL := strings.TrimSpace(string(data))
	if publicURL == "" {
		fmt.Fprintln(os.Stderr, "fake Quick Tunnel URL is empty")
		os.Exit(1)
	}

	// Match the success marker emitted by cloudflared before the generated Quick Tunnel URL.
	fmt.Fprintln(os.Stderr, "INF Your quick Tunnel has been created! Visit it at:")
	fmt.Fprintln(os.Stderr, publicURL)

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)
	<-stop
}
