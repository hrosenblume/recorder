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
    /// the system prompt exactly once.
    @MainActor
    static func promptForScreenCapture() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Recorder needs Screen Recording access to capture your screen.\n\nClick \"Open System Settings\", enable Recorder under \"Screen & System Audio Recording\", then quit and relaunch Recorder for the grant to take effect."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            // CGRequestScreenCaptureAccess() registers our app in the TCC list
            // and opens Settings to the right pane.
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
