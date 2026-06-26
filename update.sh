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

  # Treat the manifest as up-to-date only when the version matches AND no hash
  # slot is still zeroed. Hashes may be a string, a list, or under architecture.
  local has_zero_hash
  has_zero_hash=$(python3 -c "
import json
d = json.load(open('$json'))
zero = '0' * 64
def collect(x):
    if isinstance(x, str): return [x]
    if isinstance(x, list): return [v for v in x if isinstance(v, str)]
    return []
hashes = collect(d.get('hash'))
arch = d.get('architecture', {}).get('64bit', {})
hashes += collect(arch.get('hash'))
print('yes' if any(h == zero for h in hashes) else 'no')
")
  if [ "$current" = "$latest_version" ] && [ "$has_zero_hash" = "no" ]; then
    echo "  ✓  $name: already at $current"
    return
  fi

  echo "  ↑  $name: $current → $latest_version"

  # Pass 1: bump version + url(s) + extract_dir for whichever shape this manifest
  # uses: flat string url/hash, a top-level url/hash ARRAY, or architecture.64bit.
  python3 -c "
import json
with open('$json') as f:
    data = json.load(f)
old_ver = data['version']
new_ver = '$latest_version'
data['version'] = new_ver

def bump(v):
    return v.replace(old_ver, new_ver) if isinstance(v, str) else [x.replace(old_ver, new_ver) for x in v]

if 'architecture' in data and '64bit' in data['architecture']:
    arch = data['architecture']['64bit']
    arch['url'] = bump(arch['url'])
elif 'url' in data:
    data['url'] = bump(data['url'])
if 'extract_dir' in data:
    data['extract_dir'] = bump(data['extract_dir'])

with open('$json', 'w') as f:
    json.dump(data, f, indent=4, ensure_ascii=False)
    f.write('\n')
"

  # Emit the finalized URL(s) to hash, one per line (order preserved).
  local urls
  urls=$(python3 -c "
import json
d = json.load(open('$json'))
arch = d.get('architecture', {}).get('64bit')
if arch:
    print(arch['url'])
else:
    u = d.get('url', '')
    if isinstance(u, list):
        for x in u: print(x)
    else:
        print(u)
")

  # Hash each URL (what Scoop will download); abort loudly on any failure.
  local shas=() url sha curl_rc
  while IFS= read -r url; do
    [ -z "$url" ] && continue
    sha=$(set -o pipefail; curl -fsSL "$url" | shasum -a 256 | awk '{print $1}')
    curl_rc=$?
    if [ "$curl_rc" -ne 0 ] || [ -z "$sha" ]; then
      echo "  ✗  $name: failed to hash $url (curl exit $curl_rc)" >&2
      return 1
    fi
    shas+=("$sha")
  done <<< "$urls"

  # Pass 2: write the hash(es) back, matching the manifest's shape.
  SHAS="${shas[*]}" python3 -c "
import json, os
shas = os.environ['SHAS'].split()
with open('$json') as f:
    data = json.load(f)

if 'architecture' in data and '64bit' in data['architecture']:
    data['architecture']['64bit']['hash'] = shas[0]
elif isinstance(data.get('url'), list):
    data['hash'] = shas
else:
    data['hash'] = shas[0]

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
