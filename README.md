# whisper-dictate

Local push-to-talk dictation for Omarchy / Hyprland, built on whisper.cpp.

Written as a replacement for Omarchy's bundled **Voxtype**, which ships only
AVX2 and AVX-512 binaries and therefore dies with `SIGILL: illegal
instruction` on any pre-Haswell CPU (Ivy Bridge, Sandy Bridge, older AMD).
whisper.cpp's `ggml-cpu` package selects a matching CPU kernel at runtime, so
it runs where Voxtype cannot.

Everything runs locally. No audio leaves the machine.

## Install

```bash
git clone <this-repo> ~/Work/whisper-dictate
cd ~/Work/whisper-dictate
./install.sh
```

Re-running is safe: it skips what is already installed and never overwrites an
existing config.

```bash
MODEL_NAME=ggml-tiny-q5_1.bin ./install.sh   # smaller/faster model
./install.sh --no-bindings                   # leave Hyprland keys alone
./uninstall.sh [--purge]
```

## Keys

| Key | Action |
| --- | --- |
| `F9` (hold) | Dictate in the configured default language |
| `F10` (hold) | Dictate in English |
| `Super+Ctrl+X` | Toggle dictation (default language) |

Text is typed at the cursor with `wtype`, falling back to the clipboard if
typing fails.

## What it installs

| Path | |
| --- | --- |
| `~/.local/bin/whisper-dictate` | the script |
| `~/.config/whisper-dictate/config` | settings (not overwritten on reinstall) |
| `~/.local/share/whisper-dictate/models/` | the Whisper model |
| `~/.config/hypr/whisper_dictate.lua` | keybindings |
| `~/.config/hypr/hyprland.lua` | one `require()` line appended (backed up first) |

Packages: `whisper-cpp`, `ggml-cpu`, `wtype`, `wl-clipboard`.

## Tuning notes

Measured on an Intel i5-3210M (Ivy Bridge, 2 cores / 4 threads, AVX but no
AVX2), 4-second clip, best of 3 runs. Three things dominate:

**1. Pin the language.** `LANGUAGE="auto"` makes Whisper run a separate
language-detection pass over the clip before transcribing. It roughly doubles
total time — the single most expensive default.

**2. Scale the audio context to the clip.** Whisper's encoder always processes
a 30-second window (`audio_ctx` 1500, i.e. 50 units per second), so a 4-second
take costs the same as a 30-second one unless you shrink it. The script
computes the context from the actual WAV length with a 35% margin.

That margin is not cosmetic. On an 11 s clip:

| `-ac` | Time | Result |
| --- | --- | --- |
| full (1500) | 4.3 s | correct |
| 660 (formula) | 1.7 s | correct |
| 550 | 13.8 s | hallucinated `(Music)`, garbled |
| 500 | 7.5 s | **truncated** — lost the ending |

Cutting too close is worse on both axes at once: the transcript degrades *and*
it gets slower, because Whisper starts retrying with temperature fallback.

**3. Prefer `q8_0` over `f16` — and over `q5_1`.**

| Model | Time | Notes |
| --- | --- | --- |
| `ggml-tiny-q5_1` | 3.3 s | noticeably less accurate |
| `ggml-base-q8_0` | 5.4 s | **default** — output identical to f16 in testing |
| `ggml-base` (f16) | 7.1 s | slower than q8_0, no accuracy gain |
| `ggml-base-q5_1` | 8.8 s | q5 dequantisation is expensive without AVX2 |
| `ggml-small-q5_1` | 19.2 s | too slow for dictation on this CPU |

Beam search turned out to be irrelevant here (5.35 s at `-bs 5` vs 5.54 s at
`-bs 1`), so the script leaves Whisper's default beam size alone and keeps the
accuracy it buys.

Combined, pinning the language plus the dynamic context took a 4 s take from
**9.0 s to 2.5 s**.

## Gotcha: a wrong language makes Whisper translate

Whisper does not merely lose accuracy when the language is wrong — it
translates. English speech transcribed with `-l es` comes out as Spanish
prose:

```
-l en  ->  And so my fellow Americans, ask not what your country can do for you...
-l es  ->  y así mi familia america. Puedes no hacer lo que su país puede hacer para ti...
```

This is why English gets its own key rather than a config change.

## Thermal throttling

On old laptops the CPU is usually the real bottleneck. Check before blaming
the model:

```bash
sensors | grep -E 'Core|fan'
```

Sustained temperatures at or above the `high` threshold mean the chip is
clocking down and every timing above roughly doubles. On the MacBook Pro 9,2
this was developed on, `fan1_output` requested 4088 RPM while `fan1_input`
read 0 — a fan that is commanded to spin and does not, which no amount of
software tuning fixes.

## Troubleshooting

```bash
whisper-dictate status          # idle | recording | transcribing
```

- **Nothing typed** — check `pactl get-default-source`, and that the take was
  longer than about a quarter second (shorter clips are discarded).
- **Endings clipped** — raise `CTX_MARGIN` in the config.
- **Output in the wrong language** — see the gotcha above; use F10 for English.
- **`SIGILL` from whisper-cli** — the `ggml-cpu` package is missing, so no CPU
  kernel is available.
