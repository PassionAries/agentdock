//go:build darwin

package selfupdate

import (
	"context"
	"encoding/json"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestExtractDesktopUpdateArchiveValidatesSignedApp(t *testing.T) {
	dir := t.TempDir()
	sourceRoot := filepath.Join(dir, "source")
	appPath := writeSignedMacOSApp(t, sourceRoot, "0.7.1")
	archivePath := filepath.Join(dir, macOSDesktopArchiveName)
	runTestCommand(t, "/usr/bin/ditto", "-c", "-k", "--keepParent", appPath, archivePath)
	archiveData, err := os.ReadFile(archivePath)
	if err != nil {
		t.Fatal(err)
	}

	extracted, err := extractDesktopUpdateArchive(
		context.Background(),
		archiveData,
		filepath.Join(dir, "extract"),
		"v0.7.1",
	)
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Base(extracted) != "AgentDock.app" {
		t.Fatalf("unexpected extracted App path: %s", extracted)
	}
	if err := validateMacOSDesktopVersion(context.Background(), extracted, "v0.7.1"); err != nil {
		t.Fatal(err)
	}
}

func TestMacOSDesktopUpdateInstallsAndRestoresApp(t *testing.T) {
	dir := t.TempDir()
	target := writeSignedMacOSApp(t, filepath.Join(dir, "installed"), "0.7.0")
	staged := writeSignedMacOSApp(t, filepath.Join(dir, "staged"), "0.7.1")

	transaction, err := prepareDesktopUpdate(
		context.Background(),
		target,
		staged,
		"v0.7.1",
	)
	if err != nil {
		t.Fatal(err)
	}
	if err := transaction.Install(context.Background()); err != nil {
		t.Fatal(err)
	}
	assertMacOSAppVersion(t, target, "v0.7.1")
	if err := transaction.Restore(context.Background()); err != nil {
		t.Fatal(err)
	}
	assertMacOSAppVersion(t, target, "v0.7.0")
}

func TestApplyPlatformUpdateRestoresCoreAndAppWhenSkillBootstrapFails(t *testing.T) {
	dir := t.TempDir()
	coreTarget := filepath.Join(dir, "bin", "agentdock")
	coreStaged := filepath.Join(dir, "staged-agentdock")
	if err := os.MkdirAll(filepath.Dir(coreTarget), 0o700); err != nil {
		t.Fatal(err)
	}
	writeVersionScript(t, coreTarget, "v0.7.0")
	failedCore := `#!/bin/sh
case "${1:-}" in
  --version) printf 'AgentDock v0.7.1\n' ;;
  skill) printf 'bootstrap failed\n' >&2; exit 1 ;;
  *) exit 2 ;;
esac
`
	if err := os.WriteFile(coreStaged, []byte(failedCore), 0o755); err != nil {
		t.Fatal(err)
	}
	bundle := writeCoreSkillBundle(t, dir)
	appTarget := writeSignedMacOSApp(t, filepath.Join(dir, "Applications"), "0.7.0")
	appStaged := writeSignedMacOSApp(t, filepath.Join(dir, "staged-app"), "0.7.1")

	_, err := applyPlatformUpdate(context.Background(), applyRequest{
		CurrentPath:       coreTarget,
		CurrentVersion:    "v0.7.0",
		StagedPath:        coreStaged,
		BundlePath:        bundle,
		DesktopTargetPath: appTarget,
		DesktopStagedPath: appStaged,
		TargetVersion:     "v0.7.1",
		Output:            io.Discard,
	})
	if err == nil || !strings.Contains(err.Error(), "已自动恢复旧版本") {
		t.Fatalf("unexpected error: %v", err)
	}
	assertVersionScript(t, coreTarget, "v0.7.0")
	assertMacOSAppVersion(t, appTarget, "v0.7.0")
}

func TestWriteMacOSDesktopUpdateResultIsPrivateAndExplicit(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	outcome := desktopUpdateOutcome{
		OK:             true,
		CurrentVersion: "v0.7.0",
		TargetVersion:  "v0.7.1",
		Message:        "更新完成",
	}
	if err := writeMacOSDesktopUpdateResult(outcome); err != nil {
		t.Fatal(err)
	}

	path := filepath.Join(home, "Library", "Application Support", "AgentDock", "update-result.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	var result struct {
		SchemaVersion  int    `json:"schema_version"`
		OK             bool   `json:"ok"`
		CurrentVersion string `json:"current_version"`
		TargetVersion  string `json:"target_version"`
		Message        string `json:"message"`
	}
	if err := json.Unmarshal(data, &result); err != nil {
		t.Fatal(err)
	}
	if result.SchemaVersion != 1 || !result.OK || result.CurrentVersion != "v0.7.0" ||
		result.TargetVersion != "v0.7.1" || result.Message != "更新完成" {
		t.Fatalf("unexpected update result: %#v", result)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("update result permissions = %o, want 600", info.Mode().Perm())
	}
}

func writeSignedMacOSApp(t *testing.T, root, version string) string {
	t.Helper()
	appPath := filepath.Join(root, "AgentDock.app")
	contents := filepath.Join(appPath, "Contents")
	macOSDir := filepath.Join(contents, "MacOS")
	if err := os.MkdirAll(macOSDir, 0o755); err != nil {
		t.Fatal(err)
	}
	executable := filepath.Join(macOSDir, "AgentDock")
	binary, err := os.ReadFile("/usr/bin/true")
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(executable, binary, 0o755); err != nil {
		t.Fatal(err)
	}
	plist := `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>AgentDock</string>
<key>CFBundleIdentifier</key><string>com.uvwt.agentdock</string>
<key>CFBundleName</key><string>AgentDock</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>` + version + `</string>
<key>CFBundleVersion</key><string>` + version + `</string>
</dict></plist>
`
	if err := os.WriteFile(filepath.Join(contents, "Info.plist"), []byte(plist), 0o644); err != nil {
		t.Fatal(err)
	}
	runTestCommand(t, "/usr/bin/codesign", "--force", "--deep", "--sign", "-", "--identifier", "com.uvwt.agentdock", appPath)
	if err := validateMacOSDesktopVersion(context.Background(), appPath, version); err != nil {
		t.Fatal(err)
	}
	return appPath
}

func assertMacOSAppVersion(t *testing.T, appPath, version string) {
	t.Helper()
	if err := validateMacOSDesktopVersion(context.Background(), appPath, version); err != nil {
		t.Fatal(err)
	}
}

func runTestCommand(t *testing.T, path string, args ...string) {
	t.Helper()
	output, err := exec.Command(path, args...).CombinedOutput()
	if err != nil {
		t.Fatalf("%s %v failed: %v: %s", path, args, err, strings.TrimSpace(string(output)))
	}
}
