import Foundation

struct DesktopUpdateResult: Decodable {
    let schemaVersion: Int
    let ok: Bool
    let currentVersion: String
    let targetVersion: String
    let message: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case ok
        case currentVersion = "current_version"
        case targetVersion = "target_version"
        case message
    }

    static func consume(from path: URL) -> DesktopUpdateResult? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        defer { try? FileManager.default.removeItem(at: path) }
        guard let result = try? JSONDecoder().decode(DesktopUpdateResult.self, from: data),
              result.schemaVersion == 1 else {
            return nil
        }
        return result
    }
}
