import Foundation

enum Config {
    static let bundleID = "com.hunter.recorder"
    static let githubReleasesURL = "https://api.github.com/repos/hrosenblume/recorder/releases/latest"
    static let releaseDownloadURL = "https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip"
    static let websiteURL = "https://hrosenblume.github.io/recorder/"
    static let updateCheckInterval: TimeInterval = 86400
    static let lastUpdateCheckKey = "lastUpdateCheck"

    private static let recordingsFolderKey = "recordingsFolderPath"
    static let defaultRecordingsPath = ("~/Local/Screenshots" as NSString).expandingTildeInPath

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var recordingsDirectory: URL {
        let path = UserDefaults.standard.string(forKey: recordingsFolderKey) ?? defaultRecordingsPath
        return URL(fileURLWithPath: path)
    }

    static func setRecordingsDirectory(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: recordingsFolderKey)
    }
}
