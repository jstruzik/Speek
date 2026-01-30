import AVFoundation
import Foundation
import os.log

private let logger = Logger(subsystem: "com.speek.app", category: "audio")

class AudioRecorder {
    private var audioEngine: AVAudioEngine?
    private var isRecording = false

    private let sampleRate: Double = 16000
    private let channelCount: AVAudioChannelCount = 1

    // Store all audio samples in memory for full-context transcription
    private var audioSamples: [Float] = []
    private let samplesLock = NSLock()

    init() {
        setupAudioSession()
    }

    private func setupAudioSession() {
        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                logger.info("Microphone access granted")
            } else {
                logger.error("Microphone access denied")
            }
        }
    }

    func startRecording() {
        guard !isRecording else {
            logger.warning("Already recording, ignoring start request")
            return
        }

        // Clear previous samples
        samplesLock.lock()
        audioSamples.removeAll()
        samplesLock.unlock()

        do {
            audioEngine = AVAudioEngine()
            guard let audioEngine = audioEngine else {
                logger.error("Failed to create audio engine")
                return
            }

            let inputNode = audioEngine.inputNode
            let inputFormat = inputNode.inputFormat(forBus: 0)
            logger.info("Input format: \(inputFormat.sampleRate)Hz, \(inputFormat.channelCount) channels")

            // Create output format (16kHz mono for Whisper)
            guard let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sampleRate,
                channels: channelCount,
                interleaved: false
            ) else {
                logger.error("Failed to create output format")
                return
            }

            // Create converter
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)

            // Install tap on input node - store samples in memory
            inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
                guard let self = self else { return }

                // Convert to 16kHz mono
                if let converter = converter {
                    let ratio = self.sampleRate / inputFormat.sampleRate
                    let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

                    guard let outputBuffer = AVAudioPCMBuffer(
                        pcmFormat: outputFormat,
                        frameCapacity: outputFrameCount
                    ) else { return }

                    var error: NSError?
                    converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
                        outStatus.pointee = .haveData
                        return buffer
                    }

                    // Append converted samples to our array
                    if let channelData = outputBuffer.floatChannelData?[0] {
                        let samples = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
                        self.samplesLock.lock()
                        self.audioSamples.append(contentsOf: samples)
                        self.samplesLock.unlock()
                    }
                }
            }

            audioEngine.prepare()
            try audioEngine.start()
            isRecording = true
            logger.info("Recording started (in-memory)")

        } catch {
            logger.error("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() async throws -> URL {
        guard isRecording, let audioEngine = audioEngine else {
            throw RecorderError.notRecording
        }

        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        self.audioEngine = nil
        isRecording = false

        // Write accumulated samples to file
        let url = try writeSamplesToFile()
        samplesLock.lock()
        let count = audioSamples.count
        samplesLock.unlock()
        logger.info("Recording stopped, wrote \(count) samples")
        return url
    }

    func getIntermediateRecording() async throws -> URL {
        guard isRecording else {
            logger.error("getIntermediateRecording called but not recording")
            throw RecorderError.notRecording
        }

        // Get current sample count
        samplesLock.lock()
        let sampleCount = audioSamples.count
        samplesLock.unlock()

        let duration = Double(sampleCount) / sampleRate
        logger.info("Intermediate recording: \(sampleCount) samples (\(String(format: "%.1f", duration))s)")

        if sampleCount < Int(sampleRate) {  // Less than 1 second
            logger.warning("Audio too short, skipping")
            throw RecorderError.notRecording
        }

        // Write current samples to a temp file (recording continues)
        let url = try writeSamplesToFile()
        return url
    }

    private func writeSamplesToFile() throws -> URL {
        samplesLock.lock()
        let samples = audioSamples
        samplesLock.unlock()

        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("speek_\(UUID().uuidString).wav")

        // Create WAV file
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            throw RecorderError.notRecording
        }

        let audioFile = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
        )

        // Create buffer and write samples
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw RecorderError.notRecording
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for (i, sample) in samples.enumerated() {
                channelData[i] = sample
            }
        }

        try audioFile.write(from: buffer)
        return url
    }

    enum RecorderError: Error, LocalizedError {
        case notRecording
        case noMicrophoneAccess

        var errorDescription: String? {
            switch self {
            case .notRecording:
                return "Not currently recording"
            case .noMicrophoneAccess:
                return "Microphone access not granted"
            }
        }
    }
}
