#!/usr/bin/env bash

release_checksum_files() {
  local dist="$1" sums="$2" line hash name count=0 seen=$'\n'
  local pattern='^([A-Za-z0-9_-]{43}) [*]([A-Za-z0-9][A-Za-z0-9._-]*)$'
  [[ -f "$sums" && ! -L "$sums" ]] || { echo 'Invalid checksum file' >&2; return 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    [[ "$line" =~ $pattern ]] || { echo 'Invalid checksum record' >&2; return 1; }
    hash="${BASH_REMATCH[1]}" name="${BASH_REMATCH[2]}"
    [[ "$seen" != *$'\n'"$name"$'\n'* ]] || { echo 'Duplicate checksum record' >&2; return 1; }
    [[ -f "$dist/$name" && ! -L "$dist/$name" ]] || { echo 'Missing or unsafe artifact' >&2; return 1; }
    seen+="$name"$'\n'
    count=$((count + 1))
    printf '%s %s\n' "$hash" "$name"
  done < "$sums"
  [[ "$count" -gt 0 ]] || { echo 'Empty checksum file' >&2; return 1; }
}

release_checksum_file() {
  local dist="$1" explicit="${2:-}"
  if [[ -n "$explicit" ]]; then printf '%s\n' "$explicit"; return; fi
  local files=()
  shopt -s nullglob
  files=("$dist"/SHA256SUMS*.b64url)
  [[ ${#files[@]} -eq 1 ]] || { echo 'Pass exactly one checksum file' >&2; return 1; }
  printf '%s\n' "${files[0]}"
}
