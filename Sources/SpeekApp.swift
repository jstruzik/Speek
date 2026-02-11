import SwiftUI
import Carbon.HIToolbox
import CoreAudio
import os.log
import AVFoundation
import WhisperKit
import ApplicationServices

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
    var fnGlobalMonitor: Any?
    var fnLocalMonitor: Any?

    // Overlay window for real-time transcription display
    var overlayWindow: NSPanel?
    var overlayTextView: NSTextView?

    // Streaming mode state
    var streamingAXElement: AXUIElement?
    var streamingInsertionPoint: Int = 0
    var streamingPastedLength: Int = 0
    var streamingUseAX: Bool = true
    var totalPastedText: String = ""
    var savedClipboard: String?
    var lastStreamingUpdateTime: CFAbsoluteTime = 0

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

        // Observe system sleep/wake to avoid audio engine crashes
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(self, selector: #selector(systemWillSleep), name: NSWorkspace.willSleepNotification, object: nil)
        workspace.addObserver(self, selector: #selector(systemDidWake), name: NSWorkspace.didWakeNotification, object: nil)

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
                await streamingTranscriber.initialize(whisperKit: whisperKit, audioProcessor: transcriber.getAudioProcessor())
            }

            // Pre-warm the audio engine so the first recording doesn't pause music.
            // This creates and briefly starts the engine to force Core Audio to set up
            // hardware routing, then stops it. The engine stays cached for instant restart.
            let warmUpDeviceID = InputDeviceSettings.shared.resolvedDeviceID()
            transcriber.getAudioProcessor().warmUp(inputDeviceID: warmUpDeviceID)

            // Close progress window after loading
            await MainActor.run {
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
        let settings = HotkeySettings.shared
        let hotkeyDisplay = settings.activationMode == .pressAndHold ? "Hold Fn" : settings.displayString

        // Streaming status
        if speekState.isStreaming {
            let item = NSMenuItem(title: "Stop (\(hotkeyDisplay))", action: #selector(toggleStreaming), keyEquivalent: "")
            menu.addItem(item)
        } else if speekState.isDownloading {
            let progress = Int(speekState.downloadProgress * 100)
            menu.addItem(NSMenuItem(title: "Downloading model... \(progress)%", action: nil, keyEquivalent: ""))
        } else {
            let streamItem = NSMenuItem(title: "Start (\(hotkeyDisplay))", action: #selector(toggleStreaming), keyEquivalent: "")
            menu.addItem(streamItem)
        }

        menu.addItem(NSMenuItem.separator())

        // Model info
        let modelItem = NSMenuItem(title: "Model: \(speekState.modelName)", action: nil, keyEquivalent: "")
        modelItem.isEnabled = false
        menu.addItem(modelItem)

        if speekState.isModelLoaded {
            let readyItem = NSMenuItem(title: "Model ready", action: nil, keyEquivalent: "")
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
                contentRect: NSRect(x: 0, y: 0, width: 350, height: 500),
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

        // Set up based on current activation mode
        if HotkeySettings.shared.activationMode == .toggle {
            registerHotkey()
        } else {
            setupFnKeyMonitor()
        }

        // Observe hotkey changes to re-register
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(hotkeyDidChange),
            name: NSNotification.Name("HotkeyDidChange"),
            object: nil
        )
    }

    @objc func hotkeyDidChange() {
        let mode = HotkeySettings.shared.activationMode
        if mode == .toggle {
            teardownFnKeyMonitor()
            unregisterHotkey()
            registerHotkey()
        } else {
            unregisterHotkey()
            setupFnKeyMonitor()
        }
        updateMenu()
    }

    func setupFnKeyMonitor() {
        // Tear down any existing monitors first
        teardownFnKeyMonitor()

        let handler: (NSEvent) -> Void = { [weak self] event in
            let fnPressed = event.modifierFlags.contains(.function)
            guard let self = self else { return }
            if fnPressed && !self.speekState.isStreaming {
                guard self.speekState.isModelLoaded else {
                    self.showNotification(title: "Speek", body: "Model is still loading...")
                    return
                }
                self.startStreaming()
            } else if !fnPressed && self.speekState.isStreaming {
                self.stopStreaming()
            }
        }

        fnGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
        }
        fnLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            handler(event)
            return event
        }
    }

    func teardownFnKeyMonitor() {
        if let monitor = fnGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            fnGlobalMonitor = nil
        }
        if let monitor = fnLocalMonitor {
            NSEvent.removeMonitor(monitor)
            fnLocalMonitor = nil
        }
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

    // MARK: - Overlay Window

    /// Try to get the screen-space position of the text cursor (caret) in the focused element.
    /// Uses the AX parameterized attribute kAXBoundsForRangeParameterizedAttribute which returns
    /// the bounding rect for a given text range — we pass the zero-length selection (insertion point).
    /// Returns a rect in AppKit coordinates (bottom-left origin), or nil if not available.
    func getCaretPosition() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        let element = focusedElement as! AXUIElement

        // Get the selected text range (the insertion point is a zero-length range)
        var selectedRange: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange) == .success else {
            return nil
        }

        // Ask for the bounds of that range — this gives us the caret's screen position
        var boundsValue: AnyObject?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXBoundsForRangeParameterizedAttribute as CFString, selectedRange!, &boundsValue) == .success else {
            return nil
        }

        var bounds = CGRect.zero
        guard AXValueGetValue(boundsValue as! AXValue, .cgRect, &bounds) else {
            return nil
        }

        // AX uses top-left origin; convert to AppKit's bottom-left origin
        guard let screen = NSScreen.screens.first else { return nil }
        let screenHeight = screen.frame.height
        let flippedY = screenHeight - bounds.origin.y - bounds.size.height
        return NSRect(x: bounds.origin.x, y: flippedY, width: bounds.size.width, height: bounds.size.height)
    }

    /// Get the frame of the frontmost window from the focused application via AX API.
    func getActiveWindowFrame() -> NSRect? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedWindow: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else {
            return nil
        }

        let windowElement = focusedWindow as! AXUIElement

        // Get position
        var positionValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement, kAXPositionAttribute as CFString, &positionValue) == .success else {
            return nil
        }
        var position = CGPoint.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position) else {
            return nil
        }

        // Get size
        var sizeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(windowElement, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }
        var size = CGSize.zero
        guard AXValueGetValue(sizeValue as! AXValue, .cgSize, &size) else {
            return nil
        }

        // AX uses top-left origin; convert to AppKit's bottom-left origin
        if let screen = NSScreen.screens.first {
            let screenHeight = screen.frame.height
            let flippedY = screenHeight - position.y - size.height
            return NSRect(x: position.x, y: flippedY, width: size.width, height: size.height)
        }

        return nil
    }

    func showOverlay() {
        let overlayWidth: CGFloat = 420
        let overlayHeight: CGFloat = 56

        if overlayWindow == nil {
            // Borderless, non-activating floating panel
            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = .floating
            panel.isFloatingPanel = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = true
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            // Semi-transparent background you can see through
            let backgroundView = NSView(frame: NSRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight))
            backgroundView.wantsLayer = true
            backgroundView.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.35).cgColor
            backgroundView.layer?.cornerRadius = 14
            backgroundView.layer?.masksToBounds = true
            backgroundView.autoresizingMask = [.width, .height]

            // Recording indicator (red dot)
            let dotSize: CGFloat = 10
            let dotView = NSView(frame: NSRect(x: 14, y: (overlayHeight - dotSize) / 2, width: dotSize, height: dotSize))
            dotView.wantsLayer = true
            dotView.layer?.backgroundColor = NSColor.systemRed.cgColor
            dotView.layer?.cornerRadius = dotSize / 2

            // Text view for the transcription
            let textView = NSTextView(frame: NSRect(x: 32, y: 4, width: overlayWidth - 44, height: overlayHeight - 8))
            textView.isEditable = false
            textView.isSelectable = false
            textView.drawsBackground = false
            textView.font = NSFont.systemFont(ofSize: 14, weight: .medium)
            textView.textColor = .white.withAlphaComponent(0.95)
            textView.textContainerInset = NSSize(width: 4, height: 8)
            textView.string = "Listening..."

            backgroundView.addSubview(dotView)
            backgroundView.addSubview(textView)
            panel.contentView = backgroundView

            self.overlayWindow = panel
            self.overlayTextView = textView
        }

        // Position priority:
        // 1. Just above the text cursor (caret) if detectable
        // 2. Centered in the active window
        // 3. Centered on screen
        var overlayX: CGFloat
        var overlayY: CGFloat
        let gap: CGFloat = 36  // space between overlay and cursor

        if let caretRect = getCaretPosition() {
            // Place centered horizontally on the caret, above it.
            // caretRect.maxY is the top of the caret in AppKit coords (bottom-left origin),
            // so placing at maxY + gap puts the overlay above the caret line.
            overlayX = caretRect.midX - overlayWidth / 2
            overlayY = caretRect.maxY + gap

            // Clamp to screen bounds
            if let screen = NSScreen.main {
                let screenFrame = screen.visibleFrame
                overlayX = max(screenFrame.minX, min(overlayX, screenFrame.maxX - overlayWidth))
                // If overlay would go above the screen top, put it below the caret instead
                if overlayY + overlayHeight > screenFrame.maxY {
                    overlayY = caretRect.minY - overlayHeight - gap
                }
            }

            logger.debug("Overlay positioned near caret at (\(caretRect.origin.x), \(caretRect.origin.y))")
        } else if let windowFrame = getActiveWindowFrame() {
            overlayX = windowFrame.midX - overlayWidth / 2
            overlayY = windowFrame.origin.y + windowFrame.height * 0.25 - overlayHeight / 2
        } else if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            overlayX = screenFrame.midX - overlayWidth / 2
            overlayY = screenFrame.midY - overlayHeight / 2
        } else {
            overlayX = 400
            overlayY = 400
        }

        overlayWindow?.setFrame(NSRect(x: overlayX, y: overlayY, width: overlayWidth, height: overlayHeight), display: true)

        overlayTextView?.string = "Listening..."
        overlayWindow?.orderFront(nil)
    }

    func updateOverlayText(_ text: String) {
        overlayTextView?.string = text.isEmpty ? "Listening..." : text

        // Auto-scroll to bottom
        if let textView = overlayTextView {
            textView.scrollRangeToVisible(NSRange(location: textView.string.count, length: 0))
        }
    }

    func hideOverlay() {
        overlayWindow?.orderOut(nil)
    }

    // MARK: - System Sleep/Wake

    @objc func systemWillSleep(_ notification: Notification) {
        logger.info("System going to sleep — stopping audio")
        // Stop any active streaming before the audio hardware goes away
        if speekState.isStreaming {
            stopStreaming()
        }
        // Invalidate the cached audio engine — it won't survive sleep
        transcriber?.getAudioProcessor().invalidateEngine()
    }

    @objc func systemDidWake(_ notification: Notification) {
        logger.info("System woke up — audio engine will be recreated on next use")
        // Engine was already invalidated on sleep. The next startStreaming()
        // call will create a fresh engine with current hardware state.
        // Re-warm the engine so the first post-wake recording is fast.
        let warmUpDeviceID = InputDeviceSettings.shared.resolvedDeviceID()
        transcriber?.getAudioProcessor().warmUp(inputDeviceID: warmUpDeviceID)
    }

    // MARK: - Streaming

    func startStreaming() {
        // Check accessibility permission before starting
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
            return
        }

        let mode = HotkeySettings.shared.transcriptionMode

        speekState.isStreaming = true
        speekState.streamedText = ""
        updateMenuBarIcon(streaming: true)
        updateMenu()

        // Streaming mode: capture the focused text element BEFORE showing the overlay
        if mode == .streaming {
            streamingAXElement = getFocusedTextElement()
            streamingInsertionPoint = getInsertionPoint(from: streamingAXElement) ?? 0
            streamingPastedLength = 0
            streamingUseAX = true
            totalPastedText = ""
            savedClipboard = NSPasteboard.general.string(forType: .string)
            lastStreamingUpdateTime = 0
        }

        // Show the floating overlay
        showOverlay()

        // Resolve the input device from settings
        let inputDeviceID = InputDeviceSettings.shared.resolvedDeviceID()

        Task {
            do {
                try await streamingTranscriber.startStreaming(inputDeviceID: inputDeviceID) { [weak self] fullText in
                    DispatchQueue.main.async {
                        self?.speekState.streamedText = fullText
                        self?.updateOverlayText(fullText)

                        // In streaming mode, type text into the focused app in real-time
                        if mode == .streaming {
                            self?.onStreamingTextUpdate(fullText)
                        }
                    }
                }
            } catch {
                logger.error("Failed to start streaming: \(error.localizedDescription)")
                await MainActor.run {
                    self.speekState.isStreaming = false
                    self.updateMenuBarIcon(streaming: false)
                    self.updateMenu()
                    self.hideOverlay()
                    self.showNotification(title: "Speek", body: "Failed to start: \(error.localizedDescription)")
                }
            }
        }
    }

    func stopStreaming() {
        let mode = HotkeySettings.shared.transcriptionMode

        speekState.isStreaming = false
        updateMenuBarIcon(streaming: false)

        Task {
            // Stop transcription and wait for the transcription loop to fully finish
            await streamingTranscriber.stopStreaming()

            // Do a one-shot transcription of the full audio buffer to catch any
            // audio that the streaming loop missed (the last < 1 second)
            let finalText = await streamingTranscriber.finalTranscribe()
            await streamingTranscriber.clearLastText()

            await MainActor.run {
                self.hideOverlay()
                self.updateMenu()

                if mode == .streaming {
                    // Do one final update with the complete text
                    if !finalText.isEmpty {
                        self.onStreamingTextUpdate(finalText, force: true)
                    }
                    // Restore the original clipboard
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    if let saved = self.savedClipboard {
                        pasteboard.setString(saved, forType: .string)
                    }
                    self.savedClipboard = nil
                    self.streamingAXElement = nil
                    self.streamingPastedLength = 0
                    self.totalPastedText = ""
                } else {
                    // Transcribe mode: paste the final text
                    if !finalText.isEmpty {
                        self.pasteText(finalText)
                    }
                }
            }
        }
    }

    /// Paste text into the focused application via clipboard + Cmd+V
    func pasteText(_ text: String) {
        let pasteboard = NSPasteboard.general
        let previousContents = pasteboard.string(forType: .string)

        // Put our text on the clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V to paste
        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9  // 'V' key
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Brief delay for the paste to complete, then restore clipboard
        usleep(50000)
        pasteboard.clearContents()
        if let previous = previousContents {
            pasteboard.setString(previous, forType: .string)
        }
    }

    // MARK: - Streaming Mode (Text Insertion)

    /// Get the focused text element from the frontmost application.
    func getFocusedTextElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        return (focusedElement as! AXUIElement)
    }

    /// Get the current cursor position (UTF-16 offset) from an AX text element.
    func getInsertionPoint(from element: AXUIElement?) -> Int? {
        guard let element = element else { return nil }

        var rangeValue: AnyObject?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success else {
            return nil
        }

        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) else {
            return nil
        }

        return range.location
    }

    /// Replace text at a given range in the focused AX element (atomic, no keystrokes needed).
    func replaceTextInElement(_ element: AXUIElement, location: Int, length: Int, with text: String) -> Bool {
        var range = CFRange(location: location, length: length)
        guard let axRange = AXValueCreate(.cfRange, &range) else { return false }

        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, axRange) == .success else {
            return false
        }

        return AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFTypeRef) == .success
    }

    /// Called on each WhisperKit callback in streaming mode.
    /// Tries the Accessibility API first (atomic text replacement). If AX fails on the
    /// first attempt, falls back to CGEvent backspaces + clipboard paste for the rest
    /// of the session.
    func onStreamingTextUpdate(_ targetText: String, force: Bool = false) {
        // Throttle to prevent clipboard race conditions: each update must fully
        // complete (including usleep) before the next fires. 500ms gives the target
        // app plenty of time to process events between updates.
        let now = CFAbsoluteTimeGetCurrent()
        if !force && now - lastStreamingUpdateTime < 0.5 {
            return
        }
        lastStreamingUpdateTime = now

        // Try the Accessibility API first (works in TextEdit, Notes, etc.)
        if streamingUseAX, let element = streamingAXElement {
            if replaceTextInElement(element, location: streamingInsertionPoint, length: streamingPastedLength, with: targetText) {
                streamingPastedLength = (targetText as NSString).length
                totalPastedText = targetText
                return
            }
            // AX write not supported by this app — switch to CGEvent fallback
            logger.info("AX text replacement not supported, falling back to CGEvent approach")
            streamingUseAX = false
        }

        // CGEvent fallback: diff-based backspace + clipboard paste
        let oldText = totalPastedText
        let commonLength = zip(oldText, targetText).prefix(while: { $0 == $1 }).count
        let deleteCount = oldText.count - commonLength
        let newSuffix = String(targetText.dropFirst(commonLength))

        if deleteCount > 0 {
            typeBackspaces(count: deleteCount)
        }

        if !newSuffix.isEmpty {
            clipboardPaste(newSuffix)
        }

        totalPastedText = targetText
    }

    /// Send N backspace key-down/key-up CGEvents with a delay scaled to the count.
    func typeBackspaces(count: Int) {
        let source = CGEventSource(stateID: .hidSystemState)
        let backspaceKeyCode: CGKeyCode = 51

        for _ in 0..<count {
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: true)
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: backspaceKeyCode, keyDown: false)
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }

        // Wait for the target app to process all backspaces.
        // Events are ordered in the HID queue, but the app needs time to handle each one.
        if count > 0 {
            usleep(UInt32(count) * 3000 + 50000)
        }
    }

    /// Put text on the clipboard and synthesize Cmd+V to paste it.
    func clipboardPaste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let source = CGEventSource(stateID: .hidSystemState)
        let vKeyCode: CGKeyCode = 9
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)

        // Wait for the target app to process the paste before returning.
        // This prevents the next callback from overwriting the clipboard.
        usleep(100000)
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
        // Cleanup hotkey and monitors
        unregisterHotkey()
        teardownFnKeyMonitor()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
            eventHandler = nil
        }
        globalHotkeyCallback = nil
        NSApplication.shared.terminate(nil)
    }
}

