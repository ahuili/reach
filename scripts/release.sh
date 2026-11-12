#!/bin/zsh
# 打发布包：通用版 Reach.app → dist/Reach-<版本>.zip + .dmg + sha256 + brew cask 文件
# 用法：scripts/release.sh            只打包（不碰 GitHub）
#       scripts/release.sh --publish  打包后打 tag、推送、建 GitHub Release、更新 brew tap（需要 gh 已登录）
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/repo.env
VERSION=$(cat VERSION)
PUBLISH=0; [[ "${1:-}" == "--publish" ]] && PUBLISH=1

echo "▸ 版本 $VERSION"
# 1. 离线测试必须全过
swift build -c release --product ReachSelfTest 2>&1 | grep -v -E "PlatformPath|xcrun" | grep -E "error" && exit 1 || true
.build/release/ReachSelfTest | tail -1 | grep -q "全部通过" || { echo "✗ 离线测试没全过"; exit 1; }

# 2. 通用版 .app
scripts/build-app.sh --universal
APP=build/Reach.app
lipo -info $APP/Contents/MacOS/Reach $APP/Contents/MacOS/reachctl

# 3. zip（ditto 保留签名和扩展属性）+ dmg（带「应用程序」快捷方式）
mkdir -p dist
ZIP=dist/Reach-$VERSION.zip
DMG=dist/Reach-$VERSION.dmg
rm -f $ZIP $DMG
ditto -c -k --sequesterRsrc --keepParent $APP $ZIP
STAGE=$(mktemp -d)
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
hdiutil create -volname "Reach $VERSION" -srcfolder $STAGE -ov -format UDZO -quiet $DMG
rm -rf $STAGE
SHA_ZIP=$(shasum -a 256 $ZIP | awk '{print $1}')
SHA_DMG=$(shasum -a 256 $DMG | awk '{print $1}')
printf "%s  %s\n%s  %s\n" $SHA_ZIP ${ZIP:t} $SHA_DMG ${DMG:t} > dist/SHA256SUMS-$VERSION.txt

# 4. brew cask（从模板生成）
sed -e "s/{{VERSION}}/$VERSION/g" -e "s/{{SHA256}}/$SHA_ZIP/g" \
    -e "s/{{OWNER}}/$GITHUB_OWNER/g" -e "s/{{REPO}}/$GITHUB_REPO/g" -e "s/{{BUNDLE_ID}}/$BUNDLE_ID/g" \
    packaging/homebrew/reach.rb.tmpl > dist/reach.rb

# 5. 这一版的更新说明（CHANGELOG 里「## v版本」那一节）
awk -v v="## v$VERSION" '$0 ~ "^## v" { p = (index($0, v) == 1) } p' CHANGELOG.md > dist/release-notes-$VERSION.md
[[ -s dist/release-notes-$VERSION.md ]] || echo "⚠️ CHANGELOG.md 里没有「## v$VERSION」这一节"

ls -lh dist | grep -E "$VERSION|reach.rb"
echo "✓ 打包完成"

[[ $PUBLISH == 1 ]] || { echo "（只打包。要发布：scripts/release.sh --publish）"; exit 0; }

# ---- 发布 ----
[[ $GITHUB_OWNER != OWNER ]] || { echo "✗ 先在 scripts/repo.env 里填 GITHUB_OWNER"; exit 1; }
command -v gh >/dev/null || { echo "✗ 需要 gh：brew install gh && gh auth login"; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo "✗ 有没提交的改动"; exit 1; }
git tag -a v$VERSION -m "Reach v$VERSION" 2>/dev/null || echo "（tag v$VERSION 已存在）"
git push origin main --tags
gh release create v$VERSION $ZIP $DMG dist/SHA256SUMS-$VERSION.txt \
  --repo $GITHUB_OWNER/$GITHUB_REPO --title "Reach v$VERSION" --notes-file dist/release-notes-$VERSION.md

# 更新 brew tap 里的 Casks/reach.rb
TAP=$(mktemp -d)
gh repo clone $GITHUB_OWNER/$TAP_REPO $TAP -- -q
git -C $TAP config user.name "$(git config user.name)"; git -C $TAP config user.email "$(git config user.email)"
mkdir -p $TAP/Casks && cp dist/reach.rb $TAP/Casks/reach.rb
git -C $TAP add Casks/reach.rb
git -C $TAP commit -q -m "reach $VERSION" && git -C $TAP push -q
rm -rf $TAP
echo "✓ 已发布 v$VERSION：https://github.com/$GITHUB_OWNER/$GITHUB_REPO/releases/tag/v$VERSION"
