#!/usr/bin/env python3
"""
OCR PDF Converter - Batch Processing

Batch-converts scanned PDFs to Word (.docx) or plain text (.txt) using OCR.
Runs on macOS, Windows and Linux: file pickers come from Tk (bundled with
Python), and the two external binaries - Tesseract and Poppler - are located
per platform at start-up rather than assumed to be on PATH.

    ocr_batch_pro.py             convert some PDFs
    ocr_batch_pro.py selftest    report what this copy can and cannot do

The self-test is what build-exe.bat / build-app.command run before either
claims a standalone build worked.
"""

import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import traceback
from pathlib import Path

# Colours for the Tk dialogs (theme.py beside this file). It imports tkinter
# itself, so on a Python with no Tk it is simply absent - the typed prompts
# below need no colours.
try:
    import theme
except Exception:
    theme = None

IS_WINDOWS = sys.platform.startswith("win")
IS_MAC = sys.platform == "darwin"

# When its output is redirected (run.bat > log.txt) Windows writes the console
# in the locale code page, and the first emoji below would then stop the whole
# run with a UnicodeEncodeError. A "?" for what cannot be shown is fine here -
# the converted files are written as UTF-8 regardless.
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(errors="replace")
    except Exception:
        pass


def _app_dir():
    """The folder this app treats as its own - where ./tools sits and where
    anything it writes for itself goes.

    Normally that is the folder holding this script. In a standalone build it
    is the folder holding the exe. On macOS the executable sits three levels
    down inside "OCR PDF Converter.app", and writing inside a bundle breaks its
    code signature (the next launch is then killed), so the folder *containing*
    the .app is used instead.
    """
    if not getattr(sys, "frozen", False):
        return os.path.dirname(os.path.realpath(__file__))
    exe_dir = os.path.dirname(os.path.realpath(sys.executable))
    parts = exe_dir.split(os.sep)
    if (sys.platform == "darwin" and len(parts) >= 3
            and parts[-1] == "MacOS" and parts[-2] == "Contents"
            and parts[-3].endswith(".app")):
        return os.path.dirname(os.path.dirname(os.path.dirname(exe_dir)))
    return exe_dir


def _startup_failure(exc, report_name="ocr-startup-error.txt",
                     title="OCR PDF Converter could not start"):
    """Leave a note about a start-up failure, and show it if Tk still works.

    Only a standalone build reaches this: it means a component that should
    have been baked in was not. Such a build has no console and, on macOS, no
    window either - without this it would simply vanish when double-clicked.
    The same routine reports a crash later in the run (see the bottom of the
    file), under a different file name.
    """
    text = "".join(traceback.format_exception(type(exc), exc, exc.__traceback__))
    report = os.path.join(_app_dir(), report_name)
    for attempt in (report, os.path.join(tempfile.gettempdir(), report_name)):
        try:
            with open(attempt, "w", encoding="utf-8") as fh:
                fh.write(text)
            report = attempt
            break
        except Exception:
            report = "(could not be written)"
    if sys.stderr is not None:   # None in a windowed build
        sys.stderr.write(text)
    try:
        import tkinter
        from tkinter import messagebox
        root = tkinter.Tk()
        root.withdraw()
        messagebox.showerror(
            title,
            "{}\n\nFull details: {}".format(
                text.strip().splitlines()[-1], report))
        root.destroy()
    except Exception:
        pass
    raise SystemExit(1)


# The packages pip installs. In a standalone build a missing one means the
# build itself was incomplete, so say which one rather than disappearing.
try:
    import pdf2image
    import pytesseract
    import cv2
    import numpy as np
    from PIL import Image
    from docx import Document
    from docx.enum.text import WD_ALIGN_PARAGRAPH
except Exception as _import_error:
    if getattr(sys, "frozen", False):
        _startup_failure(_import_error)
    raise


# --------------------------------------------------------------------------- #
# Locating the two external binaries.
#
# On macOS and Linux a package manager puts these on PATH. On Windows the
# installers do not touch PATH by default, so the usual install locations are
# checked explicitly - otherwise the failure is an opaque error from deep
# inside pytesseract or pdf2image rather than something a person can act on.
# --------------------------------------------------------------------------- #

APP_DIR = Path(_app_dir())

# Where a copy of tesseract or poppler that came with this app would be:
#   - sys._MEIPASS/tools in a standalone build, which is where PyInstaller
#     unpacks what build-exe.bat / build-app.command baked in
#   - ./tools beside the app, which is where setup.ps1 puts the portable
#     poppler on Windows
# Either is preferred to anything on PATH - a tool that came with the app is
# the one this copy was set up with, and its version is known.
TOOLS_DIRS = []
if getattr(sys, "_MEIPASS", None):
    TOOLS_DIRS.append(Path(sys._MEIPASS) / "tools")
