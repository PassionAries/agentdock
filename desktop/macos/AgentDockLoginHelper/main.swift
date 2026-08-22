import AppKit
import Darwin
import Foundation

var executablePathSize: UInt32 = 0
_NSGetExecutablePath(nil, &executablePathSize)
var executablePath = [CChar](repeating: 0, count: Int(executablePathSize))

guard _NSGetExecutablePath(&executablePath, &executablePathSize) == 0 else {
    exit(EXIT_FAILURE)
}

let executableURL = URL(fileURLWithPath: String(cString: executablePath)).resolvingSymlinksInPath()
let appBundle = executableURL
    .deletingLastPathComponent() // Helpers
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // AgentDock.app

guard appBundle.pathExtension == "app" else {
    exit(EXIT_FAILURE)
}

// 更新过程中重新注册 LaunchAgent 会立即执行一次 RunAtLoad。
// 主 App 已经在运行时不再调用 open，避免触发额外的 reopen/窗口展示。
if !NSRunningApplication.runningApplications(withBundleIdentifier: "com.uvwt.agentdock").isEmpty {
    exit(EXIT_SUCCESS)
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
process.arguments = ["-gj", appBundle.path, "--args", "--background"]
do {
    try process.run()
} catch {
    FileHandle.standardError.write(Data("AgentDock menu helper failed: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
