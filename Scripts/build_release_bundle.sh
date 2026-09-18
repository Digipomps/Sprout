#!/usr/bin/env bash
set -euo pipefail

dist_dir="${1:-dist}"
artifact_suffix="${2:-${SPROUT_RELEASE_SUFFIX:-}}"
swift_bin=${SPROUT_SWIFT_BIN:-swift}
host_os=$(uname -s)
host_arch=$(uname -m)
case "$host_os" in Darwin) host_os=macos ;; Linux) host_os=linux ;; *) echo 'Unsupported build host' >&2; exit 1 ;; esac
if [[ "$host_os" == linux && "$host_arch" == arm64 ]]; then host_arch=aarch64; fi
platform=${artifact_suffix:-"$host_os-$host_arch"}
case "$platform" in macos-arm64|macos-x86_64|linux-x86_64|linux-aarch64) ;; *) echo 'Invalid release platform' >&2; exit 1 ;; esac
objcopy_bin=''

build_args=(--disable-automatic-resolution --skip-update --jobs "${SPROUT_BUILD_JOBS:-4}")
if [[ "${SPROUT_DISABLE_SANDBOX:-0}" == 1 ]]; then build_args+=(--disable-sandbox); fi
if [[ "$platform" == linux-* ]]; then
  [[ -n "${SPROUT_STATIC_LINUX_SDK:-}" ]] || {
    echo 'Linux delivery requires SPROUT_STATIC_LINUX_SDK and a matching open-source Swift toolchain, not a renamed native binary' >&2; exit 1;
  }
  [[ "$SPROUT_STATIC_LINUX_SDK" == "${platform#linux-}-swift-linux-musl" ]] || {
    echo 'SDK and requested architecture do not match' >&2; exit 1;
  }
  build_args+=(--swift-sdk "$SPROUT_STATIC_LINUX_SDK")
  if [[ -n "${SPROUT_SWIFT_SDKS_PATH:-}" ]]; then build_args+=(--swift-sdks-path "$SPROUT_SWIFT_SDKS_PATH"); fi
  if [[ -n "${SPROUT_OBJCOPY_BIN:-}" ]]; then
    objcopy_bin=$SPROUT_OBJCOPY_BIN
  elif [[ -x "$(dirname "$swift_bin")/llvm-objcopy" ]]; then
    objcopy_bin="$(dirname "$swift_bin")/llvm-objcopy"
  else
    objcopy_bin=$(command -v llvm-objcopy || command -v objcopy || true)
  fi
  [[ -n "$objcopy_bin" ]] && command -v "$objcopy_bin" >/dev/null || {
    echo 'Linux packaging requires llvm-objcopy or objcopy to exclude debug data' >&2; exit 1;
  }
elif [[ "$platform" != "$host_os-$host_arch" ]]; then
  echo 'Requested platform does not match native build host' >&2; exit 1
fi
nearby_build_args=("${build_args[@]}")
if [[ -n "${SPROUT_SCRATCH_PATH:-}" ]]; then
  build_args+=(--scratch-path "$SPROUT_SCRATCH_PATH" --cache-path "$SPROUT_SCRATCH_PATH/cache"
    --config-path "$SPROUT_SCRATCH_PATH/config" --security-path "$SPROUT_SCRATCH_PATH/security")
  nearby_build_args+=(--scratch-path "$SPROUT_SCRATCH_PATH/nearby" --cache-path "$SPROUT_SCRATCH_PATH/nearby/cache"
    --config-path "$SPROUT_SCRATCH_PATH/nearby/config" --security-path "$SPROUT_SCRATCH_PATH/nearby/security")
fi

