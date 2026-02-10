import Foundation
import WhisperKit
import CoreAudio
import AVFoundation
import AudioToolbox
import Accelerate
import CoreML
import os.log

private let logger = Logger(subsystem: "com.speek.app", category: "audio-device")

// MARK: - Device-Aware Audio Processor with Persistent Engine

/// Implements the AudioProcessing protocol with a persistent AVAudioEngine.
///
/// WhisperKit's default AudioProcessor creates and destroys a brand-new
/// AVAudioEngine on every recording session. This forces Core Audio to
/// reconfigure hardware routing each time, which briefly interrupts music
/// playback (a ~1s pause).
///
/// By owning a single engine instance that persists across recordings, we
/// avoid repeated hardware reconfiguration. The engine is created and started
/// once on the first recording. On subsequent recordings, we reuse the same
/// engine (reinstalling the tap), so Core Audio has nothing to reconfigure.
class DeviceAwareAudioProcessor: AudioProcessing {
    let wrapped: AudioProcessor
    var preferredInputDeviceID: AudioDeviceID?

    // Persistent engine state
    private var audioEngine: AVAudioEngine?
    private var audioConverter: AVAudioConverter?
    private var lastConfiguredDeviceID: AudioDeviceID?
    private var tapFormat: AVAudioFormat?

    // Audio data (replicate WhisperKit's AudioProcessor behavior)
    private var _audioSamples = ContiguousArray<Float>()
    private var _audioEnergy: [(rel: Float, avg: Float, max: Float, min: Float)] = []
    private var _relativeEnergyWindow: Int = 20
    private var audioBufferCallback: (([Float]) -> Void)?

    init(wrapping processor: AudioProcessor = AudioProcessor()) {
        self.wrapped = processor
    }

    // MARK: - AudioProcessing protocol properties

    var audioSamples: ContiguousArray<Float> { _audioSamples }

    var relativeEnergy: [Float] { _audioEnergy.map { $0.rel } }

    var relativeEnergyWindow: Int {
        get { _relativeEnergyWindow }
        set { _relativeEnergyWindow = newValue }
    }

    func purgeAudioSamples(keepingLast keep: Int) {
        if keep == 0 {
            _audioSamples.removeAll()
        } else if _audioSamples.count > keep {
            _audioSamples.removeFirst(_audioSamples.count - keep)
        }
    }

    // MARK: - Engine lifecycle

    /// Pre-warm the audio engine so the first recording starts without pausing music.
    /// Creates, configures, and briefly starts the engine to force Core Audio to set up
    /// hardware routing, then immediately stops it. The engine instance is kept alive
    /// so subsequent start() calls reuse the cached configuration.
    func warmUp(inputDeviceID: AudioDeviceID?) {
        do {
            try ensureEngine(inputDeviceID: inputDeviceID)
            // Engine is now running — stop it immediately.
            // The instance stays alive with its device configuration cached.
            audioEngine?.stop()
            logger.info("Audio engine pre-warmed and stopped (ready for instant restart)")
        } catch {
            logger.warning("Audio engine warm-up failed: \(error.localizedDescription)")
        }
    }

    /// Create (or reuse) the AVAudioEngine for the given input device.
    /// The engine is prepared and started, but no tap is installed yet.
    private func ensureEngine(inputDeviceID: AudioDeviceID?) throws {
        // Reuse existing engine if it's configured for the same device
        if audioEngine != nil && lastConfiguredDeviceID == inputDeviceID {
            return
        }

        // Tear down old engine if device changed
        if let oldEngine = audioEngine {
            oldEngine.inputNode.removeTap(onBus: 0)
            oldEngine.stop()
            audioEngine = nil
            audioConverter = nil
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Set the input device on macOS
        if let deviceID = inputDeviceID {
            setInputDevice(deviceID, on: inputNode)
        }

        // Get the hardware format from the input node
        let hardwareSampleRate = inputNode.inputFormat(forBus: 0).sampleRate
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard let nodeFormat = AVAudioFormat(
            commonFormat: inputFormat.commonFormat,
            sampleRate: hardwareSampleRate,
            channels: inputFormat.channelCount,
            interleaved: inputFormat.isInterleaved
        ) else {
            throw AudioProcessorError.formatCreationFailed("node format")
        }

        // Target: 16kHz mono Float32 (what WhisperKit expects)
        let whisperSampleRate: Double = 16000.0
        guard let desiredFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: whisperSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioProcessorError.formatCreationFailed("desired format")
        }

        guard let converter = AVAudioConverter(from: nodeFormat, to: desiredFormat) else {
            throw AudioProcessorError.converterCreationFailed
        }

        self.audioEngine = engine
        self.audioConverter = converter
        self.tapFormat = nodeFormat
        self.lastConfiguredDeviceID = inputDeviceID

        // Prepare and start the engine now.
        // This is the one-time cost: Core Audio configures hardware routing here.
        engine.prepare()
        try engine.start()

        logger.info("Audio engine created and started (device: \(inputDeviceID.map { String($0) } ?? "default", privacy: .public), sampleRate: \(hardwareSampleRate, privacy: .public))")
    }

