#!/bin/zsh
# 构建 手边 Reach（build/Reach.app）。用法：scripts/build-app.sh [--install] [--universal]
#   --install    装到 ~/Applications 并重启
#   --universal  同时编 Apple 芯片 + Intel，合成通用二进制（发布用）
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/repo.env
VERSION=$(cat VERSION)
INSTALL=0; UNIVERSAL=0
for a in "$@"; do case $a in --install) INSTALL=1;; --universal) UNIVERSAL=1;; esac; done

build() { swift build -c release --product $1 "${@:2}" 2>&1 | grep -v -E "PlatformPath|XCTest|xcrun" || true; }
build Reach; build reachctl
[[ -x .build/release/Reach && -x .build/release/reachctl ]] || { echo "构建失败"; exit 1; }
APPBIN=.build/release/Reach; CTLBIN=.build/release/reachctl
if [[ $UNIVERSAL == 1 ]]; then
  build Reach --triple x86_64-apple-macosx14.0 --scratch-path .build/x86
  build reachctl --triple x86_64-apple-macosx14.0 --scratch-path .build/x86
  [[ -x .build/x86/release/Reach && -x .build/x86/release/reachctl ]] || { echo "Intel 版构建失败"; exit 1; }
  mkdir -p .build/universal
  lipo -create -output .build/universal/Reach $APPBIN .build/x86/release/Reach
  lipo -create -output .build/universal/reachctl $CTLBIN .build/x86/release/reachctl
  APPBIN=.build/universal/Reach; CTLBIN=.build/universal/reachctl
fi

APP=build/Reach.app
rm -rf $APP build/Margin.app
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $APPBIN $APP/Contents/MacOS/Reach
cp $CTLBIN $APP/Contents/MacOS/reachctl
cp assets/AppIcon.icns $APP/Contents/Resources/AppIcon.icns
# 中文系统显示「手边」，其他语言显示「Reach」；Spotlight 两个名字都能搜到
# （macOS 只在文件名 Reach.app 和下面的默认名一致时才换成本地化的名字）
mkdir -p $APP/Contents/Resources/zh-Hans.lproj $APP/Contents/Resources/en.lproj
printf '"CFBundleDisplayName" = "手边";\n"CFBundleName" = "手边";\n' > $APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings
printf '"CFBundleDisplayName" = "Reach";\n"CFBundleName" = "Reach";\n' > $APP/Contents/Resources/en.lproj/InfoPlist.strings
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>Reach</string>
  <key>CFBundleDisplayName</key><string>Reach</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>CFBundleAllowMixedLocalizations</key><true/>
  <key>LSHasLocalizedDisplayName</key><true/>
  <key>CFBundleExecutable</key><string>Reach</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict></plist>
PLIST

if security find-identity -p codesigning 2>/dev/null | grep -q "\"$SIGN_IDENTITY\""; then
  codesign --force -s "$SIGN_IDENTITY" --identifier $BUNDLE_ID.ctl $APP/Contents/MacOS/reachctl
  codesign --force -s "$SIGN_IDENTITY" $APP
  echo "（签名：$SIGN_IDENTITY）"
else
  codesign --force -s - --identifier $BUNDLE_ID.ctl $APP/Contents/MacOS/reachctl
  codesign --force -s - $APP
  echo "⚠️ 没找到证书「$SIGN_IDENTITY」，用临时签名：每次重新构建后系统会再问一次辅助功能和屏幕录制。运行 scripts/make-cert.sh 建一张就好。"
fi
echo "✓ $APP"

if [[ $INSTALL == 1 ]]; then
  pkill -x Reach || true; pkill -x Margin || true
  for _ in $(seq 1 30); do pgrep -x Reach >/dev/null || pgrep -x Margin >/dev/null || break; sleep 0.2; done
  mkdir -p ~/Applications && rm -rf ~/Applications/Margin.app ~/Applications/Reach.app && cp -R $APP ~/Applications/
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/Reach.app 2>/dev/null || true
  mdimport ~/Applications/Reach.app 2>/dev/null || true
  open ~/Applications/Reach.app
  echo "✓ 已安装到 ~/Applications/Reach.app 并启动"
fi
