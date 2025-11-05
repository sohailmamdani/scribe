"""
Whisper transcription service for converting audio to text.
Uses original OpenAI Whisper Large-v3 (unquantized) for maximum accuracy.
GPU-accelerated on Apple Silicon via PyTorch MPS backend.
"""
import numpy as np
import threading
from typing import Callable, Optional
import torch
import ssl
import certifi

# SSL certificate workaround for corporate firewalls
ssl._create_default_https_context = ssl._create_unverified_context


class TranscriptionService:
    """Handles audio transcription using OpenAI Whisper model."""

    def __init__(
        self,
        model_size: str = "large-v3",
        on_transcription: Optional[Callable[[str], None]] = None
    ):
        """
        Initialize the transcription service.

        Args:
            model_size: Whisper model size (large-v3, medium, small, etc.)
            on_transcription: Callback function called with transcribed text
        """
        self.model_size = model_size
        self.on_transcription = on_transcription
        self.model = None
        self.is_loading = False
        self.is_loaded = False

        # Detect best device for M3 Pro
        if torch.backends.mps.is_available():
            self.device = "mps"  # Apple Metal Performance Shaders (GPU)
            print(f"Using Apple Metal GPU (MPS) for acceleration")
        elif torch.cuda.is_available():
            self.device = "cuda"
            print(f"Using CUDA GPU")
        else:
            self.device = "cpu"
            print(f"Using CPU (GPU not available)")

    def load_model(self, on_progress: Optional[Callable[[str], None]] = None) -> bool:
        """
        Load the Whisper model.

        Args:
            on_progress: Callback for progress updates

        Returns:
            True if loaded successfully, False otherwise
        """
        if self.is_loaded:
            return True

        self.is_loading = True

        try:
            import whisper

            if on_progress:
                on_progress(f"Downloading Whisper {self.model_size} model...")

            # Model size info for user
            model_sizes = {
                "large-v3": "~3GB (best accuracy - unquantized)",
                "medium": "~1.5GB",
                "small": "~466MB"
            }
            size_info = model_sizes.get(self.model_size, "")

            if on_progress:
                on_progress(f"Model size: {size_info} (first download only)")

            if on_progress:
                on_progress(f"Loading model with {self.device.upper()} acceleration...")

            # Load model with device specification
            self.model = whisper.load_model(
                self.model_size,
                device=self.device,
                download_root=None  # Use default cache
            )

            self.is_loaded = True
            self.is_loading = False

            device_name = "Apple GPU (MPS)" if self.device == "mps" else self.device.upper()
            if on_progress:
                on_progress(f"✓ Model loaded ({device_name}-accelerated)")

            return True

        except Exception as e:
            self.is_loading = False
            error_msg = str(e)

            # Provide helpful error messages
            if "certificate" in error_msg.lower() or "ssl" in error_msg.lower():
                msg = "SSL Error: Cannot download model. Check network connection."
            elif "connection" in error_msg.lower():
                msg = "Network Error: Check your internet connection"
            elif "disk" in error_msg.lower() or "space" in error_msg.lower():
                msg = "Disk Error: Not enough space (~3-4GB needed for large-v3)"
            elif "memory" in error_msg.lower():
                msg = "Memory Error: Not enough RAM"
            else:
                msg = f"Error: {error_msg}"

            if on_progress:
                on_progress(msg)
            print(f"Error loading Whisper model: {error_msg}")
            return False

    def transcribe(self, audio: np.ndarray) -> Optional[str]:
        """
        Transcribe audio data to text using Whisper.

        Args:
            audio: Audio data as numpy array (normalized to [-1.0, 1.0])

        Returns:
            Transcribed text or None if transcription failed
        """
        if not self.is_loaded or self.model is None:
            print("Model not loaded")
            return None

        try:
            # Validate audio data
            if audio is None or len(audio) == 0:
                print("Empty audio data")
                return None

            # Ensure audio is float32 normalized to [-1.0, 1.0]
            if audio.dtype != np.float32:
                audio = audio.astype(np.float32)

            # Ensure proper range
            if np.abs(audio).max() > 1.0:
                audio = audio / 32768.0

            # Check if audio is too quiet (might be silence)
            if np.abs(audio).max() < 0.001:
                print("Audio too quiet, skipping")
                return None

            # Ensure minimum audio length (Whisper needs at least 0.1 seconds)
            min_samples = int(0.1 * 16000)  # 0.1 seconds at 16kHz
            if len(audio) < min_samples:
                print(f"Audio too short ({len(audio)} samples), padding")
                audio = np.pad(audio, (0, min_samples - len(audio)))

            # Transcribe with Whisper
            result = self.model.transcribe(
                audio,
                language="en",  # Set to None for auto-detection
                task="transcribe",
                fp16=False,  # Disable FP16 on MPS - can cause NaN issues
                verbose=False,
                condition_on_previous_text=False,  # Prevent hallucinations
                no_speech_threshold=0.6,  # Higher threshold to detect silence
                logprob_threshold=-1.0,  # Filter low-confidence transcriptions
                compression_ratio_threshold=2.4,  # Filter repetitive/nonsensical output
                word_timestamps=False  # Disable word-level timestamps for better flow
            )

            # Extract text from result
            text = result["text"].strip()

            # Fix punctuation issues - periods before conjunctions
            import re
            # Fix ".and" -> " and", ".but" -> " but", etc.
            text = re.sub(r'\.(\s*)(and|but|or|so|yet|for|nor)\s+', r'\1\2 ', text, flags=re.IGNORECASE)

            # Fix ".that" -> " that" (common with clauses)
            text = re.sub(r'\.(\s*)(that|which|who|where|when)\s+', r'\1\2 ', text, flags=re.IGNORECASE)

            # Remove common hallucinations
            hallucinations = [
                "Thank you.", "Thank you", "Thanks for watching",
                "Thanks for watching.", "Bye.", "Goodbye.", "Thank you for watching."
            ]
            for hallucination in hallucinations:
                if text.endswith(hallucination):
                    text = text[:-len(hallucination)].strip()
                if text == hallucination:
                    text = ""

            # Call callback if provided
            if self.on_transcription and text:
                self.on_transcription(text)

            return text

        except Exception as e:
            print(f"Transcription error: {e}")
            return None

    def transcribe_async(self, audio: np.ndarray):
        """
        Transcribe audio asynchronously in a separate thread.

        Args:
            audio: Audio data as numpy array
        """
        threading.Thread(
            target=self.transcribe,
            args=(audio,),
            daemon=True
        ).start()

    def cleanup(self):
        """Clean up model resources."""
        if self.model is not None:
            del self.model
            self.model = None
            self.is_loaded = False

            # Clear GPU cache if using GPU
            if self.device == "mps":
                torch.mps.empty_cache()
            elif self.device == "cuda":
                torch.cuda.empty_cache()
