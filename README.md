# Recorder

Screen recording, one tap.

A macOS menu bar app that records your screen with microphone narration. Hit `⌘⇧2` to start. Hit it again to stop. Files land in `~/Local/Screenshots`.

[Download for Mac](https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip) · [Website](https://hrosenblume.github.io/recorder/)

## What it does

- Global hotkey: `⌘⇧2` from anywhere — same UX as `⌘⇧3` for screenshots
- Captures the main display (retina) plus the default microphone
- Saves to `~/Local/Screenshots/Recording <date> at <time>.mov`
- Lives in the menu bar — colorful play-button icon, turns red while recording
- Auto-checks GitHub Releases once a day for updates
- Native AppKit + ScreenCaptureKit + AVFoundation. ~26 MB resident, 0% CPU at idle.

## Install

1. Download `Recorder.app.zip` from [the latest release](https://github.com/hrosenblume/recorder/releases/latest)
2. Unzip and move `Recorder.app` to `/Applications`
3. Strip the quarantine flag:
   ```bash
   xattr -cr /Applications/Recorder.app
   ```
4. Launch it. First run will prompt for Screen Recording and Microphone permission. Grant both, then quit and relaunch Recorder once (TCC requires it).

Or have Claude do it:
```bash
curl -LO https://github.com/hrosenblume/recorder/releases/latest/download/Recorder.app.zip && \
unzip -o Recorder.app.zip -d /Applications && \
rm Recorder.app.zip && \
xattr -cr /Applications/Recorder.app && \
open /Applications/Recorder.app
```

## Build from source

Requires Swift 5.9+ (Command Line Tools is enough — full Xcode not needed).

```bash
git clone https://github.com/hrosenblume/recorder
cd recorder
bash scripts/build-app.sh
open ~/Applications/Recorder.app
```

The build script generates the icon, compiles via SwiftPM, assembles the `.app` bundle, and ad-hoc codesigns with a stable identifier so TCC remembers your permission grants across rebuilds.

## Auto-start on login

```xml
<!-- ~/Library/LaunchAgents/com.hunter.recorder.plist -->
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.hunter.recorder</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/open</string>
        <string>-a</string>
        <string>/Applications/Recorder.app</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
```

Then `launchctl load ~/Library/LaunchAgents/com.hunter.recorder.plist`.

## Cutting a release

```bash
scripts/release.sh 1.0.1
```

Bumps `CFBundleShortVersionString`, builds the `.app`, zips it, tags `v1.0.1`, pushes, and runs `gh release create` with the asset attached. The in-app updater picks it up within 24 hours (or immediately via "Check for Updates…" in the menu).

## Architecture

| File | Role |
|------|------|
| `Sources/recorder/main.swift` | NSApplication bootstrap (`.accessory` activation policy) |
| `Sources/recorder/AppDelegate.swift` | Menu bar status item, menu, recent recordings, instructions |
| `Sources/recorder/RecordingEngine.swift` | `SCStream` + `AVCaptureSession` (mic) → `AVAssetWriter` |
| `Sources/recorder/HotKeyManager.swift` | Carbon `RegisterEventHotKey` for the global shortcut |
| `Sources/recorder/Permissions.swift` | TCC preflight for screen + mic |
| `Sources/recorder/Updater.swift` | GitHub Releases auto-update flow |
| `Sources/recorder/Notifications.swift` | "Recording saved" notification |
| `Sources/recorder/Config.swift` | Constants (bundle id, releases URL, etc.) |
| `Resources/Info.plist` | Bundle metadata, `LSUIElement`, mic usage description |
| `scripts/build-app.sh` | Build + bundle + ad-hoc codesign |
| `scripts/generate-icon.swift` | Render `Recorder.icns` programmatically |
| `scripts/release.sh` | Version bump, build, zip, tag, GitHub release |
| `website/` | Next.js marketing site, deployed to GitHub Pages |

## License

MIT — see [LICENSE](LICENSE).

---

[Learn more on the website](https://hrosenblume.github.io/recorder/)
