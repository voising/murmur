import AVFoundation
import AudioToolbox
import CoreAudio
import os
import os.lock

private let audioLog = Logger(subsystem: "com.railssquad.murmur", category: "audio")

/// Records mic audio via a private AUHAL bound directly to the chosen
/// device. We never touch the system default input — other apps recording
/// at the same time (Zoom, FaceTime, etc.) see no change in their input
/// routing. AVAudioEngine isn't used because its inputNode is married to
/// whatever the system default was when first accessed, and a post-hoc
/// setDeviceID doesn't always re-propagate the format down the graph
/// (especially after Bluetooth HFP), leading to silent zero-buffer
/// recordings.
final class AudioRecorder {
    private var unit: AudioUnit?
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16000
    private var isRecording = false

    private var converter: AVAudioConverter?
    private var clientFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    // Manually-allocated ABL + backing storage owned by this recorder. Passing
    // AVAudioPCMBuffer.mutableAudioBufferList directly to AudioUnitRender from
    // a real-time callback yielded -10863 (CannotDoInCurrentContext) every
    // call; allocating the ABL ourselves and pointing the AVAudioPCMBuffer
    // wrapper at the same memory via bufferListNoCopy resolves it.
    private var renderABL: UnsafeMutablePointer<AudioBufferList>?
    private var renderABLBuffers: [UnsafeMutableRawPointer] = []
    private var renderBuffer: AVAudioPCMBuffer?
    private var outputBuffer: AVAudioPCMBuffer?
    private var renderBufferCapacity: AVAudioFrameCount = 0
    private var renderBytesPerFrame: UInt32 = 0

    private var bufferCount: Int = 0
    private var converterErrorCount: Int = 0
    private var renderErrorStatus: OSStatus = noErr

    // Render callback runs on a real-time thread; samples array is read on
    // the main thread in stopRecording.
    private var samplesLock = os_unfair_lock_s()

    enum StartError: Error {
        case micPermissionDenied
        case invalidInputFormat
        case noInputDevice
        case audioUnitFailed(OSStatus)
    }

    func requestMicPermission(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    @discardableResult
    func startRecording() -> StartError? {
        guard !isRecording else { return nil }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            return .micPermissionDenied
        }

        samples.removeAll()
        bufferCount = 0
        converterErrorCount = 0
        renderErrorStatus = noErr

        let pinnedID = AudioDeviceManager.resolveSelectedDeviceID()
        let deviceID = pinnedID ?? AudioDeviceManager.defaultInputDeviceID() ?? 0
        guard deviceID != 0 else {
            audioLog.error("startRecording: no input device available")
            return .noInputDevice
        }
        audioLog.notice("startRecording: device=\(AudioDeviceManager.describe(deviceID), privacy: .public) pinned=\(pinnedID != nil, privacy: .public)")

        // 1. Instantiate an AUHAL output unit.
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &desc) else {
            audioLog.error("startRecording: AudioComponentFindNext returned nil")
            return .audioUnitFailed(-1)
        }
        var newUnit: AudioUnit?
        var status = AudioComponentInstanceNew(component, &newUnit)
        guard status == noErr, let unit = newUnit else {
            audioLog.error("AudioComponentInstanceNew failed status=\(status, privacy: .public)")
            return .audioUnitFailed(status)
        }
        self.unit = unit

