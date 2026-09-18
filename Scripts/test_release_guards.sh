#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
binary=${1:-"$repo/.build/debug/sprout"}
temporary=$(mktemp -d "${TMPDIR:-/tmp}/sprout-release-test.XXXXXX")
trap 'rm -rf "$temporary"' EXIT
bundle="$temporary/bundle"
mkdir -p "$bundle"
printf 'synthetic artifact\n' > "$bundle/sprout"
digest() { openssl dgst -sha256 -binary "$1" | openssl base64 -A | tr '+/' '-_' | tr -d '='; }
hash=$(digest "$bundle/sprout")
sums="$bundle/SHA256SUMS.b64url"
printf '%s *sprout\n' "$hash" > "$sums"
reject() {
  if "$@" > "$temporary/rejected.log" 2>&1; then echo 'Expected refusal' >&2; exit 1; fi
}
verify=(bash "$repo/Scripts/verify_release_bundle.sh" "$bundle")
reject env SPROUT_ALLOW_UNSIGNED=0 "${verify[@]}"
env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}" > /dev/null
printf 'tamper' >> "$bundle/sprout"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
printf 'synthetic artifact\n' > "$bundle/sprout"
printf '%s *../outside\n' "$hash" > "$sums"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
printf '%s *sprout\n%s *sprout\n' "$hash" "$hash" > "$sums"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
: > "$sums"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
printf '%s *sprout\n' "$hash" > "$sums"
mv "$bundle/sprout" "$temporary/original"
ln -s "$temporary/original" "$bundle/sprout"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
rm "$bundle/sprout"
mv "$temporary/original" "$bundle/sprout"
: > "$sums.sig"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
rm "$sums.sig"
ln -s "$temporary/missing-signature" "$sums.sig"
reject env SPROUT_ALLOW_UNSIGNED=1 "${verify[@]}"
rm "$sums.sig"

# A local test double verifies signer-selection wiring, not Sigstore cryptography.
mkdir -p "$temporary/bin"
cat > "$temporary/bin/cosign" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >> "$COSIGN_TEST_LOG"
[[ "$1" == verify-blob ]]
MOCK
chmod 700 "$temporary/bin/cosign"
for item in "$sums" "$bundle/sprout"; do : > "$item.sig"; : > "$item.pem"; done
PATH="$temporary/bin:$PATH" COSIGN_TEST_LOG="$temporary/cosign.log" SPROUT_ALLOW_UNSIGNED=0 "${verify[@]}" > /dev/null
grep -Fq 'Digipomps/Sprout/' "$temporary/cosign.log"
grep -Fq 'refs/tags/v[0-9]' "$temporary/cosign.log"
! grep -Fq 'https://github.com/.+' "$temporary/cosign.log"
reject env SPROUT_STATIC_LINUX_SDK='' bash "$repo/Scripts/build_release_bundle.sh" "$temporary/mislabeled" linux-x86_64
test ! -e "$temporary/mislabeled"
if [[ $(uname -s) == Darwin ]]; then
  reject env SPROUT_CELLPROTOCOL_CHECKOUT="$temporary/missing-source" bash "$repo/Scripts/build_release_bundle.sh" "$temporary/missing-companion" "macos-$(uname -m)"
  test ! -e "$temporary/missing-companion"
fi

mkdir -p "$temporary/source"
(
  cd "$temporary/source"
  git init -q
  git -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m fixture
  git tag v1.2.3
  if [[ $(uname -s) == Darwin ]]; then
    (cd "$repo"; reject env SPROUT_CELLPROTOCOL_CHECKOUT="$temporary/source" bash "$repo/Scripts/build_release_bundle.sh" "$temporary/wrong-companion" "macos-$(uname -m)")
    test ! -e "$temporary/wrong-companion"
  fi
  GITHUB_REF=refs/tags/v1.2.3 SPROUT_REQUESTED_RELEASE_TAG=v1.2.3 bash "$repo/Scripts/validate_release_ref.sh" > /dev/null
  reject env GITHUB_REF=refs/heads/main SPROUT_REQUESTED_RELEASE_TAG=v1.2.3 bash "$repo/Scripts/validate_release_ref.sh"
  reject env GITHUB_REF=refs/tags/v1.2.3 SPROUT_REQUESTED_RELEASE_TAG=v2.0.0 bash "$repo/Scripts/validate_release_ref.sh"
  git -c user.name=Test -c user.email=test@example.invalid commit -q --allow-empty -m other
  reject env GITHUB_REF=refs/tags/v1.2.3 SPROUT_REQUESTED_RELEASE_TAG=v1.2.3 bash "$repo/Scripts/validate_release_ref.sh"
)

swiftc "$repo/Scripts/validate_release_platform.swift" -o "$temporary/inspect"
dd if=/dev/zero of="$temporary/elf" bs=120 count=1 2>/dev/null
printf '\177ELF\002\001' | dd of="$temporary/elf" bs=1 conv=notrunc 2>/dev/null
printf '\002\000\076\000' | dd of="$temporary/elf" bs=1 seek=16 conv=notrunc 2>/dev/null
printf '\100' | dd of="$temporary/elf" bs=1 seek=32 conv=notrunc 2>/dev/null
printf '\070\000\001\000' | dd of="$temporary/elf" bs=1 seek=54 conv=notrunc 2>/dev/null
printf '\001' | dd of="$temporary/elf" bs=1 seek=64 conv=notrunc 2>/dev/null
"$temporary/inspect" linux-x86_64 "$temporary/elf" > /dev/null
reject "$temporary/inspect" linux-aarch64 "$temporary/elf"
printf '\003' | dd of="$temporary/elf" bs=1 seek=64 conv=notrunc 2>/dev/null
reject "$temporary/inspect" linux-x86_64 "$temporary/elf"
printf '\002' | dd of="$temporary/elf" bs=1 seek=64 conv=notrunc 2>/dev/null
printf '\170' | dd of="$temporary/elf" bs=1 seek=72 conv=notrunc 2>/dev/null
printf '\020' | dd of="$temporary/elf" bs=1 seek=96 conv=notrunc 2>/dev/null
printf '\001\000\000\000\000\000\000\000\000\000\000\000\000\000\000\000' >> "$temporary/elf"
reject "$temporary/inspect" linux-x86_64 "$temporary/elf"
if [[ $(uname -s) == Darwin ]]; then
  "$temporary/inspect" "macos-$(uname -m)" "$binary" > /dev/null
  reject "$temporary/inspect" linux-x86_64 "$binary"
fi
echo 'PASS: unsigned, tamper, traversal, duplicates, empty, symlink, partial signature, publisher selection, release ref/source, missing/wrong Nearby source, wrong platform and dynamic ELF guards'
