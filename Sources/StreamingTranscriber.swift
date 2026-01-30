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

    // Rolling window: text that's been locked in and won't be revised
    private var lockedText = ""
    private var lockedSegmentCount = 0

    // Configuration
    private let silenceThreshold: Float = 0.2  // Lower = more sensitive to voice
    private let requiredSegmentsForConfirmation: Int = 2  // Higher = better word boundaries, more latency
    private let segmentsToKeepRevisable: Int = 3  // Keep last N confirmed segments revisable

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
        lockedText = ""
        lockedSegmentCount = 0

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
        lockedText = ""
        lockedSegmentCount = 0
    }

    /// Filter out WhisperKit special tokens and markers
    private func filterSpecialTokens(_ text: String) -> String {
        var filtered = text
        // Remove common WhisperKit special markers and non-speech sounds
        let specialPatterns = [
            // Blank audio markers (various formats)
            "\\[\\[BLANK_AUDIO\\]\\]",
            "\\[BLANK_AUDIO\\]",
            "\\(blank audio\\)",
            "BLANK_AUDIO",
            "BLANK AUDIO",
            "\\bBLANK\\b",
            // Speech quality markers (various spacing formats)
            "\\[\\s*inaudible\\s*\\]",
            "\\[\\s*silence\\s*\\]",
            "\\[\\s*unintelligible\\s*\\]",
            "\\(\\s*silence\\s*\\)",
            // Non-speech sounds in brackets [clicking], [typing], [music], etc.
            "\\[[^\\]]*(?:click|type|typing|keyboard|music|applause|laughter|cough|sneeze|noise|sound|static|background|breathing)s?[^\\]]*\\]",
            // Non-speech sounds in asterisks *clicking*, *typing*, etc.
            "\\*[^*]*(?:click|type|typing|keyboard|cough|sneeze|sigh|laugh|noise|sound|breathing)s?[^*]*\\*",
            // Non-speech sounds in parentheses (clicking), (typing), etc.
            "\\([^)]*(?:click|type|typing|keyboard|cough|sneeze|sigh|laugh|noise|sound|breathing)s?[^)]*\\)",
            // Whisper hallucinations
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
        // (keyboard clicks often transcribe as ".", "..", "tick", "tock", single letters)
        let stripped = filtered.lowercased().filter { $0.isLetter }

        // Allow common short words, filter everything else under 2 letters
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
        // Only split on words unlikely to be suffixes of real English words
        // e.g., "meanit" -> "mean it", but "exit" stays "exit"
        let safeSplitWords = [
            "seems", "would", "could", "should", "think", "because", "concatenate", "concatenates",
            "actually", "really", "probably", "definitely", "something", "everything", "nothing",
            "always", "never", "maybe", "pretty", "very", "just", "still", "also", "even",
            "only", "well", "much", "more", "most", "some", "many", "such", "like"
        ]
        var result = filtered
        for word in safeSplitWords {
            // Match word concatenated after a letter (e.g., "itseems" -> "it seems")
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
    private func handleStateChange(oldState: AudioStreamTranscriber.State, newState: AudioStreamTranscriber.State) {
        let confirmedCount = newState.confirmedSegments.count

        // Lock in older segments that are beyond our revisable window
        // This prevents revisions to text from long ago
        if confirmedCount > lockedSegmentCount + segmentsToKeepRevisable {
            let segmentsToLock = confirmedCount - segmentsToKeepRevisable
            let newLockedSegments = newState.confirmedSegments[lockedSegmentCount..<segmentsToLock]
            let newLockedText = newLockedSegments
                .map { filterSpecialTokens($0.text.trimmingCharacters(in: .whitespaces)) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            if !newLockedText.isEmpty {
                if !lockedText.isEmpty {
                    lockedText += " "
                }
                lockedText += newLockedText
            }
            lockedSegmentCount = segmentsToLock
            logger.info("Locked \(segmentsToLock) segments, locked text now: '\(self.lockedText.suffix(50))...'")
        }

        // Build revisable text from recent confirmed segments + unconfirmed
        let revisableSegments = Array(newState.confirmedSegments.suffix(from: lockedSegmentCount))
        var revisableText = revisableSegments
            .map { filterSpecialTokens($0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Include unconfirmed segments for realtime output
        for segment in newState.unconfirmedSegments {
            let text = filterSpecialTokens(segment.text.trimmingCharacters(in: .whitespaces))
            if !text.isEmpty {
                if !revisableText.isEmpty {
                    revisableText += " "
                }
                revisableText += text
            }
        }

        // Combine locked + revisable for full text
        var currentText = lockedText
        if !revisableText.isEmpty {
            if !currentText.isEmpty {
                currentText += " "
            }
            currentText += revisableText
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
