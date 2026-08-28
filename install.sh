#!/bin/bash
# Installer for whisper-dictate. Safe to re-run: it never overwrites an
# existing config, and it skips anything already in place.
#
#   ./install.sh                      # install with defaults
#   MODEL_NAME=ggml-tiny-q5_1.bin ./install.sh
#   ./install.sh --no-bindings        # skip Hyprland keybindings

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BIN_DIR="$HOME/.local/bin"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/whisper-dictate"
DATA_DIR="$HOME/.local/share/whisper-dictate"
HYPR_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/hypr"

MODEL_NAME="${MODEL_NAME:-ggml-base-q8_0.bin}"
MODEL_BASE_URL="https://huggingface.co/ggerganov/whisper.cpp/resolve/main"

INSTALL_BINDINGS=1
[[ "${1:-}" == "--no-bindings" ]] && INSTALL_BINDINGS=0

info() { printf '\033[1;34m::\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mXX\033[0m %s\n' "$*" >&2; exit 1; }

# --- sanity ------------------------------------------------------------------

command -v pacman >/dev/null || die "This installer targets Arch/Omarchy (pacman not found)."

# ggml dispatches CPU kernels at runtime, so an older CPU just needs the
# ggml-cpu package -- but say so, since this is exactly why Voxtype fails.
if ! grep -qm1 avx2 /proc/cpuinfo; then
  warn "CPU has no AVX2. That is fine here (ggml picks a matching kernel at"
  warn "runtime), but Omarchy's voxtype-bin cannot run on this machine at all."
fi

# --- packages ----------------------------------------------------------------

PKGS=(whisper-cpp ggml-cpu wtype wl-clipboard)
MISSING=()
for p in "${PKGS[@]}"; do
  pacman -Q "$p" &>/dev/null || MISSING+=("$p")
done

if (( ${#MISSING[@]} )); then
  info "Installing: ${MISSING[*]}"
  if command -v omarchy-pkg-add >/dev/null; then
    omarchy-pkg-add "${MISSING[@]}"
  elif [[ -t 0 ]]; then
    sudo pacman -S --needed --noconfirm "${MISSING[@]}"
  else
    pkexec pacman -S --needed --noconfirm "${MISSING[@]}"
  fi
else
  info "Packages already installed."
fi

command -v pw-record >/dev/null || die "pw-record not found -- is PipeWire running?"

# --- model -------------------------------------------------------------------

mkdir -p "$DATA_DIR/models"
if [[ -f "$DATA_DIR/models/$MODEL_NAME" ]]; then
  info "Model already present: $MODEL_NAME"
else
  info "Downloading $MODEL_NAME (this is a few hundred MB at most)..."
  curl -fL# --retry 3 -o "$DATA_DIR/models/$MODEL_NAME.part" \
    "$MODEL_BASE_URL/$MODEL_NAME"
  mv -f "$DATA_DIR/models/$MODEL_NAME.part" "$DATA_DIR/models/$MODEL_NAME"
fi

# --- script ------------------------------------------------------------------

mkdir -p "$BIN_DIR"
install -m755 "$REPO_DIR/bin/whisper-dictate" "$BIN_DIR/whisper-dictate"
info "Installed $BIN_DIR/whisper-dictate"

case ":$PATH:" in
  *":$BIN_DIR:"*) ;;
  *) warn "$BIN_DIR is not on your PATH. The keybindings use an absolute path,"
     warn "so dictation still works, but the command will not be on your shell." ;;
esac

# --- config ------------------------------------------------------------------

mkdir -p "$CONFIG_DIR"
if [[ -f "$CONFIG_DIR/config" ]]; then
  info "Keeping existing config at $CONFIG_DIR/config"
else
  cp "$REPO_DIR/config/config.example" "$CONFIG_DIR/config"
  # Match the model actually installed, in case MODEL_NAME was overridden.
  sed -i "s|^MODEL=.*|MODEL=\"\$DATA_DIR/models/$MODEL_NAME\"|" "$CONFIG_DIR/config"
  info "Wrote $CONFIG_DIR/config"
fi

# --- hyprland bindings -------------------------------------------------------

if (( INSTALL_BINDINGS )); then
  if [[ ! -d "$HYPR_DIR" ]]; then
    warn "No $HYPR_DIR -- skipping keybindings."
  else
    install -m644 "$REPO_DIR/hypr/whisper_dictate.lua" "$HYPR_DIR/whisper_dictate.lua"
    info "Installed $HYPR_DIR/whisper_dictate.lua"

    if grep -q 'require("hypr.whisper_dictate")' "$HYPR_DIR/hyprland.lua" 2>/dev/null; then
      info "hyprland.lua already loads it."
    else
      cp "$HYPR_DIR/hyprland.lua" "$HYPR_DIR/hyprland.lua.bak.$(date +%s)"
      printf '\n-- Local dictation keybindings (whisper-dictate).\nrequire("hypr.whisper_dictate")\n' \
        >>"$HYPR_DIR/hyprland.lua"
      info "Added require() to hyprland.lua (backup alongside it)."
    fi

    if command -v hyprctl >/dev/null && hyprctl version &>/dev/null; then
      hyprctl reload >/dev/null && info "Hyprland reloaded."
      errs="$(hyprctl configerrors 2>/dev/null)"
      [[ -z "${errs//[[:space:]]/}" ]] || warn "hyprctl configerrors: $errs"
    fi
  fi
fi

# --- verify ------------------------------------------------------------------

info "Verifying..."
"$BIN_DIR/whisper-dictate" status >/dev/null || die "script failed to run"
whisper-cli --help >/dev/null 2>&1 || die "whisper-cli is not runnable"

cat <<EOF

Done.

  F9              hold to dictate (language: see $CONFIG_DIR/config)
  F10             hold to dictate in English
  Super+Ctrl+X    toggle dictation

Config: $CONFIG_DIR/config
Model:  $DATA_DIR/models/$MODEL_NAME
EOF
