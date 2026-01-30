import Foundation
import WhisperKit
import os.log

private let logger = Logger(subsystem: "com.speek.app", category: "transcriber")

class Transcriber {
    private var whisperKit: WhisperKit?
    private var state: SpeekState

    init(state: SpeekState) {
        self.state = state
    }

    /// Get the WhisperKit instance (for use with StreamingTranscriber)
    func getWhisperKit() -> WhisperKit? {
        return whisperKit
    }

    /// Get persistent model storage path in Application Support
    private func getModelStoragePath() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let speekDir = appSupport.appendingPathComponent("Speek/Models")
        try? FileManager.default.createDirectory(at: speekDir, withIntermediateDirectories: true)
        return speekDir
    }

    /// Check if the model is already downloaded (public for UI decisions)
    func isModelDownloaded() -> Bool {
        let modelPath = getModelStoragePath()
        // WhisperKit stores models in: downloadBase/models/argmaxinc/whisperkit-coreml/openai_whisper-{model}/
        let expectedPath = modelPath
            .appendingPathComponent("models")
            .appendingPathComponent("argmaxinc")
            .appendingPathComponent("whisperkit-coreml")
            .appendingPathComponent("openai_whisper-\(state.modelName)")

        // Check if the model directory exists and contains files
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expectedPath.path, isDirectory: &isDirectory)

        if exists && isDirectory.boolValue {
            // Check if it has the model files (e.g., MelSpectrogram.mlmodelc)
            if let contents = try? FileManager.default.contentsOfDirectory(atPath: expectedPath.path) {
                return contents.contains { $0.hasSuffix(".mlmodelc") }
            }
        }
        return false
    }

    func loadModel() async {
        let needsDownload = !isModelDownloaded()

        await MainActor.run {
            state.isDownloading = needsDownload
            state.downloadProgress = needsDownload ? 0 : 0.5
        }

        do {
            let modelPath = getModelStoragePath()
            print("[Transcriber] Loading WhisperKit model: \(state.modelName) from \(modelPath.path) (needsDownload: \(needsDownload))")

            // Initialize WhisperKit with persistent storage
            let config = WhisperKitConfig(
                model: state.modelName,
                downloadBase: modelPath,
                verbose: true,
                logLevel: .debug,
                prewarm: true,
                load: true,
                download: true
            )

            whisperKit = try await WhisperKit(config)

            await MainActor.run {
                state.isDownloading = false
                state.isModelLoaded = true
                state.downloadProgress = 1.0
            }

            print("[Transcriber] Model loaded successfully")

        } catch {
            print("[Transcriber] Failed to load model: \(error)")
            await MainActor.run {
                state.isDownloading = false
                state.statusMessage = "Failed to load model: \(error.localizedDescription)"
            }
        }
    }

    func transcribe(audioURL: URL) async throws -> String {
        guard let whisperKit = whisperKit else {
            logger.error("Model not loaded")
            throw TranscriberError.modelNotLoaded
        }

        logger.info("Transcribing: \(audioURL.path)")

        // Enable word-level timestamps to know when words are finalized
        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,  // Enable timestamps
            wordTimestamps: true       // Enable word-level timestamps
        )

        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        logger.info("Transcription result: \(text)")
        return text
    }

    // New method: transcribe and return word timings for smarter incremental typing
    func transcribeWithTimings(audioURL: URL) async throws -> (text: String, words: [WordInfo]) {
        guard let whisperKit = whisperKit else {
            throw TranscriberError.modelNotLoaded
        }

        let options = DecodingOptions(
            task: .transcribe,
            language: "en",
            usePrefillPrompt: true,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true
        )

        let results = try await whisperKit.transcribe(
            audioPath: audioURL.path,
            decodeOptions: options
        )

        var allWords: [WordInfo] = []
        for result in results {
            // Use the allWords extension to get flattened word timings
            for timing in result.allWords {
                allWords.append(WordInfo(
                    word: timing.word,
                    start: timing.start,
                    end: timing.end,
                    probability: timing.probability
                ))
            }
        }

        let text = results.map { $0.text }.joined(separator: " ").trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        return (text, allWords)
    }

    struct WordInfo {
        let word: String
        let start: Float
        let end: Float
        let probability: Float
    }

    enum TranscriberError: Error, LocalizedError {
        case modelNotLoaded

        var errorDescription: String? {
            switch self {
            case .modelNotLoaded:
                return "Whisper model not loaded"
            }
        }
    }
}
