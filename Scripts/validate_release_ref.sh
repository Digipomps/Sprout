#!/usr/bin/env bash
set -euo pipefail

ref=${GITHUB_REF:-}
tag=${SPROUT_REQUESTED_RELEASE_TAG:-${ref#refs/tags/}}
[[ "$tag" =~ ^v[0-9][A-Za-z0-9._-]*$ && "$ref" == "refs/tags/$tag" ]] || {
  echo 'Release must run from the exact requested version tag, never from a branch or another tag' >&2
  exit 1
}
[[ $(git rev-parse HEAD) == "$(git rev-parse "$ref^{commit}")" ]] || {
  echo 'Checked-out source does not match the release tag' >&2
  exit 1
}
echo "Release source verified: $tag"
