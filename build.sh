#!/bin/bash
# Shanmoメモ帳.app をビルドする（Intel / Apple シリコン両対応のユニバーサル）
#   ./build.sh           … build/Shanmoメモ帳.app を作る
#   ./build.sh install   … 作ったあと /Applications にコピー（前の名前で入れてた同じアプリは消す）
#   NO_SHANMO_LOGO=1 ./build.sh … SHANMO なし: 名前は「SEDITメモ」、アイコンは元の紙だけ、ステータスバーにロゴを出さない
# バージョンはビルドするたびに 0.01 ずつ上がる（1.01、1.02、… 1.99、2.00）。数えた回数は .build-number（git には入れない）
#   SWIFT_OPT=-Osize ./build.sh … 速さより大きさ優先で最適化（ふつうは -O）
#   NO_STRIP=1 ./build.sh       … 関数名などの記号を残す（ふつうは落として 3 割小さくする）
# 要るもの: Xcode のコマンドラインツール（xcode-select --install）
set -euo pipefail
cd "$(dirname "$0")"

# 名前と説明（Finder の「情報を見る」とアプリについての説明）は、SHANMO ありなしで変える
if [ -n "${NO_SHANMO_LOGO:-}" ]; then
  DEFAULT_APP_NAME="SEDITメモ"
  DESCRIPTION="SEDITモード搭載なつかしテキストエディタ"
else
  DEFAULT_APP_NAME="Shanmoメモ帳"
  DESCRIPTION="Copyright (c) 2026 Shanmo Corp"
fi
APP_NAME="${APP_NAME:-$DEFAULT_APP_NAME}"
EXEC_NAME="Memocho"
BUNDLE_ID="${BUNDLE_ID:-local.memocho}"
BUILD_NUMBER_FILE=".build-number"
PREVIOUS_BUILD="$(cat "$BUILD_NUMBER_FILE" 2>/dev/null || true)"
case "$PREVIOUS_BUILD" in
  ''|*[!0-9]*) PREVIOUS_BUILD=0 ;;
esac
BUILD_NUMBER=$((10#$PREVIOUS_BUILD + 1))
VERSION="$((1 + BUILD_NUMBER / 100)).$(printf '%02d' $((BUILD_NUMBER % 100)))"
MIN_ARM64="11.0"
MIN_X86_64="10.15"
ARCHS="${ARCHS:-arm64 x86_64}"
SWIFT_OPT="${SWIFT_OPT:--O}"
case "$SWIFT_OPT" in
  -O|-Osize) ;;
  *) echo "SWIFT_OPT は -O か -Osize: $SWIFT_OPT" >&2; exit 1 ;;
esac
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

