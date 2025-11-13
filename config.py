"""
Configuration settings for Scribe
Now using OpenAI Whisper Large-v3 (unquantized) + Mistral-7B post-processing
Optimized for Apple Silicon (M1/M2/M3) with GPU and Neural Engine acceleration!
"""

# ============================================================================
# WHISPER MODEL SETTINGS (OpenAI Whisper - Unquantized for Maximum Accuracy)
# ============================================================================

# Model size - Using large-v3 for best accuracy on M3 Pro
# GPU-accelerated via PyTorch MPS backend (Apple Metal)
#
# Options: "large-v3", "medium", "small"
#
# Recommended for M3 Pro:
#   "large-v3" - Best accuracy (96-97%), ~3GB, GPU-accelerated (RECOMMENDED)
#   "medium"   - Good accuracy (94-95%), ~1.5GB, faster
#   "small"    - Decent accuracy (92-93%), ~466MB, fastest
#
WHISPER_MODEL_SIZE = "large-v3"

# ============================================================================
# POST-PROCESSING SETTINGS (MLX-LLM - Neural Engine Accelerated)
# ============================================================================

# Enable LLM post-processing for technical jargon correction
# When enabled, transcribed text is corrected by a local LLM to fix:
#   - Technical terms (e.g., "communities" → "Kubernetes")
#   - Acronyms (e.g., "api" → "API", "graphql" → "GraphQL")
#   - Programming languages (e.g., "python" → "Python")
#   - Cloud providers, databases, tools, etc.
#
# NOTE: Currently disabled - LLM was adding unwanted text and not worth the trade-off
# Whisper Large-v3 alone gives 96-97% accuracy which is excellent
# 100% offline - no data leaves your machine
POST_PROCESSING_ENABLED = False

# Post-processing model (MLX-optimized for M3 Pro Neural Engine)
# Options:
#   "mlx-community/Mistral-7B-Instruct-v0.3-4bit" - Best accuracy, ~4GB (RECOMMENDED)
#   "mlx-community/Llama-3.2-3B-Instruct-4bit"    - Faster, lighter, ~2GB
#
POST_PROCESSING_MODEL = "mlx-community/Mistral-7B-Instruct-v0.3-4bit"

# Performance expectations with post-processing:
# - Whisper transcription: 3-5 sec/chunk (GPU-accelerated)
# - LLM post-processing: 1-2 sec/chunk (Neural Engine-accelerated)
# - Total latency: 5-7 sec/chunk
# - Accuracy: 97-98% for technical content

# ============================================================================
# AUDIO CAPTURE SETTINGS
# ============================================================================

SAMPLE_RATE = 16000  # Hz - Whisper requires 16kHz
CHANNELS = 1  # Mono audio

# ============================================================================
# VOICE ACTIVITY DETECTION (VAD) SETTINGS
# ============================================================================

# VAD aggressiveness mode (0-3)
# 0 = least aggressive (more sensitive, may capture background noise)
# 1 = quality mode (balanced)
# 2 = low bitrate mode
# 3 = very aggressive (only very clear speech is detected)
VAD_MODE = 1

# Frame duration for VAD analysis (milliseconds)
# Must be 10, 20, or 30
# Shorter = more responsive, Longer = more stable
VAD_FRAME_DURATION = 30  # ms

# How long to wait after speech ends before processing (seconds)
# Lower = faster response, Higher = less likely to cut off speech
SILENCE_DURATION = 1.5  # seconds

# Minimum speech duration to process (seconds)
# Prevents processing very short utterances or background noise
MIN_SPEECH_DURATION = 0.5  # seconds

# ============================================================================
# LANGUAGE SETTINGS
# ============================================================================

# Set to None for auto-detection, or specify language code
# Examples: "en", "es", "fr", "de", "zh", "ja", etc.
LANGUAGE = "en"

# ============================================================================
# UI SETTINGS
# ============================================================================

WINDOW_WIDTH = 800
WINDOW_HEIGHT = 600
WINDOW_TITLE = "Scribe - Whisper + Mistral Post-Processing"

# ============================================================================
# ADVANCED SETTINGS
# ============================================================================

# Hardware Acceleration Settings
# Whisper: Uses PyTorch MPS backend (Apple Metal GPU)
# Post-processor: Uses MLX (Apple Neural Engine + GPU)
#
# Your M3 Pro hardware:
#   - 16-core Neural Engine (used by MLX-LLM)
#   - 18-core GPU (used by Whisper + MLX-LLM)
#   - 36GB unified memory
#
# Both models automatically detect and use optimal hardware acceleration!

# ============================================================================
# AUTO-PASTE SETTINGS
# ============================================================================

# Auto-paste transcribed text into active application
# When enabled, transcribed text is automatically pasted into whatever
# text field you're currently focused on (e.g., email, document, chat)
AUTO_PASTE_ENABLED = True

# Restore clipboard after pasting
# If True, your previous clipboard content is restored after auto-paste
# If False, transcribed text remains in clipboard
RESTORE_CLIPBOARD_AFTER_PASTE = True

# Delay before auto-paste (seconds)
# Small delay to give you time to click into the target text area before pasting
# Recommended: 0.5-1.0 seconds gives enough time to switch focus to target app
AUTO_PASTE_DELAY = 0.5

# ============================================================================
# GLOBAL HOTKEY SETTINGS
# ============================================================================

# Enable global keyboard shortcut
# When enabled, you can start/stop recording from anywhere without
# clicking into the app window
GLOBAL_HOTKEY_ENABLED = True

# Global hotkey combination: Cmd+Option+Ctrl+V
# This hotkey works system-wide, even when the app is in the background
# You can keep focus on your email/document/chat while recording
HOTKEY_DISPLAY_NAME = "⌘⌥⌃V"  # How it appears in the UI
