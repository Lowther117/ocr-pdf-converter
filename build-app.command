#!/bin/bash
# OPTIONAL: build a standalone "OCR PDF Converter.app" that runs without
# Python, and with Tesseract and Poppler carried inside it where possible.
# The normal run.command setup is unchanged by this.
#
# Everything this prints is also written to build-mac-log.txt, and the built
# app is tested before this script claims success.

cd "$(dirname "$0")" || exit 1
LOG="build-mac-log.txt"
: > "$LOG"
exec > >(tee -a "$LOG") 2>&1

VENV=".venv-build-mac"
PY="$VENV/bin/python"
NAME="OCR PDF Converter"
APP="dist/$NAME.app"
BIN="$APP/Contents/MacOS/$NAME"

say()  { printf '\n== %s\n' "$1"; }
note() { printf '   %s\n' "$1"; }
fail() { printf '\nBuild stopped: %s\nFull log: %s/%s\n' "$1" "$PWD" "$LOG"; exit 1; }

printf 'OCR PDF Converter standalone build - %s\n' "$(date)"
printf 'macOS %s on %s\n' "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)"

# --------------------------------------------------------------------------
# Homebrew - where a bundle-able Python and any external tools come from.
#
# A double-clicked .command starts with a bare PATH, so Homebrew's folders are
# added by hand, and Homebrew itself is installed if the Mac has none (its
# installer asks for the Mac password once, in this window).
# --------------------------------------------------------------------------
export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

ensure_brew() {
    command -v brew >/dev/null 2>&1 && return 0
    say "Installing Homebrew"
    echo "   This asks for your Mac password once, then takes a few minutes."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" < /dev/tty
    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
    command -v brew >/dev/null 2>&1
}

# brew_install <formula>... - installs each one (a formula that is already
# there is a no-op). Non-zero if Homebrew is unavailable or an install failed.
brew_install() {
    ensure_brew || { echo "   Homebrew is not available, so $* cannot be installed automatically."; return 1; }
    local f rc=0
    for f in "$@"; do
        echo "   brew install $f"
        HOMEBREW_NO_AUTO_UPDATE=1 brew install "$f" < /dev/null || rc=1
    done
    return $rc
}

# --------------------------------------------------------------------------
# 1. Pick an interpreter that can actually be bundled.
#
# Apple's /usr/bin/python3 is tied to the system Tcl/Tk 8.5 frameworks, which
# do not survive being copied into an app bundle - the build succeeds and the
# app then dies on launch with no window and no message. The file pickers are
# Tk, so a Python with its own Tk 8.6 is required and the system one is
# refused by name.
# --------------------------------------------------------------------------
say "Choosing a Python to build with"

tk_version() {   # prints e.g. 8.6, or nothing if tkinter is unusable
    "$1" -c 'import tkinter;print(tkinter.TkVersion)' 2>/dev/null
}

CANDIDATES=()
[ -n "$OCR_BUILD_PYTHON" ] && CANDIDATES+=("$OCR_BUILD_PYTHON")
for v in 3.14 3.13 3.12 3.11 3.10 3.9; do
    CANDIDATES+=("/opt/homebrew/bin/python$v" "/usr/local/bin/python$v" \
                 "/Library/Frameworks/Python.framework/Versions/$v/bin/python3")
done
CANDIDATES+=("$(command -v python3 2>/dev/null)")

