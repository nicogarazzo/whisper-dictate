# whisper-dictate

Local push-to-talk dictation for Omarchy / Hyprland, built on whisper.cpp.

A fallback for hardware Omarchy's bundled **Voxtype** cannot run on. Voxtype
ships only AVX2 and AVX-512 binaries, so on any pre-Haswell CPU (Ivy Bridge,
Sandy Bridge, older AMD) every one of them aborts with `SIGILL: illegal
instruction`. whisper.cpp's `ggml-cpu` package picks a matching CPU kernel at
runtime, so it runs where Voxtype cannot.

On newer hardware, use Voxtype. See *Relationship to Omarchy and Voxtype*
below.

Everything runs locally. No audio leaves the machine.

## Install

```bash
git clone https://github.com/nicogarazzo/whisper-dictate ~/Work/whisper-dictate
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

## Tests

```bash
./test/all
```

18 tests, no microphone, model, or Wayland session required. The real script
runs against mocked binaries placed on `PATH`, mirroring the approach in
Omarchy's own `test/shell.d` suite. Assertions are made against the flags the
script hands to `whisper-cli`, since the language and the computed audio
context are otherwise invisible from the outside.

The suite exists because of a real regression: an edit that was supposed to
wire up the per-take language override silently failed to apply, so `F10`
recorded English and transcribed it as Spanish. The first test in the file
covers exactly that.

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

## Limitations

Stated plainly, because most of these are design trade-offs rather than bugs.

**Latency is not streaming.** Nothing is transcribed until you release the
key, so you always wait after speaking. Perceived latency is therefore the
full transcription time, not a trailing tail.

**Silence is still paid for.** There is no voice-activity detection, so a take
with two seconds of dead air at the end costs the encoder those two seconds.
`whisper-cli` has a `--vad` option that would trim this; it is not wired up.

**The model reloads on every take.** Roughly 100–300 ms for `base-q8_0`. A
persistent `whisper-server` would remove it, but the encoder dominates total
time, so the gain would be modest.

**The language is chosen before you speak, not detected.** That is a deliberate
trade — `auto` roughly doubles the time — but it means bilingual use needs two
keys, and a sentence that switches languages mid-way will be wrong whichever
key you pressed.

**Accuracy is spot-checked, not measured.** The claim that `q8_0` matches `f16`
rests on identical output for one English sample. There is no word-error-rate
benchmark, and Spanish accuracy in particular has not been quantified — it has
only been used and found good enough.

**The benchmarks come from one machine, and a throttled one.** An i5-3210M
running at 91–95 °C. The relative ordering of the options should hold
elsewhere; the absolute numbers will not.

**A take cannot be cancelled.** Releasing the key always transcribes. There is
no discard key, and no way to abort a 60-second take you regret at second two.

**`install.sh` is not covered by tests.** Only the runtime script is.

**Tested on exactly one CPU and one distro.** Everything here is
Arch/Omarchy-specific: `pacman`, PipeWire, Hyprland, `wtype`.

## Next steps

Roughly in order of value:

1. **Voice-activity detection** to trim leading and trailing silence before
   the encoder sees it. Likely the largest remaining speedup, and it composes
   with the audio-context scaling rather than replacing it.
2. **A cancel binding** that stops a recording and discards it.
3. **A word-error-rate benchmark**, in Spanish and English, so model and
   quantisation choices rest on measurement instead of one spot-check.
4. **A status widget for the Omarchy bar.** The script already writes
   `idle` / `recording` / `transcribing` to `$XDG_RUNTIME_DIR/whisper-dictate/state`
   for exactly this; nothing consumes it yet.
5. **Tests for `install.sh`**, using the same mocking approach.
6. **Verification on other hardware** — particularly a non-throttled CPU, to
   separate the model's cost from this laptop's thermal problem.

## Relationship to Omarchy and Voxtype

Omarchy ships [Voxtype](https://github.com/peteonrails/voxtype) as its
dictation tool. This project does not aim to replace that choice, and it is
not a fork: Voxtype is a far more capable program, and on any CPU from 2013
onward it is the right thing to use.

The gap this fills is narrow. Voxtype's published packages target the
x86-64-v3 baseline, so on pre-Haswell hardware every shipped binary aborts
with `SIGILL`. That has been reported to Omarchy twice, in
[#7883](https://github.com/basecamp/omarchy/issues/7883) and
[#8312](https://github.com/basecamp/omarchy/issues/8312), and
[PR #7890](https://github.com/basecamp/omarchy/pull/7890) proposes refusing
the install on such CPUs. That is the correct fix for the broken-install bug —
but it leaves those users with no dictation at all. This is something for them
to run instead.

Worth noting that Voxtype is MIT-licensed and builds from source, so the more
durable fix is upstream: a baseline build in Voxtype's own release matrix
would resolve this for every distribution at once, not just Omarchy.

Prior art in the same space: [Somnius/VoxTyper](https://github.com/Somnius/VoxTyper)
takes a similar whisper.cpp approach for Arch and Fedora.

## License

MIT. Copy it, adapt it, take it to your own Omarchy.
