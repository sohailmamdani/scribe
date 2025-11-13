# Scribe - Project Overview

## Architecture

Scribe is a lightweight Mac application for real-time speech-to-text transcription using OpenAI's Whisper model running completely offline.

### Components

```
┌─────────────────────────────────────────────────────────┐
│                     main.py                             │
│              (PyQt5 GUI Application)                    │
└────────────┬──────────────────────────┬─────────────────┘
             │                          │
             ▼                          ▼
┌────────────────────────┐  ┌──────────────────────────┐
│   audio_capture.py     │  │ transcription_service.py │
│   (PyAudio wrapper)    │  │   (Whisper wrapper)      │
└────────────────────────┘  └──────────────────────────┘
             │                          │
             ▼                          ▼
┌────────────────────────┐  ┌──────────────────────────┐
│   System Microphone    │  │   Whisper Small Model    │
│      (Hardware)        │  │  (~244M parameters)      │
└────────────────────────┘  └──────────────────────────┘
```

### Data Flow

1. **Audio Capture**: PyAudio captures audio from microphone in chunks
2. **Buffering**: Audio chunks are buffered for 5 seconds
3. **Preprocessing**: Audio is normalized and converted to Whisper's expected format (16kHz, mono, float32)
4. **Transcription**: Whisper model processes the audio chunk
5. **Display**: Transcribed text is displayed in the UI

### Threading Model

- **Main Thread**: Runs PyQt5 event loop and UI updates
- **Audio Callback Thread**: PyAudio's stream callback (high priority)
- **Transcription Threads**: Background threads for Whisper processing
- **Signal/Slot System**: Qt signals for thread-safe UI updates

## File Structure

```
scribe/
├── main.py                    # Main application and UI
├── audio_capture.py           # Audio capture service
├── transcription_service.py   # Whisper transcription service
├── config.py                  # Configuration settings
├── requirements.txt           # Python dependencies
├── setup.sh                   # Installation script
├── test_setup.py             # Setup verification script
├── README.md                  # Project documentation
├── QUICKSTART.md             # Quick start guide
├── PROJECT.md                # This file - project overview
└── .gitignore                # Git ignore patterns
```

## Key Features

### Real-time Processing
- Continuous audio capture using PyAudio
- 5-second buffering for optimal processing
- Non-blocking transcription using threading

### Offline Operation
- All processing happens locally
- No internet required after initial model download
- Private - no data sent to external servers

### Mac Optimization
- Automatic detection and use of Metal Performance Shaders (MPS)
- Native PyQt5 UI with macOS styling
- Optimized for Apple Silicon

### User Experience
- Clean, modern UI
- Visual status indicators
- Real-time transcription display
- One-click start/stop recording

## Configuration Options

Edit `config.py` to customize:

### Model Size
```python
WHISPER_MODEL_SIZE = "small"  # Options: tiny, base, small, medium, large
```

| Model  | Parameters | RAM     | Speed       | Accuracy |
|--------|-----------|---------|-------------|----------|
| tiny   | 39M       | ~1GB    | Very Fast   | Good     |
| base   | 74M       | ~1.5GB  | Fast        | Better   |
| small  | 244M      | ~2GB    | Moderate    | Great    |
| medium | 769M      | ~5GB    | Slow        | Excellent|
| large  | 1550M     | ~10GB   | Very Slow   | Best     |

### Audio Settings
```python
BUFFER_DURATION = 5  # Process every N seconds
LANGUAGE = "en"      # Force language or None for auto-detect
```

### Performance
```python
USE_FP16 = True      # Use half-precision (faster on GPU/MPS)
DEVICE = None        # Auto-detect or specify: "mps", "cuda", "cpu"
```

## Performance Characteristics

### Resource Usage (Small Model)
- **Memory**: ~2GB RAM
- **Disk**: ~1GB (model cache)
- **CPU**: Moderate (depends on device)
- **GPU**: Optimized for Apple Silicon (MPS)

### Latency
- **Buffer delay**: 5 seconds (configurable)
- **Processing time**: 2-5 seconds per chunk (varies by device)
- **Total latency**: ~7-10 seconds from speech to text

### Accuracy
- **Whisper Small**: ~95% accuracy in ideal conditions
- **Best with**: Clear speech, minimal background noise, English
- **Supports**: 99+ languages (configure in `config.py`)

## Technical Details

### Audio Format
- **Sample Rate**: 16kHz (required by Whisper)
- **Channels**: Mono
- **Format**: 16-bit PCM → float32 normalized to [-1.0, 1.0]

### Whisper Parameters
```python
result = model.transcribe(
    audio,
    language="en",      # Language code or None
    task="transcribe",  # vs "translate"
    fp16=True,          # Half-precision on GPU/MPS
    verbose=False       # Suppress detailed output
)
```

### Thread Safety
- Qt signals/slots for UI updates from background threads
- Thread-local audio buffers with locks
- Daemon threads for cleanup on exit

## Known Limitations

1. **Latency**: Not suitable for live captions (7-10 second delay)
2. **Accuracy**: Varies with audio quality, accent, and background noise
3. **Languages**: Optimized for English; other languages may be less accurate
4. **Resources**: Requires ~2GB RAM minimum for Small model
5. **No streaming**: Processes fixed-size chunks, not continuous streaming

## Future Enhancements

Potential improvements:

- [ ] Faster-Whisper integration for reduced latency
- [ ] Speaker diarization (identify different speakers)
- [ ] Export to multiple formats (SRT, VTT, JSON)
- [ ] Keyboard shortcuts for control
- [ ] Menu bar app mode
- [ ] File transcription (in addition to real-time)
- [ ] Adjustable buffer size in UI
- [ ] Pause/resume functionality
- [ ] Timestamp display
- [ ] Dark mode support

## Dependencies

### Core
- **whisper**: OpenAI's Whisper ASR model
- **torch**: PyTorch for model execution
- **PyQt5**: GUI framework
- **pyaudio**: Audio I/O
- **numpy**: Numerical processing

### Platform
- **macOS**: 10.15+ recommended
- **Python**: 3.8+ required

## Troubleshooting

See QUICKSTART.md for common issues and solutions.

## License

MIT License - Feel free to use, modify, and distribute.

## Credits

- **OpenAI Whisper**: https://github.com/openai/whisper
- **PyQt5**: https://www.riverbankcomputing.com/software/pyqt/
- **PyAudio**: http://people.csail.mit.edu/hubert/pyaudio/
