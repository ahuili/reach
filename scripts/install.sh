#!/bin/bash
# 一行安装 Reach（下载 GitHub 上最新的发布版，装到 /Applications）：
#   curl -fsSL https://raw.githubusercontent.com/ahuili/reach/main/scripts/install.sh | bash
set -euo pipefail
OWNER="${REACH_OWNER:-ahuili}"
REPO="${REACH_REPO:-reach}"
DEST="${REACH_DEST:-/Applications}"

[[ "$(uname)" == "Darwin" ]] || { echo "手边 Reach 只支持 macOS"; exit 1; }
major=$(sw_vers -productVersion | cut -d. -f1)
(( major >= 14 )) || { echo "手边 Reach 需要 macOS 14 (Sonoma) 或更新"; exit 1; }

echo "▸ 查找最新版本…"
tag=$(curl -fsSL "https://api.github.com/repos/$OWNER/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\(v[^"]*\)".*/\1/p' | head -1)
[[ -n "$tag" ]] || { echo "没找到发布版本"; exit 1; }
ver=${tag#v}
url="https://github.com/$OWNER/$REPO/releases/download/$tag/Reach-$ver.zip"

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
echo "▸ 下载 Reach $ver…"
curl -fL --progress-bar "$url" -o "$tmp/Reach.zip"
ditto -x -k "$tmp/Reach.zip" "$tmp"

if pgrep -x Reach >/dev/null || pgrep -x Margin >/dev/null; then echo "▸ 退出正在运行的 Reach…"; pkill -x Reach || true; pkill -x Margin || true; sleep 1; fi
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"
rm -rf "$DEST/Reach.app"
cp -R "$tmp/Reach.app" "$DEST/"
# 还没有 Apple 公证：去掉隔离标记，否则 macOS 会拦着不让打开
xattr -dr com.apple.quarantine "$DEST/Reach.app" 2>/dev/null || true
echo "✓ 已安装到 $DEST/Reach.app"
open "$DEST/Reach.app"
