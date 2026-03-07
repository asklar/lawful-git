# install.ps1 — install lawful-git on Windows
# Usage: iex (iwr https://raw.githubusercontent.com/asklar/lawful-git/main/install.ps1).Content
#Requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$InstallDir = "$env:LOCALAPPDATA\lawful-git"
$Target = Join-Path $InstallDir "git.exe"
$Repo = "asklar/lawful-git"

Write-Host "lawful-git installer"
Write-Host "===================="

# Detect architecture
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq "ARM64") { "arm64" } else { "amd64" }
Write-Host "Platform: windows-$Arch"

# Find real git
$realGitCmd = Get-Command git -ErrorAction SilentlyContinue
if (-not $realGitCmd) {
    Write-Error "git not found in PATH. Install Git for Windows first."
    exit 1
}
Write-Host "Real git: $($realGitCmd.Source)"

if (Test-Path $Target) {
    Write-Error "$Target already exists. Remove it first to reinstall."
    exit 1
}

# Download
$BinaryName = "lawful-git-windows-$Arch.exe"
$Url = "https://github.com/$Repo/releases/latest/download/$BinaryName"
Write-Host "Downloading $Url ..."

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
Invoke-WebRequest -Uri $Url -OutFile $Target

# Add to PATH
$currentPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
if ($currentPath -notlike "*$InstallDir*") {
    [Environment]::SetEnvironmentVariable('PATH', "$InstallDir;$currentPath", 'User')
    $env:PATH = "$InstallDir;$env:PATH"
    Write-Host "Added $InstallDir to user PATH."
}

Write-Host ""
Write-Host "lawful-git installed successfully."
Write-Host ""
Write-Host "To uninstall:"
Write-Host "  Remove-Item '$Target'"
Write-Host "  # Remove '$InstallDir' from your user PATH in System Properties"
