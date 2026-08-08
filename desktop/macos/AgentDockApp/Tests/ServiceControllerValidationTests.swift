import Foundation

@main
struct ServiceControllerValidationTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentDockServiceValidationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let launchAgents = root.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        try Data("legacy".utf8).write(
            to: launchAgents.appendingPathComponent("com.uvwt.agentdock.plist")
        )

        let persistentPaths = AppPaths(
            home: root,
            appBundle: URL(fileURLWithPath: "/Applications/AgentDock.app", isDirectory: true)
        )
        let service = ServiceController(paths: persistentPaths)

        // 迁移入口必须允许旧结构存在，否则在 begin() 之前就会被自己拦住。
        try service.validatePersistentAppLocation()
        expectFailure("检测到旧版") {
            try service.validateServiceManagementReadiness()
        }

        let mountedPaths = AppPaths(
            home: root,
            appBundle: URL(fileURLWithPath: "/Volumes/AgentDock/AgentDock.app", isDirectory: true)
        )
        expectFailure("应用程序") {
            try ServiceController(paths: mountedPaths).validatePersistentAppLocation()
        }

        print("service controller validation tests passed")
    }

    private static func expectFailure(_ expected: String, operation: () throws -> Void) {
        do {
            try operation()
            preconditionFailure("expected validation failure containing: \(expected)")
        } catch {
            precondition(error.localizedDescription.contains(expected), error.localizedDescription)
        }
    }
}