TOOLS_DIRS.append(APP_DIR / "tools")

# Stops a stray console window flashing up on Windows when a tool is checked.
_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


def _runs(exe_path):
    """True if this executable actually starts.

    A bundled binary can be present and still be useless - a copied Homebrew
    binary whose libraries did not travel with it, for instance. One quick
    subprocess here turns a baffling failure halfway through a conversion into
    a quiet fall back to the system copy.
    """
    try:
        result = subprocess.run([exe_path, "-v"],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                timeout=20,
                                creationflags=_NO_WINDOW)
        return result.returncode in (0, 1)
    except Exception:
        return False


def _in_tools(exe_name):
    """First working copy of an executable in the folders above, or None."""
    for base in TOOLS_DIRS:
        try:
            if not base.is_dir():
                continue
            for found in sorted(base.rglob(exe_name)):
                if found.is_file() and _runs(str(found)):
                    return str(found)
        except Exception:
            continue
    return None


def _is_bundled(path):
    """True if this tool came with the app rather than from the system."""
    if not path:
        return False
    try:
        resolved = Path(path).resolve()
    except Exception:
        return False
    for base in TOOLS_DIRS:
        try:
            resolved.relative_to(base.resolve())
            return True
        except Exception:
            continue
    return False


def _tool_version(exe_path):
    """First line of a tool's own version output. Used by the self-test."""
    if not exe_path:
        return "not found"
    try:
        result = subprocess.run([exe_path, "-v"], capture_output=True, text=True,
                                timeout=20, creationflags=_NO_WINDOW)
        for line in ((result.stdout or "") + (result.stderr or "")).splitlines():
            if line.strip():
                return line.strip()
    except Exception as exc:
        return "could not be asked ({})".format(exc)
    return "unknown"


TESSERACT_CANDIDATES = [
    r"C:\Program Files\Tesseract-OCR\tesseract.exe",
    r"C:\Program Files (x86)\Tesseract-OCR\tesseract.exe",
    os.path.join(os.environ.get("LOCALAPPDATA", ""),
                 "Programs", "Tesseract-OCR", "tesseract.exe"),
    "/opt/homebrew/bin/tesseract",
    "/usr/local/bin/tesseract",
    "/usr/bin/tesseract",
]

# The Windows poppler build unzips to a version-stamped folder such as
# "poppler-26.02.0", so the Windows locations are globbed rather than listed.
POPPLER_BIN_GLOBS = [
    r"C:\Program Files\poppler*\Library\bin",
    r"C:\Program Files\poppler*\bin",
    r"C:\poppler*\Library\bin",
    r"C:\poppler*\bin",
]

POPPLER_BIN_CANDIDATES = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    "/usr/bin",
]

POPPLER_PATH = None   # passed to pdf2image when the binaries are not on PATH


def _bundled_tessdata(exe_path):
    """The language data that shipped beside a bundled tesseract, if any.

    A copied tesseract has no idea where its tessdata folder went and fails
    with "Error opening data file" unless TESSDATA_PREFIX points at it.
    """
    here = Path(exe_path).resolve().parent
    for candidate in (here / "tessdata", here.parent / "tessdata",
                      here.parent / "share" / "tessdata"):
        try:
            if (candidate / "eng.traineddata").is_file():
                return str(candidate)
        except Exception:
            continue
    return None


def _find_tesseract():
    exe = "tesseract.exe" if IS_WINDOWS else "tesseract"
    bundled = _in_tools(exe)
    if bundled:
        data = _bundled_tessdata(bundled)
        if data:
            os.environ["TESSDATA_PREFIX"] = data
        return bundled
    return (shutil.which("tesseract")
            or next((c for c in TESSERACT_CANDIDATES if os.path.isfile(c)), None))


def _find_poppler_bin():
    """Return the folder holding pdftoppm, None if it is already on PATH, or
    the string "MISSING" if it cannot be found at all."""
    exe_name = "pdftoppm.exe" if IS_WINDOWS else "pdftoppm"
    local = _in_tools(exe_name)
    if local:
        return os.path.dirname(local)
    if shutil.which("pdftoppm") or shutil.which("pdftoppm.exe"):
        return None
    exe = "pdftoppm.exe" if IS_WINDOWS else "pdftoppm"
    candidates = list(POPPLER_BIN_CANDIDATES)
    if IS_WINDOWS:
        import glob
        for pattern in POPPLER_BIN_GLOBS:
            candidates = sorted(glob.glob(pattern), reverse=True) + candidates
    for d in candidates:
        if os.path.isfile(os.path.join(d, exe)):
            return d
    return "MISSING"


