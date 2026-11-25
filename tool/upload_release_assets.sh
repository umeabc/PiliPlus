#!/usr/bin/env bash
# Uploads extra release assets and refreshes SHA256SUMS.txt on an existing release.
set -euo pipefail
export PATH="/d/Program Files/Git/mingw64/bin:$PATH"
export GCM_INTERACTIVE=Never GIT_TERMINAL_PROMPT=0
cd "$(dirname "$0")/.."
REPO=umeabc/PiliPlus
TAG=${TAG:-v2.2.1-e1}
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git -c credential.helper=manager credential fill | sed -n 's/^password=//p')

REL=$(curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$REPO/releases/tags/$TAG")
UPLOAD=$(printf '%s' "$REL" | python3 -c "import json,sys;print(json.load(sys.stdin).get('upload_url',''))")
[ -n "$UPLOAD" ] || { echo "release $TAG not found" >&2; exit 1; }
UPLOAD_BASE=${UPLOAD%%\{*}

for asset in "$@"; do
  fname=$(basename "$asset")
  code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/octet-stream' \
    --data-binary "@$asset" "$UPLOAD_BASE?name=$fname&label=")
  echo "upload $fname -> HTTP $code"
done

# Refresh checksums: drop the old asset, then upload the regenerated file.
OLD_ID=$(printf '%s' "$REL" | python3 -c "import json,sys
for a in json.load(sys.stdin).get('assets',[]):
    if a['name']=='SHA256SUMS.txt': print(a['id'])")
if [ -n "$OLD_ID" ]; then
  curl -s -o /dev/null -X DELETE -H "Authorization: Bearer $TOKEN" \
    "https://api.github.com/repos/$REPO/releases/assets/$OLD_ID"
fi
sha256sum dist/PiliPlus-EE-*.apk dist/ci/* > dist/SHA256SUMS.txt
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/octet-stream' \
  --data-binary "@dist/SHA256SUMS.txt" "$UPLOAD_BASE?name=SHA256SUMS.txt&label=")
echo "upload SHA256SUMS.txt -> HTTP $code"
cat dist/SHA256SUMS.txt
