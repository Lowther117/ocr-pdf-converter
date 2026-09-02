@echo off
setlocal
rem OCR PDF Converter - Windows launcher.
rem
rem First run: sets everything up, including Tesseract and Poppler. After that
rem it just starts. Everything except Tesseract lives inside this folder, so
rem deleting the folder removes it all.

cd /d "%~dp0"

if not exist ".venv-win\Scripts\python.exe" goto :setup
if not exist "tools\poppler" goto :setup
goto :run

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