def check_dependencies():
    """Fail early, with an instruction the person can actually follow."""
    global POPPLER_PATH
    problems = []

    tess = _find_tesseract()
    if tess:
        pytesseract.pytesseract.tesseract_cmd = tess
    else:
        if IS_WINDOWS:
            problems.append(
                "Tesseract OCR was not found.\n"
                "    Install it:  winget install -e --id UB-Mannheim.TesseractOCR\n"
                "    (or download the installer from "
                "https://github.com/UB-Mannheim/tesseract/wiki)")
        elif IS_MAC:
            problems.append("Tesseract OCR was not found.\n"
                            "    Install it:  brew install tesseract")
        else:
            problems.append("Tesseract OCR was not found.\n"
                            "    Install it:  sudo apt install tesseract-ocr")

    poppler = _find_poppler_bin()
    if poppler == "MISSING":
        if IS_WINDOWS:
            problems.append(
                "Poppler was not found (needed to turn PDF pages into images).\n"
                "    Download the latest release from "
                "https://github.com/oschwartz10612/poppler-windows/releases\n"
                "    and unzip it to C:\\Program Files\\poppler")
        elif IS_MAC:
            problems.append("Poppler was not found.\n"
                            "    Install it:  brew install poppler")
        else:
            problems.append("Poppler was not found.\n"
                            "    Install it:  sudo apt install poppler-utils")
    else:
        POPPLER_PATH = poppler   # None means "already on PATH"

    if problems:
        notify("OCR PDF Converter - missing requirements",
               "Missing requirements:\n\n"
               + "\n\n".join("  - " + p for p in problems))
        return False
    return True


