# OCR PDF Converter

Batch-converts scanned PDFs into Word documents or plain text using OCR, with
optional image cleanup to improve accuracy on poor-quality scans.

Runs on **Windows and macOS** (and Linux). Point it at some PDFs, pick a folder,
and it works through them one at a time.

## Which file do I use?

| File | Windows | Mac | What it is |
|---|---|---|---|
| `run.bat` | **double-click this** | — | Starts the converter. First run sets everything up: Python, the packages, Tesseract, Poppler. |
| `run.command` | — | **double-click this** | Starts the converter. First run sets up the packages and installs Tesseract and Poppler with Homebrew. |
| `ocr_batch_pro.py` | the app itself | the app itself | The whole converter. The launchers run it for you; `python ocr_batch_pro.py selftest` reports what it can see. |
| `theme.py` | part of the app | part of the app | The dark and light colour schemes for the app's dialogs. Nothing to run. |
| `setup.ps1` | run by `run.bat` | — | The Windows first-run setup. Nothing to click; safe to run again. |
| `ensure_python.ps1` | run by `setup.ps1` | — | Finds a real Python, or installs one. Nothing to click. |
| `build-exe.bat` | optional | — | Builds `dist\OCR PDF Converter.exe`, a standalone exe with Tesseract and Poppler inside. |
| `build-app.command` | — | optional | Builds `dist/OCR PDF Converter.app`, a standalone app with as much baked in as Homebrew has. |
| `requirements.txt` | used by setup | used by setup | The list of Python packages. Nothing to run. |

## Setting it up

**Windows** — double-click `run.bat`
**macOS** — double-click `run.command`

That is the whole setup. The first run installs everything the converter needs
and then starts it; every run after that just starts it. Expect a few minutes
the first time.

On **Windows** even Python takes care of itself: if none is found, the first
run installs it automatically (winget first, python.org directly when winget
is unwell). On **macOS** install it once with `brew install python`.

### What the first run actually does

So there are no surprises:

| | Windows | macOS |
|---|---|---|
| Python packages | into `.venv-win\` in this folder | into `.venv-mac/` in this folder |
| Poppler | portable copy downloaded into `tools\` | `brew install poppler` |
| Tesseract OCR | `winget install UB-Mannheim.TesseractOCR` | `brew install tesseract` |

On Windows only Tesseract is installed properly — it has no portable build — so
you get one permission prompt for it. Poppler is just unzipped into this folder,
and the converter looks there before anywhere else. Nothing touches your PATH.

On macOS both come from Homebrew. If Homebrew isn't installed the launcher stops
and gives you the one line to paste, rather than installing it behind your back —
that needs an administrator password and should be your decision.

Deleting this folder removes everything except Tesseract on Windows, which
uninstalls from Settings like any other program.

On macOS the first double-click may be refused because the file came from the
internet: right-click → Open and confirm once, or run `chmod +x run.command`.

## Using it

1. A file dialog opens — pick one or more PDFs.
2. A second dialog asks where to save. It starts in `OCR Output` inside your
   Downloads folder; pick somewhere else and you are asked whether to make
   that the default from now on (remembered in `ocr-settings.json`).
3. Choose Word (`.docx`) or plain text (`.txt`).
4. Choose whether to clean up the images first (see below).

Each PDF produces one file named after it, with `_OCR` appended.

The dialogs are dark by default. **Ctrl+D** in any of them switches to light
(and back); the choice is remembered in `ocr-settings.json` beside the app.
Where the launchers open a Terminal or console, the questions are typed there
instead and only the file pickers appear.

## Image cleanup

On by default. Two steps run before the text is read:

- **Denoise** (default strength 10, range 0–20) removes speckle from scans and
  photocopies. Set it to 0 to skip.
- **Threshold** (default block size 11, range 0–50) converts the page to pure
  black and white, which is what Tesseract reads best. Set it to 0 to skip.

Cleanup helps on faxes, photocopies and phone photos of documents. On a clean
300 dpi scan it makes little difference and costs time, so turning it off is
reasonable for good originals.

Pages are rendered at 300 dpi, which is the resolution Tesseract is happiest
with. Lower loses accuracy; higher mostly costs time.

## Optional: a standalone app

The launchers above stay the normal way to run this. But if you want something
that needs nothing installed at all — no Python, no Homebrew, no Tesseract —
run **build-exe.bat** (Windows) or **build-app.command** (macOS). Each produces
one thing, `dist\OCR PDF Converter.exe` or `dist/OCR PDF Converter.app`, with
as much of the OCR machinery as possible carried inside it.

Building needs Python on the machine doing the building; running the result
does not. The scripts sort out what they need themselves, write everything they
do to `build-win-log.txt` / `build-mac-log.txt`, and run the finished app's own
self-test before claiming success — so a build that says Done has actually been
started and asked what it can see.

- **Windows** — Tesseract and a portable Poppler are fetched by `setup.ps1`,
  the same routine `run.bat` uses, and copied into the exe. It is one large
  file, so the first launch pauses for a few seconds while it unpacks itself.
- **macOS** — Tesseract and Poppler are taken from Homebrew's copies; if they
  are not installed the script installs them (and Homebrew itself, and a
  Python with Tk, if the Mac has none — the Homebrew step asks for your
  password once). The app is ad-hoc signed at the end, which is what lets a
  locally built app open on Apple silicon at all.
- **Anything not baked in** is looked for on the machine the app runs on, as
  the folder version does, so a partial build is still useful where the tools
  are already there.

Opened from the Finder the Mac app has no Terminal window, so it asks its
questions in dialogs rather than at a prompt; the Windows exe opens the same
console it always did. When a build misbehaves, the report it leaves beside
itself — `ocr-selftest.txt` — says which pieces are missing; running
`ocr_batch_pro.py selftest` prints the same thing for the folder version.

## When something goes wrong

**"Tesseract OCR was not found" / "Poppler was not found"** — the setup step
didn't complete. Run the launcher again; it resumes where it left off. On
Windows this usually means the Tesseract permission prompt was declined. To do
it by hand: `winget install -e --id UB-Mannheim.TesseractOCR`, and for Poppler,
unzip a [release](https://github.com/oschwartz10612/poppler-windows/releases)
into the `tools\poppler` folder beside `run.bat`.

**A page comes out as `[No text detected]`** — usually a blank page, or an image
with no readable text. If the whole document does it, try turning cleanup off:
aggressive thresholding can erase faint text.

**Recognition is poor** — check the source resolution first. A 150 dpi scan
cannot be rescued by settings. Failing that, try denoise 0 and threshold 0 to see
the unprocessed result, then raise one at a time.

**Output is a report-style document, not a facsimile.** The Word file is the
extracted text with a page heading before each page. It does not attempt to
reproduce the original layout, columns or images — if you need that, this is the
wrong tool.

---

*Built for my own use, in collaboration with AI (Anthropic's Claude). I described the problems, made the decisions and tested the results; Claude wrote much of the code. Shared as-is — a personal fix, not a product. No support and no warranty.*

## Licence

MIT No Attribution (MIT-0): do whatever you like with it - no credit needed, no warranty. See `LICENSE`.
