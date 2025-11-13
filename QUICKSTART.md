# Quick Start Guide

## Installation

### 1. Run the setup script

```bash
cd scribe
chmod +x setup.sh
./setup.sh
```

This will:
- Install Homebrew (if not already installed)
- Install PortAudio (required system dependency for audio capture)
- Create a Python virtual environment
- Install all required Python dependencies
- Download the Whisper Small model on first run

### 2. Activate the virtual environment

```bash
source venv/bin/activate
```

### 3. Run the application

```bash
python main.py
```

## First Time Setup

### macOS Microphone Permissions

When you first run the app and click "Start Recording", macOS will prompt you to grant microphone access. Click "OK" to allow the app to use your microphone.

If you denied permission by accident:
1. Go to System Settings > Privacy & Security > Microphone
2. Find Python or Terminal in the list
3. Enable the toggle

## Usage

1. **Launch the app**: Run `python main.py`
2. **Wait for model to load**: The status bar will show "Loading Whisper small model..."
3. **Start recording**: Click "Start Recording" when the status shows "Ready to transcribe"
4. **Speak**: Talk into your microphone
5. **View transcription**: Text will appear in real-time (processes every 5 seconds of audio)
6. **Stop recording**: Click "Stop Recording" when done
7. **Clear text**: Click "Clear Text" to reset the transcription display

## Performance Tips

- **First transcription**: The first transcription after launching may be slower as the model initializes
- **Better accuracy**: Speak clearly and minimize background noise
- **Processing delay**: There's a ~5 second buffer, so text appears with a slight delay
- **Mac optimization**: The app automatically uses Mac's Metal Performance Shaders (MPS) for faster processing

## Troubleshooting

### PyAudio installation fails
If you see an error about "portaudio.h not found":
```bash
brew install portaudio
source venv/bin/activate
pip install pyaudio
```

### "Error: Could not start recording"
- Check microphone permissions in System Settings
- Ensure no other app is using the microphone
- Try unplugging/replugging external microphones
- Verify PyAudio installed correctly: `python -c "import pyaudio; print('OK')"`

### "Error: Failed to load model"
- Ensure you have enough disk space (~1GB for model cache)
- Check internet connection for first-time model download
- Try deleting `~/.cache/whisper/` and rerunning

### Slow performance
- The Small model requires ~2GB RAM
- Close other memory-intensive applications
- Consider using a smaller model (edit `config.py` and set `WHISPER_MODEL_SIZE = "base"`)

## Customization

Edit `config.py` to customize:
- Model size (tiny, base, small, medium, large)
- Language settings
- Buffer duration
- UI settings

Example:
```python
WHISPER_MODEL_SIZE = "base"  # Faster, slightly less accurate
BUFFER_DURATION = 3  # Process every 3 seconds instead of 5
LANGUAGE = None  # Auto-detect language instead of forcing English
```

## Keyboard Shortcuts

- `Cmd+Q`: Quit application
- Click "Clear Text" button to clear transcription

## System Requirements

- macOS 10.15 or later
- 4GB+ RAM recommended
- 2GB free disk space (for model cache)
- Working microphone
