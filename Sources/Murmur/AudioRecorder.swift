import AVFoundation

class AudioRecorder {
    private var engine = AVAudioEngine()
    private var samples: [Float] = []
    private let targetSampleRate: Double = 16000
    private var isRecording = false
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?

    enum StartError: Error {
        case micPermissionDenied
        case invalidInputFormat
        case converterUnavailable
        case engineFailed(Error)
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
        converter = nil

        // Fresh engine each recording session — avoids stale HAL state that
        // can cause installTap to throw an NSException on subsequent runs.
        engine = AVAudioEngine()
        let inputNode = engine.inputNode

        if let deviceID = AudioDeviceManager.resolveSelectedDeviceID() {
            do {
                try inputNode.auAudioUnit.setDeviceID(deviceID)
            } catch {
                // Fall through to system default if the pinned device can't be applied
                // (e.g. unplugged between menu open and record press).
            }
        }

        guard let target = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return .invalidInputFormat
        }
        self.targetFormat = target

        let targetSR = self.targetSampleRate

        // Pass nil format so AVAudio uses the bus's native format — the most
        // reliable form. Build the converter lazily from the first buffer's
        // actual format.
        let bufferSize: AVAudioFrameCount = 4096
        inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: nil) { [weak self] buffer, _ in
            guard let self = self, let target = self.targetFormat else { return }

            if self.converter == nil {
                self.converter = AVAudioConverter(from: buffer.format, to: target)
            }
            guard let converter = self.converter else { return }

            let ratio = targetSR / buffer.format.sampleRate
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
            guard outputFrameCount > 0,
                  let outputBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: outputFrameCount) else {
                return
            }

            var error: NSError?
            var delivered = false
            converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                if delivered {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                delivered = true
                outStatus.pointee = .haveData
                return buffer
            }

            if error != nil { return }

            if let channelData = outputBuffer.floatChannelData {
                let frameCount = Int(outputBuffer.frameLength)
                let channelSamples = Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
                self.samples.append(contentsOf: channelSamples)
            }
        }

        do {
            engine.prepare()
            try engine.start()
            isRecording = true
            return nil
        } catch {
            inputNode.removeTap(onBus: 0)
            return .engineFailed(error)
        }
    }

    func stopRecording() -> Data? {
        guard isRecording else { return nil }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false

        guard !samples.isEmpty else { return nil }

        return createWAV(from: samples, sampleRate: Int(targetSampleRate))
    }

    private func createWAV(from samples: [Float], sampleRate: Int) -> Data {
        // Convert Float32 samples to Int16 PCM
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

        // RIFF header
        data.append(contentsOf: "RIFF".utf8)
        data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
        data.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        data.append(contentsOf: "fmt ".utf8)
        data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) }) // chunk size
        data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })  // PCM format
        data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
        data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

        // data chunk
        data.append(contentsOf: "data".utf8)
        data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
        for sample in int16Samples {
            data.append(contentsOf: withUnsafeBytes(of: sample.littleEndian) { Array($0) })
        }

        return data
    }
}
