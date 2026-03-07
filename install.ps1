# install.ps1 — install lawful-git on Windows
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = "$env:LOCALAPPDATA\lawful-git"
$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Definition

Write-Host "lawful-git installer"
Write-Host "===================="

# Find real git
$realGitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $realGitCmd) {
    Write-Error "git not found in PATH. Please install Git for Windows first."
    exit 1
}
$realGit = $realGitCmd.Source
Write-Host "Real git: $realGit"

# Check if git.exe already exists at install location
$target = Join-Path $InstallDir "git.exe"
if (Test-Path $target) {
    Write-Error "$target already exists. Remove it first or manually update it."
    exit 1
}

Write-Host ""
Write-Host "Install plan:"
Write-Host "  Binary:  $target (lawful-git renamed to git.exe)"
Write-Host "  Prepend $InstallDir to user PATH (ahead of real git)"
Write-Host ""
$answer = Read-Host "Proceed? [y/N]"
if ($answer -notmatch '^[Yy]$') {
    Write-Host "Aborted."
    exit 0
}

# Build the binary
Write-Host "Building lawful-git..."
Push-Location $ScriptDir
go build -o lawful-git.exe .
Pop-Location

# Install binary as git.exe so it intercepts git calls
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
Copy-Item (Join-Path $ScriptDir "lawful-git.exe") $target

# Prepend install dir to user PATH (ahead of real git)
$currentPath = [System.Environment]::GetEnvironmentVariable('PATH', 'User')
if ($currentPath -notlike "*$InstallDir*") {
    [System.Environment]::SetEnvironmentVariable('PATH', "$InstallDir;$currentPath", 'User')
    Write-Host "Added $InstallDir to user PATH."
} else {
    Write-Host "$InstallDir is already in user PATH."
}

Write-Host ""
Write-Host "✅ lawful-git installed successfully."
Write-Host ""
Write-Host "Restart your terminal or run the following to use lawful-git:"
Write-Host "  `$env:PATH = `"$InstallDir;`$env:PATH`""
Write-Host ""
Write-Host "To uninstall:"
Write-Host "  Remove-Item '$target'"
Write-Host "  # Remove '$InstallDir' from your user PATH in System Properties"
