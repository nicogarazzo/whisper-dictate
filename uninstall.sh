#!/bin/bash
# Removes whisper-dictate. Leaves the installed packages (whisper-cpp etc.)
# and, unless --purge is given, your config and downloaded models.
#
#   ./uninstall.sh            # remove script and keybindings
#   ./uninstall.sh --purge    # also remove config and models

set -euo pipefail

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whisper-dictate"
DATA_DIR="$HOME/.local/share/whisper-dictate"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"

PURGE=0
[[ "${1:-}" == "--purge" ]] && PURGE=1

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }

rm -f "$BIN_DIR/whisper-dictate" && info "Removed $BIN_DIR/whisper-dictate"
rm -f "$HYPR_DIR/whisper_dictate.lua"

if [[ -f "$HYPR_DIR/hyprland.lua" ]] &&
   grep -q 'require("hypr.whisper_dictate")' "$HYPR_DIR/hyprland.lua"; then
  cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.bak.$(date +%s)"
  # Drop the require line and the comment directly above it.
  sed -i '/-- Local dictation keybindings (whisper-dictate)\./d; /require("hypr\.whisper_dictate")/d' \
    "$HYPR_DIR/hyprland.lua"
  info "Removed require() from hyprland.lua (backup alongside it)."
fi

if (( PURGE )); then
  rm -rf "$CONFIG_DIR" "$DATA_DIR"
  info "Removed config and models."
else
  info "Kept config ($CONFIG_DIR) and models ($DATA_DIR)."
fi

if command -v hyprctl >/dev/null && hyprctl version &>/dev/null; then
  hyprctl reload >/dev/null && info "Hyprland reloaded."
fi

info "Done. Note: Omarchy will rebind F9 / Super+Ctrl+X to Voxtype if it is installed."
