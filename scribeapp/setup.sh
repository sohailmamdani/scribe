#!/bin/bash

# Scribe Setup Script

echo "Setting up Scribe..."
echo ""

# Check if Homebrew is installed
if ! command -v brew &> /dev/null; then
    echo "⚠️  Homebrew not found. Installing Homebrew..."
    echo "This is required to install PortAudio (needed for PyAudio)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
else
    echo "✓ Homebrew is installed"
fi

# Install PortAudio via Homebrew
echo ""
echo "Installing PortAudio (required for PyAudio)..."
if brew list portaudio &> /dev/null; then
    echo "✓ PortAudio already installed"
else
    brew install portaudio
    echo "✓ PortAudio installed"
fi

# Check Python version
echo ""
python_version=$(python3 --version 2>&1 | awk '{print $2}')
echo "Python version: $python_version"

# Create virtual environment
echo ""
echo "Creating virtual environment..."
python3 -m venv venv

# Activate virtual environment
echo "Activating virtual environment..."
source venv/bin/activate

# Upgrade pip
echo "Upgrading pip..."
pip install --upgrade pip

# Install dependencies
echo ""
echo "Installing Python dependencies..."
pip install -r requirements.txt

echo ""
echo "=========================================="
echo "Setup complete!"
echo "=========================================="
echo ""
echo "To run the application:"
echo "  1. Activate the virtual environment: source venv/bin/activate"
echo "  2. Run the app: python main.py"
echo ""
echo "Or run the test script first:"
echo "  python test_setup.py"
echo ""
echo "Note: On macOS, you may need to grant microphone permissions when prompted."
