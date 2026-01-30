# Speek

A lightweight macOS menu bar app for real-time speech-to-text using [WhisperKit](https://github.com/argmaxinc/WhisperKit). Speek transcribes your speech and types it directly into any application.

## Features

- **Real-time transcription** - Text appears as you speak with live corrections
- **Voice Activity Detection (VAD)** - Only transcribes when you're speaking, ignoring silence
- **Menu bar app** - Runs quietly in your menu bar, always accessible
- **Global hotkey** - Toggle transcription with `Cmd+Shift+S` from anywhere
- **Local processing** - All transcription happens on-device using WhisperKit, no data sent to the cloud
- **Automatic corrections** - Uses diff-based typing to fix transcription as the model refines its output

## Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon Mac (M1/M2/M3) recommended for best performance

## Installation

### Download Release

Download the latest `Speek.app` from the [Releases](../../releases) page.

### Build from Source

1. Clone the repository:
   ```bash
   git clone https://github.com/YOUR_USERNAME/speek.git
   cd speek
   ```

2. Open in Xcode:
   ```bash
   open Speek.xcodeproj
   ```

3. Select your development team in Signing & Capabilities

4. Build and run with `Cmd+R`

Alternatively, build from command line:
```bash
swift build -c release
```

## Usage

1. **First Launch**: The app will download the Whisper model (~50MB) on first run
2. **Grant Permissions**:
   - **Microphone**: Required for audio capture
   - **Accessibility**: Required for typing text into other applications
3. **Start Transcribing**: Click the menu bar icon or press `Cmd+Shift+S`
4. **Speak**: Your speech will be transcribed and typed in real-time
5. **Stop**: Press `Cmd+Shift+S` again to stop

## Permissions

Speek requires the following permissions:

- **Microphone Access**: To capture your speech
- **Accessibility Access**: To type transcribed text into other applications

You can grant these in System Settings > Privacy & Security.

## How It Works

Speek uses WhisperKit's `AudioStreamTranscriber` with Voice Activity Detection to:
1. Capture audio from your microphone
2. Detect when you're speaking (VAD)
3. Transcribe speech segments in real-time
4. Type the transcription with automatic corrections as the model refines its output

The app uses a diff-based approach to handle corrections - if the model revises earlier text, Speek will backspace and retype the corrected portion.

## Model

Speek uses the `base.en` Whisper model by default, which provides a good balance of speed and accuracy for English transcription. The model is downloaded on first launch and stored in `~/Library/Application Support/Speek/Models/`.

## License

MIT License - see [LICENSE](LICENSE) for details.

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) - On-device speech recognition for Apple Silicon
- [OpenAI Whisper](https://github.com/openai/whisper) - The underlying speech recognition model
