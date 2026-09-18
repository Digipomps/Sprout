#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/release_common.sh"

dist_dir="${1:-dist}"
artifact_path="${2:-}"
checksum_file=$(release_checksum_file "$dist_dir" "${3:-}")
allow_unsigned=${SPROUT_ALLOW_UNSIGNED:-0}
publisher='^https://github\.com/Digipomps/Sprout/\.github/workflows/release\.yml@refs/tags/v[0-9][A-Za-z0-9._-]*$'

verify_signature() {
  local artifact="$1"
  if [[ ! -e "$artifact.sig" && ! -L "$artifact.sig" && ! -e "$artifact.pem" && ! -L "$artifact.pem" && "$allow_unsigned" == 1 ]]; then return; fi
  [[ -f "$artifact.sig" && ! -L "$artifact.sig" && -f "$artifact.pem" && ! -L "$artifact.pem" ]] || {
    echo 'Missing or unsafe release signature; refusing unsigned delivery' >&2; exit 1;
  }
  command -v cosign >/dev/null || { echo 'Install trusted cosign to verify this release before executing it' >&2; exit 1; }
  local identity_args=(--certificate-identity-regexp "$publisher")
  if [[ -n "${COSIGN_CERT_IDENTITY:-}" ]]; then identity_args=(--certificate-identity "$COSIGN_CERT_IDENTITY"); fi
  cosign verify-blob --certificate "$artifact.pem" --signature "$artifact.sig" \
    "${identity_args[@]}" --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' "$artifact"
}

# Authenticate the manifest first; never execute downloaded binaries to verify them.
verify_signature "$checksum_file"
records=$(release_checksum_files "$dist_dir" "$checksum_file")
selected=0
while read -r expected name; do
  artifact="$dist_dir/$name"
  if [[ -n "$artifact_path" && "$artifact_path" != "$artifact" ]]; then continue; fi
  selected=$((selected + 1))
  actual=$(openssl dgst -sha256 -binary "$artifact" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  [[ "$actual" == "$expected" ]] || { echo "Checksum mismatch: $name" >&2; exit 1; }
  verify_signature "$artifact"
done <<< "$records"
[[ "$selected" -gt 0 ]] || { echo 'Requested artifact is not in the verified manifest' >&2; exit 1; }
if [[ "$allow_unsigned" == 1 ]]; then
  echo 'Integrity-only development check passed. This is NOT a verified publisher release.'
else
  echo 'Checksums and HAVEN publisher signatures verified. Runtime functionality is a separate release gate.'
fi
