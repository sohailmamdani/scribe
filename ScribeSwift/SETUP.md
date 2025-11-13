# Quick Setup Guide for Scribe

## ✅ You're Almost Done!

The Swift project has been created with **100% offline local Whisper** (just like your Python version).

## Next Steps (5 minutes)

### 1. Add WhisperKit Package

Xcode should already be open. If not:
```bash
open Scribe.xcodeproj
```

**Method A: Using File Menu (Easier)**

1. In Xcode, go to **File → Add Package Dependencies...**
2. In the search box (top right), paste: `https://github.com/argmaxinc/WhisperKit`
3. Press Enter/Return
4. Click **"Add Package"** button (bottom right)
5. Select **"WhisperKit"** from the list that appears
6. Click **"Add Package"** button again

**Method B: Using Project Settings (Alternative)**

1. Click on the **"Scribe"** project in the left sidebar (the blue icon at the very top)
2. Make sure you have the **"Scribe"** target selected (in the middle panel, under TARGETS)
3. Look for tabs at the top: General, Signing & Capabilities, Resource Tags, Info, Build Settings, Build Phases, Build Rules
4. If you see "Package Dependencies" - click it and use the "+" button
5. If you don't see it, use Method A above instead

### 2. Set Signing Team

After adding the package:

1. Click on the **"Scribe"** project in the left sidebar (blue icon)
2. Select the **"Scribe"** target (under TARGETS)
3. Click the **"Signing & Capabilities"** tab
4. Under "Signing", select your Apple ID team from the **"Team"** dropdown
   - If you don't see a team, go to Xcode → Settings → Accounts and sign in with your Apple ID
   - If you don't have an Apple ID, you can create a free one

### 3. Build & Run!

Press **⌘R** (or click the Play button in the top left)

The app will:
- Build and launch
- Show a microphone icon in your menu bar
- Download the Whisper large-v3 model on first run (~3GB, one-time)

## What's Different from Python Version?

### ✅ Same Privacy
- Still 100% offline
- Still uses Whisper large-v3
- Still GPU accelerated (CoreML instead of PyTorch)

### ✅ Fixes Your Issues
- **No more permission problems!** Native macOS app properly requests permissions
- **No Python environment needed** - just a single .app file
- **Menu bar app** - cleaner than a full window

### ✅ Better UX
- Global hotkey works system-wide (⌘⌥⌃V)
- Auto-paste works reliably
- Transcription history built-in

## Usage

Once running:

1. **Click** the microphone icon in menu bar
2. **Click** "Start Recording" (or press ⌘⌥⌃V)
3. **Speak** your message
4. **Click** "Stop Recording" (or press ⌘⌥⌃V again)
5. Text automatically pastes to active window!

## Troubleshooting

### "xcodebuild requires Xcode"
```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

### Can't find "Add Package Dependencies" menu?
- Make sure you're in Xcode (not another app)
- Try: File menu → scroll down → should see "Add Package Dependencies..."
- Alternative: Right-click on project in sidebar → Add Package Dependencies

### Build errors about WhisperKit?
- Make sure you added the package dependency first
- Try: Product → Clean Build Folder, then rebuild

### "No such module 'WhisperKit'"
- The package wasn't added properly
- Try Method A again (File → Add Package Dependencies)

## Next?

Once it's running, you can:
- **Grant permissions** when prompted (microphone + accessibility)
- **Wait for model download** (~3GB, first time only)
- **Start transcribing!**

The app will remember your settings and the model stays cached, so subsequent launches are instant.

---

**Questions?** Check the main README.md for detailed docs!
