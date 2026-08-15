package scripts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWindowsControlPanelPrivilegeModeCopyStaysUserFacing(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "desktop", "windows", "control-panel", "MainWindow.xaml"))
	if err != nil {
		t.Fatalf("read MainWindow.xaml: %v", err)
	}
	content := string(data)
	for _, want := range []string{
		`x:Name="ElevatedCoreCheckBox"`,
		`Content="以管理员权限运行 AgentDock 核心"`,
		`Click="ElevatedCoreCheckBox_Click"`,
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("Windows privilege mode control missing %q", want)
		}
	}
	if strings.Contains(content, "开启时使用 Windows Highest") {
		t.Fatal("Windows privilege mode control must not expose implementation details")
	}
}

func TestWindowsUpdateProgressWindowSizesToContent(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("..", "..", "desktop", "windows", "control-panel", "UpdateProgressWindow.xaml"))
	if err != nil {
		t.Fatalf("read UpdateProgressWindow.xaml: %v", err)
	}
	content := string(data)
	for _, want := range []string{
		`SizeToContent="Height"`,
		`x:Name="CloseButton"`,
	} {
		if !strings.Contains(content, want) {
			t.Fatalf("Windows update progress window missing %q", want)
		}
	}
	if strings.Contains(content, `<RowDefinition Height="*" />`) {
		t.Fatal("Windows update progress button row must size to its content")
	}
}
