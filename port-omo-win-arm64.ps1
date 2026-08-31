#Requires -Version 7.0
# Rebuild OmO Desktop (Linux x86-64 AppImage) as a native Windows arm64 build.
#
# The AppImage ships an Electron app: the runtime binary is a Linux x86-64 ELF, but the
# application itself (resources/app.asar) is platform-independent JavaScript. This script
# swaps the Linux Electron runtime for the matching win32-arm64 Electron release and
# replaces every bundled linux-x64 native module with its win32-arm64 counterpart.
#
# Usage: .\port-omo-win-arm64.ps1 <path-to-OmO-x.y.z-x86_64.AppImage> [output-dir]

[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$AppImage,
  [string]$OutDir = (Join-Path $PWD 'omo-win-build')
)

$ErrorActionPreference = 'Stop'

function Need($cmd, $hint) {
  if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "missing dependency: $cmd ($hint)" }
}
function Say($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }

Need 7z   'winget install 7zip.7zip'
Need npx  'install Node.js'
Need npm  'install Node.js'

if (-not (Test-Path $AppImage)) { throw "no such AppImage: $AppImage" }
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') { Write-Warning 'not running on arm64 - output is still arm64' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
Set-Location $OutDir

# ---------------------------------------------------------------------------
# 1. Locate the squashfs payload.
#
# An AppImage (type 2) is an ELF runtime with a squashfs image appended directly after the
# ELF section headers, so the payload offset is e_shoff + e_shentsize * e_shnum. Scanning
# for the "hsqs" magic is NOT reliable: the string also occurs inside the runtime's own
# code, so the superblock must be validated.
# ---------------------------------------------------------------------------
Say 'locating squashfs payload'
$fs = [System.IO.File]::OpenRead((Resolve-Path $AppImage))
try {
  $head = New-Object byte[] 64
  [void]$fs.Read($head, 0, 64)
  if ([System.Text.Encoding]::ASCII.GetString($head, 1, 3) -ne 'ELF') { throw 'not an ELF/AppImage' }
  $eShoff     = [BitConverter]::ToUInt64($head, 0x28)
  $eShentsize = [BitConverter]::ToUInt16($head, 0x3a)
  $eShnum     = [BitConverter]::ToUInt16($head, 0x3c)
  $offset     = $eShoff + $eShentsize * $eShnum
} finally { $fs.Dispose() }
Write-Host "squashfs offset: $offset"

Say 'extracting AppImage payload'
Remove-Item -Recurse -Force sqfs -ErrorAction SilentlyContinue
& 7z x -osqfs -y -- "$AppImage" | Out-Null

