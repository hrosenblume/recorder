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
///                                                        [mainMixerNode] ─► [tap]
///                                                                   ▲           │
///     SCK CMSampleBuffer ─► [AVAudioConverter] ─► [systemPlayer]   ─┘           ▼
///                                                                          CMSampleBuffer
///
/// Both player→mixer connections use the same common format
/// (Float32 stereo @ 48 kHz, deinterleaved). Each source has its own
/// AVAudioConverter that lazily configures from the first incoming sample.
///
/// PTS bookkeeping is deterministic: the first emitted CMSampleBuffer's PTS
/// is the first video sample's PTS; subsequent buffers extend the timeline by
/// the number of frames produced. This keeps the audio track tightly aligned
/// with the video track regardless of engine-internal timing.
final class AudioMixer: @unchecked Sendable {
    // MARK: - Public surface

    /// Set this before calling `start(firstVideoPTS:)`.
    var onMixedSample: ((CMSampleBuffer) -> Void)?

    /// Whether system audio playback is wired in. Set via `attach(systemAudio:)`.
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

    // MARK: - Timing

    private var firstVideoPTS: CMTime = .invalid
    private var framesEmitted: Int64 = 0
    private var isStarted = false
    private let stateLock = NSLock()

    // MARK: - Setup

    /// Wires player nodes into the engine. Must be called before `start`.
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

    /// Installs the mixer tap and starts the engine.
    /// `firstVideoPTS` anchors the audio timeline to the video track.
    func start(firstVideoPTS: CMTime) throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        self.firstVideoPTS = firstVideoPTS
        self.framesEmitted = 0

        engine.mainMixerNode.installTap(
            onBus: 0,
            bufferSize: 480, // ~10 ms at 48 kHz
            format: commonFormat
        ) { [weak self] buffer, _ in
            self?.handleMixedTap(buffer)
        }

        try engine.start()
        micPlayer.play()
        if isSystemAudioAttached {
            systemPlayer.play()
        }
        isStarted = true
    }

    /// Tears down. Safe to call multiple times.
    func stop() {
        stateLock.lock()
        let wasStarted = isStarted
        isStarted = false
        stateLock.unlock()

        guard wasStarted else { return }

        micPlayer.stop()
        systemPlayer.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        engine.stop()
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

        // Reuse an existing converter if it matches the source format.
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

    private func handleMixedTap(_ buffer: AVAudioPCMBuffer) {
        stateLock.lock()
        let started = isStarted
        let basePTS = firstVideoPTS
        let framesSoFar = framesEmitted
        stateLock.unlock()

        guard started, basePTS.isValid, buffer.frameLength > 0 else { return }

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
