#!/bin/zsh
set -euo pipefail

dist_dir="${1:-dist}"
module_cache_dir="${dist_dir}/.module-cache"

mkdir -p "$module_cache_dir"
export CLANG_MODULE_CACHE_PATH="$module_cache_dir"
export SWIFT_MODULE_CACHE_PATH="$module_cache_dir"

swift build -c release --product sprout
swift build -c release --product sprout-updater

mkdir -p "$dist_dir"
cp .build/release/sprout "$dist_dir/"
cp .build/release/sprout-updater "$dist_dir/"

/usr/bin/swift Scripts/generate_release_manifest.swift "$dist_dir" "$dist_dir/sprout" "$dist_dir/sprout-updater"
/usr/bin/swift Scripts/generate_spdx_sbom.swift Package.swift "$dist_dir/sprout.spdx.json"