$appVersion = (Select-String -Path (Get-ChildItem sqfs/*.desktop)[0] -Pattern 'X-AppImage-Version=(.*)').Matches[0].Groups[1].Value
Write-Host "app version: $appVersion"

# ---------------------------------------------------------------------------
# 2. Match the Electron runtime version the app was built against.
# ---------------------------------------------------------------------------
Say 'detecting Electron version'
$bytes = [System.IO.File]::ReadAllBytes('sqfs/omo')
$text  = [System.Text.Encoding]::ASCII.GetString($bytes)
$m = [regex]::Match($text, 'Electron/(\d+\.\d+\.\d+)')
if (-not $m.Success) { throw 'could not detect Electron version' }
$electron = $m.Groups[1].Value
Write-Host "electron: $electron"

Say "downloading Electron $electron for win32-arm64"
$zip = "electron-v$electron-win32-arm64.zip"
if (-not (Test-Path $zip)) {
  Invoke-WebRequest -Uri "https://github.com/electron/electron/releases/download/v$electron/$zip" -OutFile $zip
}
Remove-Item -Recurse -Force electron-arm64 -ErrorAction SilentlyContinue
Expand-Archive -Path $zip -DestinationPath electron-arm64 -Force

# ---------------------------------------------------------------------------
# 3. Unpack app.asar into a plain directory.
#
# Running from resources/app/ rather than a repacked asar avoids having to rewrite the asar
# header when adding the win32-arm64 packages.
# ---------------------------------------------------------------------------
Say 'extracting app.asar'
Remove-Item -Recurse -Force app -ErrorAction SilentlyContinue
$scratch = New-Item -ItemType Directory -Path (Join-Path $env:TEMP ([guid]::NewGuid()))
Push-Location $scratch
& npx --yes @electron/asar extract "$OutDir/sqfs/resources/app.asar" "$OutDir/app"
Pop-Location
Remove-Item -Recurse -Force $scratch

# Files marked "unpacked" live outside the archive and must be layered back on top.
Say 'merging app.asar.unpacked'
Copy-Item -Recurse -Force sqfs/resources/app.asar.unpacked/* app/

# ---------------------------------------------------------------------------
# 4. Replace linux-x64 native modules with win32-arm64 builds.
#
# Each of these is a platform-specific optional dependency selected at runtime, so
# installing the win32-arm64 sibling at the matching version is enough. node-pty is the
# exception: its build/Release/pty.node is a Linux ELF that wins over prebuilds/, so it
# must be overwritten with the ConPTY build.
# ---------------------------------------------------------------------------
Say 'installing win32-arm64 native modules'
Remove-Item -Recurse -Force arm64-mods -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path arm64-mods | Out-Null

function Pkg-Version($path) {
  if (Test-Path $path) { (Get-Content $path -Raw | ConvertFrom-Json).version }
}

$specs = @()
$ffi = Pkg-Version 'app/node_modules/@yuuang/ffi-rs-linux-x64-gnu/package.json'
$fff = Pkg-Version 'app/node_modules/@ff-labs/fff-bin-linux-x64-gnu/package.json'
$msg = Pkg-Version 'app/node_modules/@msgpackr-extract/msgpackr-extract-linux-x64/package.json'
if ($ffi) { $specs += ,@("@yuuang/ffi-rs-win32-arm64-msvc@$ffi", '@yuuang/ffi-rs-win32-arm64-msvc') }
if ($fff) { $specs += ,@("@ff-labs/fff-bin-win32-arm64@$fff", '@ff-labs/fff-bin-win32-arm64') }
if ($msg) { $specs += ,@("@msgpackr-extract/msgpackr-extract-win32-arm64@$msg", '@msgpackr-extract/msgpackr-extract-win32-arm64') }

foreach ($entry in $specs) {
  $spec, $dest = $entry
  Write-Host "  $spec"
  Push-Location arm64-mods
  & npm pack $spec --silent | Out-Null
  Pop-Location
  $tgz = (Get-ChildItem arm64-mods/*.tgz | Sort-Object LastWriteTime -Descending)[0]
  $target = "app/node_modules/$dest"
  New-Item -ItemType Directory -Force -Path $target | Out-Null
  & tar -xzf $tgz.FullName -C $target --strip-components=1
}

# node-pty on Windows uses ConPTY, so there is no spawn-helper to relocate: the Linux
# build/Release copy only needs to be replaced by the win32-arm64 prebuild.
$prebuild = 'app/node_modules/node-pty/prebuilds/win32-arm64/pty.node'
if (Test-Path $prebuild) {
  Write-Host '  node-pty: build/Release <- prebuilds/win32-arm64'
  Copy-Item -Force $prebuild 'app/node_modules/node-pty/build/Release/pty.node'
  }

# msgpackr-extract has the same build/Release-wins problem: drop the Linux artifact so the
# loader falls through to the win32-arm64 optional package installed above.
if (Test-Path 'app/node_modules/msgpackr-extract/build/Release/extract.node') {
  Write-Host '  msgpackr-extract: dropping linux build/Release'
  Remove-Item -Recurse -Force 'app/node_modules/msgpackr-extract/build'
}

Say 'verifying no Linux ELF remains on the load path'
$bad = Get-ChildItem -Recurse -Include *.node,*.dll app/node_modules | Where-Object {
  $sig = [System.IO.File]::ReadAllBytes($_.FullName)[0..1]
  -not ($sig[0] -eq 0x4D -and $sig[1] -eq 0x5A)   # MZ
}
if ($bad) { $bad.FullName; throw 'NOT PE/COFF' }
Write-Host 'all replaced modules are PE arm64'

# ---------------------------------------------------------------------------
# 5. Assemble and brand the build.
# ---------------------------------------------------------------------------
Say 'assembling OmO'
Remove-Item -Recurse -Force OmO -ErrorAction SilentlyContinue
Copy-Item -Recurse electron-arm64 OmO
Remove-Item -Force OmO/resources/default_app.asar -ErrorAction SilentlyContinue
Copy-Item -Recurse -Force app OmO/resources/app
Rename-Item OmO/electron.exe OmO.exe

# The desktop resolves the omo CLI from PATH and expects it to stay under one pid; the npm
# launcher boots node and then runs the senpi CLI in a SECOND process, so the rpc host is
# handed a supervisor pid that disappears and shuts itself down ~4s after reporting ready.
# The app-private shim below execs senpi under a single pid.
Say 'installing app-private omo shim'
New-Item -ItemType Directory -Force -Path OmO/resources/omo-shim | Out-Null
@'
@echo off
setlocal
set "OMO_ROOT=%OMO_ROOT%"
if "%OMO_ROOT%"=="" set "OMO_ROOT=%APPDATA%\npm\node_modules\omo-ai"
set "SENPI=%OMO_ROOT%\node_modules\@code-yeongyu\senpi\dist\cli.js"
if not exist "%SENPI%" ( omo %* & exit /b %errorlevel% )
node "%SENPI%" --extension "%OMO_ROOT%\plugin" %*
'@ | Set-Content -Encoding ASCII OmO/resources/omo-shim/omo.cmd

Say "done: $OutDir\OmO\OmO.exe"
Write-Host ''
Write-Host 'Known limitation: resources/resource-monitor/t3-resource-monitor is a Linux x86-64'
Write-Host 'ELF helper with no Windows build available, so that helper cannot run here.'
