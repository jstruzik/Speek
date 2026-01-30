import Foundation
import WhisperKit
import os.log

private let logger = Logger(subsystem: "com.speek.app", category: "streaming")

/// Wrapper around WhisperKit's AudioStreamTranscriber for VAD-based streaming transcription.
/// Types text in realtime and uses backspaces to correct when WhisperKit revises.
actor StreamingTranscriber {
    private var whisperKit: WhisperKit?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var isTranscribing = false

    // Callback sends the full current text - SpeekApp handles diff calculation
    // This avoids race conditions between what we think is typed vs what actually is
    private var onFullTextChange: ((String) -> Void)?

    // Track last sent text to avoid duplicate callbacks
    private var lastSentText = ""

    // Configuration
    private let silenceThreshold: Float = 0.2  // Lower = more sensitive to voice
    private let requiredSegmentsForConfirmation: Int = 1

    init() {}

    /// Initialize with a pre-loaded WhisperKit instance
    func initialize(whisperKit: WhisperKit) async {
        self.whisperKit = whisperKit
        logger.info("StreamingTranscriber initialized with WhisperKit")
    }

    /// Start streaming transcription with VAD
    /// - Parameter onFullText: Callback invoked with the full current transcription text
    ///   SpeekApp will handle diffing against what's actually been typed
    func startStreaming(onFullText: @escaping (String) -> Void) async throws {
        guard let whisperKit = whisperKit else {
            throw StreamingError.notInitialized
        }

        guard !isTranscribing else {
            logger.warning("Already transcribing")
            return
        }

        // Store callback
        self.onFullTextChange = onFullText

        // Reset state
        lastSentText = ""

        // Get tokenizer (already loaded by WhisperKit)
        guard let tokenizer = whisperKit.tokenizer else {
            throw StreamingError.tokenizerLoadFailed
        }

        // Configure decoding options for streaming
        let decodingOptions = DecodingOptions(
            task: .transcribe,
            language: "en",
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true
        )

        // Create AudioStreamTranscriber with VAD enabled
        let transcriber = AudioStreamTranscriber(
            audioEncoder: whisperKit.audioEncoder,
            featureExtractor: whisperKit.featureExtractor,
            segmentSeeker: whisperKit.segmentSeeker,
            textDecoder: whisperKit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: whisperKit.audioProcessor,
            decodingOptions: decodingOptions,
            requiredSegmentsForConfirmation: requiredSegmentsForConfirmation,
            silenceThreshold: silenceThreshold,
            compressionCheckWindow: 60,
            useVAD: true,
            stateChangeCallback: { [weak self] oldState, newState in
                Task { [weak self] in
                    await self?.handleStateChange(oldState: oldState, newState: newState)
                }
            }
        )

        self.audioStreamTranscriber = transcriber
        self.isTranscribing = true

        logger.info("Starting stream transcription with VAD (threshold: \(self.silenceThreshold))")

        // Start the streaming transcription (this captures audio from microphone)
        try await transcriber.startStreamTranscription()
    }

    /// Stop streaming transcription
    func stopStreaming() async {
        guard isTranscribing, let transcriber = audioStreamTranscriber else {
            return
        }

        logger.info("Stopping stream transcription")
        await transcriber.stopStreamTranscription()

        isTranscribing = false
        audioStreamTranscriber = nil
        onFullTextChange = nil
        lastSentText = ""
    }

    /// Handle state changes from AudioStreamTranscriber
    private func handleStateChange(oldState: AudioStreamTranscriber.State, newState: AudioStreamTranscriber.State) {
        // Build current full text from confirmed + unconfirmed segments
        var currentText = newState.confirmedSegments
            .map { $0.text.trimmingCharacters(in: .whitespaces) }
            .joined(separator: " ")

        // Include unconfirmed segments for realtime output
        for segment in newState.unconfirmedSegments {
            let text = segment.text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                if !currentText.isEmpty {
                    currentText += " "
                }
                currentText += text
            }
        }

        currentText = currentText.trimmingCharacters(in: .whitespaces)

        // Skip if nothing changed
        guard currentText != lastSentText else {
            return
        }

        lastSentText = currentText
        logger.info("Current text: '\(currentText)'")

        // Send full text to callback - SpeekApp handles diffing
        if let callback = onFullTextChange {
            callback(currentText)
        }
    }

    var transcribing: Bool {
        isTranscribing
    }

    enum StreamingError: Error, LocalizedError {
        case notInitialized
        case tokenizerLoadFailed

        var errorDescription: String? {
            switch self {
            case .notInitialized:
                return "StreamingTranscriber not initialized with WhisperKit"
            case .tokenizerLoadFailed:
                return "Failed to load WhisperKit tokenizer"
            }
        }
    }
}
