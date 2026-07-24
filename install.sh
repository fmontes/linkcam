#!/usr/bin/env bash
#
# Symlinks `linkcam` into a directory on your PATH so you can run it anywhere.
# The script keeps finding its bin/ helpers via the symlink, so no copying.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pick the first writable, PATH-listed install dir.
for d in /opt/homebrew/bin /usr/local/bin "$HOME/.local/bin"; do
    if [ -d "$d" ] && [ -w "$d" ]; then TARGET_DIR="$d"; break; fi
done

if [ -z "${TARGET_DIR:-}" ]; then
    echo "No writable directory found on PATH." >&2
    echo "Create one (e.g. mkdir -p ~/.local/bin and add it to PATH), then re-run." >&2
    exit 1
fi

ln -sf "$REPO_DIR/linkcam" "$TARGET_DIR/linkcam"
echo "✓ installed: $TARGET_DIR/linkcam -> $REPO_DIR/linkcam"
echo "Try:  linkcam status"
