#!/bin/bash

# Tests whisper-dictate by running the real script against mocked binaries on
# PATH, the same approach Omarchy's test/shell.d suite uses. Nothing here needs
# a microphone, a model, or a Wayland session.

set -uo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/base-test.sh"

SCRIPT="$ROOT/bin/whisper-dictate"

test_tmp=$(mktemp -d)
stub_recorders=()
cleanup() {
  local pid
  for pid in "${stub_recorders[@]}"; do
    kill "$pid" 2>/dev/null
  done
  rm -rf "$test_tmp"
}
trap cleanup EXIT

mock_bin="$test_tmp/bin"
mkdir -p "$mock_bin"

# --- mocks ------------------------------------------------------------------

# whisper-cli records the flags it was handed, then prints whatever the test
# asked it to. Checking those flags is the point: the language and the audio
# context are computed by the script and are otherwise invisible.
cat >"$mock_bin/whisper-cli" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$MOCK_CALL_LOG/whisper-cli"
printf '%s\n' "${MOCK_WHISPER_OUTPUT- And so my fellow Americans.}"
SH

cat >"$mock_bin/wtype" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$MOCK_CALL_LOG/wtype"
[[ ${MOCK_WTYPE_FAILS:-0} == 1 ]] && exit 1
exit 0
SH

for command in wl-copy pw-record notify-send omarchy-notification-send; do
  cat >"$mock_bin/$command" <<'SH'
