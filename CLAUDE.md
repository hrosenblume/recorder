# Recorder — for Claude

Personal macOS menu-bar screen recorder. Mirror of the Redeye repo treatment (auto-update, GitHub Pages site, ad-hoc codesigning).

## Build

```bash
bash scripts/build-app.sh        # builds → /Applications/Recorder.app
open /Applications/Recorder.app
```

The bundle is rebuilt **in place** so TCC keeps remembering Screen Recording / Microphone grants. Don't `rm -rf` the `.app` between builds.

## Release

```bash
scripts/release.sh 1.0.1
```

Bumps `Resources/Info.plist`, builds, zips, tags, pushes, and creates the GitHub release with `Recorder.app.zip` attached. The in-app updater hits `https://api.github.com/repos/hrosenblume/recorder/releases/latest` once a day.

## Repo layout

- `Sources/recorder/*.swift` — app source
- `Resources/Info.plist`, `Resources/Recorder.icns` — bundle resources
- `scripts/` — build-app.sh, generate-icon.swift, release.sh
- `website/` — Next.js 16 + Tailwind 4, deployed to https://hrosenblume.github.io/recorder/ via `.github/workflows/pages.yml`

## Conventions

- Stable signing identifier `com.hunter.recorder` — never change without invalidating users' permission grants
- Hardcoded hotkey: `⌘⇧2` (Carbon `RegisterEventHotKey`, `kVK_ANSI_2`)
- Output naming: `Recording yyyy-MM-dd at h.mm.ss a.mov` (matches macOS screenshot format)
- Output location: `~/Local/Screenshots` (literal, not `~/Pictures` — user-specific preference)

## Things to remember

- Swift 6 strict-concurrency `@Sendable` warnings on `RecordingEngine` are non-blocking; the class is single-actor in practice. Don't add `@unchecked Sendable` reflexively.
- ScreenCaptureKit needs `CGRequestScreenCaptureAccess()` to be called before `SCStream.startCapture()` or it fails silently.
- After granting Screen Recording the first time, the app must be relaunched once before TCC honors the grant.
- Don't bump deployment target above macOS 13 unless you have a reason — older Macs work fine.

## Known gaps (deliberately not built)

- System audio (only mic in v1)
- Window/region capture (only main display)
- Configurable hotkey UI
- Pause/resume during recording
- Trim/edit in-app
