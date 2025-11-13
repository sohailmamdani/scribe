"""
Test script to verify Scribe setup
"""
import sys


def test_imports():
    """Test that all required packages can be imported."""
    print("Testing imports...")

    try:
        import whisper
        print("  ✓ whisper")
    except ImportError as e:
        print(f"  ✗ whisper - {e}")
        return False

    try:
        import PyQt5
        print("  ✓ PyQt5")
    except ImportError as e:
        print(f"  ✗ PyQt5 - {e}")
        return False

    try:
        import pyaudio
        print("  ✓ pyaudio")
    except ImportError as e:
        print(f"  ✗ pyaudio - {e}")
        return False

    try:
        import numpy
        print("  ✓ numpy")
    except ImportError as e:
        print(f"  ✗ numpy - {e}")
        return False

    try:
        import torch
        print("  ✓ torch")
    except ImportError as e:
        print(f"  ✗ torch - {e}")
        return False

    return True


def test_audio_devices():
    """Test that audio devices are available."""
    print("\nTesting audio devices...")

    try:
        import pyaudio
        audio = pyaudio.PyAudio()

        device_count = audio.get_device_count()
        print(f"  Found {device_count} audio device(s)")

        # List input devices
        input_devices = []
        for i in range(device_count):
            device_info = audio.get_device_info_by_index(i)
            if device_info['maxInputChannels'] > 0:
                input_devices.append(device_info['name'])
                print(f"    ✓ Input: {device_info['name']}")

        audio.terminate()

        if len(input_devices) == 0:
            print("  ✗ No input devices found")
            return False

        return True

    except Exception as e:
        print(f"  ✗ Error testing audio devices: {e}")
        return False


def test_torch_device():
    """Test PyTorch device availability."""
    print("\nTesting PyTorch device...")

    try:
        import torch

        if torch.backends.mps.is_available():
            print("  ✓ MPS (Metal Performance Shaders) available - will use Mac GPU acceleration")
            return True
        elif torch.cuda.is_available():
            print("  ✓ CUDA available - will use NVIDIA GPU")
            return True
        else:
            print("  ⚠ CPU only - will be slower but still functional")
            return True

    except Exception as e:
        print(f"  ✗ Error testing PyTorch device: {e}")
        return False


def test_whisper_models():
    """Check if Whisper models are available."""
    print("\nChecking Whisper model availability...")
    print("  Note: Models will be downloaded on first use (~500MB-1GB)")

    try:
        import whisper
        available_models = whisper.available_models()
        print(f"  Available model sizes: {', '.join(available_models)}")

        if 'small' in available_models:
            print("  ✓ 'small' model is available")
            return True
        else:
            print("  ✗ 'small' model not found")
            return False

    except Exception as e:
        print(f"  ✗ Error checking Whisper models: {e}")
        return False


def main():
    """Run all tests."""
    print("=" * 60)
    print("Scribe Setup Test")
    print("=" * 60)
    print()

    tests = [
        ("Package imports", test_imports),
        ("Audio devices", test_audio_devices),
        ("PyTorch device", test_torch_device),
        ("Whisper models", test_whisper_models),
    ]

    results = []
    for name, test_func in tests:
        try:
            result = test_func()
            results.append((name, result))
        except Exception as e:
            print(f"\n✗ {name} failed with exception: {e}")
            results.append((name, False))
        print()

    # Summary
    print("=" * 60)
    print("Test Summary")
    print("=" * 60)

    all_passed = True
    for name, passed in results:
        status = "✓ PASS" if passed else "✗ FAIL"
        print(f"  {status}: {name}")
        if not passed:
            all_passed = False

    print()
    if all_passed:
        print("✓ All tests passed! You're ready to run the application.")
        print("\nRun: python main.py")
        return 0
    else:
        print("✗ Some tests failed. Please check the errors above.")
        print("\nTry running: ./setup.sh")
        return 1


if __name__ == "__main__":
    sys.exit(main())
