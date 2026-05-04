import AVFoundation
import AppKit
import CoreGraphics

enum Permissions {
    /// At launch, only request the mic (low-friction). For Screen Recording we
    /// only check status — we never call `CGRequestScreenCaptureAccess()` here
    /// because on macOS 15 with ad-hoc signing it opens System Settings on every
    /// call even when already granted. The actual prompt happens lazily when the
    /// user attempts a recording and is missing the grant.
    static func preflightAll() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Called when the user tries to start a recording without screen access.
    /// Shows our own alert with a clear path to System Settings, then triggers
    /// the system prompt exactly once. macOS handles registering the app in
    /// the Settings list — we deliberately don't try to be clever here (an
    /// earlier attempt to wipe stale TCC entries via `tccutil reset` left users
    /// with no entry in Settings to toggle).
    static func promptForScreenCapture() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Click \"Open System Settings\", toggle Recorder ON under \"Screen & System Audio Recording\", then quit Recorder fully and relaunch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            _ = CGRequestScreenCaptureAccess()
            openScreenCaptureSettings()
        }
    }

    static var hasScreenCapture: Bool { CGPreflightScreenCaptureAccess() }

    static var hasMicrophone: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    static func openScreenCaptureSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}
