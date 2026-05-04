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
    /// Wipes any stale TCC entry, re-registers the current cdhash, and opens
    /// System Settings — fixing the "toggle ON for old cdhash, app unauthorized"
    /// false-positive that happens after every rebuild under ad-hoc signing.
    static func promptForScreenCapture() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = "Recorder will reset its existing entry and ask macOS to re-authorize it. Click \"Open System Settings\", toggle Recorder ON under \"Screen & System Audio Recording\", then quit Recorder fully and relaunch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            runTccutil(service: "ScreenCapture")
            _ = CGRequestScreenCaptureAccess()
            openScreenCaptureSettings()
        }
    }

    /// User-initiated full reset: wipe both Screen Recording and Microphone TCC
    /// entries for our bundle, re-register, and open Settings. Useful when the
    /// user knows things are stale (e.g. just installed an update) and wants to
    /// recover proactively without first failing a recording.
    static func resetAndReauthorize() {
        let alert = NSAlert()
        alert.messageText = "Reset Recorder permissions?"
        alert.informativeText = "This wipes Recorder's Screen Recording and Microphone entries from System Settings, then asks macOS to add them again with the current app version. You'll need to toggle Recorder ON in Settings, then quit and relaunch Recorder."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Reset & Open Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        runTccutil(service: "ScreenCapture")
        runTccutil(service: "Microphone")
        _ = CGRequestScreenCaptureAccess()
        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        openScreenCaptureSettings()
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

    /// Shells out to `tccutil reset <service> <bundleID>`. Works for the user's
    /// own bundles without sudo. Best-effort — failure is non-fatal.
    private static func runTccutil(service: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", service, Config.bundleID]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
    }
}