pick_python() {
CHOSEN=""
for c in "${CANDIDATES[@]}"; do
    [ -n "$c" ] && [ -x "$c" ] || continue
    # readlink, not python: on a fresh Mac the only "python3" is Apple's stub,
    # and merely running it pops up the Xcode command-line-tools installer.
    real="$(readlink -f "$c" 2>/dev/null || echo "$c")"
    case "$real" in
        /usr/bin/python3|/Library/Developer/CommandLineTools/*|/Applications/Xcode.app/*)
            note "skipping $c - Apple system Python, its Tk cannot be bundled"
            continue ;;
    esac
    tkv="$(tk_version "$c")"
    if [ -z "$tkv" ]; then
        note "skipping $c - no working tkinter"
        continue
    fi
    case "$tkv" in
        8.6|8.7|9.*) CHOSEN="$c"; note "using $c (Tk $tkv)"; break ;;
        *) note "skipping $c - Tk $tkv is too old to bundle" ;;
    esac
done
}
pick_python

if [ -z "$CHOSEN" ]; then
    echo "   None of the Pythons here can be bundled - adding one with Homebrew."
    echo "   (a Python with its own Tk 8.6; Apple's own /usr/bin/python3 does not qualify.)"
    if brew_install python python-tk; then
        pick_python
    fi
fi

if [ -z "$CHOSEN" ]; then
    cat <<'MSG'

None of the Pythons on this Mac can be used to build the app.

The app needs a Python that carries its own Tk 8.6 - the file pickers are Tk.
The one Apple ships (/usr/bin/python3) uses the system Tk 8.5, which cannot be
copied into an app bundle; that is why a build can finish and the app still
not open.

Install one of these, then run this again:

    brew install python python-tk          (Homebrew - simplest)
    https://www.python.org/downloads/macos/ (official installer)

If you already have one somewhere unusual, point this script at it:

    OCR_BUILD_PYTHON=/path/to/python3 ./build-app.command

Nothing else on this Mac is affected - run.command keeps working exactly as
before whether or not you ever build the app.
MSG
    fail "no suitable Python found"
fi

# --------------------------------------------------------------------------
# 2. Build environment
#
# --only-binary :all: everywhere: a package with no wheel for this Mac then
# fails in seconds instead of trying to compile itself.
# --------------------------------------------------------------------------
say "Build environment"
if [ ! -x "$PY" ]; then
    "$CHOSEN" -m venv "$VENV" || fail "could not create the build environment"
elif ! "$PY" -c 'import sys' >/dev/null 2>&1; then
    # a venv built by a different (or since moved) Python is worse than none
    rm -rf "$VENV"
    "$CHOSEN" -m venv "$VENV" || fail "could not recreate the build environment"
fi
"$PY" -m pip install --upgrade pip --quiet
"$PY" -m pip install --upgrade --only-binary :all: pyinstaller \
    || fail "could not install PyInstaller"

say "Components to bake in"
"$PY" -m pip install --only-binary :all: -r requirements.txt \
    || fail "could not install the converter's own packages"
note "pdf2image, pytesseract, opencv, numpy, pillow, python-docx"

# --------------------------------------------------------------------------
# 3. The two external programs.
#
# Baking these in is the whole point of a standalone app: the person opening
# it should not need Homebrew. They are taken from Homebrew's copies here -
# installed first if this Mac lacks them - because there is no portable Mac
# build to download.
#
# A copied binary can still fail to start on a Mac that has no Homebrew, if
# PyInstaller could not rewrite every library reference. The app checks that
# what it carries actually runs before using it and falls back to whatever is
# on PATH, so a half-relocated copy costs nothing.
# --------------------------------------------------------------------------
say "Tesseract and Poppler"

offer_brew() {   # offer_brew <formula> <what it does> - adds it, no questions asked
    note "$1 ($2) is not installed - adding it with Homebrew so it can be baked in."
    brew_install "$1" && return 0
    note "Continuing without it - the app will look for $1 when it runs."
    return 1
}

ADD=()

# "brew --prefix <formula>" answers even for a formula that is not installed,
# so what matters is whether the binary is actually there.
brew_prefix() { command -v brew >/dev/null 2>&1 && brew --prefix "$1" 2>/dev/null; }

POPPLER_BIN=""
BREWED="$(brew_prefix poppler)"
if [ -n "$BREWED" ] && [ -x "$BREWED/bin/pdftoppm" ]; then
    POPPLER_BIN="$BREWED/bin"
elif command -v pdftoppm >/dev/null 2>&1; then
    POPPLER_BIN="$(dirname "$(command -v pdftoppm)")"
elif offer_brew poppler "turns PDF pages into images"; then
    POPPLER_BIN="$(brew_prefix poppler)/bin"
fi
if [ -n "$POPPLER_BIN" ] && [ -x "$POPPLER_BIN/pdftoppm" ]; then
    for tool in pdftoppm pdftocairo pdfinfo; do
        [ -x "$POPPLER_BIN/$tool" ] && ADD+=(--add-binary "$POPPLER_BIN/$tool:tools/poppler")
    done
    note "poppler from $POPPLER_BIN"
else
    note "WARNING: building without poppler - the app will need it installed."
fi

TESS_PREFIX=""
BREWED="$(brew_prefix tesseract)"
if [ -n "$BREWED" ] && [ -x "$BREWED/bin/tesseract" ]; then
    TESS_PREFIX="$BREWED"
elif command -v tesseract >/dev/null 2>&1; then
    TESS_PREFIX="$(dirname "$(dirname "$(command -v tesseract)")")"
elif offer_brew tesseract "reads the text off the page"; then
    TESS_PREFIX="$(brew_prefix tesseract)"
fi
if [ -n "$TESS_PREFIX" ] && [ -x "$TESS_PREFIX/bin/tesseract" ]; then
    ADD+=(--add-binary "$TESS_PREFIX/bin/tesseract:tools/tesseract")
    if [ -d "$TESS_PREFIX/share/tessdata" ]; then
        # Without its language data beside it a copied tesseract fails with
        # "Error opening data file"; the app points TESSDATA_PREFIX here.
        ADD+=(--add-data "$TESS_PREFIX/share/tessdata:tools/tesseract/tessdata")
    else
        note "WARNING: no tessdata found beside tesseract."
    fi
    note "tesseract from $TESS_PREFIX"
else
    note "WARNING: building without tesseract - the app will need it installed."
fi

# --------------------------------------------------------------------------
# 4. Build
# --------------------------------------------------------------------------
say "Building (a few minutes)"
rm -rf build dist "$NAME.spec"
"$PY" -m PyInstaller --noconfirm --clean --windowed --name "$NAME" \
    --osx-bundle-identifier com.lowther.ocrpdfconverter \
    --collect-data docx \
    "${ADD[@]}" \
    ocr_batch_pro.py \
    || fail "PyInstaller failed - the messages above say why"

[ -x "$BIN" ] || fail "the build finished but $APP is not there"

# --------------------------------------------------------------------------
# 5. Make it launchable.
#
# An ad-hoc signature is what lets a locally built app open at all on Apple
# silicon, and stray extended attributes invalidate it.
# --------------------------------------------------------------------------
say "Signing"
xattr -cr "$APP" 2>/dev/null || true
if command -v codesign >/dev/null 2>&1; then
    codesign --force --deep --sign - --timestamp=none "$APP" \
        && codesign --verify --deep --strict "$APP" \
        && note "ad-hoc signature ok" \
        || note "WARNING: signing did not complete - the app may be blocked on first open"
else
    note "codesign not available (install the Xcode command line tools)"
fi

# --------------------------------------------------------------------------
# 6. Prove it runs before saying it works.
# --------------------------------------------------------------------------
say "Testing the built app"
rm -f "dist/ocr-selftest.txt"
if "$BIN" selftest; then
    RESULT=ok
else
    RESULT=problems
fi

echo
if [ "$RESULT" = ok ]; then
    cat <<MSG
Done: $PWD/$APP

Move it wherever you like. It writes nothing inside itself - the converted
files go wherever you choose in the app - so Applications is fine.

Opened from the Finder it has no Terminal window, so it asks its questions in
dialogs instead. Anything it could not bake in it looks for on the Mac it is
opened on.
MSG
else
    cat <<MSG
The app was built but the self-test above found problems, so it may not work
properly. The report is in $PWD/dist/ocr-selftest.txt and the whole run is in
$PWD/$LOG.
MSG
fi
echo "Log: $PWD/$LOG"
