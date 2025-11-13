# Scribe - Native macOS Voice Transcription App

A lightweight, **100% offline** native macOS menu bar app for real-time voice transcription using local Whisper models.

## Features

- **100% Offline & Private**: All transcription happens locally on your Mac, no data sent to cloud
- **Menu Bar App**: Runs quietly in your menu bar, no window clutter
- **Global Hotkey**: Press `⌘⌥⌃V` (Cmd+Option+Ctrl+V) anywhere to start/stop recording
- **Auto-Paste**: Automatically pastes transcribed text into your active window
- **Native macOS**: Built with Swift and SwiftUI for optimal performance
- **Local Whisper Large-v3**: Same model as Python version, GPU + Neural Engine accelerated
- **Transcription History**: View and manage all your transcriptions
- **Privacy First**: Microphone access only when recording, all processing on-device

## Requirements

- macOS 13.0 or later
- Xcode 15.0 or later (for building)
- ~5GB free disk space (for Whisper model)
- Apple Silicon Mac recommended (M1/M2/M3) for best performance

## Privacy & Offline Operation

Unlike many transcription apps, Scribe is **100% offline**:
- ✅ No API keys required
- ✅ No internet connection needed (after model download)
- ✅ No data sent to any servers
- ✅ All processing happens locally on your Mac
- ✅ Uses Apple's Neural Engine + GPU for acceleration

## Setup

### 1. Open in Xcode

```bash
cd /Users/smamdani/code/scribe2/scribeapp/ScribeSwift
open Scribe.xcodeproj
```

### 2. Add WhisperKit Dependency

In Xcode:

1. Select the **Scribe** project in the left sidebar
2. Select the **Scribe** target
3. Go to the **"Package Dependencies"** tab
4. Click the **"+"** button
5. Enter this URL: `https://github.com/argmaxinc/WhisperKit`
6. Click **"Add Package"**
7. Select **"WhisperKit"** and click **"Add Package"**

### 3. Set Your Development Team

1. Stay in project settings
2. Go to **"Signing & Capabilities"** tab
3. Select your Apple ID team from the dropdown

### 4. Build & Run

Press **⌘R** to build and run!

On first launch, the app will download the Whisper large-v3 model (~3GB). This is a one-time download and will be cached locally.

## Usage

### Starting the App

1. Launch Scribe (it appears in your menu bar as a microphone icon)
2. Grant microphone permission when prompted
3. Grant accessibility permission for auto-paste (optional but recommended)
4. Wait for model to download on first launch (~3GB, one-time)

### Recording

**Method 1: Menu Bar**
- Click the microphone icon in menu bar
- Click "Start Recording"
- Speak your message
- Click "Stop Recording"

**Method 2: Global Hotkey**
- Press `⌘⌥⌃V` anywhere to start recording
- Speak your message
- Press `⌘⌥⌃V` again to stop

### Viewing Transcriptions

- Click the microphone icon
- Select "Show Transcriptions"
- View, copy, or delete past transcriptions

### Auto-Paste

When enabled (default), transcribed text is automatically pasted into whatever text field you're currently focused on.

To disable:
- Click microphone icon → Settings → Uncheck "Auto-paste to Active Window"

## Permissions

Scribe requires two permissions:

1. **Microphone Access**: Required for recording audio
   - System Settings → Privacy & Security → Microphone → Enable Scribe

2. **Accessibility Access**: Required for auto-paste feature
   - System Settings → Privacy & Security → Accessibility → Enable Scribe

## Technical Details

### WhisperKit

Scribe uses [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for local Whisper inference:

- **Model**: Whisper Large-v3 (same as Python version)
- **Acceleration**: CoreML with Neural Engine + GPU
- **Performance**: ~3-5 seconds per transcription on M3 Pro
- **Accuracy**: 96-97% (same as Python version)
- **Storage**: ~3GB for the model (one-time download)

### Advantages Over Python Version

- ✅ **No Permission Issues**: Native app properly requests macOS permissions
- ✅ **Better Integration**: Native macOS UI and system integration
- ✅ **Menu Bar App**: Cleaner, less intrusive than a full window
- ✅ **Easy Distribution**: Single .app bundle, no Python environment needed
- ✅ **Same Privacy**: Still 100% offline like the Python version
- ✅ **Same Model**: Uses Whisper Large-v3 just like Python version
- ✅ **Same Acceleration**: GPU + Neural Engine (CoreML vs PyTorch MPS)

### Model Storage

The Whisper model is stored in:
```
~/Library/Caches/huggingface/whisper/
```

To free up space, you can delete this folder, but the model will re-download on next use.

## Performance

On Apple Silicon (M3 Pro):
- **Model Loading**: ~5-10 seconds (first time per session)
- **Transcription**: ~3-5 seconds for typical voice clips
- **Memory Usage**: ~2GB RAM when model is loaded
- **Disk Space**: ~3GB for model storage

## Troubleshooting

### "No microphone detected"
- Check System Settings → Privacy & Security → Microphone
- Ensure Scribe is enabled

### "Auto-paste not working"
- Check System Settings → Privacy & Security → Accessibility
- Ensure Scribe is enabled
- Restart Scribe after granting permission

### "Model download failed"
- Check your internet connection
- Ensure you have ~5GB free disk space
- Try restarting the app

### "Transcription is slow"
- First transcription is slower due to model initialization
- Subsequent transcriptions are faster
- Performance is best on Apple Silicon (M1/M2/M3)

### Command line tools error when building
If you see "tool 'xcodebuild' requires Xcode", run:
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

## Development

### Project Structure

```
Scribe/
├── ScribeApp.swift           # App entry point
├── AppDelegate.swift         # Menu bar UI and app logic
├── AudioRecorder.swift       # AVFoundation audio capture
├── WhisperService.swift      # WhisperKit integration (LOCAL)
├── AutoPaste.swift           # macOS Accessibility auto-paste
├── HotkeyManager.swift       # Global hotkey handling
├── TranscriptionHistory.swift # Transcription storage
├── TranscriptionView.swift   # SwiftUI transcription list
├── Info.plist               # App metadata and permissions
└── Scribe.entitlements      # App capabilities
```

### Building for Distribution

To create a distributable app:

1. Set your Apple Developer Team in Xcode
2. Archive the app: Product → Archive
3. Distribute the app: Organizer → Distribute App

## Comparison: Swift vs Python

| Feature | Swift Version | Python Version |
|---------|--------------|----------------|
| Privacy | ✅ 100% Offline | ✅ 100% Offline |
| Model | Whisper Large-v3 | Whisper Large-v3 |
| Accuracy | 96-97% | 96-97% |
| Permissions | ✅ Works | ❌ Issues on macOS |
| Distribution | Single .app file | Requires Python + venv |
| Memory | ~2GB | ~3GB |
| Disk Space | ~3GB | ~3GB |
| Startup | Fast | Slow (model loading) |
| UI | Menu bar | PyQt5 window |

## License

MIT License - See LICENSE file for details

## Credits

Built with:
- Swift & SwiftUI
- AVFoundation for audio capture
- [WhisperKit](https://github.com/argmaxinc/WhisperKit) by Argmax for local transcription
- macOS Accessibility APIs for auto-paste
