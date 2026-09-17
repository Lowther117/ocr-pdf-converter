@echo off
rem OPTIONAL: build a standalone "OCR PDF Converter.exe" that runs without
rem Python, with Tesseract and Poppler carried inside it.
rem The normal run.bat setup is unchanged by this.
rem
rem The noisy output of pip and PyInstaller goes to build-win-log.txt so this
rem window stays readable; if anything fails, the tail of that log is shown
rem here. The finished exe is tested before this script claims success.

setlocal
cd /d "%~dp0"
set "HERE=%~dp0"
set "VENV=%HERE%.venv-build"
set "PY=%VENV%\Scripts\python.exe"
set "LOG=%HERE%build-win-log.txt"
set "EXE=%HERE%dist\OCR PDF Converter.exe"

echo OCR PDF Converter standalone build> "%LOG%"
echo %DATE% %TIME%>> "%LOG%"
echo.
echo Building the standalone OCR PDF Converter.exe. This takes several minutes
echo and produces a large file - Tesseract and its language data go inside it.
echo Detail goes to build-win-log.txt.

rem ---------------------------------------------------------------------
rem 1. A Python to build with - installed automatically if the PC has none.
rem ---------------------------------------------------------------------
echo.
echo == Python
if exist "%PY%" goto :haveenv

set "SYSPY="
for /f "delims=" %%p in ('powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%ensure_python.ps1" 2^>nul') do set "SYSPY=%%p"
if not defined SYSPY goto :nopython
if not exist "%SYSPY%" goto :nopython
echo    Using %SYSPY%
"%SYSPY%" -m venv "%VENV%" >> "%LOG%" 2>&1
if not exist "%PY%" (
    echo    ERROR: could not create the build environment.
    goto :failed
)

:haveenv
echo    Installing PyInstaller...
"%PY%" -m pip install --upgrade pip --quiet >> "%LOG%" 2>&1
"%PY%" -m pip install --upgrade --only-binary :all: pyinstaller >> "%LOG%" 2>&1
if errorlevel 1 (
    echo    ERROR: could not install PyInstaller.
    goto :failed
)

rem ---------------------------------------------------------------------
rem 2. The converter's own packages.
rem
rem --only-binary :all: everywhere: a package with no wheel for this PC then
rem fails in seconds instead of trying to compile from source and sending
rem you hunting for Visual Studio.
rem ---------------------------------------------------------------------
echo.
echo == Components to bake in
echo    pdf2image, pytesseract, opencv, numpy, pillow, python-docx...
"%PY%" -m pip install --only-binary :all: -r "%HERE%requirements.txt" >> "%LOG%" 2>&1
if errorlevel 1 (
    echo    ERROR: could not install the converter's own packages.
    goto :failed
)

rem ---------------------------------------------------------------------
rem 3. Tesseract and Poppler - the point of the exercise.
rem
rem setup.ps1 already knows how to get both: the GitHub releases API for the
rem portable Poppler, winget and then the UB-Mannheim installer for
rem Tesseract. -ToolsOnly runs just that part and skips the .venv-win it
rem builds for run.bat, which this script does not need.
rem
rem Poppler is unzipped into .\tools and Tesseract is installed properly (it
rem has no portable build), and both are then copied into the exe.
rem ---------------------------------------------------------------------
echo.
echo == Tesseract and Poppler
call :findtools
if defined POPBIN if defined TESSROOT goto :havetools
echo    Fetching what is missing - approve any permission prompt...
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%setup.ps1" -ToolsOnly >> "%LOG%" 2>&1
call :findtools

:havetools
set "POPARG="
set "TESSARG="
if defined POPBIN echo    Poppler: %POPBIN%
if defined POPBIN set POPARG=--add-data "%POPBIN%;tools/poppler"
if not defined POPBIN echo    WARNING: no Poppler - the exe will need it on the PC that runs it.
if defined TESSROOT echo    Tesseract: %TESSROOT%
if defined TESSROOT set TESSARG=--add-data "%TESSROOT%;tools/tesseract"
if not defined TESSROOT echo    WARNING: no Tesseract - the exe will need it on the PC that runs it.