    /// Set the input device on an AVAudioInputNode via its underlying AudioUnit.
    private func setInputDevice(_ deviceID: AudioDeviceID, on inputNode: AVAudioInputNode) {
        guard let audioUnit = inputNode.audioUnit else {
            logger.warning("Could not access audio unit on input node")
            return
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            logger.warning("Failed to set input device \(deviceID): \(status)")
        }
    }

    /// Install a tap on the input node to capture audio buffers.
    private func installTap() {
        guard let engine = audioEngine, let format = tapFormat else { return }

        let bufferSize = AVAudioFrameCount(1600) // ~100ms at 16kHz
        engine.inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: format) { [weak self] buffer, _ in
            self?.processIncomingBuffer(buffer)
        }
    }

    /// Remove the tap from the input node.
    private func removeTap() {
        audioEngine?.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Buffer processing

    private func processIncomingBuffer(_ buffer: AVAudioPCMBuffer) {
        var processedBuffer = buffer

        // Resample to 16kHz if hardware sample rate differs
        if let converter = audioConverter,
           !buffer.format.sampleRate.isEqual(to: 16000.0) {
            do {
                processedBuffer = try Self.resampleBuffer(buffer, with: converter)
            } catch {
                logger.error("Resample failed: \(error.localizedDescription)")
                return
            }
        }

        // Convert PCM buffer to Float array
        let samples = Self.convertBufferToArray(buffer: processedBuffer)
        guard !samples.isEmpty else { return }

        // Append to accumulated samples
        _audioSamples.append(contentsOf: samples)

        // Calculate energy for VAD
        let windowEnergies = _audioEnergy.suffix(_relativeEnergyWindow)
        let minAvgEnergy = windowEnergies.isEmpty
            ? Float.infinity
            : windowEnergies.reduce(Float.infinity) { min($0, $1.avg) }
        let relEnergy = Self.calculateRelativeEnergy(of: samples, relativeTo: minAvgEnergy)
        let signalEnergy = Self.calculateEnergy(of: samples)
        _audioEnergy.append((relEnergy, signalEnergy.avg, signalEnergy.max, signalEnergy.min))

        // Deliver buffer to callback
        audioBufferCallback?(samples)
    }

    // MARK: - AudioProcessing protocol recording methods

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let deviceToUse = preferredInputDeviceID ?? inputDeviceID

        // Clear previous audio data (WhisperKit does this too)
        _audioSamples = []
        _audioEnergy = []
        audioBufferCallback = callback

        // Ensure engine exists and is started (reuses if same device)
        try ensureEngine(inputDeviceID: deviceToUse)

        // If the engine was stopped from a previous stopRecording(), restart it
        if let engine = audioEngine, !engine.isRunning {
            try engine.start()
            logger.info("Restarted existing audio engine")
        }

        // Install tap to begin capturing audio
        installTap()
    }

    func stopRecording() {
        removeTap()
        audioBufferCallback = nil

        // Stop the engine but keep the instance for reuse.
        // This dismisses the mic indicator while preserving the engine's
        // device configuration for fast restart.
        audioEngine?.stop()
    }

    func pauseRecording() {
        audioEngine?.pause()
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let deviceToUse = preferredInputDeviceID ?? inputDeviceID

        if let callback = callback {
            audioBufferCallback = callback
        }

        if deviceToUse == lastConfiguredDeviceID, let engine = audioEngine {
            // Same device — just reinstall tap and restart
            installTap()
            if !engine.isRunning {
                try engine.start()
            }
        } else {
            // Device changed — need fresh engine
            try startRecordingLive(inputDeviceID: deviceToUse, callback: callback)
        }
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        let (stream, continuation) = AsyncThrowingStream<[Float], Error>.makeStream(bufferingPolicy: .unbounded)

        continuation.onTermination = { [weak self] _ in
            guard let self = self else { return }
            self.audioBufferCallback = nil
            self.stopRecording()
        }

        do {
            let deviceToUse = preferredInputDeviceID ?? inputDeviceID
            try self.startRecordingLive(inputDeviceID: deviceToUse) { @Sendable floats in
                continuation.yield(floats)
            }
        } catch {
            continuation.finish(throwing: error)
        }

        return (stream, continuation)
    }

    // MARK: - Audio processing utilities

    private static func resampleBuffer(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter) throws -> AVAudioPCMBuffer {
        let ratio = converter.outputFormat.sampleRate / converter.inputFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * ratio)

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: converter.outputFormat,
            frameCapacity: outputFrameCount
        ) else {
            throw AudioProcessorError.bufferAllocationFailed
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
            throw error
        }

        return outputBuffer
    }

    private static func convertBufferToArray(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    private static func calculateEnergy(of signal: [Float]) -> (avg: Float, max: Float, min: Float) {
        guard !signal.isEmpty else { return (0, 0, 0) }
        var rms: Float = 0
        var maxVal: Float = 0
        var minVal: Float = 0
        vDSP_rmsqv(signal, 1, &rms, vDSP_Length(signal.count))
        vDSP_maxmgv(signal, 1, &maxVal, vDSP_Length(signal.count))
        vDSP_minmgv(signal, 1, &minVal, vDSP_Length(signal.count))
        return (rms, maxVal, minVal)
    }

    private static func calculateRelativeEnergy(of signal: [Float], relativeTo reference: Float?) -> Float {
        guard !signal.isEmpty else { return 0 }
        var rms: Float = 0
        vDSP_rmsqv(signal, 1, &rms, vDSP_Length(signal.count))

        let referenceEnergy = max(1e-8, reference ?? 1e-3)
        let dbEnergy = 20 * log10(max(rms, 1e-10))
        let refEnergy = 20 * log10(referenceEnergy)

        guard refEnergy < 0 else { return 0 }
        let normalized = (dbEnergy - refEnergy) / (0 - refEnergy)
        return max(0, min(normalized, 1))
    }

    // MARK: - Delegated methods (static/non-recording)

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        return wrapped.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
    }

    // MARK: - Error types

    enum AudioProcessorError: Error, LocalizedError {
        case formatCreationFailed(String)
        case converterCreationFailed
        case bufferAllocationFailed

        var errorDescription: String? {
            switch self {
            case .formatCreationFailed(let detail):
                return "Failed to create audio format: \(detail)"
            case .converterCreationFailed:
                return "Failed to create audio converter"
            case .bufferAllocationFailed:
                return "Failed to allocate audio buffer"
            }
        }
    }
}

