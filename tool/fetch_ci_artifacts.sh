#!/usr/bin/env bash
# Downloads CI artifacts for the given run ids. GitHub serves a single-file
# artifact as that raw file, so payloads are stored as-is (no unpacking).
set -euo pipefail
export PATH="/d/Program Files/Git/mingw64/bin:$PATH"
export GCM_INTERACTIVE=Never GIT_TERMINAL_PROMPT=0
cd "$(dirname "$0")/.."
REPO=umeabc/PiliPlus
TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git -c credential.helper=manager credential fill | sed -n 's/^password=//p')
mkdir -p dist/ci
for run in "$@"; do
  curl -s -H "Authorization: Bearer $TOKEN" "https://api.github.com/repos/$REPO/actions/runs/$run/artifacts" \
    | python3 -c "import json,sys;[print(a['id'],a['name']) for a in json.load(sys.stdin)['artifacts']]" \
    | while read -r id name; do
        echo "downloading $name"
        curl -sL -H "Authorization: Bearer $TOKEN" -o "dist/ci/$name" \
          "https://api.github.com/repos/$REPO/actions/artifacts/$id/zip"
        size=$(stat -c %s "dist/ci/$name" 2>/dev/null || stat -f %z "dist/ci/$name")
        magic=$(head -c 2 "dist/ci/$name" | od -An -tx1 | tr -d ' \n')
        case "$magic" in
          4d5a) echo "  raw PE executable ($size bytes)" ;;
          7f45) echo "  raw ELF binary ($size bytes)" ;;
          504b) echo "  zip payload ($size bytes)" ;;
          *) echo "  UNEXPECTED payload magic=$magic size=$size" >&2; exit 1 ;;
        esac
      done
done
ls -l dist/ci
