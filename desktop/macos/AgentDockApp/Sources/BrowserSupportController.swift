import Foundation

enum BrowserSupportController {
    private static let standardExecutables = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        "/Applications/Chromium.app/Contents/MacOS/Chromium",
        "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
    ]


    static func detectExecutable() -> String? {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        let candidates = standardExecutables + [
            home + "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
            home + "/Applications/Chromium.app/Contents/MacOS/Chromium",
            home + "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
        ]
        return candidates.first(where: fileManager.isExecutableFile(atPath:))
    }
}
