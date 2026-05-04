import AVFoundation
import CoreMedia
import Foundation
import os.log

/// Mixes microphone + system audio into a single stereo PCM stream and emits
/// `CMSampleBuffer`s ready to feed an `AVAssetWriterInput`.
///
/// Pipeline (no AVAudioEngine):
///
///     mic CMSampleBuffer ──► [AVAudioConverter] ──► micLeftQueue + micRightQueue
///                                                          │
///                                       ┌──────────────────┼─── render timer (10ms tick)
///                                       │                  │
///     SCK CMSampleBuffer ─► [AVAudioConverter] ─► systemLeft + systemRight
///                                       │                  │
///                                       └──► sum L,R + soft-clip ──► CMSampleBuffer ──► writer
///
/// Uses non-interleaved Float32 buffers so `floatChannelData` is valid (docs
/// state it returns nil for interleaved). Per-channel queues avoid a flat
/// interleaved Float array.
final class AudioMixer: @unchecked Sendable {
    // MARK: - Public

    var onMixedSample: ((CMSampleBuffer) -> Void)?
    private(set) var isSystemAudioAttached: Bool = false

    // MARK: - Format (non-interleaved so floatChannelData[0/1] are valid)

    let commonFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48000,
        channels: 2,
        interleaved: false
    )!
    private let renderFrames: Int = 480 // ~10 ms @ 48 kHz

    // MARK: - Per-source state

    private var micConverter: AVAudioConverter?
    private var systemConverter: AVAudioConverter?

    private var micLeft: [Float] = []
    private var micRight: [Float] = []
    private var systemLeft: [Float] = []
    private var systemRight: [Float] = []
    private let micLock = NSLock()
    private let systemLock = NSLock()
    private let maxQueueFrames: Int = 48000 // ~1 second per channel

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

    // MARK: - Diagnostics

    private let log = OSLog(subsystem: "com.hunter.recorder", category: "AudioMixer")
    private var pushMicCount: Int = 0
    private var pushSystemCount: Int = 0
    private var tickCount: Int = 0
    private var emitCount: Int = 0

    // MARK: - API

    func attach(systemAudio: Bool) {
        isSystemAudioAttached = systemAudio
        os_log(.default, log: log, "attach systemAudio=%{public}@", String(describing: systemAudio))
    }

    func start(firstVideoPTS: CMTime) throws {
        stateLock.lock()
        self.firstVideoPTS = firstVideoPTS
        self.framesEmitted = 0
        isStarted = true
        stateLock.unlock()

        os_log(.default, log: log, "start basePTS=%{public}@", String(describing: firstVideoPTS))

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
            os_log(
                .default, log: log,
                "stop counts mic=%{public}d sys=%{public}d ticks=%{public}d emits=%{public}d",
                pushMicCount, pushSystemCount, tickCount, emitCount
            )
            micLock.lock(); micLeft.removeAll(); micRight.removeAll(); micLock.unlock()
            systemLock.lock(); systemLeft.removeAll(); systemRight.removeAll(); systemLock.unlock()
            micConverter = nil
            systemConverter = nil
        }
    }

    func pushMic(_ sampleBuffer: CMSampleBuffer) {
        push(
            sampleBuffer,
            lock: micLock,
            leftRef: \.micLeft,
            rightRef: \.micRight,
            converterRef: \.micConverter,
            isMic: true
        )
    }

    func pushSystem(_ sampleBuffer: CMSampleBuffer) {
        guard isSystemAudioAttached else { return }
        push(
            sampleBuffer,
            lock: systemLock,
            leftRef: \.systemLeft,
            rightRef: \.systemRight,
            converterRef: \.systemConverter,
            isMic: false
        )
    }

    // MARK: - Push

    private func push(
        _ sampleBuffer: CMSampleBuffer,
        lock: NSLock,
        leftRef: ReferenceWritableKeyPath<AudioMixer, [Float]>,
        rightRef: ReferenceWritableKeyPath<AudioMixer, [Float]>,
        converterRef: ReferenceWritableKeyPath<AudioMixer, AVAudioConverter?>,
        isMic: Bool
    ) {
        stateLock.lock()
        let started = isStarted
        stateLock.unlock()
        guard started else { return }

        if isMic {
            pushMicCount += 1
        } else {
            pushSystemCount += 1
        }

        guard let inputPCM = pcmBuffer(from: sampleBuffer) else {
            os_log(.error, log: log, "pcmBuffer(from:) returned nil isMic=%{public}@", String(describing: isMic))
            return
        }
        let inputFormat = inputPCM.format

        var converter = self[keyPath: converterRef]
        if converter?.inputFormat != inputFormat {
            converter = AVAudioConverter(from: inputFormat, to: commonFormat)
            self[keyPath: converterRef] = converter
            os_log(.default, log: log, "new converter isMic=%{public}@ in=%{public}@", String(describing: isMic), String(describing: inputFormat))
        }
        guard let converter else {
            os_log(.error, log: log, "no converter")
            return
        }

        let ratio = commonFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputPCM.frameLength) * ratio + 1024)
        guard let outputPCM = AVAudioPCMBuffer(pcmFormat: commonFormat, frameCapacity: outputCapacity) else {
            os_log(.error, log: log, "outputPCM alloc failed")
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
            os_log(.error, log: log, "converter error %{public}@", String(describing: error))
            return
        }
        guard outputPCM.frameLength > 0,
              let channelData = outputPCM.floatChannelData
        else {
            os_log(.error, log: log, "outputPCM has no data frameLength=%{public}d", Int(outputPCM.frameLength))
            return
        }

        let frameCount = Int(outputPCM.frameLength)
        let leftPtr = channelData[0]
        let rightPtr = channelData[1]
        let leftSamples = Array(UnsafeBufferPointer(start: leftPtr, count: frameCount))
        let rightSamples = Array(UnsafeBufferPointer(start: rightPtr, count: frameCount))

        lock.lock()
        self[keyPath: leftRef].append(contentsOf: leftSamples)
        self[keyPath: rightRef].append(contentsOf: rightSamples)
        if self[keyPath: leftRef].count > maxQueueFrames {
            let drop = self[keyPath: leftRef].count - maxQueueFrames
            self[keyPath: leftRef].removeFirst(drop)
            self[keyPath: rightRef].removeFirst(drop)
        }
        lock.unlock()
    }

    // MARK: - Render tick

    private func tick() {
        stateLock.lock()
        let started = isStarted
        let basePTS = firstVideoPTS
        let framesSoFar = framesEmitted
        stateLock.unlock()

        guard started, basePTS.isValid else { return }

        tickCount += 1

        let (micLA, micRA) = drainBoth(lock: micLock, leftRef: \.micLeft, rightRef: \.micRight, count: renderFrames)
        let (sysLA, sysRA) = drainBoth(lock: systemLock, leftRef: \.systemLeft, rightRef: \.systemRight, count: renderFrames)

        guard let mixedPCM = AVAudioPCMBuffer(
            pcmFormat: commonFormat,
            frameCapacity: AVAudioFrameCount(renderFrames)
        ) else { return }
        mixedPCM.frameLength = AVAudioFrameCount(renderFrames)

        guard let dst = mixedPCM.floatChannelData else { return }
        let dstL = dst[0]
        let dstR = dst[1]

        let micVol = Config.micVolume
        let sysVol = Config.systemAudioVolume

        for i in 0..<renderFrames {
            let mL = i < micLA.count ? micLA[i] : 0
            let mR = i < micRA.count ? micRA[i] : 0
            let sL = i < sysLA.count ? sysLA[i] : 0
            let sR = i < sysRA.count ? sysRA[i] : 0
            var lSum = mL * micVol + sL * sysVol
            var rSum = mR * micVol + sR * sysVol
            if lSum > 1.0 { lSum = 1.0 } else if lSum < -1.0 { lSum = -1.0 }
            if rSum > 1.0 { rSum = 1.0 } else if rSum < -1.0 { rSum = -1.0 }
            dstL[i] = lSum
            dstR[i] = rSum
        }

        let pts = CMTimeAdd(
            basePTS,
            CMTime(value: framesSoFar, timescale: CMTimeScale(commonFormat.sampleRate))
        )

        guard let sample = sampleBuffer(from: mixedPCM, pts: pts) else {
            os_log(.error, log: log, "sampleBuffer(from:) returned nil")
            return
        }

        stateLock.lock()
        framesEmitted += Int64(renderFrames)
        stateLock.unlock()

        emitCount += 1
        if emitCount % 100 == 0 {
            os_log(
                .default, log: log,
                "tick %{public}d mic=%{public}d sys=%{public}d emit=%{public}d",
                tickCount, pushMicCount, pushSystemCount, emitCount
            )
        }

        onMixedSample?(sample)
    }

    private func drainBoth(
        lock: NSLock,
        leftRef: ReferenceWritableKeyPath<AudioMixer, [Float]>,
        rightRef: ReferenceWritableKeyPath<AudioMixer, [Float]>,
        count: Int
    ) -> ([Float], [Float]) {
        lock.lock()
        var left = self[keyPath: leftRef]
        var right = self[keyPath: rightRef]
        let take = min(left.count, count)
        let lOut = Array(left.prefix(take))
        let rOut = Array(right.prefix(take))
        if take > 0 {
            left.removeFirst(take)
            right.removeFirst(take)
            self[keyPath: leftRef] = left
            self[keyPath: rightRef] = right
        }
        lock.unlock()
        return (lOut, rOut)
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