nearby_package=''
nearby_revision=''
if [[ "$platform" == macos-* ]]; then
  nearby_checkout=${SPROUT_CELLPROTOCOL_CHECKOUT:-.release-dependencies/CellProtocol}
  nearby_revision=$(cat ci/cellprotocol-nearby-revision.txt)
  [[ "$nearby_revision" =~ ^[0-9a-f]{40}$ && -d "$nearby_checkout" ]] || {
    echo 'macOS packaging requires the pinned CellProtocol checkout for haven-nearby' >&2; exit 1;
  }
  [[ $(git -C "$nearby_checkout" rev-parse HEAD) == "$nearby_revision" &&
     -z $(git -C "$nearby_checkout" status --porcelain --untracked-files=all -- Packages/CellNearby) ]] || {
    echo 'Nearby source must match the exact clean published package revision' >&2; exit 1;
  }
  nearby_package=$(cd "$nearby_checkout/Packages/CellNearby" && pwd -P)
fi

module_cache="${SPROUT_SCRATCH_PATH:-.build}/release-script-module-cache"
mkdir -p "$dist_dir" "$module_cache"
export CLANG_MODULE_CACHE_PATH="$module_cache"
export SWIFT_MODULE_CACHE_PATH="$module_cache"
"$swift_bin" build "${build_args[@]}" -c release --product sprout
"$swift_bin" build "${build_args[@]}" -c release --product sprout-updater
bin_dir=$("$swift_bin" build "${build_args[@]}" -c release --show-bin-path)
swift Scripts/validate_release_platform.swift "$platform" "$bin_dir/sprout" "$bin_dir/sprout-updater"

suffix="${artifact_suffix:+-$artifact_suffix}"
for product in sprout sprout-updater; do
  if [[ "$platform" == linux-* ]]; then
    "$objcopy_bin" --strip-debug "$bin_dir/$product" "$dist_dir/$product$suffix"
  else
    cp "$bin_dir/$product" "$dist_dir/$product$suffix"
  fi
done
swift Scripts/validate_release_platform.swift "$platform" "$dist_dir/sprout$suffix" "$dist_dir/sprout-updater$suffix"
swift Scripts/generate_spdx_sbom.swift Package.swift "$dist_dir/sprout$suffix.spdx.json"
artifacts=("$dist_dir/sprout$suffix" "$dist_dir/sprout-updater$suffix" "$dist_dir/sprout$suffix.spdx.json")
if [[ -n "$nearby_package" ]]; then
  # Separate package and build directory keep protocol source and ownership upstream.
  (cd "$nearby_package" && "$swift_bin" build "${nearby_build_args[@]}" -c release --product haven-nearby)
  nearby_bin_dir=$(cd "$nearby_package" && "$swift_bin" build "${nearby_build_args[@]}" -c release --show-bin-path)
  cp "$nearby_bin_dir/haven-nearby" "$dist_dir/haven-nearby$suffix"
  swift Scripts/validate_release_platform.swift "$platform" "$dist_dir/haven-nearby$suffix"
  printf '{"schema":"sprout.nearby-source.v1","repository":"https://github.com/Digipomps/CellProtocol","revision":"%s","package":"Packages/CellNearby"}\n' "$nearby_revision" > "$dist_dir/nearby-source$suffix.json"
  artifacts+=("$dist_dir/haven-nearby$suffix" "$dist_dir/nearby-source$suffix.json")
fi
swift Scripts/generate_release_manifest.swift "$dist_dir" "${artifacts[@]}"
if [[ -n "$suffix" ]]; then
  mv "$dist_dir/release-manifest.json" "$dist_dir/release-manifest$suffix.json"
  mv "$dist_dir/SHA256SUMS.b64url" "$dist_dir/SHA256SUMS$suffix.b64url"
fi
manifest="release-manifest$suffix.json"
hash=$(openssl dgst -sha256 -binary "$dist_dir/$manifest" | openssl base64 -A | tr '+/' '-_' | tr -d '=')
printf '%s *%s\n' "$hash" "$manifest" >> "$dist_dir/SHA256SUMS$suffix.b64url"
echo "Built $platform artifacts. Not signed or certified for delivery yet."
