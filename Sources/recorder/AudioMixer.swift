import AVFoundation
import CoreMedia
import Foundation

/// Mixes microphone + system audio into a single stereo PCM stream and emits
/// `CMSampleBuffer`s ready to feed an `AVAssetWriterInput`.
///
/// Pipeline (no AVAudioEngine — manual mix for predictability):
///
///     mic CMSampleBuffer ──► [AVAudioConverter] ──► micQueue (Float32 interleaved)
///                                                          │
///                                       ┌──────────────────┼─── render timer (10ms tick)
///                                       │                  │
///     SCK CMSampleBuffer ─► [AVAudioConverter] ─► systemQueue
///                                       │                  │
///                                       └──► sum + soft-clip ──► CMSampleBuffer ──► writer
///
/// Earlier attempts via AVAudioEngine had hidden issues (auto-connection to
/// outputNode → speaker playback → AirPods feedback → mic AGC reduction; manual
/// rendering mode → empty audio track). This version uses AVAudioConverter for
/// per-source format conversion (handles AirPods 16k mono → 48k stereo etc.)
/// and does the mix arithmetic ourselves.
final class AudioMixer: @unchecked Sendable {
    // MARK: - Public

    var onMixedSample: ((CMSampleBuffer) -> Void)?
    private(set) var isSystemAudioAttached: Bool = false

    // MARK: - Format

