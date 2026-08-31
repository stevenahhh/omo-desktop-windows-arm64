# OmO Desktop — unofficial Windows arm64 port

Rebuilds **OmO Desktop 0.0.33**, published only as a Linux x86-64 AppImage, into a native
`win32-arm64` build. No emulation, no VM, no WSL.

Unofficial and unaffiliated with T3 Tools. Ships no binaries in git.

## Why this works

Only the Electron runtime and four native modules are platform-specific; `resources/app.asar`
is plain JavaScript. So the port is a substitution, not a rewrite: swap the runtime for the
matching `win32-arm64` Electron release, swap each `linux-x64` native module for its
`win32-arm64` sibling, and the application code runs unchanged.

## Usage

```powershell
winget install 7zip.7zip          # only extra dependency
.\port-omo-win-arm64.ps1 C:\path\to\OmO-0.0.33-x86_64.AppImage
.\omo-win-build\OmO\OmO.exe
```

Requires Windows 11 on arm64, Node.js (for `npx`/`npm`), and PowerShell 7+.
Output defaults to `.\omo-win-build`.

## Limitations

- `t3-resource-monitor` is a Linux x86-64 ELF with no Windows build, so that helper cannot run.
- `node-pty` uses ConPTY here, so the `spawn-helper` path is skipped entirely.

## Downloads

Prebuilt archive: see [Releases](../../releases).
