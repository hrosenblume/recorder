import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

final class RecordingEngine: NSObject, @unchecked Sendable {
    enum State { case idle, starting, recording, stopping }

    var onStateChange: ((Bool) -> Void)?
    var onSaved: ((URL) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.hunter.recorder.state")
    private let videoQueue = DispatchQueue(label: "com.hunter.recorder.video")
    private let micQueue = DispatchQueue(label: "com.hunter.recorder.mic")
    private let systemAudioQueue = DispatchQueue(label: "com.hunter.recorder.systemaudio")

    private var state: State = .idle

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var captureSession: AVCaptureSession?
    private var micOutput: AVCaptureAudioDataOutput?
    private var micDelegate: MicDelegate?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var audioMixer: AudioMixer?

    private var sessionStarted = false
    private var mixerStarted = false
    private var fallbackMicOnly = false
    private var outputURL: URL?

    func toggle() {
        stateQueue.async { [weak self] in
            guard let self else { return }
            switch self.state {
            case .idle:
                self.startLocked()
            case .recording:
                self.stopLocked()
            case .starting, .stopping:
                break
            }
        }
    }

    // MARK: - Start

    private func startLocked() {
        state = .starting
        Task {
            do {
                try await self.startCapture()
                self.stateQueue.async {
                    self.state = .recording
                    self.onStateChange?(true)
                }
            } catch {
                NSLog("Recorder: failed to start - \(error)")
                self.cleanup()
                self.stateQueue.async {
                    self.state = .idle
                    self.onStateChange?(false)
                }
                // Suppress our own alert for permission errors — macOS shows
                // its native prompt for those, and stacking ours on top creates
                // a double-layered dialog. Only surface non-permission errors.
                if case RecorderError.missingScreenPermission = error { return }
                if case RecorderError.missingMicPermission = error { return }
                DispatchQueue.main.async {
                    self.showStartError(error)
                }
            }
        }
    }

    private func startCapture() async throws {
        // Skip CGPreflightScreenCaptureAccess() — on macOS 15 with ad-hoc signing
        // it reports stale results when the cdhash drifts. Trust SCShareableContent
        // instead, which consults TCC directly with the running cdhash.
        // SCShareableContent triggers macOS's native Screen Recording prompt the
        // first time it's called without permission. Don't add our own alert on
        // top — that produces a double-layered dialog stack.
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
        } catch {
            throw RecorderError.missingScreenPermission
        }

        guard !content.displays.isEmpty else {
            throw RecorderError.missingScreenPermission
        }

        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first
        else {
            throw RecorderError.noDisplay
        }

        // AVCaptureDevice.requestAccess (called from Permissions.preflightAll on
        // launch) handles the mic prompt natively. Don't open Settings ourselves.
        guard Permissions.hasMicrophone else {
            throw RecorderError.missingMicPermission
        }

        let captureSystemAudio = Config.recordSystemAudio
        let url = Self.nextOutputURL()
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = Int(CGFloat(display.width) * scale)
        let pixelHeight = Int(CGFloat(display.height) * scale)

        // Video input
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: pixelWidth,
            AVVideoHeightKey: pixelHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000,
                AVVideoMaxKeyFrameIntervalKey: 60,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(videoInput) else { throw RecorderError.writerSetup("video input") }
        writer.add(videoInput)

        // Single audio input (fed by mixer; falls back to direct mic if engine fails)
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else { throw RecorderError.writerSetup("audio input") }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw RecorderError.writerSetup("startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        // Audio mixer (started lazily on first video sample so PTS aligns)
        let mixer = AudioMixer()
        mixer.attach(systemAudio: captureSystemAudio)
        mixer.onMixedSample = { [weak self] sample in
            self?.appendMixedAudio(sample)
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.audioMixer = mixer
        self.sessionStarted = false
        self.mixerStarted = false
        self.fallbackMicOnly = false

        // Configure SCStream
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = captureSystemAudio
        if captureSystemAudio {
            config.sampleRate = 48000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }

        let output = StreamOutput(engine: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
        if captureSystemAudio {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: systemAudioQueue)
        }
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output

        // Microphone via AVCaptureSession
        let session = AVCaptureSession()
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noMicrophone
        }
        let micCaptureInput = try AVCaptureDeviceInput(device: micDevice)
        guard session.canAddInput(micCaptureInput) else { throw RecorderError.writerSetup("mic input") }
        session.addInput(micCaptureInput)

        let micOut = AVCaptureAudioDataOutput()
        let micDelegate = MicDelegate(engine: self)
        micOut.setSampleBufferDelegate(micDelegate, queue: micQueue)
        guard session.canAddOutput(micOut) else { throw RecorderError.writerSetup("mic output") }
        session.addOutput(micOut)

        session.startRunning()

        self.captureSession = session
        self.micOutput = micOut
        self.micDelegate = micDelegate
    }

    fileprivate func handleVideoSample(_ sampleBuffer: CMSampleBuffer) {
        guard sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let statusRaw = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: statusRaw),
              status == .complete
        else { return }

        guard let writer, let videoInput else { return }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true

            // Start the mixer with the same PTS so audio aligns with video.
            if let mixer = audioMixer, !mixerStarted {
                do {
                    try mixer.start(firstVideoPTS: pts)
                    mixerStarted = true
                } catch {
                    NSLog("Recorder: AudioMixer.start failed (\(error)) — falling back to direct mic")
                    fallbackMicOnly = true
                    audioMixer = nil
                }
            }
        }

        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    fileprivate func handleMicSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted else { return }

