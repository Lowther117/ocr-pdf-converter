#!/bin/bash
# OCR PDF Converter - macOS / Linux launcher.
# Builds its own Python environment inside this folder on first run, then
# starts the converter. Nothing is installed system-wide.
set -e
cd "$(dirname "$0")"

if ! command -v python3 >/dev/null 2>&1; then
    echo
    echo "Python 3 was not found."
    echo "  Install it:  brew install python"
    echo
    read -r -p "Press Return to close." _
    exit 1
fi

VENV=".venv-mac"
if [ ! -x "$VENV/bin/python" ]; then
    echo "Creating the Python environment (first run only)..."
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --upgrade pip --quiet
    echo "Installing packages..."
    "$VENV/bin/python" -m pip install -r requirements.txt --quiet
fi

if ! command -v tesseract >/dev/null 2>&1; then
    echo "Note: Tesseract is not installed yet -  brew install tesseract"
fi
if ! command -v pdftoppm >/dev/null 2>&1; then
    echo "Note: Poppler is not installed yet   -  brew install poppler"
fi

"$VENV/bin/python" "ocr_batch_pro.py"
echo
read -r -p "Press Return to close." _
