import AVFoundation
import CoreMedia
import Foundation

/// Mixes microphone + system audio into a single stereo PCM stream and emits
/// `CMSampleBuffer`s ready to feed an `AVAssetWriterInput`.
///
/// Pipeline:
///
///     mic CMSampleBuffer ─► [AVAudioConverter] ─► [micPlayer node] ─┐
///                                                                   ▼
///                                                        [mainMixerNode] ─► renderOffline
///                                                                   ▲              │
///     SCK CMSampleBuffer ─► [AVAudioConverter] ─► [systemPlayer]   ─┘              ▼
///                                                                          CMSampleBuffer
///
/// Critical: the engine runs in **manual rendering mode** (.realtime).
/// AVAudioEngine in normal mode auto-connects mainMixerNode→outputNode, which
/// plays the mix out the speakers — with AirPods that creates a feedback loop
/// where the mic captures the played-back audio and the engine's auto-gain
/// drops mic level. Manual mode disables hardware output entirely; we drive
/// the render via a DispatchSourceTimer.
final class AudioMixer: @unchecked Sendable {
    // MARK: - Public surface

    var onMixedSample: ((CMSampleBuffer) -> Void)?
    private(set) var isSystemAudioAttached: Bool = false

    // MARK: - Engine

    private let engine = AVAudioEngine()
    private let micPlayer = AVAudioPlayerNode()
    private let systemPlayer = AVAudioPlayerNode()

    private let commonFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 2,
            interleaved: false
        )!
    }()

    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?

    // MARK: - Render loop

    private let renderQueue = DispatchQueue(
        label: "com.hunter.recorder.audio.render",
        qos: .userInteractive
    )
    private var renderTimer: DispatchSourceTimer?
    private var renderBuffer: AVAudioPCMBuffer?
    private let renderFrameCount: AVAudioFrameCount = 480 // ~10 ms at 48 kHz

    // MARK: - Timing

    private var firstVideoPTS: CMTime = .invalid
    private var framesEmitted: Int64 = 0
    private var isStarted = false
    private let stateLock = NSLock()

    // MARK: - Setup

    func attach(systemAudio: Bool) {
        isSystemAudioAttached = systemAudio
        engine.attach(micPlayer)
        engine.connect(micPlayer, to: engine.mainMixerNode, format: commonFormat)
        if systemAudio {
            engine.attach(systemPlayer)
            engine.connect(systemPlayer, to: engine.mainMixerNode, format: commonFormat)
        }
        micPlayer.volume = Config.micVolume
        systemPlayer.volume = Config.systemAudioVolume
    }

    func start(firstVideoPTS: CMTime) throws {
        stateLock.lock()
        self.firstVideoPTS = firstVideoPTS
        self.framesEmitted = 0
        stateLock.unlock()

        // Detach the engine from hardware. After this call, mainMixerNode→outputNode
        // is gone; we render manually via renderOffline().
        try engine.enableManualRenderingMode(
            .realtime,
            format: commonFormat,
            maximumFrameCount: renderFrameCount
        )

        renderBuffer = AVAudioPCMBuffer(pcmFormat: commonFormat, frameCapacity: renderFrameCount)

        try engine.start()
        micPlayer.play()
        if isSystemAudioAttached {
            systemPlayer.play()
        }

        stateLock.lock()
        isStarted = true
        stateLock.unlock()

        // Drive renderOffline at audio rate (~10ms cadence). DispatchSourceTimer
        // is wall-clock-based so over time we produce exactly real-time audio.
        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(10),
            repeating: .milliseconds(10),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in self?.renderTick() }
        timer.resume()
        renderTimer = timer
    }

    func stop() {
        stateLock.lock()
        let wasStarted = isStarted
        isStarted = false
        stateLock.unlock()

        renderTimer?.cancel()
        renderTimer = nil

        guard wasStarted else { return }

        micPlayer.stop()
        systemPlayer.stop()
        engine.stop()
        renderBuffer = nil
        micConverter = nil
        systemConverter = nil
    }

    // MARK: - Sample feeding

    func pushMic(_ sampleBuffer: CMSampleBuffer) {
        push(sampleBuffer, into: micPlayer, converterRef: \.micConverter)
    }

    func pushSystem(_ sampleBuffer: CMSampleBuffer) {
        guard isSystemAudioAttached else { return }
        push(sampleBuffer, into: systemPlayer, converterRef: \.systemConverter)
    }

    // MARK: - Internals

    private func push(
        _ sampleBuffer: CMSampleBuffer,
        into player: AVAudioPlayerNode,
        converterRef: ReferenceWritableKeyPath<AudioMixer, AVAudioConverter?>
    ) {
        stateLock.lock()
        let started = isStarted
        stateLock.unlock()
        guard started else { return }

        guard let sourcePCM = pcmBuffer(from: sampleBuffer) else { return }
        let sourceFormat = sourcePCM.format

        var converter = self[keyPath: converterRef]
        if converter?.inputFormat != sourceFormat {
            converter = AVAudioConverter(from: sourceFormat, to: commonFormat)
            self[keyPath: converterRef] = converter
        }
        guard let converter else { return }

        let ratio = commonFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(sourcePCM.frameLength) * ratio + 1024)
        guard let output = AVAudioPCMBuffer(
            pcmFormat: commonFormat,
            frameCapacity: outputCapacity
        ) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: output, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return sourcePCM
        }

        if status == .error {
            if let error { NSLog("Recorder: converter error - \(error)") }
            return
        }
        if output.frameLength == 0 { return }

        player.scheduleBuffer(output, completionHandler: nil)
    }

    private func renderTick() {
        stateLock.lock()
        let started = isStarted
        let basePTS = firstVideoPTS
        let framesSoFar = framesEmitted
        stateLock.unlock()

        guard started, basePTS.isValid, let buffer = renderBuffer else { return }

        let status: AVAudioEngineManualRenderingStatus
        do {
            status = try engine.renderOffline(renderFrameCount, to: buffer)
        } catch {
            NSLog("Recorder: renderOffline threw - \(error)")
            return
        }

        guard status == .success, buffer.frameLength > 0 else { return }

        let pts = CMTimeAdd(
            basePTS,
            CMTime(value: framesSoFar, timescale: CMTimeScale(commonFormat.sampleRate))
        )

        guard let sample = sampleBuffer(from: buffer, pts: pts) else { return }

        stateLock.lock()
        framesEmitted += Int64(buffer.frameLength)
        stateLock.unlock()

        onMixedSample?(sample)
    }

    // MARK: - CMSampleBuffer ⇄ AVAudioPCMBuffer

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            return nil
        }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }
        var asbd = asbdPtr.pointee
        guard let format = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else { return nil }
        guard let pcm = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else { return nil }
        pcm.frameLength = AVAudioFrameCount(frameCount)

        let copyStatus = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcm.mutableAudioBufferList
        )
        return copyStatus == noErr ? pcm : nil
    }

    private func sampleBuffer(from pcm: AVAudioPCMBuffer, pts: CMTime) -> CMSampleBuffer? {
        var asbd = pcm.format.streamDescription.pointee

        var formatDescription: CMAudioFormatDescription?
        let formatStatus = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard formatStatus == noErr, let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(asbd.mSampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: CMItemCount(pcm.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }

        let setStatus = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: pcm.audioBufferList
        )
        return setStatus == noErr ? sampleBuffer : nil
    }
}
