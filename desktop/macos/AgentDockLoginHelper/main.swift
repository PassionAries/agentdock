import Foundation

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let appBundle = executable
    .deletingLastPathComponent() // MacOS
    .deletingLastPathComponent() // Contents
    .deletingLastPathComponent() // AgentDock.app

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
process.arguments = ["-gj", appBundle.path, "--args", "--background"]

do {
    try process.run()
    process.waitUntilExit()
    exit(process.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("AgentDock login helper failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
