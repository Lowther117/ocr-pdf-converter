@echo off
setlocal
rem OCR PDF Converter - Windows launcher.
rem Builds its own Python environment inside this folder on first run,
rem then starts the converter. Nothing is installed system-wide.

cd /d "%~dp0"

where py >nul 2>nul
if errorlevel 1 (
    where python >nul 2>nul
    if errorlevel 1 (
        echo.
        echo Python was not found.
        echo   Install it:  winget install -e --id Python.Python.3.12
        echo.
        pause
        exit /b 1
    )
    set "PY=python"
) else (
    set "PY=py -3"
)

if not exist ".venv-win\Scripts\python.exe" (
    echo Creating the Python environment ^(first run only^)...
    %PY% -m venv ".venv-win"
    if errorlevel 1 goto :failed
    ".venv-win\Scripts\python.exe" -m pip install --upgrade pip --quiet
    echo Installing packages...
    ".venv-win\Scripts\python.exe" -m pip install -r requirements.txt --quiet
    if errorlevel 1 goto :failed
)

".venv-win\Scripts\python.exe" "ocr_batch_pro.py"
echo.
pause
exit /b 0

:failed
echo.
echo Setup failed. See the messages above.
echo.
pause
exit /b 1
