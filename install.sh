#!/usr/bin/env bash
# install.sh — install lawful-git on Linux/macOS
# Usage: curl -fsSL https://raw.githubusercontent.com/asklar/lawful-git/main/install.sh | bash
set -euo pipefail

LAWFUL_GIT_INSTALL_DIR="${LAWFUL_GIT_INSTALL_DIR:-/usr/local/lib/lawful-git}"
LAWFUL_GIT_SYMLINK="${LAWFUL_GIT_SYMLINK:-/usr/local/bin/git}"
REPO="asklar/lawful-git"

echo "lawful-git installer"
echo "===================="

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
if [ -e "$LAWFUL_GIT_SYMLINK" ]; then
    echo "❌ $LAWFUL_GIT_SYMLINK already exists." >&2
    echo "   Remove it first, or override the path:" >&2
    echo "   LAWFUL_GIT_SYMLINK=/your/path bash install.sh" >&2
    exit 1
fi

# Resolve download URL (latest release)
BINARY_NAME="lawful-git-${OS}-${ARCH}"
DOWNLOAD_URL="https://github.com/${REPO}/releases/latest/download/${BINARY_NAME}"

echo ""
echo "Install plan:"
echo "  Download: $DOWNLOAD_URL"
echo "  Binary:   $LAWFUL_GIT_INSTALL_DIR/lawful-git"
echo "  Symlink:  $LAWFUL_GIT_SYMLINK -> $LAWFUL_GIT_INSTALL_DIR/lawful-git"
echo ""

# Download binary
echo "Downloading lawful-git..."
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

# Install binary
mkdir -p "$LAWFUL_GIT_INSTALL_DIR"
mv "$TMPFILE" "$LAWFUL_GIT_INSTALL_DIR/lawful-git"
chmod +x "$LAWFUL_GIT_INSTALL_DIR/lawful-git"

# Create symlink
mkdir -p "$(dirname "$LAWFUL_GIT_SYMLINK")"
ln -s "$LAWFUL_GIT_INSTALL_DIR/lawful-git" "$LAWFUL_GIT_SYMLINK"

# Check PATH order
SYMLINK_DIR="$(dirname "$LAWFUL_GIT_SYMLINK")"
REAL_GIT_DIR="$(dirname "$REAL_GIT")"
symlink_before_real=false
IFS=: read -ra PATH_DIRS <<< "$PATH"
for dir in "${PATH_DIRS[@]}"; do
    resolved="$(cd "$dir" 2>/dev/null && pwd || echo "$dir")"
    if [ "$resolved" = "$SYMLINK_DIR" ]; then
        symlink_before_real=true
        break
    fi
    if [ "$resolved" = "$REAL_GIT_DIR" ]; then
        break
    fi
done
if [ "$symlink_before_real" = false ]; then
    echo ""
    echo "⚠️  PATH order warning: $SYMLINK_DIR must come before $REAL_GIT_DIR in PATH."
    echo "   Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    echo "   export PATH=\"$SYMLINK_DIR:\$PATH\""
fi

echo ""
echo "✅ lawful-git installed successfully."
echo ""
echo "To uninstall:"
echo "  rm \"$LAWFUL_GIT_SYMLINK\""
echo "  rm -rf \"$LAWFUL_GIT_INSTALL_DIR\""
