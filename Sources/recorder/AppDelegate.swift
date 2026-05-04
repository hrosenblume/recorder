import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var statusMenu: NSMenu!
    private var hotKey: HotKeyManager?
    private var toggleItem: NSMenuItem!
    private var recentItem: NSMenuItem!
    private var systemAudioItem: NSMenuItem!
    private var isRecording = false
    private let engine = RecordingEngine()
    private let updater = Updater()
    private var instructionsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon(recording: false)

        let menu = NSMenu()
        menu.delegate = self

        toggleItem = NSMenuItem(
            title: "Start",
            action: #selector(toggleRecording),
            keyEquivalent: "2"
        )
        toggleItem.keyEquivalentModifierMask = [.command, .shift]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        recentItem = NSMenuItem(title: "Recents", action: nil, keyEquivalent: "")
        recentItem.submenu = NSMenu()
        menu.addItem(recentItem)

        let openItem = NSMenuItem(
            title: "Open Destination Folder",
            action: #selector(openRecordingsFolder),
            keyEquivalent: ""
        )
        openItem.target = self
        menu.addItem(openItem)

        let changeFolderItem = NSMenuItem(
            title: "Change Destination Folder…",
            action: #selector(changeRecordingsFolder),
            keyEquivalent: ""
        )
        changeFolderItem.target = self
        menu.addItem(changeFolderItem)

        menu.addItem(.separator())

        systemAudioItem = NSMenuItem(
            title: "Enable System IO",
            action: #selector(toggleSystemAudio),
            keyEquivalent: ""
        )
        systemAudioItem.target = self
        systemAudioItem.state = Config.recordSystemAudio ? .on : .off
        systemAudioItem.toolTip = "Mixes system audio (calls, music) with the mic into a single track."
        menu.addItem(systemAudioItem)

        menu.addItem(.separator())

        let gettingStarted = NSMenuItem(
            title: "Getting Started",
            action: #selector(showGettingStarted),
            keyEquivalent: ""
        )
        gettingStarted.target = self
        menu.addItem(gettingStarted)

        let updates = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates),
            keyEquivalent: ""
        )
        updates.target = self
        menu.addItem(updates)

        let website = NSMenuItem(
            title: "Visit Website",
            action: #selector(openWebsite),
            keyEquivalent: ""
        )
        website.target = self
        menu.addItem(website)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        let version = NSMenuItem(title: "v\(Config.currentVersion)", action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        // Don't set statusItem.menu directly. Wire the button's action so a click
        // during a recording stops & saves; otherwise we pop the menu programmatically.
        statusMenu = menu
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusButtonClicked)

        engine.onStateChange = { [weak self] recording in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRecording = recording
                self.updateIcon(recording: recording)
                self.toggleItem.title = recording ? "Stop" : "Start"
            }
        }
        engine.onSaved = { url in
            Notifications.recordingSaved(at: url)
        }

        Notifications.requestAuthorization()
        Task { await Permissions.preflightAll() }
        updater.checkIfNeeded()

        hotKey = HotKeyManager { [weak self] in
            self?.toggleRecording()
        }
    }

    // MARK: - Menu actions

    @objc private func statusButtonClicked() {
        if isRecording {
            // Click during a recording = stop & save (parity with ⌘⇧2).
            engine.toggle()
        } else {
            // Otherwise pop the menu beneath the button.
            guard let button = statusItem.button else { return }
            let location = NSPoint(x: 0, y: button.bounds.height + 4)
            statusMenu.popUp(positioning: nil, at: location, in: button)
        }
    }

    @objc private func toggleRecording() {
        engine.toggle()
    }

    @objc private func openRecordingsFolder() {
        let url = Config.recordingsDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.open(url)
    }

    @objc private func checkForUpdates() {
        updater.check(silent: false)
    }

    @objc private func toggleSystemAudio() {
        let next = !Config.recordSystemAudio
        Config.setRecordSystemAudio(next)
        systemAudioItem.state = next ? .on : .off
    }

    @objc private func changeRecordingsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = Config.recordingsDirectory
        panel.prompt = "Choose"
        panel.message = "Choose where to save your recordings"

        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            Config.setRecordingsDirectory(url)
        }
    }

    @objc private func openWebsite() {
        if let url = URL(string: Config.websiteURL) {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openRecording(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func showGettingStarted() {
        if let window = instructionsWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Recorder — Getting Started"
        window.center()
        window.isReleasedWhenClosed = false

        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.borderType = .noBorder

        let text = NSTextView(frame: scroll.bounds)
        text.isEditable = false
        text.isSelectable = true
        text.textContainerInset = NSSize(width: 18, height: 18)
        text.font = .systemFont(ofSize: 13)
        text.string = Self.gettingStartedText
        text.autoresizingMask = [.width]

        scroll.documentView = text
        window.contentView = scroll

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        instructionsWindow = window
    }

    // MARK: - Recent recordings

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusMenu {
            rebuildRecentRecordings()
        }
    }

    private func rebuildRecentRecordings() {
        let submenu = NSMenu()
        let recordings = Self.recentRecordings(limit: 8)
        if recordings.isEmpty {
            let empty = NSMenuItem(title: "No recordings yet", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for url in recordings {
                let item = NSMenuItem(
                    title: url.deletingPathExtension().lastPathComponent,
                    action: #selector(openRecording(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = url.path
                submenu.addItem(item)
            }
        }
        recentItem.submenu = submenu
    }

    private static func recentRecordings(limit: Int) -> [URL] {
        let dir = Config.recordingsDirectory
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return contents
            .filter { ["mov", "mp4", "m4v"].contains($0.pathExtension.lowercased()) }
            .filter { $0.lastPathComponent.hasPrefix("Recording ") }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return l > r
            }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Icon

    private func updateIcon(recording: Bool) {
        guard let button = statusItem.button else { return }
        button.image = recording ? Self.makeRecordingIcon() : Self.makeIdleIcon()
    }

    private static func makeIdleIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Recorder idle")
        let image = base?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static func makeRecordingIcon() -> NSImage {
        // Discreet: same template tint as idle, only shape changes (outline → filled).
        // Anyone glancing at the menu bar won't be tipped off that we're recording.
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let base = NSImage(systemSymbolName: "record.circle.fill", accessibilityDescription: "Recorder recording")
        let image = base?.withSymbolConfiguration(config) ?? NSImage()
        image.isTemplate = true
        return image
    }

    private static let gettingStartedText = """
    Recorder — Getting Started

    1. Toggle a recording
       Press ⌘⇧2 anywhere on your Mac to start. Press it again to stop. The
       menu bar icon switches from outline to filled while recording — subtle
       on purpose so it doesn't stand out when you're sharing your screen.

    2. Where files go
       Recordings save to ~/Local/Screenshots by default (matching the macOS
       screenshot folder convention). Use "Change Recordings Folder…" in the
       menu to point them anywhere you want.

       Files are named: Recording <date> at <time>.mov

    3. What's captured
       • Main display, retina resolution
       • Default microphone (great for narrating bug reports)
       • System audio (the other side of calls, music, notifications) — toggle
         "Record System Audio" in the menu. On by default.

       The output .mov has separate mic and system-audio tracks. Both play
       together in QuickTime Player, Quick Look, Slack previews, and most
       editors — no manual track-toggling needed.

    4. Recording calls (AirPods etc.)
       Leave "Record System Audio" on. The other person's voice is captured
       through system audio (their voice → your AirPods → recorded). Your
       voice is captured through the AirPods mic. Both end up in the file.

    5. Permissions (first run)
       macOS prompts for Screen Recording and Microphone access. Grant both.
       After granting Screen Recording, quit Recorder and relaunch — TCC
       requires that.

    6. Quick reference
       ⌘⇧2          Start / stop recording
       Menu bar     Click the icon for menu options
       Recent       The "Recent Recordings" submenu lists your last 8 files

    7. Updates
       Recorder checks GitHub once per day for new releases. You can also use
       "Check for Updates…" from the menu.

    Have feedback? Open an issue on GitHub.
    """
}
