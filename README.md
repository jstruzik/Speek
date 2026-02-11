<p align="center">
  <img src="Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Speek app icon">
</p>

<h1 align="center">Speek</h1>

<p align="center">
  Real-time, local-only, speech-to-text for macOS. Speak and watch your words appear in any app.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?logo=swift&logoColor=white" alt="Swift 5.9">
  <img src="https://img.shields.io/badge/macOS-14.0%2B-blue?logo=apple&logoColor=white" alt="macOS 14.0+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green" alt="MIT License"></a>
  <img src="https://img.shields.io/badge/Apple%20Silicon-recommended-purple?logo=apple" alt="Apple Silicon">
</p>

<br>

<p align="center">

https://github.com/user-attachments/assets/06180615-f644-4879-be17-d08a26f095a1

</p>

## Features

- **Real-time transcription** — text appears as you speak with live corrections
- **Floating overlay** — see your transcription in a live overlay, text is pasted when you stop recording
- **Voice Activity Detection** — only transcribes when you're speaking, ignores silence
- **Menu bar app** — runs quietly in your menu bar, always one click away
- **Global hotkey** — toggle with `Cmd+Shift+A` or hold Fn key (configurable)
- **Microphone selection** — choose your preferred input device in Settings
- **100% local** — all processing on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit), nothing sent to the cloud

## Download

Grab the latest **Speek.dmg** or **Speek.app.zip** from the [Releases page](../../releases).

> Speek is unsigned, so on first launch you may need to right-click → Open, or allow it in **System Settings → Privacy & Security**.

## Getting Started

1. **Open Speek** — it appears as a microphone icon in your menu bar
2. **Grant permissions** when prompted:
   - **Microphone** — for audio capture
   - **Accessibility** — for pasting text into other applications (System Settings → Privacy & Security → Accessibility)
3. **Press `Cmd+Shift+A`** (or hold Fn) to start transcribing
4. **Speak** — a floating overlay shows your transcription in real-time
5. **Press `Cmd+Shift+A` again** (or release Fn) to stop — the transcribed text is pasted into the focused app

On first launch, Speek downloads the Whisper `base.en` model (~50MB). This is a one-time download stored in `~/Library/Application Support/Speek/Models/`.

## Build from Source

```bash
git clone https://github.com/jstruzik/Speek.git
cd Speek
```

**Option A — Xcode:**

Open `Speek.xcodeproj` and hit `Cmd+R` to build and run. No signing configuration is needed for local development (the project uses ad-hoc signing by default).

**Option B — Makefile (recommended for install):**

```bash
make build      # Build the Release configuration
make install    # Build and copy Speek.app to /Applications
make clean      # Remove build artifacts
make uninstall  # Remove from /Applications
```

> **Note:** `make install` automatically resets the Accessibility permission for Speek, since each rebuild produces a new ad-hoc code signature. You will be prompted to re-grant Accessibility permission on the next launch.

**Option C — Swift Package Manager:**

```bash
swift build -c release
```

## Requirements

| | |
|---|---|
| **macOS** | 14.0 (Sonoma) or later |
| **Chip** | Apple Silicon (M1/M2/M3/M4) recommended |
| **Permissions** | Microphone + Accessibility |

## How It Works

Speek uses WhisperKit's `AudioStreamTranscriber` with Voice Activity Detection to capture and transcribe speech in real-time. During recording, a floating overlay displays the live transcription. When recording stops, the final text is pasted into the focused application via the clipboard.

## License

[MIT](LICENSE)

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition for Apple Silicon
- [OpenAI Whisper](https://github.com/openai/whisper) — the underlying speech recognition model