echo "==> $APP_NAME Ver $VERSION"
rm -rf "$BUILD_DIR"/*.app   # 名前を変えたときに前の名前のが残らんように
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/ja.lproj" "$BUILD_DIR/obj"

BINARIES=()
for ARCH in $ARCHS; do
  case "$ARCH" in
    arm64)  MIN="$MIN_ARM64" ;;
    x86_64) MIN="$MIN_X86_64" ;;
    *) echo "対応してないアーキテクチャ: $ARCH" >&2; exit 1 ;;
  esac
  echo "==> $ARCH 向けにコンパイル中（macOS $MIN 以降、${SWIFT_OPT}）…"
  "$SWIFTC" "$SWIFT_OPT" -whole-module-optimization -swift-version 5 \
    -sdk "$SDK" -target "$ARCH-apple-macos$MIN" \
    -module-name "$EXEC_NAME" \
    -o "$BUILD_DIR/obj/$EXEC_NAME-$ARCH" \
    Sources/*.swift
  if [ -n "${NO_STRIP:-}" ]; then
    BINARIES+=("$BUILD_DIR/obj/$EXEC_NAME-$ARCH")
  else
    # 中だけで使う関数名などの記号（1 アーキテクチャで 220KB ほど）を落とす。動きは変わらん。
    # 落とす前のは build/obj/ に残すので、落ちたときのレポートを読むならそっちを使う
    xcrun strip -x -o "$BUILD_DIR/obj/$EXEC_NAME-$ARCH.stripped" "$BUILD_DIR/obj/$EXEC_NAME-$ARCH"
    BINARIES+=("$BUILD_DIR/obj/$EXEC_NAME-$ARCH.stripped")
  fi
done

lipo -create -output "$APP/Contents/MacOS/$EXEC_NAME" "${BINARIES[@]}"
# SHANMO のロゴ（アイコンの紙とステータスバーの左はじ）。ステータスバーは StatusLogo.png が無ければ出さない
if [ -n "${NO_SHANMO_LOGO:-}" ]; then
  echo "==> SHANMO のロゴなし"
  cp Resources/AppIcon-plain.icns "$APP/Contents/Resources/AppIcon.icns"
else
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  cp Resources/StatusLogo.png "$APP/Contents/Resources/StatusLogo.png"
fi

# 等幅フォントモード用の PC-9800 フォント（retro-type.com の配布物）。
# 配布条件が書かれてないのでリポジトリには入れず、ビルドのときに落としてアプリに埋め込む。
# 要らんときは NO_PC98_FONT=1 ./build.sh。Resources/Fonts/ に置いた .ttf / .otf はどれも埋め込まれる。
FONT_DIR="Resources/Fonts"
PC98_FONT="$FONT_DIR/pc-9800.ttf"
PC98_FONT_URL="https://retro-type.com/PC98/font/pc-9800.ttf"
PC98_FONT_SHA256="ef8a08868d2d279aac1f3d646899c574775b1b8d692de54f1de08722eded7333"
if [ -z "${NO_PC98_FONT:-}" ] && [ ! -f "$PC98_FONT" ]; then
  echo "==> PC-9800 フォントを取ってくる: $PC98_FONT_URL"
  mkdir -p "$FONT_DIR"
  if curl -fsSL --connect-timeout 15 --max-time 180 --retry 2 -o "$PC98_FONT.part" "$PC98_FONT_URL" &&
     [ "$(shasum -a 256 "$PC98_FONT.part" | cut -d ' ' -f 1)" = "$PC98_FONT_SHA256" ]; then
    mv "$PC98_FONT.part" "$PC98_FONT"
  else
    rm -f "$PC98_FONT.part"
    echo "    取れんかった（通信エラーか、中身が前と違う）。等幅フォントは Osaka−等幅 か Menlo で代わりにする" >&2
  fi
fi
shopt -s nocaseglob   # Windows から持ってきた FOO.TTF も拾う
for FONT in "$FONT_DIR"/*.ttf "$FONT_DIR"/*.otf; do
  [ -f "$FONT" ] || continue
  if [ -n "${NO_PC98_FONT:-}" ] && [ "$FONT" = "$PC98_FONT" ]; then continue; fi
  mkdir -p "$APP/Contents/Resources/Fonts"
  # -X: Finder 情報などの拡張属性は持ち込まない（あると codesign が通らん）
  cp -X "$FONT" "$APP/Contents/Resources/Fonts/"
  echo "==> フォントを埋め込み: $(basename "$FONT")"
done
shopt -u nocaseglob
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
  <string>$BUILD_NUMBER</string>
  <key>NSHumanReadableCopyright</key>
  <string>$DESCRIPTION</string>
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
echo "$BUILD_NUMBER" > "$BUILD_NUMBER_FILE"   # できたときだけ数える
echo "==> できた: ${APP}（Ver ${VERSION}）"

if [ "${1:-}" = "install" ]; then
  DEST="/Applications/$APP_NAME.app"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  # 前の名前（メモ帳.app、SHANMO ありなしの切り替え）で入れてた同じアプリ（同じ ID）は消す。2 つあると関連付けが迷う
  for OTHER in /Applications/*.app; do
    [ "$OTHER" = "$DEST" ] && continue
    OTHER_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OTHER/Contents/Info.plist" 2>/dev/null || true)"
    if [ "$OTHER_ID" = "$BUNDLE_ID" ]; then
      echo "==> 前の名前のを消す: $OTHER"
      "$LSREGISTER" -u "$OTHER" >/dev/null 2>&1 || true
      rm -rf "$OTHER"
    fi
  done
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
  echo "==> $DEST に入れた"
fi
