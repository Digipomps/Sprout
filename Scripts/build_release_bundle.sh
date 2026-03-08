#!/usr/bin/env bash
set -euo pipefail

dist_dir="${1:-dist}"
artifact_suffix="${2:-${SPROUT_RELEASE_SUFFIX:-}}"
module_cache_dir="${dist_dir}/.module-cache"

suffix_part() {
  local suffix="$1"
  if [[ -n "$suffix" ]]; then
    printf -- "-%s" "$suffix"
  fi
}

artifact_name() {
  local base="$1"
  local suffix="$2"
  printf "%s%s" "$base" "$(suffix_part "$suffix")"
}

manifest_name="release-manifest$(suffix_part "$artifact_suffix").json"
checksum_name="SHA256SUMS$(suffix_part "$artifact_suffix").b64url"
sbom_name="sprout$(suffix_part "$artifact_suffix").spdx.json"
sprout_name="$(artifact_name "sprout" "$artifact_suffix")"
updater_name="$(artifact_name "sprout-updater" "$artifact_suffix")"

mkdir -p "$module_cache_dir"
export CLANG_MODULE_CACHE_PATH="$module_cache_dir"
export SWIFT_MODULE_CACHE_PATH="$module_cache_dir"

swift build -c release --product sprout
swift build -c release --product sprout-updater

mkdir -p "$dist_dir"
cp .build/release/sprout "$dist_dir/$sprout_name"
cp .build/release/sprout-updater "$dist_dir/$updater_name"

swift Scripts/generate_release_manifest.swift \
  "$dist_dir" \
  "$dist_dir/$sprout_name" \
  "$dist_dir/$updater_name"

if [[ "$manifest_name" != "release-manifest.json" ]]; then
  mv "$dist_dir/release-manifest.json" "$dist_dir/$manifest_name"
fi

if [[ "$checksum_name" != "SHA256SUMS.b64url" ]]; then
  mv "$dist_dir/SHA256SUMS.b64url" "$dist_dir/$checksum_name"
fi

swift Scripts/generate_spdx_sbom.swift Package.swift "$dist_dir/$sbom_name"
