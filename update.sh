#!/usr/bin/env bash
set -euo pipefail

# Update all Scoop manifests to their latest GitHub release versions.
# Usage: ./update.sh [manifest_name]
#   No args: updates all .json manifests
#   With arg: updates only that manifest (e.g. ./update.sh loupe)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

update_manifest() {
  local json="$1"
  local name
  name="$(basename "$json" .json)"

  # Extract repo from homepage
  local homepage
  homepage=$(python3 -c "import json; print(json.load(open('$json'))['homepage'])")
  local repo
  repo=$(echo "$homepage" | sed 's|https://github.com/||')

  # Get latest release tag
  local latest
  latest=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null) || {
    echo "  ⏭  $name: no releases found, skipping"
    return
  }
  local latest_version="${latest#v}"

  # Get current version
  local current
  current=$(python3 -c "import json; print(json.load(open('$json'))['version'])")

  if [ "$current" = "$latest_version" ]; then
    echo "  ✓  $name: already at $current"
    return
  fi

  echo "  ↑  $name: $current → $latest_version"

  # Download the windows asset
  local tmpdir
  tmpdir=$(mktemp -d)
  gh release download "$latest" --repo "$repo" --dir "$tmpdir" --pattern "*windows*.zip" 2>/dev/null || {
    echo "       no windows zip found, skipping"
    rm -rf "$tmpdir"
    return
  }

  local asset
  asset=$(ls "$tmpdir"/*.zip 2>/dev/null | head -1)
  if [ -z "$asset" ]; then
    echo "       no zip asset downloaded, skipping"
    rm -rf "$tmpdir"
    return
  fi

  local sha
  sha=$(shasum -a 256 "$asset" | awk '{print $1}')

  # Update version, url, hash, and extract_dir using python3 for safe JSON editing
  python3 -c "
import json, re

with open('$json') as f:
    data = json.load(f)

old_ver = data['version']
new_ver = '$latest_version'

data['version'] = new_ver

# Update architecture URL and hash
if 'architecture' in data and '64bit' in data['architecture']:
    arch = data['architecture']['64bit']
    arch['url'] = arch['url'].replace(old_ver, new_ver)
    arch['hash'] = '$sha'

# Update extract_dir
if 'extract_dir' in data:
    data['extract_dir'] = data['extract_dir'].replace(old_ver, new_ver)

with open('$json', 'w') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write('\n')
"

  rm -rf "$tmpdir"
  echo "       updated $json"
}

if [ $# -gt 0 ]; then
  manifests=("$SCRIPT_DIR/$1.json")
else
  manifests=("$SCRIPT_DIR"/*.json)
fi

echo "Checking Scoop manifests..."
for json in "${manifests[@]}"; do
  if [ -f "$json" ]; then
    update_manifest "$json"
  else
    echo "  ✗  $(basename "$json"): not found"
  fi
done