class OCRConverter:
    """Handles PDF → OCR → Word/TXT/Pages conversion with batch support."""

    def __init__(self, output_format, preprocess, denoise_strength, threshold_value):
        self.output_format = output_format
        self.preprocess = preprocess
        self.denoise_strength = denoise_strength
        self.threshold_value = threshold_value
        self.last_error = None   # why the most recent file failed, for the summary
        self._written = set()    # output paths already used in this run

    def _output_path(self, output_dir, pdf_name, ext):
        """Two PDFs with the same name from different folders must not share
        one output file - the second used to overwrite the first silently."""
        candidate = os.path.join(output_dir, f"{pdf_name}_OCR{ext}")
        n = 2
        while os.path.normcase(candidate) in self._written:
            candidate = os.path.join(output_dir, f"{pdf_name}_OCR ({n}){ext}")
            n += 1
        return candidate

    def preprocess_image(self, image):
        """Apply denoise and threshold to image."""
        try:
            cv_image = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2BGR)
            gray = cv2.cvtColor(cv_image, cv2.COLOR_BGR2GRAY)

            if self.denoise_strength > 0:
                denoised = cv2.fastNlMeansDenoising(
                    gray,
                    h=self.denoise_strength,
                    templateWindowSize=7,
                    searchWindowSize=21
                )
            else:
                denoised = gray

            if self.threshold_value > 0:
                # OpenCV demands an odd block size greater than 1. An even
                # number typed at the prompt used to raise here, and the whole
                # cleanup step was then silently skipped for every page.
                block = max(3, int(self.threshold_value) | 1)
                thresholded = cv2.adaptiveThreshold(
                    denoised,
                    255,
                    cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
                    cv2.THRESH_BINARY,
                    blockSize=block,
                    C=2
                )
            else:
                thresholded = denoised

            return Image.fromarray(thresholded)
        except Exception as e:
            print(f"⚠️  Preprocessing error: {str(e)}")
            return image

    def extract_text(self, pdf_path):
        """Extract text from PDF, one page at a time.

        Rendering every page up front (convert_from_path with no page range)
        held the whole document in memory at 300 dpi - about 25 MB a page - and
        a few hundred pages was enough for the process to be killed with no
        message. One page at a time keeps memory flat however long the PDF is.
        """
        try:
            print(f"  📄 Loading: {Path(pdf_path).name}")
            kw = {'dpi': 300, 'fmt': 'ppm'}
            if POPPLER_PATH:
                kw['poppler_path'] = POPPLER_PATH
            info = pdf2image.pdfinfo_from_path(pdf_path, poppler_path=POPPLER_PATH)
            total_pages = int(info.get("Pages", 0))
            print(f"  ✓ {total_pages} pages")

            extracted_pages = []
            failed = 0
            last_error = None

            for page_num in range(1, total_pages + 1):
                page = image = None
                try:
                    page = pdf2image.convert_from_path(
                        pdf_path, first_page=page_num, last_page=page_num, **kw)[0]
                    image = self.preprocess_image(page) if self.preprocess else page
                    text = pytesseract.image_to_string(image)
                    extracted_pages.append({
                        'page_num': page_num,
                        # a blank page comes back as whitespace and a form feed
                        'text': (text or "").strip() or "[No text detected]"
                    })
                    print(f"  ✓ page {page_num}/{total_pages}", flush=True)
                except Exception as e:
                    # Say what went wrong: a silent "[OCR failed]" on every
                    # page used to look like a bad scan when it was a missing
                    # tesseract or its language data.
                    failed += 1
                    last_error = e
                    print(f"  ⚠️  Page {page_num}: {e}")
                    extracted_pages.append({
                        'page_num': page_num,
                        'text': f"[OCR failed: {e}]"
                    })
                finally:
                    for im in (image, page):
                        if im is not None:
                            im.close()

            if total_pages and failed == total_pages:
                raise RuntimeError(f"no page could be read - {last_error}")
            return extracted_pages
        except Exception as e:
            self.last_error = str(e)
            print(f"  ❌ Error: {str(e)}")
            return None

    def save_as_docx(self, pdf_path, output_dir, extracted_pages):
        """Save as Word document."""
        try:
            doc = Document()
            pdf_name = Path(pdf_path).stem

            title = doc.add_heading('OCR Conversion Report', level=0)
            title.alignment = WD_ALIGN_PARAGRAPH.CENTER

            meta = doc.add_paragraph(f"Source: {pdf_name}\nPages: {len(extracted_pages)}")
            meta.alignment = WD_ALIGN_PARAGRAPH.CENTER
            doc.add_paragraph()

            for index, page_data in enumerate(extracted_pages):
                if index:
                    doc.add_page_break()   # page N of the scan is page N here
                doc.add_heading(f'Page {page_data["page_num"]}', level=2)
                # A blank line in Tesseract's output is a paragraph break, so
                # the Word file gets real paragraphs rather than one block per
                # page held together by line breaks.
                text = page_data['text']
                blocks = [b.strip() for b in re.split(r'\n\s*\n', text) if b.strip()]
                for block in blocks or [text]:
                    doc.add_paragraph(block)

            output_file = self._output_path(output_dir, pdf_name, ".docx")
            doc.save(output_file)
            self._written.add(os.path.normcase(output_file))
            return output_file
        except Exception as e:
            self.last_error = f"could not save the Word file - {e}"
            print(f"  ❌ Error saving DOCX: {str(e)}")
            return None

    def save_as_txt(self, pdf_path, output_dir, extracted_pages):
        """Save as plain text."""
        try:
            pdf_name = Path(pdf_path).stem
            output_file = self._output_path(output_dir, pdf_name, ".txt")

            with open(output_file, 'w', encoding='utf-8') as f:
                f.write(f"OCR Conversion: {pdf_name}\n")
                f.write(f"Pages: {len(extracted_pages)}\n")
                f.write("=" * 80 + "\n\n")

                for page_data in extracted_pages:
                    f.write(f"--- Page {page_data['page_num']} ---\n")
                    f.write(page_data['text'])
                    f.write("\n\n")

            self._written.add(os.path.normcase(output_file))
            return output_file
        except Exception as e:
            self.last_error = f"could not save the text file - {e}"
            print(f"  ❌ Error saving TXT: {str(e)}")
            return None


    def convert_pdf(self, pdf_path, output_dir):
        """Convert a single PDF."""
        extracted_pages = self.extract_text(pdf_path)
        if not extracted_pages:
            return None

        if self.output_format == 'Word (.docx)':
            return self.save_as_docx(pdf_path, output_dir, extracted_pages)
        elif self.output_format == 'Plain Text (.txt)':
            return self.save_as_txt(pdf_path, output_dir, extracted_pages)


# --------------------------------------------------------------------------- #
# File pickers.
#
# Tk ships with Python on every platform, so one dialog implementation works
# everywhere. If Tk is genuinely unavailable (a stripped Linux Python, a
# headless session) the prompts fall back to typed paths rather than failing.
# --------------------------------------------------------------------------- #

# The one thing this app remembers between runs: whether its dialogs are dark
# (the default) or light. Kept in a small JSON beside the app, next to the
# self-test report; a read-only app folder falls back to the home folder.
SETTINGS_NAME = "ocr-settings.json"


def _settings_path():
    beside = APP_DIR / SETTINGS_NAME
    if beside.is_file() or os.access(str(APP_DIR), os.W_OK):
        return beside
    return Path.home() / SETTINGS_NAME


def _load_settings():
    try:
        with open(_settings_path(), "r", encoding="utf-8") as fh:
            data = json.load(fh)
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _save_settings(settings):
    try:
        with open(_settings_path(), "w", encoding="utf-8") as fh:
            json.dump(settings, fh, indent=2)
    except Exception:
        pass   # a colour preference is not worth stopping for


SETTINGS = _load_settings()
DARK = bool(SETTINGS.get("dark", True))

