#!/bin/bash
set -e

# OCR PDF Converter - CLI App Bundle Builder (macOS)
# Creates /Applications/OCR PDF Converter.app with pre-installed venv

echo ""
echo "🔨 Building OCR PDF Converter.app..."
echo ""

BUNDLE="/Applications/OCR PDF Converter.app"
MACOS="$BUNDLE/Contents/MacOS"
RESOURCES="$BUNDLE/Contents/Resources"

# Source lives next to this script, wherever the repo was cloned.
HERE="$(cd "$(dirname "$0")" && pwd)"
SOURCE="$HERE/ocr_batch_pro.py"
if [ ! -f "$SOURCE" ]; then
    echo "❌ Error: ocr_batch_pro.py not found next to this script ($HERE)"
    exit 1
fi

# Check Tesseract
if ! command -v tesseract &> /dev/null; then
    echo "❌ Tesseract not found"
    echo "Install with: brew install tesseract"
    exit 1
fi

# Check Poppler
if ! command -v pdftotext &> /dev/null; then
    echo "❌ Poppler not found"
    echo "Install with: brew install poppler"
    exit 1
fi

# Remove old
if [ -d "$BUNDLE" ]; then
    sudo rm -rf "$BUNDLE" 2>/dev/null || rm -rf "$BUNDLE" 2>/dev/null || true
fi

# Create structure
mkdir -p "$MACOS" "$RESOURCES"
cp "$SOURCE" "$RESOURCES/ocr_batch_pro.py"

# Create venv in Resources
echo "📦 Creating Python environment..."
VENV="$RESOURCES/.venv"
/usr/bin/python3 -m venv "$VENV"
source "$VENV/bin/activate"

echo "📥 Installing dependencies..."
pip install --upgrade pip --quiet
pip install -r "$HERE/requirements.txt" --quiet

# Simple launcher - opens Terminal to run script
cat > "$MACOS/OCR PDF Converter" << 'LAUNCHER'
#!/bin/bash
BUNDLE="$(cd "$(dirname "$0")/../.." && pwd)"
PYTHON="$BUNDLE/Contents/Resources/.venv/bin/python"
SCRIPT="$BUNDLE/Contents/Resources/ocr_batch_pro.py"

osascript - "$PYTHON" "$SCRIPT" <<'APPLESCRIPT'
on run argv
    set python_path to item 1 of argv
    set script_path to item 2 of argv
    tell application "Terminal"
        activate
        do script quoted form of python_path & " " & quoted form of script_path
    end tell
end run
APPLESCRIPT
LAUNCHER

chmod +x "$MACOS/OCR PDF Converter"

# Info.plist
cat > "$BUNDLE/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>OCR PDF Converter</string>
    <key>CFBundleIdentifier</key>
    <string>com.personal.ocr-converter-cli</string>
    <key>CFBundleName</key>
    <string>OCR PDF Converter</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>10.13</string>
</dict>
</plist>
PLIST

xattr -d -r com.apple.quarantine "$BUNDLE" 2>/dev/null || true

echo "✅ Done!"
echo ""
echo "📦 App: /Applications/OCR PDF Converter.app"
echo ""
echo "To use:"
echo "  1. Right-click 'OCR PDF Converter' in Applications"
echo "  2. Select 'Open' (or just double-click)"
echo "  3. Terminal opens with the app"
echo ""