        if let mixer = audioMixer, !fallbackMicOnly {
            mixer.pushMic(sampleBuffer)
            return
        }

        // Fallback path: write mic directly to the audio input.
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
    }

    fileprivate func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let mixer = audioMixer, !fallbackMicOnly else { return }
        mixer.pushSystem(sampleBuffer)
    }

    private func appendMixedAudio(_ sample: CMSampleBuffer) {
        guard let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sample)
    }

    fileprivate func handleStreamStopped(_ error: Error?) {
        if let error { NSLog("Recorder: stream stopped - \(error)") }
        stateQueue.async { [weak self] in
            guard let self, self.state == .recording else { return }
            self.stopLocked()
        }
    }

    // MARK: - Stop

    private func stopLocked() {
        state = .stopping
        let writer = self.writer
        let videoInput = self.videoInput
        let audioInput = self.audioInput
        let mixer = self.audioMixer
        let session = self.captureSession
        let stream = self.stream
        let url = self.outputURL

        Task {
            if let stream {
                try? await stream.stopCapture()
            }
            session?.stopRunning()
            mixer?.stop()

            videoInput?.markAsFinished()
            audioInput?.markAsFinished()

            if let writer {
                await writer.finishWriting()
            }

            self.cleanup()

            self.stateQueue.async {
                self.state = .idle
                self.onStateChange?(false)
            }

            if let url, FileManager.default.fileExists(atPath: url.path) {
                DispatchQueue.main.async {
                    self.onSaved?(url)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }

    private func cleanup() {
        stream = nil
        streamOutput = nil
        captureSession = nil
        micOutput = nil
        micDelegate = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        audioMixer = nil
        sessionStarted = false
        mixerStarted = false
        fallbackMicOnly = false
        outputURL = nil
    }

    // MARK: - Output URL

    private static func nextOutputURL() -> URL {
        let dir = Config.recordingsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
        let stamp = formatter.string(from: Date())
        let base = "Recording \(stamp)"

        var url = dir.appendingPathComponent("\(base).mov")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("\(base) (\(n)).mov")
            n += 1
        }
        return url
    }

    private func showStartError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't start recording"
        alert.informativeText = (error as? RecorderError)?.message ?? error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}

// MARK: - Stream output

private final class StreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    weak var engine: RecordingEngine?
    init(engine: RecordingEngine) { self.engine = engine }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            engine?.handleVideoSample(sampleBuffer)
        case .audio:
            engine?.handleSystemAudioSample(sampleBuffer)
        default:
            // Future SCStreamOutputType cases (e.g. .microphone on macOS 15) — ignore.
            break
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        engine?.handleStreamStopped(error)
    }
}

private final class MicDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var engine: RecordingEngine?
    init(engine: RecordingEngine) { self.engine = engine }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine?.handleMicSample(sampleBuffer)
    }
}

// MARK: - Errors

enum RecorderError: Error {
    case missingScreenPermission
    case missingMicPermission
    case noDisplay
    case noMicrophone
    case writerSetup(String)

    var message: String {
        switch self {
        case .missingScreenPermission:
            return "Grant Screen Recording permission to Recorder in System Settings, then relaunch."
        case .missingMicPermission:
            return "Grant Microphone permission to Recorder in System Settings."
        case .noDisplay:
            return "No display available to record."
        case .noMicrophone:
            return "No microphone found."
        case .writerSetup(let detail):
            return "Could not configure writer: \(detail)"
        }
    }
}