// MARK: - Device Resolution Utilities

/// Returns the system's default input device ID.
func getSystemDefaultInputDeviceID() -> AudioDeviceID? {
    var deviceID: AudioDeviceID = 0
    var propertySize = UInt32(MemoryLayout<AudioDeviceID>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject),
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &deviceID
    )

    guard status == noErr, deviceID != kAudioObjectUnknown else {
        logger.warning("Failed to get system default input device: \(status)")
        return nil
    }
    return deviceID
}

/// Returns the built-in microphone device ID by checking transport type.
func getBuiltInMicDeviceID() -> AudioDeviceID? {
    let devices = AudioProcessor.getAudioDevices()
    for device in devices {
        var transportType: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            device.id,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &transportType
        )

        if status == noErr && transportType == kAudioDeviceTransportTypeBuiltIn {
            logger.info("Found built-in mic: \(device.name) (ID: \(device.id))")
            return device.id
        }
    }
    logger.warning("No built-in microphone found")
    return nil
}

/// Resolves the input device to use: preferred (if available) > system default > built-in mic.
func resolveInputDevice(preferred: AudioDeviceID?) -> AudioDeviceID? {
    // Check if preferred device is still available
    if let preferred = preferred {
        let available = AudioProcessor.getAudioDevices()
        if available.contains(where: { $0.id == preferred }) {
            logger.info("Using preferred device: \(preferred)")
            return preferred
        }
        logger.warning("Preferred device \(preferred) not available, falling back")
    }

    // Fall back to system default
    if let systemDefault = getSystemDefaultInputDeviceID() {
        logger.info("Using system default device: \(systemDefault)")
        return systemDefault
    }

    // Last resort: built-in mic
    if let builtIn = getBuiltInMicDeviceID() {
        logger.info("Using built-in mic: \(builtIn)")
        return builtIn
    }

    logger.error("No input device available")
    return nil
}

// MARK: - Device UID Persistence

/// Gets the UID string for an AudioDeviceID (stable across reboots, unlike the integer ID).
func getDeviceUID(for deviceID: AudioDeviceID) -> String? {
    var uid: CFString? = nil
    var propertySize = UInt32(MemoryLayout<CFString?>.size)
    var propertyAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceUID,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectGetPropertyData(
        deviceID,
        &propertyAddress,
        0,
        nil,
        &propertySize,
        &uid
    )

    guard status == noErr, let uid = uid else { return nil }
    return uid as String
}

/// Resolves a device UID string back to an AudioDeviceID by searching available devices.
func getDeviceID(forUID uid: String) -> AudioDeviceID? {
    let devices = AudioProcessor.getAudioDevices()
    for device in devices {
        if let deviceUID = getDeviceUID(for: device.id), deviceUID == uid {
            return device.id
        }
    }
    return nil
}