# Classic tk widgets take no notice of ttk styles, so each kind is coloured
# from the palette by hand: option-database entries for widgets not yet made
# (the simpledialog/messagebox windows are built after the root) and a walk
# over the live ones when the theme is switched.
_CLASSIC = {
    "Toplevel": lambda c: dict(background=c["bg"]),
    "Tk": lambda c: dict(background=c["bg"]),
    "Frame": lambda c: dict(background=c["bg"]),
    "Labelframe": lambda c: dict(background=c["bg"], foreground=c["text"]),
    "Label": lambda c: dict(background=c["bg"], foreground=c["text"]),
    "Message": lambda c: dict(background=c["bg"], foreground=c["text"]),
    "Entry": lambda c: dict(
        background=c["field"], foreground=c["field_text"],
        insertbackground=c["accent"], selectbackground=c["sel"],
        selectforeground=c["field_text"], readonlybackground=c["panel"],
        disabledbackground=c["bg"], disabledforeground=c["dim"],
        highlightbackground=c["field_border"], highlightcolor=c["accent"],
        highlightthickness=1),
    "Spinbox": lambda c: dict(
        background=c["field"], foreground=c["field_text"],
        insertbackground=c["accent"], selectbackground=c["sel"],
        selectforeground=c["field_text"], buttonbackground=c["panel"],
        highlightbackground=c["field_border"], highlightcolor=c["accent"],
        highlightthickness=1),
    "Text": lambda c: dict(
        background=c["field"], foreground=c["field_text"],
        insertbackground=c["accent"], selectbackground=c["sel"],
        selectforeground=c["field_text"],
        highlightbackground=c["field_border"], highlightcolor=c["accent"],
        highlightthickness=1),
    "Listbox": lambda c: dict(
        background=c["field"], foreground=c["field_text"],
        selectbackground=c["sel"], selectforeground=c["field_text"],
        highlightbackground=c["field_border"], highlightcolor=c["accent"],
        highlightthickness=1),
    "Canvas": lambda c: dict(background=c["panel"],
                             highlightbackground=c["border"]),
    "Button": lambda c: dict(
        background=c["panel"], foreground=c["text"],
        activebackground=c["sel"], activeforeground=c["text"],
        disabledforeground=c["dim"],
        highlightbackground=c["field_border"], highlightcolor=c["accent"],
        highlightthickness=1),
    "Checkbutton": lambda c: dict(
        background=c["bg"], foreground=c["text"], activebackground=c["bg"],
        activeforeground=c["text"], selectcolor=c["field"]),
    "Radiobutton": lambda c: dict(
        background=c["bg"], foreground=c["text"], activebackground=c["bg"],
        activeforeground=c["text"], selectcolor=c["field"]),
    "Scale": lambda c: dict(background=c["bg"], foreground=c["text"],
                            troughcolor=c["field"], activebackground=c["sel"],
                            highlightbackground=c["bg"]),
    "Scrollbar": lambda c: dict(background=c["panel"], troughcolor=c["bg"],
                                activebackground=c["sel"]),
    "Menu": lambda c: dict(background=c["panel"], foreground=c["text"],
                           activebackground=c["sel"], activeforeground=c["text"],
                           disabledforeground=c["dim"]),
}

# Tk option-database names for the same settings (camelCase, not lowercase).
_OPTION_NAMES = {
    "insertbackground": "insertBackground", "selectbackground": "selectBackground",
    "selectforeground": "selectForeground", "readonlybackground": "readonlyBackground",
    "disabledbackground": "disabledBackground", "disabledforeground": "disabledForeground",
    "highlightbackground": "highlightBackground", "highlightcolor": "highlightColor",
    "highlightthickness": "highlightThickness", "activebackground": "activeBackground",
    "activeforeground": "activeForeground", "buttonbackground": "buttonBackground",
    "troughcolor": "troughColor", "selectcolor": "selectColor",
}


def _recolour(widget, c):
    """Colour one classic widget and everything under it. Read-only Text
    (a log) sits on the panel colour rather than the field colour."""
    opts = _CLASSIC.get(widget.winfo_class())
    if opts:
        opts = opts(c)
        try:
            if widget.winfo_class() == "Text" and widget.cget("state") == "disabled":
                opts["background"] = c["panel"]
        except Exception:
            pass
        for key, value in opts.items():
            try:
                widget.configure({key: value})
            except Exception:
                continue   # macOS ignores a few of these; nothing to do about it
    for child in widget.winfo_children():
        _recolour(child, c)


def _apply_theme(root):
    """Dark or light, for the root and every window it opens."""
    if theme is None:
        return
    try:
        c = theme.apply(root, DARK)
        for cls, opts in _CLASSIC.items():
            for key, value in opts(c).items():
                root.option_add("*{}.{}".format(cls, _OPTION_NAMES.get(key, key)), value)
        _recolour(root, c)
        root.bind_all("<Control-d>", _toggle_theme)
        root.bind_all("<Control-D>", _toggle_theme)
    except Exception:
        pass   # colours are a nicety; the dialogs work without them


