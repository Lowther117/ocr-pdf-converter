@echo off
setlocal
rem OCR PDF Converter - Windows launcher.
rem
rem First run: sets everything up, including Tesseract and Poppler. After that
rem it just starts. Everything except Tesseract lives inside this folder, so
rem deleting the folder removes it all.

cd /d "%~dp0"

if not exist ".venv-win\Scripts\python.exe" goto :setup
rem The venv can exist with its packages missing (a first run that lost its
rem network part-way); without this check setup would never run again.
".venv-win\Scripts\python.exe" -c "import pdf2image, pytesseract, cv2, numpy, PIL, docx" >nul 2>&1 || goto :setup
if exist "tools\poppler" goto :tesseract
rem Poppler already installed elsewhere on this PC? setup.ps1 would only
rem confirm that, so skip it rather than announce "setting up" every launch.
where pdftoppm.exe >nul 2>&1 && goto :tesseract
goto :setup

:tesseract
rem setup.ps1 installs Tesseract before Poppler, so a declined permission
rem prompt still leaves the venv and Poppler in place - and the checks above
rem would then never run setup again. Look for Tesseract where setup.ps1
rem and the converter look, and go back to setup if it is not there.
if exist "%ProgramFiles%\Tesseract-OCR\tesseract.exe" goto :run
if exist "%ProgramFiles(x86)%\Tesseract-OCR\tesseract.exe" goto :run
if exist "%LOCALAPPDATA%\Programs\Tesseract-OCR\tesseract.exe" goto :run
where tesseract.exe >nul 2>&1 && goto :run
goto :setup

:setup
echo.
echo Setting up. This happens once and takes a few minutes.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup.ps1"
if errorlevel 1 goto :failed
if not exist ".venv-win\Scripts\python.exe" goto :failed

:run
".venv-win\Scripts\python.exe" "ocr_batch_pro.py"
echo.
pause
exit /b 0

:failed
echo.
echo Setup did not finish. Scroll up to see what went wrong.
echo You can run this file again - it picks up where it left off.
echo.
pause
exit /b 1
