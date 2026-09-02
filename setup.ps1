# OCR PDF Converter - Windows first-run setup.
#
# Called by run.bat. Makes the app self-sufficient:
#   1. builds a Python environment inside this folder and installs the packages
#   2. installs Tesseract OCR (via winget, the only sane route on Windows)
#   3. downloads a portable Poppler into .\tools - no admin, nothing on PATH
#
# Everything it creates lives in this folder except Tesseract, which has no
# portable build and must be installed properly. Re-running is cheap: each step
# checks whether it is already done and skips.

$ErrorActionPreference = 'Stop'
Set-Location -LiteralPath $PSScriptRoot

$ToolsDir = Join-Path $PSScriptRoot 'tools'
$VenvDir  = Join-Path $PSScriptRoot '.venv-win'
$VenvPy   = Join-Path $VenvDir 'Scripts\python.exe'

function Write-Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "   $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "   $msg" -ForegroundColor Yellow }

# Is an executable already reachable - on PATH, in a known location, or in .\tools?
function Find-Tool($exeName, $extraPaths) {
    $cmd = Get-Command $exeName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path $ToolsDir) {
        $hit = Get-ChildItem -Path $ToolsDir -Filter $exeName -Recurse -File -ErrorAction SilentlyContinue |
               Select-Object -First 1
        if ($hit) { return $hit.FullName }
    }
    foreach ($p in $extraPaths) {
        if ($p -and (Test-Path $p)) { return $p }
    }
    return $null
}

# Download a release asset from a public GitHub repo and unzip it under .\tools.
# The asset is matched by pattern rather than hard-coded, so a new upstream
# version does not break this script.
function Install-Portable($repo, $tag, $namePattern, $destName) {
    $dest = Join-Path $ToolsDir $destName
    $api = if ($tag -eq 'latest') {
        "https://api.github.com/repos/$repo/releases/latest"
    } else {
        "https://api.github.com/repos/$repo/releases/tags/$tag"
    }

    Write-Host "   Asking GitHub for the current $destName release..."
    $release = Invoke-RestMethod -Uri $api -Headers @{ 'User-Agent' = 'ocr-pdf-converter-setup' }
    $asset = $release.assets | Where-Object { $_.name -like $namePattern } | Select-Object -First 1
    if (-not $asset) {
        throw "No asset matching '$namePattern' in $repo ($($release.tag_name))."
    }

    $zip = Join-Path $env:TEMP $asset.name
    $mb = [math]::Round($asset.size / 1MB, 1)
    Write-Host "   Downloading $($asset.name) ($mb MB)..."
    Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing

    Write-Host "   Unpacking into tools\$destName..."
    if (Test-Path $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Expand-Archive -LiteralPath $zip -DestinationPath $dest -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
}


# --------------------------------------------------------------------------- #
# 1. Python environment
# --------------------------------------------------------------------------- #
Write-Step 'Python environment'
if (Test-Path $VenvPy) {
    Write-Ok 'Already set up.'
} else {
    # Note: build the command and its arguments separately and splat them. An
    # array slice like $a[1..($a.Length-1)] silently reverses on a one-element
    # array, which would pass the interpreter its own name as an argument.
    if (Get-Command py -ErrorAction SilentlyContinue) {
        $pyCmd = 'py'; $pyArgs = @('-3')
    } elseif (Get-Command python -ErrorAction SilentlyContinue) {
        $pyCmd = 'python'; $pyArgs = @()
    } else {
        Write-Host ''
        Write-Host 'Python was not found.' -ForegroundColor Red
        Write-Host '  Install it:  winget install -e --id Python.Python.3.12'
        exit 1
    }
    Write-Host '   Creating it (first run only)...'
    & $pyCmd @pyArgs -m venv $VenvDir
    & $VenvPy -m pip install --upgrade pip --quiet
    Write-Host '   Installing packages...'
    & $VenvPy -m pip install -r (Join-Path $PSScriptRoot 'requirements.txt') --quiet
    if ($LASTEXITCODE -ne 0) { throw 'pip install failed.' }
    Write-Ok 'Done.'
}


# --------------------------------------------------------------------------- #
# 2. Tesseract OCR
#
# There is no portable Tesseract build for Windows, so this is the one thing
# that gets properly installed. winget shows a UAC prompt; that is expected.
# --------------------------------------------------------------------------- #
Write-Step 'Tesseract OCR'
$tess = Find-Tool 'tesseract.exe' @(
    "$env:ProgramFiles\Tesseract-OCR\tesseract.exe",
    "${env:ProgramFiles(x86)}\Tesseract-OCR\tesseract.exe"
)
if ($tess) {
    Write-Ok "Found: $tess"
} elseif (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Host '   Installing with winget (you may see a permission prompt)...'
    winget install -e --id UB-Mannheim.TesseractOCR `
        --accept-package-agreements --accept-source-agreements --disable-interactivity
    $tess = Find-Tool 'tesseract.exe' @(
        "$env:ProgramFiles\Tesseract-OCR\tesseract.exe",
        "${env:ProgramFiles(x86)}\Tesseract-OCR\tesseract.exe"
    )
    if ($tess) { Write-Ok "Installed: $tess" }
    else {
        Write-Warn 'winget finished but Tesseract still is not where expected.'
        Write-Warn 'If you were asked to approve it and declined, run this again.'
    }
} else {
    Write-Warn 'winget is not available on this PC.'
    Write-Warn 'Install Tesseract by hand from:'
    Write-Warn '  https://github.com/UB-Mannheim/tesseract/wiki'
}


# --------------------------------------------------------------------------- #
# 3. Poppler (portable - no installer, no admin)
# --------------------------------------------------------------------------- #
Write-Step 'Poppler'
$pop = Find-Tool 'pdftoppm.exe' @()
if ($pop) {
    Write-Ok "Found: $pop"
} else {
    try {
        Install-Portable 'oschwartz10612/poppler-windows' 'latest' 'Release-*.zip' 'poppler'
        $pop = Find-Tool 'pdftoppm.exe' @()
        if ($pop) { Write-Ok "Installed: $pop" }
        else { Write-Warn 'Unpacked, but pdftoppm.exe was not found inside it.' }
    } catch {
        Write-Warn "Could not fetch Poppler automatically: $($_.Exception.Message)"
        Write-Warn 'Download it by hand from:'
        Write-Warn '  https://github.com/oschwartz10612/poppler-windows/releases'
        Write-Warn "and unzip it into: $ToolsDir\poppler"
    }
}

Write-Host ''