// MARK: - Activation Mode
enum ActivationMode: String, CaseIterable {
    case toggle = "toggle"
    case pressAndHold = "pressAndHold"
}

// MARK: - Transcription Mode
enum TranscriptionMode: String, CaseIterable {
    case transcribe = "transcribe"
    case streaming = "streaming"
}

// MARK: - Hotkey Settings
class HotkeySettings: ObservableObject {
    static let shared = HotkeySettings()

    // Default: Cmd+Shift+A (keyCode 0 = A)
    static let defaultKeyCode: UInt16 = 0
    static let defaultModifiers: UInt = NSEvent.ModifierFlags.command.rawValue | NSEvent.ModifierFlags.shift.rawValue

    @Published var activationMode: ActivationMode {
        didSet {
            UserDefaults.standard.set(activationMode.rawValue, forKey: "activationMode")
            NotificationCenter.default.post(name: NSNotification.Name("HotkeyDidChange"), object: nil)
        }
    }

    @Published var transcriptionMode: TranscriptionMode {
        didSet {
            UserDefaults.standard.set(transcriptionMode.rawValue, forKey: "transcriptionMode")
        }
    }

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
        if let modeString = UserDefaults.standard.string(forKey: "activationMode"),
           let mode = ActivationMode(rawValue: modeString) {
            self.activationMode = mode
        } else {
            self.activationMode = .toggle
        }

