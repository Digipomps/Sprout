#!/usr/bin/env bash
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
binary=${1:-"$repo/.build/debug/sprout"}
test -x "$binary"
temporary=$(mktemp -d "${TMPDIR:-/tmp}/sprout-terminal-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
export XDG_STATE_HOME="$temporary/default-state"

printf 'nei\n' | "$binary" > "$temporary/refused.log"
test ! -e "$XDG_STATE_HOME"
"$binary" onboard --state-dir "$temporary/eof" < /dev/null > "$temporary/eof.log"
test ! -e "$temporary/eof"

printf 'ja\nny\n\n\n\nsenere\nja\n' | "$binary" > "$temporary/offline.log"
root="$XDG_STATE_HOME/haven/sprout"
test -f "$root/onboarding.json"
seed="$root/identities/local.sprout.invalid/keys/ed25519.seed"
before=$(shasum -a 256 "$seed")
printf 'ja\n/status\nsenere\nja\n' | "$binary" chat > "$temporary/resume.log"
test "$before" = "$(shasum -a 256 "$seed")"
grep -q 'Forrige kontroll: localOnly' "$temporary/resume.log"
test ! -e "$root/scaffold-identities"

printf 'ja\n\n\n\n\n\nja\nnei\n' | "$binary" onboard \
  --state-dir "$temporary/flags" --entity-mode existing --domain example.test \
  > "$temporary/flags.log"
grep -q 'Lagret oenske: existing' "$temporary/flags.log"
test ! -e "$temporary/flags/scaffold-identities"

if "$binary" onboard --yes --state-dir "$temporary/invalid" > "$temporary/invalid.log" 2>&1; then
  echo 'Unexpected global consent bypass' >&2; exit 1
fi
test ! -e "$temporary/invalid"

printf 'corrupt' > "$root/onboarding.json"
if printf 'ja\n' | "$binary" > "$temporary/corrupt.log" 2>&1; then
  echo 'Unexpected recovery by replacing identity' >&2; exit 1
fi
test "$before" = "$(shasum -a 256 "$seed")"
grep -q 'ikke slett\|Ikke slett' "$temporary/corrupt.log"
echo 'PASS: default chat, refusal, EOF, resume, optional arguments, no --yes bypass, corrupt-state recovery guard'
