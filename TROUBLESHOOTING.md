# Troubleshooting Guide

## SSL Certificate Errors

### Symptom
Error message: `SSL: CERTIFICATE_VERIFY_FAILED` or `self-signed certificate in certificate chain`

### Cause
This usually happens on corporate networks with SSL inspection/proxy or outdated SSL certificates.

### Solution 1: Use the manual downloader
```bash
source venv/bin/activate
python download_model.py
```

This will download the model with SSL verification disabled.

### Solution 2: Update certificates
```bash
source venv/bin/activate
pip install --upgrade certifi
```

Then try running the app again.

### Solution 3: Manual download (if all else fails)

1. **Find your cache directory**:
   ```bash
   echo ~/.cache/whisper
   ```

2. **Create it if needed**:
   ```bash
   mkdir -p ~/.cache/whisper
   ```

3. **Download the model file** manually from:
   ```
   https://openaipublic.azureedge.net/main/whisper/models/9ecf779972d90ba49c06d968637d720dd632c55bbf19d441fb42bf17a411e794/small.pt
   ```

4. **Save it as**:
   ```
   ~/.cache/whisper/small.pt
   ```

5. **Run the app**:
   ```bash
   ./run.sh
   ```

## Model Download is Slow

The Whisper Small model is ~466MB. On slow connections, this can take several minutes.

**What to expect**:
- Fast connection (50+ Mbps): 1-2 minutes
- Medium connection (10-50 Mbps): 2-5 minutes
- Slow connection (<10 Mbps): 5-15 minutes

**Progress monitoring**:
The app shows progress in the status bar. You can also watch the terminal for download progress.

## Model Won't Load

### Check disk space
The model needs ~1GB of free space:
```bash
df -h ~
```

### Check cache directory permissions
```bash
ls -la ~/.cache/whisper
```

If you get "Permission denied":
```bash
chmod 755 ~/.cache/whisper
```

### Clear cache and retry
```bash
rm -rf ~/.cache/whisper
./run.sh
```

## App Says "Model not loaded yet"

This is normal! Wait for:
1. Model download (first time only, 1-15 minutes depending on connection)
2. Model loading into memory (10-20 seconds)

You'll see the status change to "✓ Ready to transcribe" when ready.

## Recording Button is Disabled

The button is disabled while the model is loading. Wait for:
- Status bar to show "✓ Ready to transcribe"
- Button text to change to "Start Recording"
- Progress bar to disappear

## "Error: Could not start recording"

### Check microphone permissions
1. Go to System Settings > Privacy & Security > Microphone
2. Find "Python" or "Terminal" in the list
3. Enable the toggle

### Check if another app is using the microphone
Close apps like:
- Zoom, Teams, Discord
- QuickTime
- Other recording software

### Test microphone access
```bash
source venv/bin/activate
python -c "import pyaudio; p = pyaudio.PyAudio(); print('Devices:', p.get_device_count()); p.terminate()"
```

Should print number of devices without errors.

## PyAudio Import Error

### Symptom
```
ImportError: No module named 'pyaudio'
```

### Solution
Make sure you're using the virtual environment:
```bash
source venv/bin/activate  # Your prompt should show (venv)
python main.py
```

Or use the wrapper script:
```bash
./run.sh
```

## "PortAudio not found" Error

### Solution
Install PortAudio:
```bash
brew install portaudio
source venv/bin/activate
pip install --force-reinstall pyaudio
```

## App is Very Slow

### Normal latency
- **Expected**: 7-10 second delay from speech to text
  - 5 seconds: audio buffering
  - 2-5 seconds: model processing

### If slower than expected:

1. **Check CPU/Memory usage** (Activity Monitor)
   - The app uses ~2-3GB RAM
   - If your Mac is low on memory, close other apps

2. **Use a smaller model** (faster but less accurate):
   Edit `config.py`:
   ```python
   WHISPER_MODEL_SIZE = "base"  # or "tiny"
   ```

3. **Check if MPS is being used**:
   The app should show "Model loaded successfully on MPS" (Mac GPU)
   If it shows "CPU", transcription will be slower

## Transcription is Inaccurate

### Tips for better accuracy:
- Speak clearly and at moderate pace
- Minimize background noise
- Use a good quality microphone
- Keep distance from mic consistent (6-12 inches)

### Try a larger model (more accurate but slower):
Edit `config.py`:
```python
WHISPER_MODEL_SIZE = "medium"  # Better accuracy, slower
```

## App Won't Close

### Normal close
- Click red close button (Cmd+Q)
- Wait a few seconds for cleanup

### Force quit
```bash
pkill -f "python main.py"
```

Or use Activity Monitor to force quit.

## Memory Leak / High RAM Usage

After long usage sessions, restart the app:
1. Close app (Cmd+Q)
2. Wait 5 seconds
3. Reopen: `./run.sh`

## Virtual Environment Issues

### "venv not found"
Run setup script:
```bash
./setup.sh
```

### "command not found: activate"
Use full path:
```bash
source venv/bin/activate
```

### Corrupt virtual environment
Delete and recreate:
```bash
rm -rf venv/
./setup.sh
```

## Still Having Issues?

### Check logs
The app prints debug info to the terminal. Run it manually to see:
```bash
source venv/bin/activate
python main.py
```

Watch for error messages.

### Test components individually

1. **Test PyAudio**:
   ```bash
   source venv/bin/activate
   python test_setup.py
   ```

2. **Test model manually**:
   ```bash
   source venv/bin/activate
   python -c "import whisper; m=whisper.load_model('small'); print('OK')"
   ```

### Get help
If none of these solutions work, please include:
1. Error message (full text)
2. Output of `python test_setup.py`
3. macOS version
4. Whether you're on a corporate network
