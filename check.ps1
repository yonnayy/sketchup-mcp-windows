# SketchUp MCP for Windows - health check
#
#     powershell -ExecutionPolicy Bypass -File .\check.ps1
# or  powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/yonnayy/sketchup-mcp-windows/main/check.ps1 | iex"
#
# Reads only; changes nothing. Exit code 0 = everything needed for modelling works.
# Keep this file ASCII-only.

$ErrorActionPreference = 'Continue'
$failed = 0
function Pass($msg) { Write-Host "[PASS] $msg" -ForegroundColor Green }
function Fail($msg, $fix) { $script:failed++; Write-Host "[FAIL] $msg" -ForegroundColor Red; if ($fix) { Write-Host "       -> $fix" -ForegroundColor Yellow } }
function Info($msg) { Write-Host "[INFO] $msg" }

# 1. extension files
$suBase = Join-Path $env:APPDATA 'SketchUp'
$found = $false
if (Test-Path $suBase) {
    Get-ChildItem $suBase -Directory -Filter 'SketchUp 20*' | ForEach-Object {
        $main = Join-Path $_.FullName 'SketchUp\Plugins\su_mcp\main.rb'
        if (Test-Path $main) {
            $text = [System.IO.File]::ReadAllText($main)
            if ($text -match 'accept_nonblock' -and $text -match 'frame_for = lambda') {
                Pass "Extension (patched) present for $($_.Name)"
                $script:found = $true
            } elseif ($text -match 'accept_nonblock') {
                Fail "Extension for $($_.Name) is an older build (no door and window frames)" 'Run install.ps1 again, then restart SketchUp.'
                $script:found = $true
            } else {
                Fail "Extension for $($_.Name) is the ORIGINAL unpatched version (it freezes SketchUp)" 'Run install.ps1 again.'
            }
        }
    }
}
if (-not $found) { Fail 'SketchUp extension not installed' 'Run install.ps1 (SketchUp must have been opened at least once).' }

# 2. Claude Desktop config + the server program it points to
$configs = @((Join-Path $env:APPDATA 'Claude\claude_desktop_config.json'))
$storeRoot = Join-Path $env:LOCALAPPDATA 'Packages'
if (Test-Path $storeRoot) {
    Get-ChildItem $storeRoot -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue | ForEach-Object {
        $configs += (Join-Path $_.FullName 'LocalCache\Roaming\Claude\claude_desktop_config.json')
    }
}
$registered = $false
foreach ($c in $configs) {
    if (Test-Path $c) {
        try {
            $j = [System.IO.File]::ReadAllText($c) | ConvertFrom-Json
            if ($j.mcpServers -and $j.mcpServers.sketchup) {
                $registered = $true
                $command = $j.mcpServers.sketchup.command
                if (Test-Path $command) {
                    Pass "Registered in $c"
                    Info "  command: $command"
                } else {
                    Fail "Registered in $c, but the program is missing: $command" 'Run install.ps1 again.'
                }
            }
        } catch { Fail "$c is not valid JSON" 'Fix the file, then run install.ps1 again.' }
    }
}
if (-not $registered) { Fail 'No "sketchup" entry in any Claude Desktop config' 'Run install.ps1.' }

# The installed server must be this repo's version, not a stale cached build.
$serverPy = $null
$uvCmd = Get-Command uv -ErrorAction SilentlyContinue
$uvExe = if ($uvCmd) { $uvCmd.Source } else { Join-Path $env:USERPROFILE '.local\bin\uv.exe' }
if (Test-Path $uvExe) {
    $toolDir = (& $uvExe tool dir 2>$null | Select-Object -First 1)
    if ($toolDir) { $serverPy = Join-Path $toolDir.Trim() 'sketchup-mcp\Lib\site-packages\sketchup_mcp\server.py' }
}
if ($serverPy -and (Test-Path $serverPy)) {
    $serverText = [System.IO.File]::ReadAllText($serverPy)
    if ($serverText -match 'def build_floor_plan') {
        Pass 'Installed server has the build_floor_plan tool'
    } else {
        Fail 'Installed server is an old build (no build_floor_plan tool)' 'Run install.ps1 again, then quit and reopen Claude Desktop.'
    }
    # Compare with the newest version: this repo when run from a checkout, GitHub otherwise.
    $installed = if ($serverText -match '__version__ = "([^"]+)"') { $Matches[1] } else { $null }
    $latest = $null
    $project = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'pyproject.toml' } else { $null }
    try {
        if ($project -and (Test-Path $project)) {
            $projectText = [System.IO.File]::ReadAllText($project)
        } else {
            $projectText = (Invoke-WebRequest -UseBasicParsing -TimeoutSec 10 'https://raw.githubusercontent.com/yonnayy/sketchup-mcp-windows/main/pyproject.toml').Content
        }
        if ($projectText -match '(?m)^version = "([^"]+)"') { $latest = $Matches[1] }
    } catch { }
    if ($installed -and $latest) {
        if ($installed -eq $latest) {
            Pass "Installed server is version $installed (the newest)"
        } else {
            Fail "Installed server is version $installed, the newest is $latest" 'Run install.ps1 again, then quit Claude Desktop from the tray icon and reopen it.'
        }
    } elseif ($installed) {
        Info "Installed server version: $installed (could not look up the newest version)"
    }
} else {
    Fail 'Installed server package not found (uv tool "sketchup-mcp")' 'Run install.ps1.'
}

# 3. SketchUp running + server listening
$su = Get-Process -Name SketchUp -ErrorAction SilentlyContinue
if ($su) { Pass 'SketchUp is running' } else { Fail 'SketchUp is not running' 'Open SketchUp and open a model (get past the Welcome window).' }

$reply = $null
try {
    $client = New-Object System.Net.Sockets.TcpClient
    $iar = $client.BeginConnect('127.0.0.1', 9876, $null, $null)
    if (-not $iar.AsyncWaitHandle.WaitOne(2000)) { throw 'timeout' }
    $client.EndConnect($iar)
    $stream = $client.GetStream()
    $stream.ReadTimeout = 10000
    $req = '{"jsonrpc":"2.0","method":"tools/call","params":{"name":"eval_ruby","arguments":{"code":"\"SketchUp #{Sketchup.version} | model: #{Sketchup.active_model ? Sketchup.active_model.entities.length : -1} entities\""}},"id":1}' + "`n"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($req)
    $stream.Write($bytes, 0, $bytes.Length)
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    $reply = $reader.ReadLine()
    $client.Close()
} catch {
    Fail 'Nothing answers on 127.0.0.1:9876 (the server inside SketchUp)' 'In SketchUp: Extensions > MCP Server > Start Server. If the menu is missing: Extension Manager > enable "Sketchup MCP Server", restart SketchUp.'
}
if ($reply) {
    try {
        $r = $reply | ConvertFrom-Json
        if ($r.result -and $r.result.success) {
            Pass "SketchUp answered: $($r.result.content[0].text)"
        } else {
            Fail "SketchUp answered with an error: $reply" 'See docs/TROUBLESHOOTING.md.'
        }
    } catch { Fail "Unreadable answer from SketchUp: $reply" 'See docs/TROUBLESHOOTING.md.' }
}

Write-Host ''
if ($failed -eq 0) {
    Write-Host 'ALL CHECKS PASSED. If Claude Desktop does not show the sketchup tools yet, quit it from the tray icon and reopen it.' -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failed check(s) failed." -ForegroundColor Red
    exit 1
}
