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
- **Voice Activity Detection** — only transcribes when you're speaking, ignores silence
- **Menu bar app** — runs quietly in your menu bar, always one click away
- **Global hotkey** — toggle with `Cmd+Shift+A` from anywhere (configurable)
- **100% local** — all processing on-device via [WhisperKit](https://github.com/argmaxinc/WhisperKit), nothing sent to the cloud
- **Auto-corrections** — diff-based typing automatically fixes text as the model refines output

## Download

Grab the latest **Speek.dmg** or **Speek.app.zip** from the [Releases page](../../releases).

> Speek is unsigned, so on first launch you may need to right-click → Open, or allow it in **System Settings → Privacy & Security**.

## Getting Started

1. **Open Speek** — it appears as a microphone icon in your menu bar
2. **Grant permissions** when prompted:
   - **Microphone** — for audio capture
   - **Accessibility** — for typing text into other applications (System Settings → Privacy & Security → Accessibility)
3. **Press `Cmd+Shift+A`** (or click the menu bar icon) to start transcribing
4. **Speak** — your words are typed in real-time into the focused app
5. **Press `Cmd+Shift+A` again** to stop

On first launch, Speek downloads the Whisper `base.en` model (~50MB). This is a one-time download stored in `~/Library/Application Support/Speek/Models/`.

## Build from Source

```bash
git clone https://github.com/jstruzik/Speek.git
cd Speek
```

**Option A — Xcode:**

Open `Speek.xcodeproj`, select your development team under Signing & Capabilities, and hit `Cmd+R`.

**Option B — Command line:**

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

Speek uses WhisperKit's `AudioStreamTranscriber` with Voice Activity Detection to capture and transcribe speech in real-time. A diff-based approach handles corrections — if the model revises earlier text, Speek backspaces and retypes the corrected portion so the final output is always accurate.

## License

[MIT](LICENSE)

## Acknowledgments

- [WhisperKit](https://github.com/argmaxinc/WhisperKit) — on-device speech recognition for Apple Silicon
- [OpenAI Whisper](https://github.com/openai/whisper) — the underlying speech recognition model
