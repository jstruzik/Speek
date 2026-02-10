import Foundation
import WhisperKit
import CoreAudio
import os.log

private let logger = Logger(subsystem: "com.speek.app", category: "streaming")

/// Wrapper around WhisperKit's AudioStreamTranscriber for VAD-based streaming transcription.
/// Sends full transcription text to a callback on each update; SpeekApp displays it in an overlay
/// and pastes the final result when recording stops.
actor StreamingTranscriber {
    private var whisperKit: WhisperKit?
    private var audioStreamTranscriber: AudioStreamTranscriber?
    private var audioProcessor: DeviceAwareAudioProcessor?
    private var isTranscribing = false

    // Callback sends the full current text
    private var onFullTextChange: ((String) -> Void)?

    // Track last sent text to avoid duplicate callbacks
    private var lastSentText = ""

    // Configuration
    private let silenceThreshold: Float = 0.2
    private let requiredSegmentsForConfirmation: Int = 2

    init() {}

    /// Initialize with a pre-loaded WhisperKit instance
    func initialize(whisperKit: WhisperKit, audioProcessor: DeviceAwareAudioProcessor) async {
        self.whisperKit = whisperKit
        self.audioProcessor = audioProcessor
        logger.info("StreamingTranscriber initialized with WhisperKit")
    }

    /// Start streaming transcription with VAD
    /// - Parameters:
    ///   - inputDeviceID: The audio input device to use, or nil for default
    ///   - onFullText: Callback invoked with the full current transcription text
    func startStreaming(inputDeviceID: AudioDeviceID? = nil, onFullText: @escaping (String) -> Void) async throws {
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

        // Set preferred input device before creating the stream transcriber
        audioProcessor?.preferredInputDeviceID = inputDeviceID

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

        logger.info("Starting stream transcription with VAD")

        // Start the streaming transcription (this captures audio from microphone)
        try await transcriber.startStreamTranscription()
    }

    /// Stop streaming transcription
    func stopStreaming() async {
        guard isTranscribing, let transcriber = audioStreamTranscriber else {
            return
        }

        await transcriber.stopStreamTranscription()

        isTranscribing = false
        audioStreamTranscriber = nil
        onFullTextChange = nil
        lastSentText = ""
    }

    /// Get the last transcription text (for pasting on stop)
    func getLastText() -> String {
        return lastSentText
    }

    /// Filter out WhisperKit special tokens and markers
    private func filterSpecialTokens(_ text: String) -> String {
        var filtered = text
        // Remove common WhisperKit special markers and non-speech sounds
        let specialPatterns = [
            "\\[\\[BLANK_AUDIO\\]\\]",
            "\\[BLANK_AUDIO\\]",
            "\\(blank audio\\)",
            "BLANK_AUDIO",
            "BLANK AUDIO",
            "\\bBLANK\\b",
            "\\[\\s*inaudible\\s*\\]",
            "\\[\\s*silence\\s*\\]",
            "\\[\\s*unintelligible\\s*\\]",
            "\\(\\s*silence\\s*\\)",
            "\\[[^\\]]*(?:click|type|typing|keyboard|music|applause|laughter|cough|sneeze|noise|sound|static|background|breathing)s?[^\\]]*\\]",
            "\\*[^*]*(?:click|type|typing|keyboard|cough|sneeze|sigh|laugh|noise|sound|breathing)s?[^*]*\\*",
            "\\([^)]*(?:click|type|typing|keyboard|cough|sneeze|sigh|laugh|noise|sound|breathing)s?[^)]*\\)",
            "thank(?:s| you) for (?:watching|listening)",
            "(?:please )?(?:like and )?subscribe",
            "see you (?:next time|in the next)"
        ]
        for pattern in specialPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                filtered = regex.stringByReplacingMatches(
                    in: filtered,
                    range: NSRange(filtered.startIndex..., in: filtered),
                    withTemplate: ""
                )
            }
        }
        // Clean up extra whitespace
        filtered = filtered.replacingOccurrences(of: "  ", with: " ")
        filtered = filtered.trimmingCharacters(in: .whitespaces)

        // Filter out text that's just punctuation or non-word sounds
        let stripped = filtered.lowercased().filter { $0.isLetter }

        let validShortWords = Set(["i", "a", "o", "oh", "ah", "ok", "no", "so", "go", "do", "to", "be", "he", "we", "me", "my", "by", "up", "or", "on", "in", "an", "at", "as", "is", "it", "if"])
        if stripped.count < 2 && !validShortWords.contains(stripped) {
            return ""
        }

        // Filter common click/noise transcriptions
        let noiseWords = Set(["tick", "tock", "click", "clack", "tap", "tic", "tik", "tak", "pop", "beep", "ding", "thud", "thump", "bang", "blank"])
        if noiseWords.contains(stripped) {
            return ""
        }

        // Fix common word concatenation issues from Whisper
        let safeSplitWords = [
            "seems", "would", "could", "should", "think", "because", "concatenate", "concatenates",
            "actually", "really", "probably", "definitely", "something", "everything", "nothing",
            "always", "never", "maybe", "pretty", "very", "just", "still", "also", "even",
            "only", "well", "much", "more", "most", "some", "many", "such", "like"
        ]
        var result = filtered
        for word in safeSplitWords {
            let pattern = "([a-zA-Z])(\(word))\\b"
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1 $2"
                )
            }
        }

        return result
    }

    /// Handle state changes from AudioStreamTranscriber
    /// Simply builds full text from all confirmed + unconfirmed segments.
    private func handleStateChange(oldState: AudioStreamTranscriber.State, newState: AudioStreamTranscriber.State) {
        // Build text from all confirmed segments
        var parts: [String] = []
        for segment in newState.confirmedSegments {
            let text = filterSpecialTokens(segment.text.trimmingCharacters(in: .whitespaces))
            if !text.isEmpty {
                parts.append(text)
            }
        }

        // Include unconfirmed segments for real-time output
        for segment in newState.unconfirmedSegments {
            let text = filterSpecialTokens(segment.text.trimmingCharacters(in: .whitespaces))
            if !text.isEmpty {
                parts.append(text)
            }
        }

        let currentText = parts.joined(separator: " ").trimmingCharacters(in: .whitespaces)

        // Skip if nothing changed
        guard currentText != lastSentText else {
            return
        }

        lastSentText = currentText

        // Send full text to callback
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