def _toggle_theme(event=None):
    """Ctrl+D in any dialog: switch between dark and light, and remember."""
    global DARK
    DARK = not DARK
    SETTINGS["dark"] = DARK
    _save_settings(SETTINGS)
    widget = getattr(event, "widget", None)
    if widget is None:
        return
    root = widget
    while getattr(root, "master", None) is not None:
        root = root.master
    _apply_theme(root)


def _tk_root():
    """A hidden Tk root, or None if Tk cannot start here."""
    try:
        import tkinter as tk
        root = tk.Tk()
        root.withdraw()
        _apply_theme(root)
        root.update()
        try:
            root.attributes("-topmost", True)   # dialogs above the console
        except Exception:
            pass
        return root
    except Exception:
        return None


def pick_pdfs():
    """Pick one or more PDFs. Returns a list of paths (empty if cancelled)."""
    root = _tk_root()
    if root is not None:
        try:
            from tkinter import filedialog
            chosen = filedialog.askopenfilenames(
                title="Select PDF file(s)",
                filetypes=[("PDF files", "*.pdf"), ("All files", "*.*")],
            )
            if isinstance(chosen, str):   # some Tk builds hand back one string
                chosen = root.tk.splitlist(chosen)
            return list(chosen)
        finally:
            root.destroy()

    typed = input("  Path to a PDF (or a folder of PDFs): ").strip().strip('"\'')
    if not typed:
        return []
    path = Path(typed).expanduser()
    if path.is_dir():
        # not glob("*.pdf"): that is case-sensitive, and scanners write ".PDF"
        return [str(f) for f in sorted(path.iterdir())
                if f.is_file() and f.suffix.lower() == ".pdf"]
    return [str(path)] if path.is_file() else []


def _downloads_dir():
    """The user's Downloads folder. Windows can move it, so ask the shell;
    everywhere else (and if the shell will not say) it is ~/Downloads."""
    if IS_WINDOWS:
        try:
            import ctypes
            from ctypes import wintypes
            guid = (ctypes.c_ubyte * 16)()
            ctypes.windll.ole32.CLSIDFromString(
                "{374DE290-123F-4565-9164-39C4925E467B}", guid)   # FOLDERID_Downloads
            out = ctypes.c_wchar_p()
            if ctypes.windll.shell32.SHGetKnownFolderPath(
                    guid, wintypes.DWORD(0), None, ctypes.byref(out)) == 0:
                path = out.value
                ctypes.windll.ole32.CoTaskMemFree(out)
                if path and os.path.isdir(path):
                    return path
        except Exception:
            pass
    return str(Path.home() / "Downloads")


def default_save_dir():
    """Where output goes unless told otherwise: the remembered folder if it
    still exists, else "OCR Output" inside Downloads, else the home folder."""
    remembered = SETTINGS.get("save_dir")
    if remembered and os.path.isdir(str(remembered)):
        return str(remembered)
    downloads = _downloads_dir()
    if os.path.isdir(downloads):
        return os.path.join(downloads, "OCR Output")
    return str(Path.home())


def pick_output_folder():
    """Pick the output folder, starting from the default. Cancel keeps it."""
    default = default_save_dir()
    root = _tk_root()
    if root is not None:
        try:
            from tkinter import filedialog
            start = default if os.path.isdir(default) else os.path.dirname(default)
            chosen = filedialog.askdirectory(title="Save into", initialdir=start)
            return chosen or default
        finally:
            root.destroy()

    typed = input(f"  Save into (Enter for {default}): ").strip().strip('"\'')
    return str(Path(typed).expanduser()) if typed else default


def remember_output_folder(output_dir):
    """Offer to make a folder that is not the current default the default."""
    if os.path.normcase(os.path.abspath(output_dir)) == \
            os.path.normcase(os.path.abspath(default_save_dir())):
        return
    if ask_yes_no("  Use this folder as the default from now on? (y/n, default n): ",
                  "Use this folder as the default from now on?\n\n" + output_dir,
                  default=False):
        SETTINGS["save_dir"] = output_dir
        _save_settings(SETTINGS)


def open_folder(path):
    """Reveal a folder in the platform's file manager."""
    try:
        if IS_WINDOWS:
            os.startfile(path)                              # noqa: S606
        elif IS_MAC:
            subprocess.run(["open", path], check=False)
        else:
            subprocess.run(["xdg-open", path], check=False)
    except Exception as e:
        print(f"  Could not open the folder automatically ({e}).")
        print(f"  It is here: {path}")


# --------------------------------------------------------------------------- #
# Asking questions with or without a console.
#
# run.bat / run.command start this in a terminal, so the questions below are
# typed answers as they always were. A standalone .app opened from the Finder
# has no terminal at all: input() there reads end-of-file and every question
# would answer itself. When there is no console the same questions are asked
# with Tk dialogs instead.
# --------------------------------------------------------------------------- #

