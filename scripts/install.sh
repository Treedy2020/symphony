#!/bin/sh
# install.sh: build the symphony + symphony-tracker escripts and install
# the wrapper scripts into ~/.local/bin so they're callable from any directory.
#
# Run this from the repo root after cloning, e.g.:
#   git clone https://github.com/Treedy2020/symphony && cd symphony
#   ./scripts/install.sh
#
# Prerequisites:
#   - mise (https://mise.jdx.dev/) with the elixir/erlang toolchain installed
#   - Run `cd elixir && mise install` once before this script if mise hasn't
#     populated the toolchain yet.

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="$HOME/.local/bin"

# ── 1. Build both escripts ──────────────────────────────────────────────────
echo "→ Building symphony + symphony-tracker (this takes ~30s on first run)"
cd "$REPO_ROOT/elixir"
mise exec -- mix deps.get >/dev/null
mise exec -- mix build

# ── 2. Install escript binaries to ~/.local/bin/.{symphony,symphony-tracker}-escript
mkdir -p "$BIN_DIR"
cp bin/symphony           "$BIN_DIR/.symphony-escript"
cp bin/symphony-tracker   "$BIN_DIR/.symphony-tracker-escript"
chmod +x "$BIN_DIR/.symphony-escript" "$BIN_DIR/.symphony-tracker-escript"

# ── 3. Install wrapper scripts (PATH-callable) ──────────────────────────────
cp "$REPO_ROOT/scripts/symphony"          "$BIN_DIR/symphony"
cp "$REPO_ROOT/scripts/symphony-tracker"  "$BIN_DIR/symphony-tracker"
cp "$REPO_ROOT/scripts/symphony-up"       "$BIN_DIR/symphony-up"
chmod +x "$BIN_DIR/symphony" "$BIN_DIR/symphony-tracker" "$BIN_DIR/symphony-up"

# ── 4. Sanity check ─────────────────────────────────────────────────────────
echo ""
echo "✓ Installed:"
ls -la "$BIN_DIR/symphony" "$BIN_DIR/symphony-tracker" "$BIN_DIR/symphony-up"

echo ""
case ":$PATH:" in
  *":$BIN_DIR:"*) echo "✓ $BIN_DIR is on your PATH — try: symphony --help" ;;
  *) echo "⚠ Add $BIN_DIR to your PATH:"
     echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc && source ~/.zshrc" ;;
esac
