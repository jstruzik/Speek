import SwiftUI
import Carbon.HIToolbox
import os.log
import AVFoundation

private let logger = Logger(subsystem: "com.speek.app", category: "main")

@main
struct SpeekApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Window for download progress
        Window("Speek Setup", id: "progress") {
            ProgressWindowView()
                .environmentObject(appDelegate.speekState)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

// MARK: - App Delegate (Menu Bar)
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var speekState = SpeekState()
    var transcriber: Transcriber!
    var streamingTranscriber: StreamingTranscriber!
    var globalMonitor: Any?
    var localMonitor: Any?

    // Text-based deduplication for typing
    var totalTypedText = ""

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false  // Keep running as menu bar app
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if trusted {
            logger.info("Accessibility permission granted")
        } else {
            logger.warning("Accessibility permission not yet granted - user needs to enable in System Settings")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (menu bar app)
        NSApp.setActivationPolicy(.accessory)

        // Request accessibility permission (shows system prompt if not granted)
        requestAccessibilityPermission()

        // Request microphone permission
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            if granted {
                logger.info("Microphone access granted")
            } else {
                logger.error("Microphone access denied")
            }
        }

        // Setup menu bar
        setupMenuBar()

        // Setup keyboard shortcuts
        setupGlobalHotkeys()

        // Initialize components
        transcriber = Transcriber(state: speekState)
        streamingTranscriber = StreamingTranscriber()

        // Load model (only show progress window if download is needed)
        Task {
            let needsDownload = !transcriber.isModelDownloaded()

            // Only show progress window if we need to download
            if needsDownload {
                await MainActor.run {
                    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "progress" }) {
                        window.makeKeyAndOrderFront(nil)
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }

            await transcriber.loadModel()

            // Initialize streaming transcriber with the loaded WhisperKit instance
            if let whisperKit = transcriber.getWhisperKit() {
                await streamingTranscriber.initialize(whisperKit: whisperKit)
            }

            // Close progress window after loading (whether download was needed or not)
            await MainActor.run {
                // Close any windows with "Speek" in the title (the setup window)
                for window in NSApp.windows {
                    if window.title.contains("Speek") || window.identifier?.rawValue == "progress" {
                        window.close()
                    }
                }
            }
        }
    }

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Speek")
            button.image?.isTemplate = true
        }

        updateMenu()
    }

    func updateMenu() {
        let menu = NSMenu()

        // Streaming status
        if speekState.isStreaming {
            let item = NSMenuItem(title: "⏹ Stop (⌘⇧S)", action: #selector(toggleStreaming), keyEquivalent: "")
            menu.addItem(item)
        } else if speekState.isDownloading {
            let progress = Int(speekState.downloadProgress * 100)
            menu.addItem(NSMenuItem(title: "Downloading model... \(progress)%", action: nil, keyEquivalent: ""))
        } else {
            let streamItem = NSMenuItem(title: "▶ Start (⌘⇧S)", action: #selector(toggleStreaming), keyEquivalent: "")
            menu.addItem(streamItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Model info
        let modelItem = NSMenuItem(title: "Model: \(speekState.modelName)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        if speekState.isModelLoaded {
            let readyItem = NSMenuItem(title: "✓ Model ready", action: nil, keyEquivalent: "")
            readyItem.isEnabled = false
            menu.addItem(readyItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit Speek", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    func setupGlobalHotkeys() {
        // Monitor for global key events (Cmd+Shift+S)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
        }

        // Also monitor local events when app is focused
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyEvent(event)
            return event
        }

        logger.info("Global hotkey registered: ⌘⇧S (stream)")
    }

    func handleKeyEvent(_ event: NSEvent) {
        // Check for Cmd+Shift modifier
        guard event.modifierFlags.contains([.command, .shift]) else { return }

        switch event.keyCode {
        case 1: // S key
            DispatchQueue.main.async { [weak self] in
                self?.toggleStreaming()
            }
        default:
            break
        }
    }

    @objc func toggleStreaming() {
        guard speekState.isModelLoaded else {
            showNotification(title: "Speek", body: "Model is still loading...")
            return
        }

        if speekState.isStreaming {
            stopStreaming()
        } else {
            startStreaming()
        }
    }

    func startStreaming() {
        logger.info("Starting streaming mode")
        speekState.isStreaming = true
        speekState.streamedText = ""
        totalTypedText = ""
        updateMenuBarIcon(streaming: true)
        updateMenu()

        Task {
            do {
                try await streamingTranscriber.startStreaming { [weak self] fullText in
                    // This callback is invoked with the full current transcription
                    // We handle diffing here to avoid race conditions
                    DispatchQueue.main.async {
                        self?.onFullTextUpdate(fullText)
                    }
                }
                logger.info("Streaming started - speak now!")
            } catch {
                logger.error("Failed to start streaming: \(error.localizedDescription)")
                await MainActor.run {
                    self.speekState.isStreaming = false
                    self.updateMenuBarIcon(streaming: false)
                    self.updateMenu()
                    self.showNotification(title: "Speek", body: "Failed to start: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Handle full text update from StreamingTranscriber - calculate diff and apply
    func onFullTextUpdate(_ targetText: String) {
        // Calculate diff between what we've typed and what we should have
        let (backspaceCount, newText) = calculateDiff(from: totalTypedText, to: targetText)

        // Apply the diff
        if backspaceCount > 0 {
            typeBackspaces(count: backspaceCount)
            let keepCount = max(0, totalTypedText.count - backspaceCount)
            totalTypedText = String(totalTypedText.prefix(keepCount))
        }

        if !newText.isEmpty {
            typeText(newText)
            totalTypedText += newText
        }

        speekState.streamedText = totalTypedText
    }

    /// Calculate diff between current typed text and target text
    /// Returns (backspaceCount, textToType)
    func calculateDiff(from oldText: String, to newText: String) -> (Int, String) {
        let oldChars = Array(oldText)
        let newChars = Array(newText)

        // Find common prefix length
        var commonPrefixLength = 0
        for i in 0..<min(oldChars.count, newChars.count) {
            if oldChars[i] == newChars[i] {
                commonPrefixLength = i + 1
            } else {
                break
            }
        }

        // Backspaces needed = old chars after common prefix
        let backspaceCount = oldChars.count - commonPrefixLength

        // New text = new chars after common prefix
        let textToType = String(newChars[commonPrefixLength...])

        return (backspaceCount, textToType)
    }

    /// Send backspace key presses to delete characters
    func typeBackspaces(count: Int) {
        guard count > 0 else { return }

        let source = CGEventSource(stateID: .hidSystemState)
        let backspaceKeyCode: CGKeyCode = 51  // macOS backspace key code

        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            usleep(3000)  // Small delay for reliability
        }
    }

    func stopStreaming() {
        speekState.isStreaming = false
        updateMenuBarIcon(streaming: false)

        Task {
            await streamingTranscriber.stopStreaming()

            await MainActor.run {
                showNotification(title: "Speek", body: "Streaming stopped")
                updateMenu()
            }
        }
    }

    func typeText(_ text: String) {
        // Check if we have accessibility permission
        let trusted = AXIsProcessTrusted()
        if !trusted {
            logger.error("Accessibility permission not granted! Please enable in System Settings → Privacy & Security → Accessibility")
            showNotification(title: "Speek", body: "Please grant Accessibility permission in System Settings")
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)

        for char in text {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)

            var chars = [UniChar](String(char).utf16)
            keyDown?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)
            keyUp?.keyboardSetUnicodeString(stringLength: chars.count, unicodeString: &chars)

            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)

            // Small delay between characters for reliability
            usleep(5000)
        }
    }

    func updateMenuBarIcon(streaming: Bool) {
        if let button = statusItem.button {
            if streaming {
                button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Streaming")
                button.contentTintColor = .systemRed
            } else {
                button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Speek")
                button.contentTintColor = nil
            }
            button.image?.isTemplate = !streaming
        }
    }

    func showNotification(title: String, body: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    @objc func quitApp() {
        // Cleanup monitors
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
        }
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - App State
class SpeekState: ObservableObject {
    @Published var isStreaming = false
    @Published var isDownloading = false
    @Published var downloadProgress: Double = 0
    @Published var isModelLoaded = false
    @Published var modelName = "base.en"
    @Published var streamedText = ""
    @Published var statusMessage = ""
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var state: SpeekState

    var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                HStack {
                    Text("Toggle streaming:")
                    Spacer()
                    Text("⌘⇧S")
                        .foregroundColor(.secondary)
                }
            }

            Section("Model") {
                HStack {
                    Text("Current model:")
                    Spacer()
                    Text(state.modelName)
                        .foregroundColor(.secondary)
                }
                if state.isModelLoaded {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Label("Ready", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                }
            }

            Section("About") {
                Text("Speek - Speech to Text")
                Text("Uses WhisperKit for local transcription")
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 350, height: 250)
    }
}

// MARK: - Progress Window View
struct ProgressWindowView: View {
    @EnvironmentObject var state: SpeekState

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "mic.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Speek")
                .font(.title)
                .fontWeight(.semibold)

            if state.isDownloading {
                VStack(spacing: 12) {
                    Text("Downloading \(state.modelName) model...")
                        .foregroundColor(.secondary)

                    ProgressView(value: state.downloadProgress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)

                    Text("\(Int(state.downloadProgress * 100))%")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("This only happens once")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if state.isModelLoaded {
                VStack(spacing: 8) {
                    Label("Ready!", systemImage: "checkmark.circle.fill")
                        .font(.headline)
                        .foregroundColor(.green)

                    Text("You can close this window")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Initializing...")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(40)
        .frame(width: 320, height: 280)
    }
}
