import Foundation
import WhisperKit
import CoreAudio
import AVFoundation
import CoreML
import os.log

private let logger = Logger(subsystem: "com.speek.app", category: "audio-device")

// MARK: - Device-Aware Audio Processor Wrapper

/// Wraps WhisperKit's AudioProcessor to inject a preferred input device
/// before recording starts. This prevents Core Audio from reconfiguring the audio
/// system (e.g., switching Bluetooth codecs) when Speek starts recording.
///
/// We use composition instead of subclassing because AudioProcessor's
/// startRecordingLive/resumeRecordingLive are declared in a protocol extension
/// and cannot be overridden.
class DeviceAwareAudioProcessor: AudioProcessing {
    let wrapped: AudioProcessor
    var preferredInputDeviceID: AudioDeviceID?

    init(wrapping processor: AudioProcessor = AudioProcessor()) {
        self.wrapped = processor
    }

    // MARK: - Intercepted methods (inject device ID)

    func startRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let deviceToUse = preferredInputDeviceID ?? inputDeviceID
        logger.info("startRecordingLive with device: \(deviceToUse.map { String($0) } ?? "nil")")
        try wrapped.startRecordingLive(inputDeviceID: deviceToUse, callback: callback)
    }

    func startStreamingRecordingLive(inputDeviceID: DeviceID?) -> (AsyncThrowingStream<[Float], Error>, AsyncThrowingStream<[Float], Error>.Continuation) {
        let deviceToUse = preferredInputDeviceID ?? inputDeviceID
        return wrapped.startStreamingRecordingLive(inputDeviceID: deviceToUse)
    }

    func resumeRecordingLive(inputDeviceID: DeviceID?, callback: (([Float]) -> Void)?) throws {
        let deviceToUse = preferredInputDeviceID ?? inputDeviceID
        logger.info("resumeRecordingLive with device: \(deviceToUse.map { String($0) } ?? "nil")")
        try wrapped.resumeRecordingLive(inputDeviceID: deviceToUse, callback: callback)
    }

    // MARK: - Delegated instance methods/properties

    var audioSamples: ContiguousArray<Float> { wrapped.audioSamples }
    func purgeAudioSamples(keepingLast keep: Int) { wrapped.purgeAudioSamples(keepingLast: keep) }
    var relativeEnergy: [Float] { wrapped.relativeEnergy }
    var relativeEnergyWindow: Int {
        get { wrapped.relativeEnergyWindow }
        set { wrapped.relativeEnergyWindow = newValue }
    }

    func pauseRecording() { wrapped.pauseRecording() }
    func stopRecording() { wrapped.stopRecording() }

    func padOrTrim(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int) -> (any AudioProcessorOutputType)? {
        return wrapped.padOrTrim(fromArray: audioArray, startAt: startIndex, toLength: frameLength)
    }

    // MARK: - Delegated static methods

    static func loadAudio(fromPath audioFilePath: String, channelMode: ChannelMode, startTime: Double?, endTime: Double?, maxReadFrameSize: AVAudioFrameCount?) throws -> AVAudioPCMBuffer {
        try AudioProcessor.loadAudio(fromPath: audioFilePath, channelMode: channelMode, startTime: startTime, endTime: endTime, maxReadFrameSize: maxReadFrameSize)
    }

    static func loadAudio(at audioPaths: [String], channelMode: ChannelMode) async -> [Result<[Float], Swift.Error>] {
        await AudioProcessor.loadAudio(at: audioPaths, channelMode: channelMode)
    }

    static func padOrTrimAudio(fromArray audioArray: [Float], startAt startIndex: Int, toLength frameLength: Int, saveSegment: Bool) -> MLMultiArray? {
        AudioProcessor.padOrTrimAudio(fromArray: audioArray, startAt: startIndex, toLength: frameLength, saveSegment: saveSegment)
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
