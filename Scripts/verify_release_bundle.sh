#!/usr/bin/env bash
set -euo pipefail

dist_dir="${1:-dist}"
artifact_path="${2:-}"
checksum_file="${3:-}"

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

resolved_checksum_file="$(resolve_checksum_file "$dist_dir" "$checksum_file")"

artifacts=()
if [[ -n "$artifact_path" ]]; then
  artifacts=("$artifact_path")
else
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    file_name="$(awk '{print $2}' <<<"$line" | tr -d '*')"
    artifacts+=("$dist_dir/$file_name")
  done < "$resolved_checksum_file"
fi

for artifact in "${artifacts[@]}"; do
  swift run sprout-updater verify-bundle --artifact-path "$artifact" --checksum-file "$resolved_checksum_file"
done

asc_file="${resolved_checksum_file}.asc"
if [[ -f "$asc_file" ]]; then
  gpg --verify "$asc_file" "$resolved_checksum_file"
fi

for artifact in "${artifacts[@]}"; do
  verify_cosign_blob "$artifact"
done
verify_cosign_blob "$resolved_checksum_file"