        // 2. Enable input bus (1), disable output bus (0).
        var one: UInt32 = 1
        var zero: UInt32 = 0
        let u32 = UInt32(MemoryLayout<UInt32>.size)
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, u32)
        guard status == noErr else { return failConfig("EnableIO input", status) }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &zero, u32)
        guard status == noErr else { return failConfig("EnableIO output", status) }

        // 3. Bind unit to chosen device BEFORE format negotiation. This is
        //    the key step — by setting the device here, the unit's format
        //    properties reflect the device we actually want.
        var dID = deviceID
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global,
            0, &dID, UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { return failConfig("CurrentDevice", status) }

        // 4. Read the device's hardware format (scope=Input bus=1) and
        //    reflect it back as the client format (scope=Output bus=1).
        //    Even though AUHAL will infer a default client format during
        //    Initialize, explicitly declaring it ensures the internal
        //    render context is fully wired — without this step,
        //    AudioUnitRender returns -10863 even when Start succeeds.
        var asbdSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var hwAsbd = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hwAsbd, &asbdSize)
        guard status == noErr else { return failConfig("Get hw StreamFormat", status) }
        audioLog.notice("hw asbd: sr=\(hwAsbd.mSampleRate, privacy: .public) ch=\(hwAsbd.mChannelsPerFrame, privacy: .public) bits=\(hwAsbd.mBitsPerChannel, privacy: .public) flags=0x\(String(hwAsbd.mFormatFlags, radix: 16), privacy: .public)")
        guard hwAsbd.mSampleRate > 0, hwAsbd.mChannelsPerFrame > 0 else {
            audioLog.error("hw asbd has zero sample rate or channels")
            return .invalidInputFormat
        }

        // Canonical Float32 non-interleaved at the device's sample rate and
        // channel count. This is what we want delivered to the callback;
        // AUHAL converts internally from the hardware format if needed.
        var clientAsbd = AudioStreamBasicDescription(
            mSampleRate: hwAsbd.mSampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: hwAsbd.mChannelsPerFrame,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &clientAsbd, UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        guard status == noErr else { return failConfig("Set client StreamFormat", status) }

        // 5. Install the input callback BEFORE Initialize. AUHAL wires its
        //    input render context during Initialize; registering the
        //    callback afterward leaves the context half-built.
        var cb = AURenderCallbackStruct(
            inputProc: AudioRecorder.inputCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        status = AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global,
            0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size)
        )
        guard status == noErr else { return failConfig("SetInputCallback", status) }

        // 6. Initialize. For Bluetooth devices (AirPods), this is what
        //    triggers macOS to switch from A2DP to HFP.
        status = AudioUnitInitialize(unit)
        guard status == noErr else { return failConfig("AudioUnitInitialize", status) }

        // Re-read client format after Initialize in case AUHAL re-negotiated
        // (e.g. sample rate forced by the device).
        var postAsbd = AudioStreamBasicDescription()
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &postAsbd, &asbdSize)
        guard status == noErr else { return failConfig("Get post-init StreamFormat", status) }
        audioLog.notice("post-init client asbd: sr=\(postAsbd.mSampleRate, privacy: .public) ch=\(postAsbd.mChannelsPerFrame, privacy: .public) bytesPerFrame=\(postAsbd.mBytesPerFrame, privacy: .public)")

        guard let avClient = AVAudioFormat(streamDescription: &postAsbd) else {
            audioLog.error("AVAudioFormat(streamDescription:) returned nil")
            return .invalidInputFormat
        }
        self.clientFormat = avClient

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate,
            channels: 1, interleaved: false
        ) else {
            return .invalidInputFormat
        }
        self.targetFormat = target
        self.converter = AVAudioConverter(from: avClient, to: target)
        guard converter != nil else {
            audioLog.error("AVAudioConverter init failed (from \(avClient, privacy: .public) to \(target, privacy: .public))")
            return .invalidInputFormat
        }

        // 7. Allocate the ABL we hand to AudioUnitRender. 16384 frames is well
        //    above any real-world per-slice size; AUHAL chunks are usually
        //    256–2048 frames.
        let cap: AVAudioFrameCount = 16384
        let channelCount = Int(postAsbd.mChannelsPerFrame)
        let nonInterleaved = (postAsbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let ablBufferCount = nonInterleaved ? channelCount : 1
        let channelsPerBuffer = UInt32(nonInterleaved ? 1 : channelCount)
        let bytesPerFrame = postAsbd.mBytesPerFrame
        let perBufferBytes = Int(cap) * Int(bytesPerFrame)

        let ablSize = MemoryLayout<AudioBufferList>.size + max(0, ablBufferCount - 1) * MemoryLayout<AudioBuffer>.size
        let ablRaw = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: MemoryLayout<AudioBufferList>.alignment)
        let abl = ablRaw.assumingMemoryBound(to: AudioBufferList.self)
        abl.pointee.mNumberBuffers = UInt32(ablBufferCount)
        let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
        var bufferStorage: [UnsafeMutableRawPointer] = []
        for i in 0..<ablBufferCount {
            let data = UnsafeMutableRawPointer.allocate(byteCount: perBufferBytes, alignment: 16)
            ablPtr[i] = AudioBuffer(mNumberChannels: channelsPerBuffer, mDataByteSize: UInt32(perBufferBytes), mData: data)
            bufferStorage.append(data)
        }
        self.renderABL = abl
        self.renderABLBuffers = bufferStorage
        self.renderBufferCapacity = cap
        self.renderBytesPerFrame = bytesPerFrame

        // AVAudioPCMBuffer that wraps the same memory (no copy) so we can
        // feed AVAudioConverter without rebuilding a buffer per callback.
        self.renderBuffer = AVAudioPCMBuffer(pcmFormat: avClient, bufferListNoCopy: abl, deallocator: nil)
        guard renderBuffer != nil else {
            audioLog.error("AVAudioPCMBuffer(bufferListNoCopy:) returned nil")
            return .invalidInputFormat
        }

        // Pre-allocated output buffer for the converter (mono 16 kHz). A
        // single 16384-frame input at 48 kHz produces ≤5461 frames at 16 kHz;
        // matching capacity is safe.
        self.outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)
        guard outputBuffer != nil else { return .invalidInputFormat }

        // 8. Start. The callback fires only after this point.
        status = AudioOutputUnitStart(unit)
        guard status == noErr else { return failConfig("AudioOutputUnitStart", status) }

        isRecording = true
        audioLog.notice("AUHAL running: capturing sr=\(postAsbd.mSampleRate, privacy: .public) ch=\(postAsbd.mChannelsPerFrame, privacy: .public) ablBuffers=\(ablBufferCount, privacy: .public)")
        return nil
    }

    func stopRecording() -> Data? {
        guard isRecording, let unit = unit else { return nil }
        isRecording = false

        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        self.unit = nil

        let collected: [Float] = {
            os_unfair_lock_lock(&samplesLock)
            defer { os_unfair_lock_unlock(&samplesLock) }
            let s = samples
            samples = []
            return s
        }()

        audioLog.notice("stopRecording: buffers=\(self.bufferCount, privacy: .public) samples=\(collected.count, privacy: .public) converterErrors=\(self.converterErrorCount, privacy: .public) lastRenderStatus=\(self.renderErrorStatus, privacy: .public)")

        self.converter = nil
        self.renderBuffer = nil
        self.outputBuffer = nil
        self.clientFormat = nil
        self.targetFormat = nil
        for ptr in renderABLBuffers { ptr.deallocate() }
        renderABLBuffers = []
        if let abl = renderABL {
            UnsafeMutableRawPointer(abl).deallocate()
            renderABL = nil
        }

        guard !collected.isEmpty else {
            if bufferCount == 0 {
                audioLog.error("zero buffers arrived — device produced no audio (Bluetooth HFP not ready, or device muted)")
            } else {
                audioLog.error("\(self.bufferCount, privacy: .public) buffers arrived but produced 0 samples (converter dropped everything)")
            }
            return nil
        }
        return createWAV(from: collected, sampleRate: Int(targetSampleRate))
    }

    // MARK: - Render callback

    private static let inputCallback: AURenderCallback = { (
        inRefCon, ioActionFlags, inTimeStamp, inBusNumber, inNumberFrames, _
    ) -> OSStatus in
        let me = Unmanaged<AudioRecorder>.fromOpaque(inRefCon).takeUnretainedValue()
        return me.renderInput(flags: ioActionFlags, ts: inTimeStamp, bus: inBusNumber, frames: inNumberFrames)
    }

    private func renderInput(
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        ts: UnsafePointer<AudioTimeStamp>,
        bus: UInt32,
        frames: UInt32
    ) -> OSStatus {
        guard let unit = unit,
              let abl = renderABL,
              let buf = renderBuffer,
              let outBuf = outputBuffer,
              let converter = converter else {
            return noErr
        }

        if frames > renderBufferCapacity {
            audioLog.error("render frames=\(frames, privacy: .public) > capacity=\(self.renderBufferCapacity, privacy: .public); dropping")
            renderErrorStatus = -50
            return noErr
        }

        // AudioUnitRender modifies mDataByteSize, so we reset to the expected
        // request size before each pull. The mData pointers stay the same
        // (they point at our own storage).
        let ablPtr = UnsafeMutableAudioBufferListPointer(abl)
        let perBufferBytes = frames * renderBytesPerFrame
        for i in 0..<ablPtr.count {
            ablPtr[i].mDataByteSize = perBufferBytes
        }

        let status = AudioUnitRender(unit, flags, ts, bus, frames, abl)
        if status != noErr {
            renderErrorStatus = status
            if bufferCount == 0 {
                audioLog.error("first AudioUnitRender failed: status=\(status, privacy: .public) frames=\(frames, privacy: .public) bus=\(bus, privacy: .public) ablBuffers=\(ablPtr.count, privacy: .public) bytesPerFrame=\(self.renderBytesPerFrame, privacy: .public)")
            }
            return status
        }
        buf.frameLength = frames

        if bufferCount == 0 {
            audioLog.notice("first buffer: frames=\(frames, privacy: .public) bus=\(bus, privacy: .public) ch=\(buf.format.channelCount, privacy: .public) sr=\(buf.format.sampleRate, privacy: .public) ablBuffers=\(ablPtr.count, privacy: .public)")
        }
        bufferCount += 1

        outBuf.frameLength = 0
        var error: NSError?
        var delivered = false
        converter.convert(to: outBuf, error: &error) { _, outStatus in
            if delivered {
                outStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            outStatus.pointee = .haveData
            return buf
        }
        if error != nil {
            converterErrorCount += 1
            return noErr
        }
        if let ch = outBuf.floatChannelData {
            let n = Int(outBuf.frameLength)
            if n > 0 {
                let slice = Array(UnsafeBufferPointer(start: ch[0], count: n))
                os_unfair_lock_lock(&samplesLock)
                samples.append(contentsOf: slice)
                os_unfair_lock_unlock(&samplesLock)
            }
        }
        return noErr
    }

    private func failConfig(_ label: String, _ status: OSStatus) -> StartError {
        audioLog.error("startRecording: \(label, privacy: .public) failed status=\(status, privacy: .public)")
        if let unit = unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            self.unit = nil
        }
        return .audioUnitFailed(status)
    }

    // MARK: - WAV encoding

    private func createWAV(from samples: [Float], sampleRate: Int) -> Data {
        let int16Samples = samples.map { sample -> Int16 in
            let clamped = max(-1.0, min(1.0, sample))
            return Int16(clamped * Float(Int16.max))
        }

        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = numChannels * (bitsPerSample / 8)
        let dataSize = UInt32(int16Samples.count * 2)
        let fileSize = 36 + dataSize

        var data = Data()
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in int16Samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }
        return data
    }
}
