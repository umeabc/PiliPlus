#!/usr/bin/env bash
# Creates the GitHub release for PiliPlus EE and uploads the signed APK.
# The token is read from Git Credential Manager and never printed.
set -euo pipefail
export PATH="/d/Program Files/Git/mingw64/bin:$PATH"
export GCM_INTERACTIVE=Never GIT_TERMINAL_PROMPT=0
cd "$(dirname "$0")/.."

TAG="${TAG:-v2.2.1-e1}"
NAME="${NAME:-PiliPlus EE 2.2.1-e1}"
APK="dist/PiliPlus-EE-2.2.1-e1-arm64.apk"
REPO="umeabc/PiliPlus"

TOKEN=$(printf 'protocol=https\nhost=github.com\n\n' | git -c credential.helper=manager credential fill | sed -n 's/^password=//p')
if [ -z "$TOKEN" ]; then echo "No stored GitHub credential" >&2; exit 1; fi

CHECK=$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $TOKEN" \
  "https://api.github.com/repos/$REPO/releases/tags/$TAG")
if [ "$CHECK" = "200" ]; then
  echo "Release $TAG already exists; nothing to do."
  exit 0
fi

BODY=$(cat <<'MD'
个人使用的 PiliPlus 增强版（跟随上游 2.2.1）。

### 本版新增
- 大肥鱼评论屏蔽：四档关键词规则（小杯/标准/杀戮/只屏蔽@），简繁通吃，支持自定义关键词与昵称
- 保留置顶整棵子树；楼中楼三种处理策略（只删命中 / 命中则隐藏整楼 / 不处理）
- 评论区「已屏蔽 N 条」计数，按账号与稿件隔离
- 批量删评 / 拉黑：需逐项勾选 + 二次确认；删评仅限本人视频；限速、`-509` 退避、`-352` 等风控立即停止
- 详情见仓库 `DAFEIYU.md`

### 安装
- 应用名 **PiliPlus EE**，包名 `com.umeabc.piliplus`，可与官方 PiliPlus 共存
- 请妥善保存本版本签名；后续升级必须使用同一签名的 APK
- 覆盖安装前请勿卸载，否则本地设置与账本会丢失

### 校验
见 `SHA256SUMS.txt`。

> 关键词过滤必然存在误判；批量删评/拉黑为不可逆操作，默认关闭、需手动确认。
MD
)

python3 - "$TAG" "$NAME" <<'PY2' > .tmp/release.json
import json,sys
tag,name=sys.argv[1],sys.argv[2]
body = """个人使用的 PiliPlus 增强版（跟随上游 2.2.1）。

### 本版新增
- 大肥鱼评论屏蔽：四档关键词规则（小杯/标准/杀戮/只屏蔽@），简繁通吃，支持自定义关键词与昵称
- 保留置顶整棵子树；楼中楼三种处理策略（只删命中 / 命中则隐藏整楼 / 不处理）
- 评论区「已屏蔽 N 条」计数，按账号与稿件隔离
- 批量删评 / 拉黑：需逐项勾选 + 二次确认；删评仅限本人视频；限速、-509 退避、-352 等风控立即停止
- 详情见仓库 DAFEIYU.md

### 安装
- 应用名 PiliPlus EE，包名 com.umeabc.piliplus，可与官方 PiliPlus 共存
- 请妥善保存本版本签名；后续升级必须使用同一签名的 APK
- 覆盖安装前请勿卸载，否则本地设置与账本会丢失

### 校验
见 SHA256SUMS.txt。

> 关键词过滤必然存在误判；批量删评/拉黑为不可逆操作，默认关闭、需手动确认。"""
sys.stdout.buffer.write(json.dumps({"tag_name":tag,"name":name,"body":body,"draft":False,"prerelease":False},ensure_ascii=False).encode("utf-8"))
PY2
python3 -c "import json;json.load(open('.tmp/release.json',encoding='utf-8'))"

RESP=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Accept: application/vnd.github+json' \
  -H 'Content-Type: application/json' --data-binary @.tmp/release.json \
  "https://api.github.com/repos/$REPO/releases")
UPLOAD=$(printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('upload_url',''))")
RELEASE_URL=$(printf '%s' "$RESP" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('html_url',''))")
if [ -z "$UPLOAD" ]; then echo "Release creation failed: $RESP" >&2; exit 1; fi
echo "Release: $RELEASE_URL"

UPLOAD_BASE=${UPLOAD%%\{*}
for asset in "$APK" "dist/SHA256SUMS.txt"; do
  fname=$(basename "$asset")
  code=$(curl -s -o /tmp/upload.out -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/octet-stream' \
    --data-binary "@$asset" "$UPLOAD_BASE?name=$fname&label=")
  echo "upload $fname -> HTTP $code"
done
echo "DONE $RELEASE_URL"
