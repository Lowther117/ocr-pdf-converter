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
    # ensure_python.ps1 finds a REAL interpreter (the py launcher counts, the
    # Microsoft Store's fake python.exe stub does not) and installs Python
    # automatically when the PC has none - winget first, python.org directly
    # when winget is broken. It prints the interpreter path as its last line.
    $sysPy = (& (Join-Path $PSScriptRoot 'ensure_python.ps1') |
              Select-Object -Last 1)
    if (-not $sysPy -or -not (Test-Path "$sysPy")) {
        Write-Host ''
        Write-Host 'Python was not found and could not be installed automatically.' -ForegroundColor Red
        Write-Host '  Install it from https://www.python.org/downloads/windows/'
        Write-Host '  (tick "Add python.exe to PATH"), then run this again.'
        exit 1
    }
    Write-Host "   Using Python: $sysPy"
    Write-Host '   Creating it (first run only)...'
    & "$sysPy" -m venv $VenvDir
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
$tessPaths = @(
    "$env:ProgramFiles\Tesseract-OCR\tesseract.exe",
    "${env:ProgramFiles(x86)}\Tesseract-OCR\tesseract.exe",
    "$env:LOCALAPPDATA\Programs\Tesseract-OCR\tesseract.exe"
)
$tess = Find-Tool 'tesseract.exe' $tessPaths

# Route 1: winget - quick when it works, but on some PCs its source update
# fails (403), so a failure here is expected and handled, not fatal.
if (-not $tess -and (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host '   Trying winget (you may see a permission prompt)...'
    try {
        winget install -e --id UB-Mannheim.TesseractOCR `
            --accept-package-agreements --accept-source-agreements --disable-interactivity
    } catch { }
    $tess = Find-Tool 'tesseract.exe' $tessPaths
    if (-not $tess) {
        Write-Warn 'winget did not produce Tesseract - fetching the installer directly.'
    }
}

# Route 2: the UB-Mannheim installer, downloaded directly - immune to winget
# being broken. Runs silently; Windows may show one permission prompt.
if (-not $tess) {
    $exe = Join-Path $env:TEMP 'tesseract-setup.exe'
    $got = $false
    try {
        Write-Host '   Asking GitHub for the current Tesseract installer...'
        $release = Invoke-RestMethod `
            -Uri 'https://api.github.com/repos/UB-Mannheim/tesseract/releases/latest' `
            -Headers @{ 'User-Agent' = 'ocr-pdf-converter-setup' }
        $asset = $release.assets |
            Where-Object { $_.name -like 'tesseract-ocr-w64-setup-*.exe' } |
            Select-Object -First 1
        if ($asset) {
            $mb = [math]::Round($asset.size / 1MB, 1)
            Write-Host "   Downloading $($asset.name) ($mb MB)..."
            Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $exe -UseBasicParsing
            $got = $true
        }
    } catch { }
    if (-not $got) {
        try {
            Write-Host '   Downloading Tesseract from the UB-Mannheim mirror...'
            Invoke-WebRequest -OutFile $exe -UseBasicParsing -Uri `
                'https://digi.bib.uni-mannheim.de/tesseract/tesseract-ocr-w64-setup-5.4.0.20240606.exe'
            $got = $true
        } catch {
            Write-Warn "Could not download the installer: $($_.Exception.Message)"
        }
    }
    if ($got) {
        Write-Host '   Installing (silent - approve the permission prompt if one appears)...'
        try {
            Start-Process -FilePath $exe -ArgumentList '/S' -Wait
        } catch {
            Write-Warn "The installer did not finish: $($_.Exception.Message)"
        }
        Remove-Item $exe -Force -ErrorAction SilentlyContinue
        $tess = Find-Tool 'tesseract.exe' $tessPaths
    }
}

if ($tess) {
    Write-Ok "Ready: $tess"
} else {
    Write-Warn 'Tesseract could not be installed automatically.'
    Write-Warn 'Install it by hand from:'
    Write-Warn '  https://github.com/UB-Mannheim/tesseract/wiki'
    Write-Warn 'then run this again.'
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
