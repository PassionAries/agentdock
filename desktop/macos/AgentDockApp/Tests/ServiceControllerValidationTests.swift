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

        let appBundle = root.appendingPathComponent("Applications/AgentDock.app", isDirectory: true)
        let launchAgentBundle = appBundle
            .appendingPathComponent("Contents/Library/LaunchAgents", isDirectory: true)
        try FileManager.default.createDirectory(at: launchAgentBundle, withIntermediateDirectories: true)
        let corePlist = launchAgentBundle.appendingPathComponent(ServiceController.corePlistName)
        try Data("plist".utf8).write(to: corePlist)

        let persistentPaths = AppPaths(
            home: root,
            appBundle: appBundle
        )
        let service = ServiceController(paths: persistentPaths)

        // 迁移入口必须允许旧结构存在，否则在 begin() 之前就会被自己拦住。
        try service.validatePersistentAppLocation()
        expectFailure("检测到旧版") {
            try service.validateServiceManagementReadiness()
        }
        try service.validateBundledServiceDefinition(
            plistName: ServiceController.corePlistName,
            displayName: "AgentDock Core"
        )
        try FileManager.default.removeItem(at: corePlist)
        expectFailure("缺少 AgentDock Core") {
            try service.validateBundledServiceDefinition(
                plistName: ServiceController.corePlistName,
                displayName: "AgentDock Core"
            )
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
