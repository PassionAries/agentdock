//go:build windows

package selfupdate

import (
	"context"
	"testing"

	"golang.org/x/sys/windows"
)

func TestWindowsDesktopRepairCommandSkipsDuplicateProcess(t *testing.T) {
	name, err := windows.UTF16PtrFromString(windowsDesktopRepairMutexName)
	if err != nil {
		t.Fatal(err)
	}
	mutex, err := windows.CreateMutex(nil, true, name)
	if err != nil && err != windows.ERROR_ALREADY_EXISTS {
		t.Fatal(err)
	}
	if mutex == 0 {
		t.Fatal("CreateMutex returned zero handle")
	}
	defer func() {
		_ = windows.ReleaseMutex(mutex)
		_ = windows.CloseHandle(mutex)
	}()

	handled, err := handleWindowsDesktopRepairCommand(context.Background(), []string{windowsDesktopRepairCommand})
	if err != nil {
		t.Fatal(err)
	}
	if !handled {
		t.Fatal("desktop repair command was not handled")
	}
}