def _has_console():
    if os.environ.get("OCR_FORCE_CONSOLE") == "1":
        return True
    try:
        return sys.stdin is not None and sys.stdin.isatty()
    except Exception:
        return False


CONSOLE = _has_console()


def ask_text(console_prompt, dialog_prompt, default=""):
    """One typed answer, from the console or a dialog."""
    if CONSOLE:
        return input(console_prompt).strip()
    root = _tk_root()
    if root is None:
        return default
    try:
        from tkinter import simpledialog
        answer = simpledialog.askstring(
            "OCR PDF Converter", dialog_prompt, parent=root)
        return (answer or "").strip()
    except Exception:
        return default
    finally:
        root.destroy()


def ask_int(console_prompt, dialog_prompt, default):
    """A number, falling back to the default on anything unreadable."""
    try:
        typed = ask_text(console_prompt, dialog_prompt, "")
        return int(typed) if typed else default
    except Exception:
        return default


def ask_yes_no(console_prompt, dialog_prompt, default=True):
    """Yes or no. Anything other than a leading "n" is a yes, as before."""
    if CONSOLE:
        answer = input(console_prompt).strip().lower()
        if not answer:
            return default
        return not answer.startswith("n")
    root = _tk_root()
    if root is None:
        return default
    try:
        from tkinter import messagebox
        return bool(messagebox.askyesno(
            "OCR PDF Converter", dialog_prompt, parent=root))
    except Exception:
        return default
    finally:
        root.destroy()


def notify(title, message):
    """Say something important where the person will actually see it."""
    print(message)
    if CONSOLE:
        return
    root = _tk_root()
    if root is None:
        return
    try:
        from tkinter import messagebox
        messagebox.showinfo(title, message, parent=root)
    except Exception:
        pass
    finally:
        root.destroy()


def selftest():
    """Report what this copy can actually do, then exit.

    Run by build-exe.bat / build-app.command before either claims success. A
    standalone build has no console of its own, so the report is written to
    ocr-selftest.txt beside the app as well as printed - that file is the one
    to send on when a build misbehaves.
    """
    lines = []

    def say(text=""):
        lines.append(text)
        out = sys.__stdout__
        if out is not None:
            try:
                out.write(text + "\n")
                out.flush()
            except Exception:
                pass

    ok = True
    say("OCR PDF Converter - self-test")
    say("executable : {}".format(sys.executable))
    say("python     : {}".format(sys.version.replace("\n", " ")))
    say("frozen     : {}".format(bool(getattr(sys, "frozen", False))))
    say("app folder : {}".format(APP_DIR))
    say("             writable: {}".format(os.access(str(APP_DIR), os.W_OK)))
    say("tool folders: {}".format(
        ", ".join(str(d) for d in TOOLS_DIRS) or "(none)"))

    try:
        import tkinter
        root = tkinter.Tk()
        say("tk         : {} (patch {})".format(
            tkinter.TkVersion, root.tk.call("info", "patchlevel")))
        root.destroy()
        if float(tkinter.TkVersion) < 8.6:
            ok = False
            say("             PROBLEM: the file dialogs need Tk 8.6 or newer")
    except Exception as exc:
        ok = False
        say("tk         : FAILED - {} (no file dialogs)".format(exc))

    say("packages   :")
    for label, module in (("pdf2image", "pdf2image"),
                          ("pytesseract", "pytesseract"),
                          ("opencv (cleanup)", "cv2"),
                          ("numpy", "numpy"),
                          ("pillow", "PIL"),
                          ("python-docx", "docx")):
        try:
            __import__(module)
            say("  {:<20} yes".format(label))
        except Exception as exc:
            ok = False
            say("  {:<20} FAILED - {}".format(label, exc))

    tess = _find_tesseract()
    if tess:
        say("tesseract  : {}".format(tess))
        say("             {}".format(_tool_version(tess)))
        say("             bundled with the app: {}".format(
            "yes" if _is_bundled(tess) else "no (found on this machine)"))
        say("             tessdata: {}".format(
            os.environ.get("TESSDATA_PREFIX", "tesseract's own")))
    else:
        ok = False
        say("tesseract  : NOT FOUND - no text can be read without it")

    poppler = _find_poppler_bin()
    if poppler == "MISSING":
        ok = False
        say("poppler    : NOT FOUND - PDF pages cannot be turned into images")
    else:
        exe = "pdftoppm.exe" if IS_WINDOWS else "pdftoppm"
        pdftoppm = os.path.join(poppler, exe) if poppler else shutil.which("pdftoppm")
        say("poppler    : {}".format(pdftoppm or "on PATH"))
        say("             {}".format(_tool_version(pdftoppm)))
        say("             bundled with the app: {}".format(
            "yes" if _is_bundled(pdftoppm) else "no (found on this machine)"))

    say("RESULT: {}".format("ok" if ok else "PROBLEMS FOUND"))

    report = os.path.join(str(APP_DIR), "ocr-selftest.txt")
    try:
        with open(report, "w", encoding="utf-8") as fh:
            fh.write("\n".join(lines) + "\n")
        say("report: {}".format(report))
    except Exception as exc:
        say("report could not be written to {} - {}".format(report, exc))
    return 0 if ok else 1


