#!/usr/bin/env bash
# install.sh — install lawful-git on Linux/macOS
set -euo pipefail

LAWFUL_GIT_INSTALL_DIR="${LAWFUL_GIT_INSTALL_DIR:-/usr/local/lib/lawful-git}"
LAWFUL_GIT_SYMLINK="${LAWFUL_GIT_SYMLINK:-/usr/local/bin/git}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "lawful-git installer"
echo "===================="

# Check for Go
if ! command -v go &>/dev/null; then
    echo "❌ Go is not installed." >&2
    echo "   Install it from https://go.dev/dl/ and re-run this script." >&2
    exit 1
fi

# Check if symlink target already exists
if [ -e "$LAWFUL_GIT_SYMLINK" ]; then
    echo "❌ $LAWFUL_GIT_SYMLINK already exists." >&2
    echo "   Remove it first, or override the path:" >&2
    echo "   LAWFUL_GIT_SYMLINK=/your/path $0" >&2
    exit 1
fi

# Find the real git
REAL_GIT="$(command -v git || true)"
if [ -z "$REAL_GIT" ]; then
    echo "❌ git not found in PATH." >&2
    exit 1
fi

# Check PATH order: warn if symlink dir doesn't precede real git dir
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
    echo "⚠️  PATH order warning: $SYMLINK_DIR must come before $REAL_GIT_DIR in PATH."
    echo "   Add this to your shell profile (~/.bashrc, ~/.zshrc, etc.):"
    echo "   export PATH=\"$SYMLINK_DIR:\$PATH\""
fi

echo ""
echo "Install plan:"
echo "  Binary:  $LAWFUL_GIT_INSTALL_DIR/lawful-git"
echo "  Symlink: $LAWFUL_GIT_SYMLINK -> $LAWFUL_GIT_INSTALL_DIR/lawful-git"
echo "  Real git: $REAL_GIT"
echo ""
read -r -p "Proceed? [y/N] " answer
if [[ ! "$answer" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Build the binary
echo "Building lawful-git..."
(cd "$SCRIPT_DIR" && go build -o lawful-git .)

# Install binary
mkdir -p "$LAWFUL_GIT_INSTALL_DIR"
cp "$SCRIPT_DIR/lawful-git" "$LAWFUL_GIT_INSTALL_DIR/lawful-git"
chmod +x "$LAWFUL_GIT_INSTALL_DIR/lawful-git"

# Create symlink
mkdir -p "$(dirname "$LAWFUL_GIT_SYMLINK")"
ln -s "$LAWFUL_GIT_INSTALL_DIR/lawful-git" "$LAWFUL_GIT_SYMLINK"

echo ""
echo "✅ lawful-git installed successfully."
echo ""
echo "To uninstall:"
echo "  rm \"$LAWFUL_GIT_SYMLINK\""
echo "  rm -rf \"$LAWFUL_GIT_INSTALL_DIR\""