    private let commonFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 2,
        interleaved: true
    )!
    private let renderFrames: Int = 480 // ~10 ms @ 48 kHz

    // MARK: - Per-source state

    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?

    private var micQueue: [Float] = [] // interleaved L,R,L,R,...
    private var systemQueue: [Float] = []
    private let micLock = NSLock()
    private let systemLock = NSLock()

    /// Cap each per-source queue to ~1 second (96000 stereo samples). If we
    /// somehow get behind, drop oldest data rather than leak memory.
    private let maxQueueSamples: Int = 96000

    // MARK: - Render loop

    private var renderTimer: DispatchSourceTimer?
    private let renderQueue = DispatchQueue(
        label: "com.hunter.recorder.audio.render",
        qos: .userInteractive
    )

    // MARK: - Timing

    private var firstVideoPTS: CMTime = .invalid
    private var framesEmitted: Int64 = 0
    private var isStarted = false
    private let stateLock = NSLock()

    // MARK: - API

    func attach(systemAudio: Bool) {
        isSystemAudioAttached = systemAudio
    }

    func start(firstVideoPTS: CMTime) throws {
        stateLock.lock()
        self.firstVideoPTS = firstVideoPTS
        self.framesEmitted = 0
        isStarted = true
        stateLock.unlock()

        let timer = DispatchSource.makeTimerSource(queue: renderQueue)
        timer.schedule(
            deadline: .now() + .milliseconds(10),
            repeating: .milliseconds(10),
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in self?.tick() }
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

        if wasStarted {
            micLock.lock(); micQueue.removeAll(); micLock.unlock()
            systemLock.lock(); systemQueue.removeAll(); systemLock.unlock()
            micConverter = nil
            systemConverter = nil
        }
    }

    func pushMic(_ sampleBuffer: CMSampleBuffer) {
        push(sampleBuffer, lock: micLock, queueRef: \.micQueue, converterRef: \.micConverter)
    }

    func pushSystem(_ sampleBuffer: CMSampleBuffer) {
        guard isSystemAudioAttached else { return }
        push(sampleBuffer, lock: systemLock, queueRef: \.systemQueue, converterRef: \.systemConverter)
    }

    // MARK: - Push (CMSampleBuffer → converted Float32 interleaved → queue)

    private func push(
        _ sampleBuffer: CMSampleBuffer,
        lock: NSLock,
        queueRef: ReferenceWritableKeyPath<AudioMixer, [Float]>,
        converterRef: ReferenceWritableKeyPath<AudioMixer, AVAudioConverter?>
    ) {
        stateLock.lock()
        let started = isStarted
        stateLock.unlock()
        guard started else { return }

        guard let inputPCM = pcmBuffer(from: sampleBuffer) else { return }
        let inputFormat = inputPCM.format

        var converter = self[keyPath: converterRef]
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: commonFormat)
            self[keyPath: converterRef] = converter
        }
        guard let converter else { return }

        let ratio = commonFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputPCM.frameLength) * ratio + 1024)
        guard let outputPCM = AVAudioPCMBuffer(pcmFormat: commonFormat, frameCapacity: outputCapacity) else {
            return
        }

        var consumed = false
        var error: NSError?
        let status = converter.convert(to: outputPCM, error: &error) { _, statusOut in
            if consumed {
                statusOut.pointee = .endOfStream
                return nil
            }
            consumed = true
            statusOut.pointee = .haveData
            return inputPCM
        }
        if status == .error {
            if let error { NSLog("Recorder: converter error - \(error)") }
            return
        }
        guard outputPCM.frameLength > 0,
              let channelData = outputPCM.floatChannelData
        else { return }

        let sampleCount = Int(outputPCM.frameLength) * Int(commonFormat.channelCount)
        let buffer = UnsafeBufferPointer(start: channelData[0], count: sampleCount)

        lock.lock()
        self[keyPath: queueRef].append(contentsOf: buffer)
        let queueSize = self[keyPath: queueRef].count
        if queueSize > maxQueueSamples {
            self[keyPath: queueRef].removeFirst(queueSize - maxQueueSamples)
        }
        lock.unlock()
    }

    // MARK: - Render tick (pull from queues, mix, emit)

    private func tick() {
        stateLock.lock()
        let started = isStarted
        let basePTS = firstVideoPTS
        let framesSoFar = framesEmitted
        stateLock.unlock()

        guard started, basePTS.isValid else { return }

        let stereoSamples = renderFrames * 2

        // Pull from each queue (zero-pad if not enough samples available yet)
        let micFrames = drainSamples(lock: micLock, queueRef: \.micQueue, count: stereoSamples)
        let sysFrames = drainSamples(lock: systemLock, queueRef: \.systemQueue, count: stereoSamples)

        // Mix into the output buffer
        guard let mixedPCM = AVAudioPCMBuffer(
            pcmFormat: commonFormat,
            frameCapacity: AVAudioFrameCount(renderFrames)
        ) else { return }
        mixedPCM.frameLength = AVAudioFrameCount(renderFrames)
        guard let dst = mixedPCM.floatChannelData else { return }
        let dstPtr = dst[0]

        let micVol = Config.micVolume
        let sysVol = Config.systemAudioVolume
        for i in 0..<stereoSamples {
            let mic = i < micFrames.count ? micFrames[i] : 0
            let sys = i < sysFrames.count ? sysFrames[i] : 0
            var sum = mic * micVol + sys * sysVol
            if sum > 1.0 { sum = 1.0 } else if sum < -1.0 { sum = -1.0 }
            dstPtr[i] = sum
        }

        // PTS = video start + frames emitted so far / sample rate
        let pts = CMTimeAdd(
            basePTS,
            CMTime(value: framesSoFar, timescale: CMTimeScale(commonFormat.sampleRate))
        )

        guard let sample = sampleBuffer(from: mixedPCM, pts: pts) else { return }

        stateLock.lock()
        framesEmitted += Int64(renderFrames)
        stateLock.unlock()

        onMixedSample?(sample)
    }

    private func drainSamples(
        lock: NSLock,
        queueRef: ReferenceWritableKeyPath<AudioMixer, [Float]>,
        count: Int
    ) -> [Float] {
        lock.lock()
        var queue = self[keyPath: queueRef]
        let take = min(queue.count, count)
        let result = Array(queue.prefix(take))
        if take > 0 {
            queue.removeFirst(take)
            self[keyPath: queueRef] = queue
        }
        lock.unlock()
        return result
    }

    // MARK: - CMSampleBuffer ⇄ AVAudioPCMBuffer

    private func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer) else { return nil }
        guard let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return nil }
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
