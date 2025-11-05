#!/bin/bash

# Scribe - Test script wrapper

# Check if virtual environment exists
if [ ! -d "venv" ]; then
    echo "❌ Virtual environment not found!"
    echo "Please run ./setup.sh first to install dependencies."
    exit 1
fi

# Activate virtual environment and run tests
echo "🧪 Running setup verification tests..."
echo ""
source venv/bin/activate
python test_setup.py
