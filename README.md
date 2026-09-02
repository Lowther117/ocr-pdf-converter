# OCR PDF Converter

Batch-converts scanned PDFs into Word documents or plain text using OCR, with
optional image cleanup to improve accuracy on poor-quality scans.

Runs on **Windows and macOS** (and Linux). Point it at some PDFs, pick a folder,
and it works through them one at a time.

## What you need

**Python 3.9 or newer.** The launcher builds its own environment inside this
folder and installs the Python packages into it. Nothing is installed
system-wide.

- Windows: `winget install -e --id Python.Python.3.12`
- macOS: `brew install python`

Two programs also have to be installed separately, because they are not Python
packages — **Tesseract** does the actual character recognition, and **Poppler**
turns each PDF page into an image for Tesseract to read.

**Windows**

```
winget install -e --id UB-Mannheim.TesseractOCR
```

Poppler has no installer. Download the latest zip from
[poppler-windows releases](https://github.com/oschwartz10612/poppler-windows/releases)
and unzip it to `C:\Program Files\` — a folder like `poppler-26.02.0` is what
you want, and the converter finds it there by itself. You do not need to touch
PATH.

**macOS**

```
brew install tesseract poppler
```

If either is missing, the converter says which one and gives you the command,
rather than failing with something cryptic part-way through a batch.

## Running it

- **Windows** — double-click `run.bat`
- **macOS** — double-click `run.command`

The first run takes a minute longer while the environment is built. On macOS the
first double-click may be refused because the file came from the internet:
right-click → Open and confirm once, or run
`chmod +x run.command` in Terminal.

Then:

1. A file dialog opens — pick one or more PDFs.
2. A second dialog asks where the output should go.
3. Choose Word (`.docx`) or plain text (`.txt`).
4. Choose whether to clean up the images first (see below).

Each PDF produces one file named after it, with `_OCR` appended.

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

## Building a macOS app

Optional. `build_cli_app.sh` creates `/Applications/OCR PDF Converter.app`, which
opens Terminal and runs the converter, so it can be launched from Spotlight or
the Dock:

```bash
bash build_cli_app.sh
```

There is no equivalent Windows build — `run.bat` is already a double-click, and
pinning it to the taskbar or Start menu does the same job.

## When something goes wrong

**"Tesseract OCR was not found" / "Poppler was not found"** — install the one it
names, using the command above, then run it again. On Windows, if you unzipped
poppler somewhere other than `C:\Program Files\`, move it there or add its
`Library\bin` folder to PATH.

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
