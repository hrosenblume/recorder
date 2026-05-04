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