def main(argv=None):
    """Main application."""
    argv = list(sys.argv[1:] if argv is None else argv)

    # macOS hands a Finder-launched .app an extra "-psn_0_12345" argument.
    # Anything that reads arguments has to drop it or the app quits before its
    # first window appears - with no console, and so no way to see why.
    argv = [a for a in argv if not a.startswith("-psn_")]

    if argv and argv[0] == "selftest":
        return selftest()

    print("\n" + "="*70)
    print("  OCR PDF Converter (Batch Processing)")
    print("="*70 + "\n")

    if not check_dependencies():
        print("=" * 70 + "\n")
        return 1

    # Pick PDFs
    print("📁 Select PDF file(s)...")
    pdf_files = pick_pdfs()
    if not pdf_files or pdf_files[0] == '':
        print("❌ No PDFs selected")
        return

    # Pick output folder
    print("📁 Select output folder...")
    output_dir = pick_output_folder()
    try:
        os.makedirs(output_dir, exist_ok=True)   # a typed folder may not exist yet
    except Exception as e:
        notify("OCR PDF Converter", f"Cannot use the output folder:\n{output_dir}\n\n{e}")
        return 1
    remember_output_folder(output_dir)

    # Ask for format
    print("\n📋 Output format:")
    print("  1) Word (.docx)")
    print("  2) Plain Text (.txt)")
    choice = ask_text("  Enter choice (1-2): ",
                      "Output format:\n\n"
                      "    1) Word (.docx)\n"
                      "    2) Plain text (.txt)\n\n"
                      "Enter 1 or 2:")

    formats = {
        '1': 'Word (.docx)',
        '2': 'Plain Text (.txt)'
    }
    output_format = formats.get(choice, 'Word (.docx)')

    # Ask for preprocessing
    preprocess = ask_yes_no(
        "\n🔧 Enable preprocessing? (y/n, default y): ",
        "Clean up the page images before reading them?\n\n"
        "Worth it for faxes, photocopies and phone photos.\n"
        "Makes little difference to a clean 300 dpi scan.",
        default=True)

    denoise = 10
    threshold = 11

    if preprocess:
        denoise = ask_int("  Denoise strength (0-20, default 10): ",
                          "Denoise strength (0-20, 0 to skip):", 10)
        threshold = ask_int("  Threshold block size (0-50, default 11): ",
                            "Threshold block size (0-50, 0 to skip):", 11)

    # Process files
    print("\n" + "="*70)
    converter = OCRConverter(output_format, preprocess, denoise, threshold)

    results = []
    failures = []
    for i, pdf_path in enumerate(pdf_files, 1):
        print(f"\n[{i}/{len(pdf_files)}] Processing...")
        converter.last_error = None
        output_file = converter.convert_pdf(pdf_path, output_dir)
        if output_file:
            print(f"  ✅ Saved: {Path(output_file).name}")
            results.append(output_file)
        else:
            print(f"  ❌ Failed")
            failures.append("{}: {}".format(Path(pdf_path).name,
                                            converter.last_error or "unknown error"))

    # With no console the reasons scrolled past nobody, so they go in the
    # closing dialog too.
    failure_note = ""
    if failures:
        failure_note = "\n\nNot converted:\n" + "\n".join("  - " + f for f in failures)

    # Summary
    print("\n" + "="*70)
    if results:
        print(f"✅ Completed: {len(results)}/{len(pdf_files)} files")
        print(f"📁 Output folder: {output_dir}\n")
        if not CONSOLE:
            notify("OCR PDF Converter",
                   "Converted {} of {} files.\n\nOutput folder:\n{}{}".format(
                       len(results), len(pdf_files), output_dir, failure_note))
        if ask_yes_no("Open output folder? (y/n): ",
                      "Open the output folder?", default=False):
            open_folder(output_dir)
    else:
        notify("OCR PDF Converter", "No files were converted." + failure_note)

    print("="*70 + "\n")
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print("\nStopped.")
        sys.exit(130)
    except Exception as _crash:
        # In a terminal the traceback is enough. A windowed build has no
        # terminal, and would otherwise just disappear.
        if CONSOLE:
            raise
        _startup_failure(_crash, "ocr-error.txt",
                         "OCR PDF Converter stopped unexpectedly")
