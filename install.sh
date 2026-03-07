#!/usr/bin/env bash
# install.sh — install lawful-git on Linux/macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/asklar/lawful-git/main/install.sh | bash
set -euo pipefail

INSTALL_DIR="/usr/local/lib/lawful-git"
SYMLINK="/usr/local/bin/git"
REPO="asklar/lawful-git"

echo ""
echo "  ██╗      █████╗ ██╗    ██╗███████╗██╗   ██╗██╗"
echo "  ██║     ██╔══██╗██║    ██║██╔════╝██║   ██║██║"
echo "  ██║     ███████║██║ █╗ ██║█████╗  ██║   ██║██║"
echo "  ██║     ██╔══██║██║███╗██║██╔══╝  ██║   ██║██║"
echo "  ███████╗██║  ██║╚███╔███╔╝██║     ╚██████╔╝███████╗"
echo "  ╚══════╝╚═╝  ╚═╝ ╚══╝╚══╝ ╚═╝      ╚═════╝ ╚══════╝"
echo "           ┌─┐┬┌┬┐   git guardrails for AI agents"
echo "           │ ┬│ │ "
echo "           └─┘┴ ┴ "
echo ""

# Detect OS and architecture
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) echo "❌ Unsupported architecture: $ARCH" >&2; exit 1 ;;
esac
echo "Platform: ${OS}-${ARCH}"

# Find the real git
REAL_GIT="$(command -v git || true)"
if [ -z "$REAL_GIT" ]; then
    echo "❌ git not found in PATH." >&2
    exit 1
fi
echo "Real git: $REAL_GIT"

# Check if symlink target already exists
if [ -e "$SYMLINK" ]; then
    echo "❌ $SYMLINK already exists." >&2
    echo "   Remove it first if you want to reinstall." >&2
    exit 1
fi

# Download binary
BINARY_NAME="lawful-git-${OS}-${ARCH}"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${BINARY_NAME}"
echo "Downloading $DOWNLOAD_URL ..."

TMPFILE="$(mktemp)"
trap 'rm -f "$TMPFILE"' EXIT
if command -v curl &>/dev/null; then
    curl -fSL -o "$TMPFILE" "$DOWNLOAD_URL"
elif command -v wget &>/dev/null; then
    wget -qO "$TMPFILE" "$DOWNLOAD_URL"
else
    echo "❌ Neither curl nor wget found." >&2
    exit 1
fi

# Install
sudo mkdir -p "$INSTALL_DIR"
sudo mv "$TMPFILE" "$INSTALL_DIR/lawful-git"
sudo chmod +x "$INSTALL_DIR/lawful-git"
sudo ln -s "$INSTALL_DIR/lawful-git" "$SYMLINK"

echo ""
echo "✅ lawful-git installed successfully."
echo ""
echo "To uninstall:"
echo "  sudo rm \"$SYMLINK\""
echo "  sudo rm -rf \"$INSTALL_DIR\""
