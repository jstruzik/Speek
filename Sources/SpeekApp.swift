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

// MARK: - Global Hotkey Handler (Carbon)
private var globalHotkeyCallback: AppDelegate?

private func carbonHotkeyHandler(nextHandler: EventHandlerCallRef?, event: EventRef?, userData: UnsafeMutableRawPointer?) -> OSStatus {
    globalHotkeyCallback?.toggleStreaming()
    return noErr
}

// MARK: - App Delegate (Menu Bar)
class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    var statusItem: NSStatusItem!
    var speekState = SpeekState()
    var transcriber: Transcriber!
    var streamingTranscriber: StreamingTranscriber!
    var hotkeyRef: EventHotKeyRef?
    var eventHandler: EventHandlerRef?

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

    var settingsWindow: NSWindow?

    func updateMenu() {
        let menu = NSMenu()
        let hotkeyDisplay = HotkeySettings.shared.displayString

        // Streaming status
        if speekState.isStreaming {
            let item = NSMenuItem(title: "⏹ Stop (\(hotkeyDisplay))", action: #selector(toggleStreaming), keyEquivalent: "")
            menu.addItem(item)
        } else if speekState.isDownloading {
            let progress = Int(speekState.downloadProgress * 100)
            menu.addItem(NSMenuItem(title: "Downloading model... \(progress)%", action: nil, keyEquivalent: ""))
        } else {
            let streamItem = NSMenuItem(title: "▶ Start (\(hotkeyDisplay))", action: #selector(toggleStreaming), keyEquivalent: "")
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

        // Settings
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(NSMenuItem.separator())

        // Quit
        menu.addItem(NSMenuItem(title: "Quit Speek", action: #selector(quitApp), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let settingsView = SettingsView()
                .environmentObject(speekState)
            settingsWindow = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 350, height: 300),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            settingsWindow?.title = "Speek Settings"
            settingsWindow?.contentView = NSHostingView(rootView: settingsView)
            settingsWindow?.center()
            settingsWindow?.isReleasedWhenClosed = false
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func setupGlobalHotkeys() {
        globalHotkeyCallback = self
        registerHotkey()

        // Observe hotkey changes to re-register
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: NSNotification.Name("HotkeyDidChange"),
            object: nil
        )
    }

    @objc func hotkeyDidChange() {
        unregisterHotkey()
        registerHotkey()
        updateMenu()
    }

    func registerHotkey() {
        let settings = HotkeySettings.shared

        // Convert NSEvent modifier flags to Carbon modifiers
        var carbonModifiers: UInt32 = 0
        let flags = NSEvent.ModifierFlags(rawValue: settings.modifiers)
        if flags.contains(.command) { carbonModifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { carbonModifiers |= UInt32(optionKey) }
        if flags.contains(.control) { carbonModifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { carbonModifiers |= UInt32(shiftKey) }

        // Register event handler if not already registered
        if eventHandler == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(
                GetApplicationEventTarget(),
                carbonHotkeyHandler,
                1,
                &eventType,
                nil,
                &eventHandler
            )
        }

        // Register the hotkey
        let hotkeyID = EventHotKeyID(signature: OSType(0x5350454B), id: 1) // "SPEK"
        let status = RegisterEventHotKey(
            UInt32(settings.keyCode),
            carbonModifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        if status == noErr {
            logger.info("Global hotkey registered: \(settings.displayString)")
        } else {
            logger.error("Failed to register hotkey: \(status)")
        }
    }

    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
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
        // Cleanup hotkey
        unregisterHotkey()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        globalHotkeyCallback = nil
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Hotkey Settings
class HotkeySettings: ObservableObject {
    static let shared = HotkeySettings()

    // Default: Cmd+Shift+A (keyCode 0 = A)
    static let defaultKeyCode: UInt16 = 0
    static let defaultModifiers: UInt = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue

    @Published var keyCode: UInt16 {
        didSet {
            UserDefaults.standard.set(Int(keyCode), forKey: "hotkeyKeyCode")
            NotificationCenter.default.post(name: NSNotification.Name("HotkeyDidChange"), object: nil)
        }
    }
    @Published var modifiers: UInt {
        didSet {
            UserDefaults.standard.set(Int(modifiers), forKey: "hotkeyModifiers")
            NotificationCenter.default.post(name: NSNotification.Name("HotkeyDidChange"), object: nil)
        }
    }

    init() {
        if UserDefaults.standard.object(forKey: "hotkeyKeyCode") != nil {
            self.keyCode = UInt16(UserDefaults.standard.integer(forKey: "hotkeyKeyCode"))
            self.modifiers = UInt(UserDefaults.standard.integer(forKey: "hotkeyModifiers"))
        } else {
            self.keyCode = HotkeySettings.defaultKeyCode
            self.modifiers = HotkeySettings.defaultModifiers
        }
    }

    func reset() {
        keyCode = HotkeySettings.defaultKeyCode
        modifiers = HotkeySettings.defaultModifiers
    }

    var displayString: String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("⌃") }
        if flags.contains(.option) { parts.append("⌥") }
        if flags.contains(.shift) { parts.append("⇧") }
        if flags.contains(.command) { parts.append("⌘") }
        parts.append(keyCodeToString(keyCode))
        return parts.joined()
    }

    private func keyCodeToString(_ keyCode: UInt16) -> String {
        let keyMap: [UInt16: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 50: "`",
            36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
            98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
            123: "←", 124: "→", 125: "↓", 126: "↑"
        ]
        return keyMap[keyCode] ?? "?"
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

// MARK: - Hotkey Recorder View
struct HotkeyRecorderView: View {
    @ObservedObject var hotkeySettings: HotkeySettings
    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        HStack {
            Text("Toggle streaming:")
            Spacer()
            Button(action: { startRecording() }) {
                Text(isRecording ? "Press keys..." : hotkeySettings.displayString)
                    .frame(minWidth: 80)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.bordered)
            .foregroundColor(isRecording ? .orange : .primary)
        }
    }

    private func startRecording() {
        isRecording = true
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordedKey(event)
            return nil  // Consume the event
        }
    }

    private func handleRecordedKey(_ event: NSEvent) {
        // Require at least one modifier (Cmd, Option, Control, or Shift)
        let requiredModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        let hasModifier = !event.modifierFlags.intersection(requiredModifiers).isEmpty

        // Escape cancels recording
        if event.keyCode == 53 {
            stopRecording()
            return
        }

        if hasModifier {
            // Save the new hotkey
            let modifierMask: UInt = event.modifierFlags.intersection([.command, .option, .control, .shift]).rawValue
            hotkeySettings.keyCode = event.keyCode
            hotkeySettings.modifiers = modifierMask
        }

        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        if let monitor = localMonitor {
            NSEvent.removeMonitor(monitor)
            localMonitor = nil
        }
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @EnvironmentObject var state: SpeekState
    @ObservedObject var hotkeySettings = HotkeySettings.shared

    var body: some View {
        Form {
            Section("Keyboard Shortcut") {
                HotkeyRecorderView(hotkeySettings: hotkeySettings)

                Text("Click the button and press your desired key combination")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Button("Reset to Default (⌘⇧A)") {
                    hotkeySettings.reset()
                }
                .buttonStyle(.borderless)
                .foregroundColor(.accentColor)
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
        .frame(width: 350, height: 300)
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
