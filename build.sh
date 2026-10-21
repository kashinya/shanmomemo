#!/bin/bash
# メモ帳.app をビルドする（Intel / Apple シリコン両対応のユニバーサル）
#   ./build.sh           … build/メモ帳.app を作る
#   ./build.sh install   … 作ったあと /Applications にコピー
# 要るもの: Xcode のコマンドラインツール（xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="${APP_NAME:-メモ帳}"
EXEC_NAME="Memocho"
BUNDLE_ID="${BUNDLE_ID:-local.memocho}"
VERSION="1.0"
MIN_ARM64="11.0"
MIN_X86_64="10.15"
ARCHS="${ARCHS:-arm64 x86_64}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "swiftc が見つかりません。先に Xcode のコマンドラインツールを入れてください:" >&2
  echo "  xcode-select --install" >&2
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC="$(xcrun --find swiftc)"
SWIFT_VERSION="$("$SWIFTC" --version 2>&1 | head -n 1 || true)"
echo "==> $SWIFT_VERSION"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ja.lproj" "$BUILD_DIR/obj"

BINARIES=()
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64)  MIN="$MIN_ARM64" ;;
    x86_64) MIN="$MIN_X86_64" ;;
    *) echo "対応してないアーキテクチャ: $ARCH" >&2; exit 1 ;;
  esac
  echo "==> $ARCH 向けにコンパイル中（macOS $MIN 以降）…"
  "$SWIFTC" -O -whole-module-optimization -swift-version 5 \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN" \
    -module-name "$EXEC_NAME" \
    -o "$BUILD_DIR/obj/$EXEC_NAME-$ARCH" \
    Sources/*.swift
  BINARIES+=("$BUILD_DIR/obj/$EXEC_NAME-$ARCH")
done

lipo -create -output "$APP/Contents/MacOS/$EXEC_NAME" "${BINARIES[@]}"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>ja</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>ja</string>
  </array>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$EXEC_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$VERSION</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_X86_64</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key>
  <false/>
  <key>NSSupportsSuddenTermination</key>
  <false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>テキスト</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.plain-text</string>
        <string>public.text</string>
        <string>public.data</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

plutil -lint "$APP/Contents/Info.plist" >/dev/null
codesign --force --sign - "$APP"
echo "==> できた: $APP"

if [ "${1:-}" = "install" ]; then
  DEST="/Applications/$APP_NAME.app"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1 || true
  echo "==> $DEST に入れた"
fi
