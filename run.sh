#!/bin/bash

# Scribe - Easy run script

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo "❌ Virtual environment not found!"
    echo "Please run ./setup.sh first to install dependencies."
    exit 1
fi

# Activate virtual environment and run the app
echo "🎙️  Starting Scribe..."
source venv/bin/activate
python3 main.py
