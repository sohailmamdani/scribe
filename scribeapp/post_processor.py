"""
LLM-based post-processing for transcription correction.
Uses MLX-optimized models for Apple Silicon Neural Engine acceleration.
Specifically designed for correcting technical jargon and terminology.
"""
import threading
from typing import Callable, Optional
import os
import ssl
import certifi

# SSL certificate workaround for corporate firewalls
ssl._create_default_https_context = ssl._create_unverified_context


class PostProcessor:
    """Handles LLM-based post-processing of transcribed text."""

    def __init__(
        self,
        model_name: str = "mlx-community/Mistral-7B-Instruct-v0.3-4bit",
        on_processed: Optional[Callable[[str], None]] = None
    ):
        """
        Initialize the post-processor.

        Args:
            model_name: MLX-compatible model from HuggingFace
                       Recommended: mlx-community/Mistral-7B-Instruct-v0.3-4bit (best accuracy)
                       Alternative: mlx-community/Llama-3.2-3B-Instruct-4bit (faster, lighter)
            on_processed: Callback function called with corrected text
        """
        self.model_name = model_name
        self.on_processed = on_processed
        self.model = None
        self.tokenizer = None
        self.is_loading = False
        self.is_loaded = False

        print(f"Post-processor initialized with MLX (Apple Neural Engine)")

    def load_model(self, on_progress: Optional[Callable[[str], None]] = None) -> bool:
        """
        Load the MLX-optimized LLM model.

        Args:
            on_progress: Callback for progress updates

        Returns:
            True if loaded successfully, False otherwise
        """
        if self.is_loaded:
            return True

        self.is_loading = True

        try:
            from mlx_lm import load, generate

            if on_progress:
                on_progress(f"Downloading post-processing model ({self.model_name})...")

            # Model size info
            model_sizes = {
                "mlx-community/Llama-3.2-3B-Instruct-4bit": "~2GB (4-bit quantized)",
                "mlx-community/Mistral-7B-Instruct-v0.3-4bit": "~4GB (4-bit quantized)"
            }
            size_info = model_sizes.get(self.model_name, "~2-4GB")

            if on_progress:
                on_progress(f"Model size: {size_info} (first download only)")

            if on_progress:
                on_progress(f"Loading LLM with MLX optimization for M3 Pro...")

            # Load model and tokenizer
            # MLX will automatically use Neural Engine + GPU
            self.model, self.tokenizer = load(self.model_name)

            self.is_loaded = True
            self.is_loading = False

            if on_progress:
                on_progress(f"✓ Post-processor loaded (MLX Neural Engine)")

            return True

        except Exception as e:
            self.is_loading = False
            error_msg = str(e)

            if "certificate" in error_msg.lower() or "ssl" in error_msg.lower():
                msg = "SSL Error: Cannot download model. Check network connection."
            elif "connection" in error_msg.lower():
                msg = "Network Error: Check your internet connection"
            elif "disk" in error_msg.lower() or "space" in error_msg.lower():
                msg = "Disk Error: Not enough space (~2-4GB needed)"
            elif "memory" in error_msg.lower():
                msg = "Memory Error: Not enough RAM"
            else:
                msg = f"Error: {error_msg}"

            if on_progress:
                on_progress(msg)
            print(f"Error loading post-processing model: {error_msg}")
            return False

    def process(self, text: str) -> Optional[str]:
        """
        Post-process transcribed text to correct errors, especially technical jargon.

        Args:
            text: Raw transcribed text from Whisper

        Returns:
            Corrected text or None if processing failed
        """
        if not self.is_loaded or self.model is None:
            print("Post-processor model not loaded")
            return text  # Return original if model not loaded

        try:
            from mlx_lm import generate

            # Prompt specifically designed for technical transcription correction
            # Using Mistral's instruction format
            prompt = f"""<s>[INST] You are a technical transcription correction assistant. Fix speech-to-text errors in technical content.

Common corrections:
- "communities" → "Kubernetes"
- "postgres" or "postgres equal" → "PostgreSQL"
- "api" → "API"
- "graphql" or "graph ql" → "GraphQL"
- "ci cd" → "CI/CD"
- "docker" → "Docker"
- "aws" → "AWS"

Rules:
- Only fix clear transcription errors
- If the text is already correct, return it exactly as-is
- Don't add explanations, notes, or commentary
- Preserve all original words and punctuation

Text to correct:
{text}

Corrected text: [/INST]"""

            # Generate correction with MLX
            # Uses Apple Neural Engine automatically
            corrected = generate(
                model=self.model,
                tokenizer=self.tokenizer,
                prompt=prompt,
                max_tokens=512,  # Enough for most transcriptions
                verbose=False
            )

            # Extract just the corrected text (remove prompt)
            corrected = corrected.strip()

            # Remove common LLM prefixes/suffixes
            prefixes_to_remove = [
                "Corrected text:",
                "Here's the corrected text:",
                "The corrected text is:",
                "Here is the corrected text:",
            ]
            for prefix in prefixes_to_remove:
                if corrected.lower().startswith(prefix.lower()):
                    corrected = corrected[len(prefix):].strip()

            # Remove quotes if the LLM wrapped the response
            if corrected.startswith('"') and corrected.endswith('"'):
                corrected = corrected[1:-1]

            # Remove parenthetical notes the LLM might add
            # e.g., "(No technical terms found)" or similar
            import re
            corrected = re.sub(r'\s*\([^)]*technical[^)]*\)\s*$', '', corrected, flags=re.IGNORECASE)
            corrected = re.sub(r'\s*\([^)]*acronym[^)]*\)\s*$', '', corrected, flags=re.IGNORECASE)
            corrected = re.sub(r'\s*\([^)]*correction[^)]*\)\s*$', '', corrected, flags=re.IGNORECASE)

            # Final cleanup
            corrected = corrected.strip()

            # If corrected is empty, return original
            if not corrected:
                corrected = text

            # Call callback if provided
            if self.on_processed and corrected:
                self.on_processed(corrected)

            return corrected

        except Exception as e:
            print(f"Post-processing error: {e}")
            return text  # Return original on error

    def process_async(self, text: str):
        """
        Post-process text asynchronously in a separate thread.

        Args:
            text: Raw transcribed text
        """
        threading.Thread(
            target=self.process,
            args=(text,),
            daemon=True
        ).start()

    def cleanup(self):
        """Clean up model resources."""
        if self.model is not None:
            del self.model
            del self.tokenizer
            self.model = None
            self.tokenizer = None
            self.is_loaded = False

            # MLX handles cleanup automatically
