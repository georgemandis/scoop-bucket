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

  # Optional tag prefix for monorepo-resident tools (custom field Scoop ignores)
  local tag_prefix
  tag_prefix=$(python3 -c "import json; print(json.load(open('$json')).get('tag_prefix',''))" 2>/dev/null || echo "")

  # Get latest release tag
  local latest latest_version
  if [ -n "$tag_prefix" ]; then
    # Monorepo: pick the latest release whose tag starts with this product's prefix.
    latest=$(gh release list --repo "$repo" --limit 100 --json tagName -q "[.[].tagName | select(startswith(\"$tag_prefix\"))] | .[0]" 2>/dev/null | tr -d '\r') || latest=""
    if [ -z "$latest" ] || [ "$latest" = "null" ]; then
      echo "  ⏭  $name: no $tag_prefix* releases, skipping"
      return
    fi
    latest_version="${latest#$tag_prefix}"
  else
    latest=$(gh release view --repo "$repo" --json tagName -q .tagName 2>/dev/null) || {
      echo "  ⏭  $name: no releases found, skipping"
      return
    }
    latest_version="${latest#v}"
  fi

  # Get current version
  local current
  current=$(python3 -c "import json; print(json.load(open('$json'))['version'])")

  if [ "$current" = "$latest_version" ] && ! grep -q '"hash":[[:space:]]*"0\{64\}"' "$json"; then
    echo "  ✓  $name: already at $current"
    return
  fi

  echo "  ↑  $name: $current → $latest_version"

  # Pass 1: bump version + URL + extract_dir for whichever shape this manifest
  # uses (flat top-level url/hash, or architecture.64bit). Writes the file so the
  # finalized URL can be hashed next.
  python3 -c "
import json
with open('$json') as f:
    data = json.load(f)
old_ver = data['version']
new_ver = '$latest_version'
data['version'] = new_ver
if 'architecture' in data and '64bit' in data['architecture']:
    arch = data['architecture']['64bit']
    arch['url'] = arch['url'].replace(old_ver, new_ver)
elif 'url' in data:
    data['url'] = data['url'].replace(old_ver, new_ver)
if 'extract_dir' in data:
    data['extract_dir'] = data['extract_dir'].replace(old_ver, new_ver)
with open('$json', 'w') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write('\n')
"

  # Read the finalized URL back, hash exactly that (what Scoop will download).
  local url
  url=$(python3 -c "import json; d=json.load(open('$json')); print(d.get('url') or d.get('architecture',{}).get('64bit',{}).get('url',''))")
  local sha
  sha=$(set -o pipefail; curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')
  local curl_rc=$?
  if [ "$curl_rc" -ne 0 ] || [ -z "$sha" ]; then
    echo "  ✗  $name: failed to hash $url (curl exit $curl_rc)" >&2
    return 1
  fi

  # Pass 2: write the hash into the matching field (arch or flat).
  python3 -c "
import json
with open('$json') as f:
    data = json.load(f)
if 'architecture' in data and '64bit' in data['architecture']:
    data['architecture']['64bit']['hash'] = '$sha'
else:
    data['hash'] = '$sha'
with open('$json', 'w') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write('\n')
"

  echo "       updated $json ($latest_version)"
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
