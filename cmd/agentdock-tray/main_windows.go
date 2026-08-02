//go:build windows

package main

import (
	"fmt"
	"os"

	"github.com/uvwt/agentdock/desktop/windows/tray"
)

func main() {
	if err := tray.Run(); err != nil {
		fmt.Fprintln(os.Stderr, "agentdock-tray:", err)
		os.Exit(1)
	}
}
