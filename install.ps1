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
$RealGitDir = Split-Path $realGitCmd.Source
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

# Determine if real git is in system PATH (common case: C:\Program Files\Git\cmd)
$SystemPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
$GitInSystemPath = $SystemPath -like "*$RealGitDir*"

if ($GitInSystemPath) {
    Write-Host ""
    Write-Host "Git is in the system PATH. lawful-git needs to be added to the system PATH"
    Write-Host "(ahead of git) to intercept git calls. This requires administrator privileges."
    Write-Host ""

    # Check if already elevated
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if ($isAdmin) {
        $SystemPath = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
        if ($SystemPath -notlike "*$InstallDir*") {
            [Environment]::SetEnvironmentVariable('PATH', "$InstallDir;$SystemPath", 'Machine')
            $env:PATH = "$InstallDir;$env:PATH"
            Write-Host "Added $InstallDir to system PATH (ahead of git)."
        }
    } else {
        Write-Host "Requesting elevation to modify system PATH..."
        $script = @"
`$sp = [Environment]::GetEnvironmentVariable('PATH', 'Machine')
if (`$sp -notlike '*$InstallDir*') {
    [Environment]::SetEnvironmentVariable('PATH', '$InstallDir;' + `$sp, 'Machine')
    Write-Host 'Done.'
} else {
    Write-Host 'Already in system PATH.'
}
"@
        Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile", "-Command", $script -Wait
        $env:PATH = "$InstallDir;$env:PATH"
    }
} else {
    # Git is only in user PATH, so user PATH works
    $UserPath = [Environment]::GetEnvironmentVariable('PATH', 'User')
    if ($UserPath -notlike "*$InstallDir*") {
        [Environment]::SetEnvironmentVariable('PATH', "$InstallDir;$UserPath", 'User')
        $env:PATH = "$InstallDir;$env:PATH"
        Write-Host "Added $InstallDir to user PATH."
    }
}

Write-Host ""
Write-Host "lawful-git installed successfully."
Write-Host ""
Write-Host "To uninstall:"
Write-Host "  Remove-Item '$Target'"
Write-Host "  # Remove '$InstallDir' from your PATH (system or user) in System Properties"
