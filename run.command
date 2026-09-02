#!/bin/bash
# OCR PDF Converter - macOS / Linux launcher.
#
# First run: builds a Python environment inside this folder and installs
# Tesseract and Poppler for you. After that it just starts.
#
# Homebrew is the only thing it will not install on your behalf, because that
# needs an administrator password and is not mine to do quietly. If it is
# missing you get the one command to paste.
set -e
cd "$(dirname "$0")"

say()  { printf '\n== %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }

# --- Python ---------------------------------------------------------------- #
if ! command -v python3 >/dev/null 2>&1; then
    say "Python 3 is not installed"
    note "Install it:  brew install python"
    read -r -p "Press Return to close." _
    exit 1
fi

VENV=".venv-mac"
if [ ! -x "$VENV/bin/python" ]; then
    say "Setting up (first run only) — this takes a few minutes"
    note "Creating the Python environment..."
    python3 -m venv "$VENV"
    "$VENV/bin/python" -m pip install --upgrade pip --quiet
    note "Installing packages..."
    "$VENV/bin/python" -m pip install -r requirements.txt --quiet
fi

# --- Tesseract and Poppler ------------------------------------------------- #
missing=""
command -v tesseract >/dev/null 2>&1 || missing="$missing tesseract"
command -v pdftoppm  >/dev/null 2>&1 || missing="$missing poppler"

if [ -n "$missing" ]; then
    if command -v brew >/dev/null 2>&1; then
        say "Installing:$missing"
        # shellcheck disable=SC2086
        brew install $missing || {
            note "Homebrew could not install them. Try by hand:"
            note "  brew install$missing"
            read -r -p "Press Return to close." _
            exit 1
        }
    else
        say "Two extra programs are needed:$missing"
        note "They come from Homebrew, which is not installed on this Mac."
        note ""
        note "Install Homebrew by pasting this into Terminal:"
        note '  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
        note ""
        note "Then double-click this file again and it will do the rest."
        read -r -p "Press Return to close." _
        exit 1
    fi
fi

"$VENV/bin/python" "ocr_batch_pro.py"
echo
read -r -p "Press Return to close." _
