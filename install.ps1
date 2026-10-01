# SketchUp MCP for Windows - installer
#
# Run from a clone/unzipped copy of the repo:
#     powershell -ExecutionPolicy Bypass -File .\install.ps1
# or straight from GitHub:
#     powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/yonnayy/sketchup-mcp-windows/main/install.ps1 | iex"
#
# What it does (safe to run again at any time):
#   1. copies the SketchUp extension into every SketchUp 20xx Plugins folder
#   2. installs uv (Python tool runner) if it is missing
#   3. installs the MCP server as %USERPROFILE%\.local\bin\sketchup-mcp.exe
#   4. registers the server in Claude Desktop's claude_desktop_config.json
#
# Keep this file ASCII-only: Windows PowerShell 5.1 misreads UTF-8 without BOM.

$ErrorActionPreference = 'Stop'
$RepoZip = 'https://github.com/yonnayy/sketchup-mcp-windows/archive/refs/heads/main.zip'

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "   [OK] $msg" -ForegroundColor Green }
function Warn($msg) { Write-Host "   [!!] $msg" -ForegroundColor Yellow }

# --- 0. locate the repo files -------------------------------------------------
Step 'Locating repo files'
$root = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'su_mcp\su_mcp\main.rb'))) {
    $root = $PSScriptRoot
    Ok "Using local copy: $root"
} else {
    $work = Join-Path $env:TEMP 'sketchup-mcp-windows-install'
    New-Item -ItemType Directory -Force $work | Out-Null
    $zip = Join-Path $work 'repo.zip'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $RepoZip -OutFile $zip -UseBasicParsing
    $extract = Join-Path $work ('src-' + (Get-Date -Format 'yyyyMMddHHmmss'))
    Expand-Archive -Path $zip -DestinationPath $extract -Force
    $root = (Get-ChildItem $extract -Directory | Select-Object -First 1).FullName
    Ok "Downloaded to: $root"
}

# --- 1. SketchUp extension ----------------------------------------------------
Step 'Installing the SketchUp extension'
$pluginDirs = @()
$suBase = Join-Path $env:APPDATA 'SketchUp'
if (Test-Path $suBase) {
    $pluginDirs = @(Get-ChildItem $suBase -Directory -Filter 'SketchUp 20*' |
        ForEach-Object { Join-Path $_.FullName 'SketchUp\Plugins' } |
        Where-Object { Test-Path (Split-Path $_ -Parent) })
}
if ($pluginDirs.Count -eq 0) {
    Warn 'No SketchUp profile folder found. Install SketchUp, open it once, then run this installer again.'
    Warn "Manual alternative: Extension Manager > Install Extension > $root\release\su_mcp_v1.6.1.rbz"
} else {
    foreach ($dir in $pluginDirs) {
        New-Item -ItemType Directory -Force (Join-Path $dir 'su_mcp') | Out-Null
        Copy-Item (Join-Path $root 'su_mcp\su_mcp.rb') (Join-Path $dir 'su_mcp.rb') -Force
        Copy-Item (Join-Path $root 'su_mcp\su_mcp\main.rb') (Join-Path $dir 'su_mcp\main.rb') -Force
        Ok "Extension copied to $dir"
    }
    if (Get-Process -Name SketchUp -ErrorAction SilentlyContinue) {
        Warn 'SketchUp is running. Close and reopen it so the new extension loads.'
    }
}

# --- 2. uv ----------------------------------------------------------------------
Step 'Checking uv'
$uv = $null
$cmd = Get-Command uv -ErrorAction SilentlyContinue
if ($cmd) { $uv = $cmd.Source }
if (-not $uv) {
    $candidate = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (Test-Path $candidate) { $uv = $candidate }
}
if (-not $uv) {
    Write-Host '   uv not found, installing it (official installer from astral.sh)...'
    Invoke-RestMethod https://astral.sh/uv/install.ps1 | Invoke-Expression
    $uv = Join-Path $env:USERPROFILE '.local\bin\uv.exe'
    if (-not (Test-Path $uv)) { throw 'uv installation failed. Install it manually from https://docs.astral.sh/uv/ and run this script again.' }
}
Ok "uv: $uv"

# --- 3. MCP server --------------------------------------------------------------
Step 'Installing the MCP server (sketchup-mcp.exe)'
$binDir = (& $uv tool dir --bin).Trim()
$exe = Join-Path $binDir 'sketchup-mcp.exe'
# Claude Desktop keeps a previous copy of this exe locked while it is running.
Get-CimInstance Win32_Process -Filter "Name = 'sketchup-mcp.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.ExecutablePath -eq $exe } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
# --reinstall-package: without it uv reuses a cached build of the same version
# number, so re-running the installer after an update would install old code.
& $uv tool install --force --reinstall-package sketchup-mcp --python 3.12 --from $root sketchup-mcp
if ($LASTEXITCODE -ne 0) { throw 'uv tool install failed (see the message above).' }
if (-not (Test-Path $exe)) { throw "Expected $exe after installation, but it is missing." }
Ok "Server: $exe"

# --- 4. Claude Desktop config ---------------------------------------------------
Step 'Registering the server in Claude Desktop'
$configDirs = @()
$classic = Join-Path $env:APPDATA 'Claude'
if (Test-Path $classic) { $configDirs += $classic }
$storeRoot = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path $storeRoot) {
    Get-ChildItem $storeRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $d = Join-Path $_.FullName 'LocalCache\Roaming\Claude'
        if (Test-Path $d) { $configDirs += $d }
    }
}
if ($configDirs.Count -eq 0) {
    Warn 'Claude Desktop does not look installed (no Claude config folder). Creating the default one anyway.'
    New-Item -ItemType Directory -Force $classic | Out-Null
    $configDirs += $classic
}
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
foreach ($dir in $configDirs) {
    $path = Join-Path $dir 'claude_desktop_config.json'
    $config = New-Object PSObject
    if (Test-Path $path) {
        $raw = [System.IO.File]::ReadAllText($path)
        if ($raw.Trim().Length -gt 0) {
            try { $config = $raw | ConvertFrom-Json }
            catch {
                Warn "$path is not valid JSON. Left untouched. Fix it or add the entry by hand (see docs/INSTALL.md)."
                continue
            }
            Copy-Item $path ($path + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
        }
    }
    if (-not ($config.PSObject.Properties.Name -contains 'mcpServers')) {
        $config | Add-Member -NotePropertyName mcpServers -NotePropertyValue (New-Object PSObject)
    }
    $entry = New-Object PSObject -Property @{ command = $exe; args = @() }
    if ($config.mcpServers.PSObject.Properties.Name -contains 'sketchup') {
        $config.mcpServers.sketchup = $entry
    } else {
        $config.mcpServers | Add-Member -NotePropertyName sketchup -NotePropertyValue $entry
    }
    [System.IO.File]::WriteAllText($path, ($config | ConvertTo-Json -Depth 32), $utf8NoBom)
    Ok "Config updated: $path"
}

# --- done -----------------------------------------------------------------------
Step 'Done. Next steps'
Write-Host '   1. Open (or restart) SketchUp and open a model. The MCP server starts by itself.'
Write-Host '      Check: Extensions > MCP Server > Status'
Write-Host '   2. Fully quit Claude Desktop (tray icon > Quit) and open it again.'
Write-Host '   3. Verify with:  powershell -ExecutionPolicy Bypass -File check.ps1'
Write-Host "      (the script is in $root)"
