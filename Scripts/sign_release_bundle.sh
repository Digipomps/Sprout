#!/usr/bin/env bash
set -euo pipefail

dist_dir="${1:-dist}"
checksum_file="${2:-}"

if ! command -v cosign >/dev/null 2>&1; then
  echo "cosign is required to sign the release bundle" >&2
  exit 1
fi

resolve_checksum_file() {
  local dist="$1"
  local explicit="${2:-}"
  if [[ -n "$explicit" ]]; then
    printf "%s" "$explicit"
    return 0
  fi

  shopt -s nullglob
  local candidates=("$dist"/SHA256SUMS*.b64url)
  shopt -u nullglob

  if [[ "${#candidates[@]}" -eq 1 ]]; then
    printf "%s" "${candidates[0]}"
    return 0
  fi

  if [[ "${#candidates[@]}" -eq 0 ]]; then
    echo "no checksum file found in $dist" >&2
  else
    echo "multiple checksum files found in $dist; pass the checksum file explicitly" >&2
  fi
  exit 1
}

sign_blob() {
  local artifact="$1"
  cosign sign-blob \
    --yes \
    --output-signature "${artifact}.sig" \
    --output-certificate "${artifact}.pem" \
    "${artifact}"
}

resolved_checksum_file="$(resolve_checksum_file "$dist_dir" "$checksum_file")"

while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file_name="$(awk '{print $2}' <<<"$line" | tr -d '*')"
  sign_blob "$dist_dir/$file_name"
done < "$resolved_checksum_file"

sign_blob "$resolved_checksum_file"
