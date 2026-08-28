#!/bin/bash

# Minimal test helpers, mirroring the shape of Omarchy's own test/shell.d
# harness so these tests read the same way to anyone who works on that repo.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

FAILURES=0

pass() {
  printf '\033[1;32m  ok\033[0m %s\n' "$1"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf '\033[1;31mFAIL\033[0m %s\n' "$1" >&2
  if [[ -n ${2:-} ]]; then
    printf '     %s\n' "$2" >&2
  fi
}

finish() {
  if (( FAILURES > 0 )); then
    printf '\n\033[1;31m%d failure(s)\033[0m\n' "$FAILURES" >&2
    exit 1
  fi
  printf '\n\033[1;32mAll tests passed.\033[0m\n'
}

# Assert helpers -------------------------------------------------------------

assert_contains() {
  local haystack=$1 needle=$2 what=$3
  if [[ $haystack == *"$needle"* ]]; then
    pass "$what"
  else
    fail "$what" "expected to find: $needle"
  fi
}

assert_not_contains() {
  local haystack=$1 needle=$2 what=$3
  if [[ $haystack == *"$needle"* ]]; then
    fail "$what" "did not expect to find: $needle"
  else
    pass "$what"
  fi
}

assert_equals() {
  local actual=$1 expected=$2 what=$3
  if [[ $actual == "$expected" ]]; then
    pass "$what"
  else
    fail "$what" "expected '$expected', got '$actual'"
  fi
}
