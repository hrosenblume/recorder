import Foundation

enum Config {
    static let bundleID = "com.hunter.recorder"
    static let githubReleasesURL = "https://api.github.com/repos/hrosenblume/recorder/releases/latest"
    static let releaseDownloadURL = "https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip"
    static let websiteURL = "https://hrosenblume.github.io/recorder/"
    static let updateCheckInterval: TimeInterval = 86400
    static let lastUpdateCheckKey = "lastUpdateCheck"

    private static let recordingsFolderKey = "recordingsFolderPath"
    private static let recordSystemAudioKey = "recordSystemAudio"
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

    /// Default true. When enabled, recordings include a second audio track
    /// captured from system output (other side of calls, music, notifications).
    static var recordSystemAudio: Bool {
        // UserDefaults.bool(forKey:) returns false for unset keys, so use object(forKey:)
        // to distinguish "unset" (default to true) from "explicitly false".
        if let stored = UserDefaults.standard.object(forKey: recordSystemAudioKey) as? Bool {
            return stored
        }
        return true
    }

    static func setRecordSystemAudio(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: recordSystemAudioKey)
    }

    // MARK: - Audio mix levels
    //
    // Hardcoded for v1.2.0; could become user-configurable later. Mic is
    // dominant so the user's voice cuts through; system audio is slightly
    // quieter so it doesn't drown the mic.
    static let micVolume: Float = 1.0
    static let systemAudioVolume: Float = 0.85
}
