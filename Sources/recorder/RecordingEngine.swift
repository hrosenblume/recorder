import AVFoundation
import AppKit
import CoreMedia
import ScreenCaptureKit

final class RecordingEngine: NSObject {
    enum State { case idle, starting, recording, stopping }

    var onStateChange: ((Bool) -> Void)?
    var onSaved: ((URL) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.hunter.recorder.state")
    private let videoQueue = DispatchQueue(label: "com.hunter.recorder.video")
    private let audioQueue = DispatchQueue(label: "com.hunter.recorder.audio")

    private var state: State = .idle

    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var captureSession: AVCaptureSession?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioDelegate: AudioDelegate?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?

    private var sessionStarted = false
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
                DispatchQueue.main.async {
                    self.showStartError(error)
                }
            }
        }
    }

    private func startCapture() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            Permissions.openScreenCaptureSettings()
            throw RecorderError.missingScreenPermission
        }
        guard Permissions.hasMicrophone else {
            Permissions.openMicrophoneSettings()
            throw RecorderError.missingMicPermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true
        )
        let mainID = CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays.first
        else {
            throw RecorderError.noDisplay
        }

        let url = Self.nextOutputURL()
        outputURL = url

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        // Use display's pixel dimensions (SCDisplay reports point dimensions on macOS 14+;
        // multiply by backingScaleFactor for retina output).
        let scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let pixelWidth = Int(CGFloat(display.width) * scale)
        let pixelHeight = Int(CGFloat(display.height) * scale)

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

        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000
        ]
        let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audioInput.expectsMediaDataInRealTime = true
        guard writer.canAdd(audioInput) else { throw RecorderError.writerSetup("audio input") }
        writer.add(audioInput)

        guard writer.startWriting() else {
            throw RecorderError.writerSetup("startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
        }

        self.writer = writer
        self.videoInput = videoInput
        self.audioInput = audioInput
        self.sessionStarted = false

        // Configure SCStream
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixelWidth
        config.height = pixelHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 6
        config.showsCursor = true
        config.capturesAudio = false

        let output = StreamOutput(engine: self)
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()

        self.stream = stream
        self.streamOutput = output

        // Microphone via AVCaptureSession
        let session = AVCaptureSession()
        guard let micDevice = AVCaptureDevice.default(for: .audio) else {
            throw RecorderError.noMicrophone
        }
        let micInput = try AVCaptureDeviceInput(device: micDevice)
        guard session.canAddInput(micInput) else { throw RecorderError.writerSetup("mic input") }
        session.addInput(micInput)

        let audioOut = AVCaptureAudioDataOutput()
        let audioDelegate = AudioDelegate(engine: self)
        audioOut.setSampleBufferDelegate(audioDelegate, queue: audioQueue)
        guard session.canAddOutput(audioOut) else { throw RecorderError.writerSetup("audio output") }
        session.addOutput(audioOut)

        session.startRunning()

        self.captureSession = session
        self.audioOutput = audioOut
        self.audioDelegate = audioDelegate
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
        }

        if videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    fileprivate func handleAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
        audioInput.append(sampleBuffer)
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
        let session = self.captureSession
        let stream = self.stream
        let url = self.outputURL

        Task {
            if let stream {
                try? await stream.stopCapture()
            }
            session?.stopRunning()

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
        audioOutput = nil
        audioDelegate = nil
        writer = nil
        videoInput = nil
        audioInput = nil
        sessionStarted = false
        outputURL = nil
    }

    // MARK: - Output URL

    private static func nextOutputURL() -> URL {
        let dir = URL(fileURLWithPath: ("~/Local/Screenshots" as NSString).expandingTildeInPath)
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
        guard type == .screen else { return }
        engine?.handleVideoSample(sampleBuffer)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        engine?.handleStreamStopped(error)
    }
}

private final class AudioDelegate: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    weak var engine: RecordingEngine?
    init(engine: RecordingEngine) { self.engine = engine }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        engine?.handleAudioSample(sampleBuffer)
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
