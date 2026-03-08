#!/bin/zsh
set -euo pipefail

dist_dir="${1:-dist}"

if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign is required to sign the release bundle" >&2
  exit 1
fi

sign_blob() {
  local artifact="$1"
  cosign sign-blob \
    --yes \
    --output-signature "${artifact}.sig" \
    --output-certificate "${artifact}.pem" \
    "${artifact}"
}

sign_blob "${dist_dir}/sprout"
sign_blob "${dist_dir}/sprout-updater"
sign_blob "${dist_dir}/SHA256SUMS.b64url"
