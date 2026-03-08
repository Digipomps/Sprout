#!/bin/zsh
set -euo pipefail

dist_dir="${1:-dist}"

artifact="${2:-$dist_dir/sprout}"
checksum_file="${3:-$dist_dir/SHA256SUMS.b64url}"

swift run sprout-updater verify-bundle --artifact-path "$artifact" --checksum-file "$checksum_file"

if [[ -f "$dist_dir/SHA256SUMS.b64url.asc" ]]; then
  gpg --verify "$dist_dir/SHA256SUMS.b64url.asc" "$dist_dir/SHA256SUMS.b64url"
fi

verify_cosign_blob() {
  local artifact="$1"
  local signature="${artifact}.sig"
  local certificate="${artifact}.pem"
  if [[ -f "$signature" && -f "$certificate" ]]; then
    if ! command -v cosign >/dev/null 2>&1; then
      echo "cosign signatures found, but cosign is not installed" >&2
      exit 1
    fi
    cosign verify-blob \
      --certificate "$certificate" \
      --signature "$signature" \
      --certificate-identity-regexp "${COSIGN_CERT_IDENTITY_REGEXP:-https://github.com/.+}" \
      --certificate-oidc-issuer "${COSIGN_CERT_OIDC_ISSUER:-https://token.actions.githubusercontent.com}" \
      "$artifact"
  fi
}

verify_cosign_blob "$dist_dir/sprout"
verify_cosign_blob "$dist_dir/sprout-updater"
verify_cosign_blob "$dist_dir/SHA256SUMS.b64url"