        if let tmString = UserDefaults.standard.string(forKey: "transcriptionMode"),
           let tm = TranscriptionMode(rawValue: tmString) {
            self.transcriptionMode = tm
        } else {
            self.transcriptionMode = .transcribe
        }

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

// MARK: - Input Device Settings
class InputDeviceSettings: ObservableObject {
    static let shared = InputDeviceSettings()

    /// The UID string of the preferred device (stable across reboots), or nil for "System Default"
    @Published var preferredDeviceUID: String? {
        didSet {
            if let uid = preferredDeviceUID {
                UserDefaults.standard.set(uid, forKey: "preferredInputDeviceUID")
            } else {
                UserDefaults.standard.removeObject(forKey: "preferredInputDeviceUID")
            }
        }
    }

    /// Available input devices, refreshed on demand
    @Published var availableDevices: [AudioDevice] = []

    init() {
        self.preferredDeviceUID = UserDefaults.standard.string(forKey: "preferredInputDeviceUID")
    }

    /// Refresh the list of available input devices
    func refreshDevices() {
        availableDevices = AudioProcessor.getAudioDevices()
    }

    /// Resolve the preferred device UID to a runtime AudioDeviceID
    func resolvedDeviceID() -> AudioDeviceID? {
        guard let uid = preferredDeviceUID else {
            return resolveInputDevice(preferred: nil)
        }
        if let deviceID = getDeviceID(forUID: uid) {
            return resolveInputDevice(preferred: deviceID)
        }
        return resolveInputDevice(preferred: nil)
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
    @ObservedObject var inputDeviceSettings = InputDeviceSettings.shared

    var body: some View {
        Form {
            Section("Microphone") {
                Picker("Input device:", selection: $inputDeviceSettings.preferredDeviceUID) {
                    Text("System Default").tag(nil as String?)
                    ForEach(inputDeviceSettings.availableDevices) { device in
                        Text(device.name).tag(getDeviceUID(for: device.id) as String?)
                    }
                }
            }

            Section("Transcription Mode") {
                Picker("Mode:", selection: $hotkeySettings.transcriptionMode) {
                    Text("Transcribe (paste when done)").tag(TranscriptionMode.transcribe)
                    Text("Streaming (type as you speak)").tag(TranscriptionMode.streaming)
                }

                if hotkeySettings.transcriptionMode == .streaming {
                    Text("Text is typed into the focused app in real-time as you speak. Corrections are applied automatically.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Text is transcribed and pasted into the focused app when you stop recording.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Activation") {
                Picker("Activation mode:", selection: $hotkeySettings.activationMode) {
                    Text("Toggle (keyboard shortcut)").tag(ActivationMode.toggle)
                    Text("Press and hold Fn key").tag(ActivationMode.pressAndHold)
                }

                if hotkeySettings.activationMode == .toggle {
                    HotkeyRecorderView(hotkeySettings: hotkeySettings)

                    Text("Click the button and press your desired key combination")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Button("Reset to Default") {
                        hotkeySettings.reset()
                    }
                    .buttonStyle(.borderless)
                    .foregroundColor(.accentColor)
                } else {
                    Text("Hold the Fn key to record, release to stop.\nYou may need to set \"Press Fn key to\" → \"Do Nothing\" in System Settings → Keyboard.")
                        .font(.caption)
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
        .frame(width: 350, height: 500)
        .onAppear {
            inputDeviceSettings.refreshDevices()
        }
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
