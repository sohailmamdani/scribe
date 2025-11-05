# Installation Notes

## What Was Installed

### System Dependencies (via Homebrew)
- **PortAudio 19.7.0**: Audio I/O library required by PyAudio

### Python Environment
- Python virtual environment created at `venv/`

### Python Packages
All packages successfully installed:

| Package | Version | Purpose |
|---------|---------|---------|
| openai-whisper | 20231117 | Speech-to-text AI model |
| PyQt5 | 5.15.10 | GUI framework |
| pyaudio | 0.2.14 | Audio capture |
| numpy | 2.3.4 | Numerical computing |
| torch | 2.9.0 | PyTorch ML framework |

Plus supporting dependencies (tiktoken, numba, etc.)

## Verified Capabilities

✅ All package imports working
✅ Audio devices detected (3 input devices found)
✅ MPS (Metal Performance Shaders) available for GPU acceleration
✅ Whisper Small model available for download

## System Configuration

- **Platform**: macOS (Apple Silicon)
- **Acceleration**: Metal Performance Shaders (MPS)
- **Audio Input Devices**:
  - Logitech Webcam C925e
  - SMiPhone16ProMaxMk2 Microphone
  - MacBook Pro Microphone

## Next Steps

### To run the application:
```bash
source venv/bin/activate
python main.py
```

### First Run Notes:
1. On first launch, Whisper will download the "small" model (~500MB)
2. macOS will prompt for microphone permissions - click "Allow"
3. Model loading takes 10-20 seconds on first run

## Resource Usage

Expected resource usage during operation:
- **RAM**: ~2-3GB (model + buffers)
- **Disk**: ~1GB (model cache at ~/.cache/whisper/)
- **CPU/GPU**: Moderate (MPS acceleration enabled)

## Performance Optimization

The app is configured to use:
- ✅ Metal Performance Shaders (MPS) on Mac GPU
- ✅ Float16 precision for faster processing
- ✅ 5-second audio buffering for optimal latency

## Troubleshooting Reference

If you encounter issues, see:
- `QUICKSTART.md` - Common problems and solutions
- `PROJECT.md` - Technical architecture details
- `test_setup.py` - Run this to verify installation

## Uninstallation

To completely remove the app:
```bash
# Remove virtual environment
rm -rf venv/

# Remove Whisper model cache
rm -rf ~/.cache/whisper/

# Optionally remove PortAudio if not needed by other apps
brew uninstall portaudio
```
