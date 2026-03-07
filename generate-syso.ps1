# Regenerate .syso resource files from the Windows manifest.
# Requires: go install github.com/akavel/rsrc@latest
$ErrorActionPreference = "Stop"

$manifest = "lawful-git.manifest"
if (-not (Test-Path $manifest)) {
    Write-Error "$manifest not found"
    exit 1
}

if (-not (Get-Command rsrc -ErrorAction SilentlyContinue)) {
    Write-Host "Installing rsrc..."
    go install github.com/akavel/rsrc@latest
}

rsrc -manifest $manifest -arch amd64 -o rsrc_windows_amd64.syso
rsrc -manifest $manifest -arch arm64 -o rsrc_windows_arm64.syso
Write-Host "Generated rsrc_windows_amd64.syso and rsrc_windows_arm64.syso"
