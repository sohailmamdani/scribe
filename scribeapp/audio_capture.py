"""
Audio capture service for real-time microphone input with Voice Activity Detection.
"""
import pyaudio
import numpy as np
import threading
import queue
from typing import Callable, Optional
import webrtcvad
import struct
import config


class AudioCapture:
    """Captures audio from the microphone in real-time with Voice Activity Detection."""

    # Audio settings optimized for Whisper
    SAMPLE_RATE = config.SAMPLE_RATE
    CHUNK_SIZE = 1024
    CHANNELS = config.CHANNELS
    FORMAT = pyaudio.paInt16

    # VAD settings - read from config
    VAD_MODE = config.VAD_MODE
    VAD_FRAME_DURATION = config.VAD_FRAME_DURATION
    SILENCE_DURATION = config.SILENCE_DURATION
    MIN_SPEECH_DURATION = config.MIN_SPEECH_DURATION

    def __init__(self, callback: Optional[Callable[[np.ndarray], None]] = None):
        """
        Initialize audio capture with Voice Activity Detection.

        Args:
            callback: Function to call when speech ends and audio is ready for processing
        """
        self.callback = callback
        self.audio = pyaudio.PyAudio()
        self.stream = None
        self.is_recording = False
        self.audio_buffer = []
        self.buffer_lock = threading.Lock()

        # VAD initialization
        self.vad = webrtcvad.Vad(self.VAD_MODE)
        self.is_speaking = False
        self.silence_start = None
        self.speech_frames = 0

        # Calculate frame size for VAD (must be 10, 20, or 30ms of audio)
        self.vad_frame_size = int(self.SAMPLE_RATE * self.VAD_FRAME_DURATION / 1000)

    def start(self) -> bool:
        """
        Start capturing audio from the microphone.

        Returns:
            True if started successfully, False otherwise
        """
        try:
            self.stream = self.audio.open(
                format=self.FORMAT,
                channels=self.CHANNELS,
                rate=self.SAMPLE_RATE,
                input=True,
                frames_per_buffer=self.CHUNK_SIZE,
                stream_callback=self._audio_callback
            )

            self.is_recording = True
            self.stream.start_stream()
            return True

        except Exception as e:
            print(f"Error starting audio capture: {e}")
            return False

    def stop(self):
        """Stop capturing audio and process all accumulated audio."""
        self.is_recording = False

        if self.stream:
            self.stream.stop_stream()
            self.stream.close()
            self.stream = None

        # Process all accumulated audio when manually stopped
        with self.buffer_lock:
            if len(self.audio_buffer) > 0:
                self._process_audio_buffer()
            self.audio_buffer.clear()
            self.is_speaking = False
            self.silence_start = None
            self.speech_frames = 0

    def _audio_callback(self, in_data, frame_count, time_info, status):
        """
        Callback function called by PyAudio when new audio data is available.
        In manual mode, just accumulates audio until stop() is called.
        """
        if status:
            print(f"Audio callback status: {status}")

        # Convert bytes to numpy array
        audio_data = np.frombuffer(in_data, dtype=np.int16)

        with self.buffer_lock:
            # Just accumulate audio - we'll process it when stop() is called
            self.audio_buffer.extend(audio_data)

        return (in_data, pyaudio.paContinue)

    def _process_audio_buffer(self):
        """Process the accumulated audio buffer and send for transcription."""
        if len(self.audio_buffer) == 0:
            return

        # Convert to numpy array and normalize
        audio_chunk = np.array(self.audio_buffer, dtype=np.float32)
        audio_chunk = audio_chunk / 32768.0  # Normalize to [-1.0, 1.0]

        print(f"Processing {len(audio_chunk)/self.SAMPLE_RATE:.1f}s of speech")

        # Process in a separate thread to avoid blocking audio stream
        if self.callback:
            threading.Thread(
                target=self.callback,
                args=(audio_chunk,),
                daemon=True
            ).start()

    def get_available_devices(self):
        """Get list of available audio input devices."""
        devices = []
        for i in range(self.audio.get_device_count()):
            device_info = self.audio.get_device_info_by_index(i)
            if device_info['maxInputChannels'] > 0:
                devices.append({
                    'index': i,
                    'name': device_info['name'],
                    'sample_rate': int(device_info['defaultSampleRate'])
                })
        return devices

    def cleanup(self):
        """Clean up audio resources."""
        self.stop()
        self.audio.terminate()
