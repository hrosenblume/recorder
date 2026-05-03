import AppKit
import Foundation

final class Updater {
    private var latestVersion: String?
    private var assetURL: String?
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?
    private var progressBar: NSProgressIndicator?

    var currentVersion: String { Config.currentVersion }

    var updateAvailable: Bool {
        guard let latest = latestVersion else { return false }
        return Self.compareVersions(latest, isNewerThan: currentVersion)
    }

    func checkIfNeeded() {
        let lastCheck = UserDefaults.standard.double(forKey: Config.lastUpdateCheckKey)
        if Date().timeIntervalSince1970 - lastCheck < Config.updateCheckInterval { return }
        check(silent: true)
    }

    func check(silent: Bool) {
        guard let url = URL(string: Config.githubReleasesURL) else {
            if !silent { showErrorAlert() }
            return
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, _, _ in
            guard let self else { return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                if !silent { DispatchQueue.main.async { self.showErrorAlert() } }
                return
            }

            let assets = json["assets"] as? [[String: Any]] ?? []
            let zipURL = assets
                .first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true })
                .flatMap { $0["browser_download_url"] as? String }

            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Config.lastUpdateCheckKey)

            DispatchQueue.main.async {
                self.latestVersion = version
                self.assetURL = zipURL
                if self.updateAvailable {
                    self.showUpdateAlert(version: version)
                } else if !silent {
                    self.showUpToDateAlert()
                }
            }
        }.resume()
    }

    private func showUpdateAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available — v\(version)"
        alert.informativeText = "A new version of Recorder is available. You're currently on v\(currentVersion).\n\nRecorder will download and install the update, then relaunch."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Update")
        alert.addButton(withTitle: "Skip")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            downloadAndInstall()
        }
    }

    private func downloadAndInstall() {
        guard let urlString = assetURL, let url = URL(string: urlString) else {
            showErrorAlert(); return
        }
        showProgressWindow(text: "Downloading update…")

        URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
            guard let self else { return }
            guard let tempURL, error == nil else {
                DispatchQueue.main.async {
                    self.hideProgressWindow()
                    self.showErrorAlert()
                }
                return
            }

            let stagingDir = FileManager.default.temporaryDirectory.appendingPathComponent("recorder-update")
            try? FileManager.default.removeItem(at: stagingDir)
            try? FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
            let zipPath = stagingDir.appendingPathComponent("Recorder.app.zip")
            do {
                try FileManager.default.moveItem(at: tempURL, to: zipPath)
            } catch {
                DispatchQueue.main.async {
                    self.hideProgressWindow()
                    self.showErrorAlert()
                }
                return
            }

            DispatchQueue.main.async { self.updateProgressText("Installing…") }
            self.runInstaller(zipPath: zipPath.path)
        }.resume()
    }

    private func showProgressWindow(text: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 110),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.title = "Recorder Update"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .floating

        let container = NSView(frame: window.contentView!.bounds)
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 60, width: 300, height: 22)
        label.alignment = .center
        label.font = .systemFont(ofSize: 13, weight: .medium)
        container.addSubview(label)

        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 30, width: 300, height: 20))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        container.addSubview(bar)

        window.contentView = container
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        progressWindow = window
        progressLabel = label
        progressBar = bar
    }

    private func updateProgressText(_ text: String) { progressLabel?.stringValue = text }

    private func hideProgressWindow() {
        progressBar?.stopAnimation(nil)
        progressWindow?.orderOut(nil)
        progressWindow = nil; progressLabel = nil; progressBar = nil
    }

    private func runInstaller(zipPath: String) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = Bundle.main.bundlePath
        let script = """
        for i in $(seq 1 50); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.2
        done
        rm -rf "\(appPath)"
        /usr/bin/ditto -xk "\(zipPath)" "$(dirname "\(appPath)")"
        xattr -cr "\(appPath)" 2>/dev/null
        open "\(appPath)"
        rm -rf "$(dirname "\(zipPath)")"
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", script]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch {
            DispatchQueue.main.async { self.showErrorAlert() }
            return
        }

        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    private func showUpToDateAlert() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "Recorder v\(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showErrorAlert() {
        let alert = NSAlert()
        alert.messageText = "Update Check Failed"
        alert.informativeText = "Could not reach GitHub to check for updates."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func compareVersions(_ a: String, isNewerThan b: String) -> Bool {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av != bv { return av > bv }
        }
        return false
    }
}
