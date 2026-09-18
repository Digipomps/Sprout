#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/release_common.sh"

dist_dir="${1:-dist}"
checksum_file=$(release_checksum_file "$dist_dir" "${2:-}")
records=$(release_checksum_files "$dist_dir" "$checksum_file")
command -v cosign >/dev/null || { echo 'cosign is required to sign the release bundle' >&2; exit 1; }

sign_blob() {
  cosign sign-blob --yes --output-signature "$1.sig" --output-certificate "$1.pem" "$1"
}
while read -r expected name; do
  actual=$(openssl dgst -sha256 -binary "$dist_dir/$name" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
  [[ "$actual" == "$expected" ]] || { echo 'Artifact changed before signing' >&2; exit 1; }
done <<< "$records"
while read -r expected name; do sign_blob "$dist_dir/$name"; done <<< "$records"
sign_blob "$checksum_file"
