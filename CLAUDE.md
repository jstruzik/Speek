# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build with Swift Package Manager
swift build -c release

# Run during development
swift run

# Build Xcode project (for app bundle/distribution)
xcodebuild -project Speek.xcodeproj -scheme Speek -configuration Release

# Monitor app logs
log stream --predicate 'subsystem == "com.speek.app"' --level debug

# Clean build
rm -rf .build/ && swift build
```

## Architecture

Speek is a macOS menu bar app that provides real-time speech-to-text using WhisperKit's on-device Whisper model. It types transcribed text directly into any focused application.

### Data Flow

```
Global Hotkey (Carbon API) → AppDelegate.toggleStreaming()
    ↓
StreamingTranscriber (actor) → WhisperKit AudioStreamTranscriber with VAD
    ↓
Real-time transcription with segment confirmation
    ↓
Full text callback → AppDelegate.onFullTextUpdate()
    ↓
Diff calculation → CGEvent keyboard synthesis → Text typed into active app
```

### Key Components

- **SpeekApp.swift**: Main app, AppDelegate, menu bar, hotkey registration (Carbon EventHotKeyRef), settings UI, and keyboard event synthesis via CGEvent API
- **StreamingTranscriber.swift**: Actor wrapper around WhisperKit's AudioStreamTranscriber with VAD enabled. Filters special tokens like `[[BLANK_AUDIO]]` and sends full text updates
- **Transcriber.swift**: WhisperKit model initialization and management. Downloads "base.en" model (~50MB) to `~/Library/Application Support/Speek/Models/` on first run

### Text Correction Strategy

Uses diff-based typing to handle WhisperKit's real-time refinements:
1. Maintains `totalTypedText` (what's been typed)
2. Compares against new `targetText` from transcriber
3. Calculates common prefix, backspaces to remove divergent text, types new characters

## Dependencies

- **WhisperKit** (0.9.0+): On-device Whisper implementation with Core ML optimization
- System frameworks: SwiftUI, Carbon.HIToolbox (hotkeys), AVFoundation (audio), CoreGraphics (CGEvent)

## Platform Requirements

- macOS 14.0+ (Swift 5.9 features)
- Apple Silicon recommended (Core ML performance)
- **No app sandbox** - required for accessibility features
- Requires Accessibility permission for keyboard synthesis and global hotkeys

## Configuration

- Default hotkey: Cmd+Shift+A (stored in UserDefaults as keyCode + modifiers)
- VAD silence threshold: 0.4 in StreamingTranscriber (higher = less sensitive to noise)
- LSUIElement=true (menu bar app, no dock icon)