rem ---------------------------------------------------------------------
rem 4. Build.
rem
rem Not --windowed: the converter asks its questions in the window it opens
rem in, exactly as it does under run.bat, and a windowed build would have
rem nowhere to ask them.
rem ---------------------------------------------------------------------
echo.
echo == Building ^(several minutes^)
if exist "%HERE%build" rd /s /q "%HERE%build"
if exist "%HERE%dist" rd /s /q "%HERE%dist"
if exist "%HERE%OCR PDF Converter.spec" del /q "%HERE%OCR PDF Converter.spec"

"%PY%" -m PyInstaller --noconfirm --clean --onefile --name "OCR PDF Converter" ^
    --collect-data docx ^
    %POPARG% %TESSARG% ^
    "%HERE%ocr_batch_pro.py" >> "%LOG%" 2>&1
if errorlevel 1 (
    echo    Build failed.
    goto :failed
)
if not exist "%EXE%" (
    echo    The build finished but dist\OCR PDF Converter.exe is not there.
    goto :failed
)

rem ---------------------------------------------------------------------
rem 5. Prove it runs before saying it works.
rem
rem The self-test also writes its report next to the exe, so the same thing
rem ends up in the log and can be sent on.
rem ---------------------------------------------------------------------
echo.
echo == Testing the built exe
if exist "%HERE%dist\ocr-selftest.txt" del /q "%HERE%dist\ocr-selftest.txt"
"%EXE%" selftest
set "RC=%ERRORLEVEL%"
if exist "%HERE%dist\ocr-selftest.txt" (
    type "%HERE%dist\ocr-selftest.txt" >> "%LOG%"
) else (
    echo    The exe did not produce a self-test report.
    set "RC=1"
)

echo.
if "%RC%"=="0" (
    echo Done: dist\OCR PDF Converter.exe
    echo.
    echo Copy it anywhere - it needs nothing installed on the PC that runs it.
    echo The first launch takes a few seconds while it unpacks itself.
) else (
    echo The exe was built but the self-test above found problems, so it may
    echo not work properly. Send build-win-log.txt if you want it looked at.
)
echo.
echo Log: %LOG%
pause
exit /b 0

rem ---------------------------------------------------------------------
rem Where the two tools ended up. Poppler unzips into a version-stamped
rem folder such as tools\poppler\poppler-25.07.0\Library\bin, so it is
rem searched for rather than assumed.
rem ---------------------------------------------------------------------
:findtools
set "POPBIN="
for /f "delims=" %%d in ('dir /s /b "%HERE%tools\pdftoppm.exe" 2^>nul') do if not defined POPBIN set "POPBIN=%%~dpd"
if defined POPBIN set "POPBIN=%POPBIN:~0,-1%"
set "TESSROOT="
if exist "%ProgramFiles%\Tesseract-OCR\tesseract.exe" set "TESSROOT=%ProgramFiles%\Tesseract-OCR"
if not defined TESSROOT if exist "%ProgramFiles(x86)%\Tesseract-OCR\tesseract.exe" set "TESSROOT=%ProgramFiles(x86)%\Tesseract-OCR"
if not defined TESSROOT if exist "%LOCALAPPDATA%\Programs\Tesseract-OCR\tesseract.exe" set "TESSROOT=%LOCALAPPDATA%\Programs\Tesseract-OCR"
goto :eof

:nopython
echo    ERROR: Python 3.9+ is needed to BUILD the exe ^(not to run it^), and
echo    it could not be installed automatically.
echo    Install it from https://www.python.org/downloads/windows/
echo    ^(tick "Add python.exe to PATH"^), then run this again.
goto :failed

:failed
echo.
echo ---- last 40 lines of the log ----
powershell -NoProfile -Command "Get-Content -LiteralPath '%LOG%' -Tail 40" 2>nul
echo ----------------------------------
echo Full log: %LOG%
echo.
pause
exit /b 1
