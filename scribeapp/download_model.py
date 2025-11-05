"""
Manual Whisper model downloader

Use this if the automatic download fails due to SSL or network issues.
This script will download the model with SSL verification disabled.
"""
import os
import sys
import urllib.request
import ssl

def download_model(model_size="small"):
    """
    Manually download Whisper model.

    Args:
        model_size: Model size to download (tiny, base, small, medium, large)
    """
    # Model URLs
    model_urls = {
        "tiny": "https://openaipublic.azureedge.net/main/whisper/models/65147644a518d12f04e32d6f3b26facc3f8dd46e5390956a9424a650c0ce22b9/tiny.pt",
        "base": "https://openaipublic.azureedge.net/main/whisper/models/ed3a0b6b1c0edf879ad9b11b1af5a0e6ab5db9205f891f668f8b0e6c6326e34e/base.pt",
        "small": "https://openaipublic.azureedge.net/main/whisper/models/9ecf779972d90ba49c06d968637d720dd632c55bbf19d441fb42bf17a411e794/small.pt",
        "medium": "https://openaipublic.azureedge.net/main/whisper/models/345ae4da62f9b3d59415adc60127b97c714f32e89e936602e85993674d08dcb1/medium.pt",
        "large": "https://openaipublic.azureedge.net/main/whisper/models/e4b87e7e0bf463eb8e6956e646f1e277e901512310def2c24bf0e11bd3c28e9a/large-v3.pt",
    }

    if model_size not in model_urls:
        print(f"Error: Invalid model size '{model_size}'")
        print(f"Valid options: {', '.join(model_urls.keys())}")
        return False

    # Get cache directory
    cache_dir = os.path.expanduser("~/.cache/whisper")
    os.makedirs(cache_dir, exist_ok=True)

    model_path = os.path.join(cache_dir, f"{model_size}.pt")

    # Check if already downloaded
    if os.path.exists(model_path):
        print(f"✓ Model '{model_size}' already exists at: {model_path}")
        response = input("Download again? (y/N): ")
        if response.lower() != 'y':
            return True

    url = model_urls[model_size]
    print(f"Downloading Whisper {model_size} model...")
    print(f"URL: {url}")
    print(f"Destination: {model_path}")
    print()

    try:
        # Disable SSL verification for problematic networks
        ssl._create_default_https_context = ssl._create_unverified_context

        def download_progress(block_num, block_size, total_size):
            """Show download progress."""
            downloaded = block_num * block_size
            if total_size > 0:
                percent = min(100, (downloaded / total_size) * 100)
                mb_downloaded = downloaded / (1024 * 1024)
                mb_total = total_size / (1024 * 1024)
                print(f"\rProgress: {percent:.1f}% ({mb_downloaded:.1f}MB / {mb_total:.1f}MB)", end='')

        urllib.request.urlretrieve(url, model_path, download_progress)
        print()  # New line after progress
        print(f"✓ Successfully downloaded {model_size} model")
        print(f"  Location: {model_path}")
        return True

    except Exception as e:
        print(f"\n✗ Download failed: {e}")
        print("\nAlternative: Download manually from:")
        print(f"  {url}")
        print(f"Save to: {model_path}")
        return False


def main():
    """Main entry point."""
    print("=" * 60)
    print("Whisper Model Manual Downloader")
    print("=" * 60)
    print()

    if len(sys.argv) > 1:
        model_size = sys.argv[1]
    else:
        print("Available models:")
        print("  tiny   - 39M params  (~75MB)")
        print("  base   - 74M params  (~142MB)")
        print("  small  - 244M params (~466MB)  [RECOMMENDED]")
        print("  medium - 769M params (~1.5GB)")
        print("  large  - 1550M params (~2.9GB)")
        print()
        model_size = input("Enter model size [small]: ").strip().lower() or "small"

    print()
    success = download_model(model_size)

    if success:
        print()
        print("=" * 60)
        print("✓ Done! You can now run the application:")
        print("  ./run.sh")
        print("=" * 60)
        return 0
    else:
        print()
        print("=" * 60)
        print("✗ Download failed. Please check your internet connection")
        print("  or download the model file manually.")
        print("=" * 60)
        return 1


if __name__ == "__main__":
    sys.exit(main())
