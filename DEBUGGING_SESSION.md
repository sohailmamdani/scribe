# Scribe Audio Capture Debugging Session

## Problem Summary

The Scribe voice transcription app is getting **zero audio input** from the microphone, even though:
- ✓ The Logitech Webcam C925e is selected as the default input device
- ✓ macOS Sound Settings shows the input level meter is active and detecting audio
- ✓ The input volume is NOT muted
- ✓ The exact same code works on your home computer

## Symptoms

When recording, the app shows:
```
Using audio input device: Logitech Webcam C925e (index 1)
Processing X.Xs of speech
Audio level: 0.000000
Audio too quiet, skipping
```

## What We Discovered

1. **PyAudio is receiving all zeros** - Test scripts confirmed that PyAudio is getting zero audio data even though macOS can see the microphone input
2. **Not a code issue** - The code works on your home computer, so it's an environment/system configuration issue
3. **Not a permission issue (maybe?)** - Reset microphone permissions with `tccutil reset Microphone` but no permission dialog appeared
4. **Virtual environment was recreated** - Fresh venv setup didn't fix the issue

## What We Tried

### 1. Fixed Manual Recording Mode
- Modified `audio_capture.py` to disable automatic VAD-based processing
- Audio now accumulates during recording and only processes when manually stopped
- This part works correctly (the manual recording behavior)

### 2. Configuration Changes
- Changed `VAD_MODE` from 3 to 1 (less aggressive)
- Increased `SILENCE_DURATION` from 1.0s to 1.5s
- Fixed `run.sh` to use `python3` instead of `python`

### 3. Audio Capture Debugging
- Added debug logging to see audio levels
- Tested with both mono (1 channel) and stereo (2 channels)
- Created test scripts: `test_mic_permission.py`, `test_raw_audio.py`, `test_stereo.py`
- All tests showed **max audio value = 0**

### 4. Permission Troubleshooting
- Checked System Settings → Privacy & Security → Microphone
- Warp (terminal) has permission but Python doesn't appear in the list
- Reset all microphone permissions but dialog never appeared
- Attempted to manually add Python executable to permissions (no + button visible in UI)

## Current Status

**BLOCKED**: PyAudio is not receiving any audio data despite the microphone being functional in macOS.

## Hypothesis

The most likely cause is a **macOS microphone permission issue** where:
- The Python executable needs explicit permission to access the microphone
- macOS is silently denying access without showing a permission dialog
- This might be a macOS Sequoia-specific behavior or security setting

## Next Steps to Try

### Option 1: Test with Stereo (2 channels)
The webcam has 2 input channels, we were requesting 1 (mono). Test if using stereo works:
```bash
cd /Users/smamdani/code/scribe2/scribeapp
source venv/bin/activate
python3 test_stereo.py  # If this file exists
```

### Option 2: Try Different Microphone
Test with MacBook Pro built-in microphone instead of the webcam:
- Go to System Settings → Sound → Input
- Select "MacBook Pro Microphone"
- Run the app and see if it works

### Option 3: Grant Python Microphone Permission Manually
Try to manually add Python to microphone permissions:
1. System Settings → Privacy & Security → Microphone
2. Try finding a way to add `/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12`

### Option 4: Use a Different Python Environment
- Try using a different Python installation (e.g., from Homebrew)
- Or package the app as a proper macOS .app bundle which might trigger permissions correctly

### Option 5: Check macOS Security Logs
```bash
log show --predicate 'process == "tccd"' --info --last 1h | grep python
```
This might show if permissions are being denied.

### Option 6: Compare with Home Computer
Check what's different on your home computer:
- macOS version
- Python version and installation method
- Whether Python appears in microphone permissions
- Any other system settings

## Files Modified

### `/Users/smamdani/code/scribe2/scribeapp/audio_capture.py`
- Simplified `_audio_callback()` to just accumulate audio (manual mode)
- Modified `stop()` to process all accumulated audio when manually stopped

### `/Users/smamdani/code/scribe2/scribeapp/config.py`
- `VAD_MODE = 1` (was 3)
- `SILENCE_DURATION = 1.5` (was 1.0)

### `/Users/smamdani/code/scribe2/scribeapp/run.sh`
- Changed `python` to `python3` for macOS compatibility

### `/Users/smamdani/code/scribe2/scribeapp/transcription_service.py`
- No changes needed (already had "too quiet" check)

## Test Scripts Created

- `list_audio_devices.py` - Shows all available audio input devices
- `test_mic_permission.py` - Tests basic microphone access
- `test_raw_audio.py` - Records 3 seconds and saves WAV file
- `test_stereo.py` - Tests with 2 channels instead of 1

## Git Status

Latest commit should include manual recording mode changes. The remote repository at `git@github.com:sohailmamdani/scribe.git` has been updated.

## Key Commands

```bash
# Navigate to project
cd /Users/smamdani/code/scribe2/scribeapp

# Setup venv (if not already done)
./setup.sh

# Run the app
./run.sh

# Test audio capture
source venv/bin/activate
python3 test_raw_audio.py

# List audio devices
python3 list_audio_devices.py

# Reset microphone permissions
tccutil reset Microphone
```

## Important Notes

1. The code itself is fine - it works on your home computer
2. This is definitely a system/environment configuration issue
3. The webcam microphone IS working (macOS can see it)
4. PyAudio just can't access it for some reason
5. This might be a macOS security feature blocking Python from accessing the mic

## Questions to Answer

1. What macOS version are you running? (Check: System Settings → General → About)
2. What macOS version is on your home computer where it works?
3. Does the built-in MacBook microphone work with the app?
4. Does Python appear in your microphone permissions on the home computer?

---

**Created**: 2025-11-12
**Session**: Debugging audio capture with PyAudio on macOS
