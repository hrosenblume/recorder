import AVFoundation
import AppKit
import CoreGraphics

enum Permissions {
    static func preflightAll() async {
        if !CGPreflightScreenCaptureAccess() {
            // Triggers TCC prompt the first time; subsequent calls just return false until granted.
            _ = CGRequestScreenCaptureAccess()
        }
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