#!/bin/bash
name=$(basename "$0")
printf '%s\n' "$*" >>"$MOCK_CALL_LOG/$name"
[[ $name == "wl-copy" ]] && cat >"$MOCK_CALL_LOG/clipboard"
exit 0
SH
done
chmod +x "$mock_bin"/*

# --- fixtures ---------------------------------------------------------------

# A WAV of a given length. The script reads duration from the file size
# (16 kHz mono s16 = 32000 bytes/s), so the bytes need not be real audio.
make_wav() {
  local secs=$1 path=$2
  printf 'RIFF____WAVEfmt ____________________________data____' >"$path"
  head -c $((secs * 32000)) /dev/zero >>"$path"
}

# Puts the script into the state it would be in mid-recording: a live recorder
# process, a captured WAV, and a chosen language.
# The stand-in recorder must not inherit stdout: an orphan holding the pipe
# open makes the whole suite hang until it expires.
given_recording() {
  local secs=$1 lang=$2
  make_wav "$secs" "$run_dir/whisper-dictate/recording.wav"
  sleep 300 >/dev/null 2>&1 &
  local recorder=$!
  stub_recorders+=("$recorder")
  echo "$recorder" >"$run_dir/whisper-dictate/record.pid"
  echo "$lang" >"$run_dir/whisper-dictate/language"
}

reset_env() {
  rm -rf "$test_tmp/run" "$test_tmp/cfg" "$test_tmp/calls"
  run_dir="$test_tmp/run"
  mkdir -p "$run_dir/whisper-dictate" "$test_tmp/cfg/whisper-dictate" "$test_tmp/calls"
  mkdir -p "$test_tmp/model"
  : >"$test_tmp/model/fake.bin"
  cat >"$test_tmp/cfg/whisper-dictate/config" <<EOF
MODEL="$test_tmp/model/fake.bin"
LANGUAGE="es"
OUTPUT_MODE="type"
NOTIFY=0
CTX_MARGIN=135
EOF
}

run_dictate() {
  XDG_RUNTIME_DIR="$run_dir" \
  XDG_CONFIG_HOME="$test_tmp/cfg" \
  MOCK_CALL_LOG="$test_tmp/calls" \
  PATH="$mock_bin:$PATH" \
    bash "$SCRIPT" "$@" 2>/dev/null
}

calls() { cat "$test_tmp/calls/$1" 2>/dev/null; }

# --- the regression that shipped --------------------------------------------
# `whisper-dictate start en` used to record the language but transcribe with
# the configured default anyway. Whisper does not merely lose accuracy on a
# mismatched language, it translates, so English dictation came out in Spanish.

reset_env
given_recording 4 en
run_dictate stop
assert_contains "$(calls whisper-cli)" "-l en" \
  "per-take language override reaches whisper-cli"
assert_not_contains "$(calls whisper-cli)" "-l es" \
  "per-take override replaces the configured default rather than adding to it"

reset_env
given_recording 4 ""
run_dictate stop
assert_contains "$(calls whisper-cli)" "-l es" \
  "falls back to the configured language when no override was given"

# --- audio context scaling --------------------------------------------------
# The encoder always processes a 30 s window unless told otherwise, so the
# script sizes the context to the clip. Too small truncates the transcript.

reset_env
given_recording 4 es
run_dictate stop
assert_contains "$(calls whisper-cli)" "-ac 337" \
  "a 4 s clip asks for a proportionally small audio context"

reset_env
given_recording 11 es
run_dictate stop
assert_contains "$(calls whisper-cli)" "-ac 810" \
  "an 11 s clip asks for a larger audio context"

reset_env
given_recording 25 es
run_dictate stop
assert_not_contains "$(calls whisper-cli)" "-ac" \
  "a clip near the 30 s window uses Whisper's full context"

# The margin must stay above 1.0: a context that only just covers the clip
# both truncates the text and runs slower via temperature fallback.
reset_env
given_recording 10 es
run_dictate stop
requested=$(calls whisper-cli | grep -oP '(?<=-ac )\d+')
if (( requested > 10 * 50 )); then
  pass "requested context exceeds the clip's own length, leaving margin"
else
  fail "requested context exceeds the clip's own length, leaving margin" \
    "clip needs $((10 * 50)), asked for $requested"
fi

# --- silence and empty results ----------------------------------------------

reset_env
given_recording 0 es
run_dictate stop
assert_equals "$(calls whisper-cli)" "" \
  "a clip too short to hold speech never reaches whisper-cli"

reset_env
given_recording 4 es
MOCK_WHISPER_OUTPUT="[BLANK_AUDIO]" run_dictate stop
assert_equals "$(calls wtype)" "" \
  "Whisper's bracketed silence markers are not typed out"

# --- output routing ---------------------------------------------------------

reset_env
given_recording 4 es
run_dictate stop
assert_contains "$(calls wtype)" "And so my fellow Americans." \
  "transcribed text is typed at the cursor"

reset_env
given_recording 4 es
MOCK_WTYPE_FAILS=1 run_dictate stop
assert_contains "$(calls clipboard)" "And so my fellow Americans." \
  "falls back to the clipboard when typing fails"

reset_env
sed -i 's/OUTPUT_MODE="type"/OUTPUT_MODE="clipboard"/' \
  "$test_tmp/cfg/whisper-dictate/config"
given_recording 4 es
run_dictate stop
assert_equals "$(calls wtype)" "" \
  "clipboard mode does not type"
assert_contains "$(calls clipboard)" "And so my fellow Americans." \
  "clipboard mode copies instead"

# --- state machine ----------------------------------------------------------

reset_env
assert_equals "$(run_dictate status)" "idle" \
  "reports idle before anything has run"

reset_env
run_dictate start
assert_equals "$(run_dictate status)" "recording" \
  "reports recording once started"
assert_contains "$(calls pw-record)" "--rate 16000" \
  "records at the sample rate Whisper expects"

# A second start must not clobber the language of a take already in progress.
reset_env
given_recording 4 en
run_dictate start es
assert_equals "$(cat "$run_dir/whisper-dictate/language")" "en" \
  "starting again mid-recording leaves the in-flight take untouched"

reset_env
given_recording 4 es
run_dictate stop
assert_equals "$(run_dictate status)" "idle" \
  "returns to idle after transcribing"

finish
