#!/bin/bash
# 編譯並組裝 MeetingRecorder.app，安裝到 ~/Applications。
# 用法：./build.sh            編譯＋安裝
#       ./build.sh --no-install 只編譯到 build/（不裝腳本、不動已安裝的 App）
set -euo pipefail
cd "$(dirname "$0")"

for a in "$@"; do
  case "$a" in
    --no-install) ;;
    *) echo "不認得的參數：$a" >&2; exit 2 ;;
  esac
done

ROOT="$PWD"
BUILD="$ROOT/build"
APP="$BUILD/MeetingRecorder.app"
mkdir -p "$BUILD"

# 有些 Command Line Tools 會殘留舊版 usr/include/swift/module.modulemap，
# 跟新版 bridging.modulemap 重複定義 SwiftBridging，編譯直接失敗。
# 這裡用 VFS overlay 把舊檔遮成空檔，不必動系統檔。
CLT_INC=/Library/Developer/CommandLineTools/usr/include/swift
VFS_FLAGS=()
if [[ -f "$CLT_INC/module.modulemap" && -f "$CLT_INC/bridging.modulemap" ]]; then
  : > "$BUILD/empty.modulemap"
  cat > "$BUILD/vfs.yaml" <<EOF
{"version":0,"case-sensitive":"false","roots":[{"type":"file","name":"$CLT_INC/module.modulemap","external-contents":"$BUILD/empty.modulemap"}]}
EOF
  VFS_FLAGS=(-vfsoverlay "$BUILD/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$BUILD/vfs.yaml")
fi

echo "==> 編譯"
# ${A[@]+...} 寫法：macOS 內建 bash 3.2 在 set -u 下展開空陣列會報錯
swiftc -O -target arm64-apple-macosx15.0 \
  ${VFS_FLAGS[@]+"${VFS_FLAGS[@]}"} \
  -framework ScreenCaptureKit -framework AVFoundation -framework Carbon -framework AppKit \
  Sources/MeetingRecorder/*.swift -o "$BUILD/MeetingRecorder"

echo "==> 組裝 .app"
# .app 裡只放執行檔、Info.plist 和圖示。腳本另外裝到 Application Support，
# 這樣改轉錄流程或播放器時不必重簽 App，螢幕錄製授權不會失效。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/MeetingRecorder" "$APP/Contents/MacOS/MeetingRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 簽章：鑰匙圈裡有「MeetingRecorder Local Signing」這張程式碼簽署憑證就用它（README 有建立步驟），
# 指定需求（designated requirement）固定，重編後授權可以沿用；沒有就退回 ad-hoc，
# ad-hoc 的指定需求綁在 cdhash 上，執行檔一變授權就失效。
SIGN_ID="${MR_SIGN_IDENTITY:-MeetingRecorder Local Signing}"
if security find-identity -p codesigning 2>/dev/null | grep -qF "\"$SIGN_ID\""; then
  echo "==> 用憑證「$SIGN_ID」簽章"
  codesign --force --sign "$SIGN_ID" "$APP"
else
  echo "==> 用 ad-hoc 簽章（沒有找到憑證「$SIGN_ID」）"
  codesign --force --sign - "$APP"
fi

if [[ " $* " == *" --no-install "* ]]; then
  echo "完成：$APP"
  exit 0
fi

SCRIPTS="$HOME/Library/Application Support/MeetingRecorder/scripts"
echo "==> 安裝腳本到 $SCRIPTS"
mkdir -p "$SCRIPTS"
cp scripts/mr_process.py scripts/player_template.html glossary.default.txt replacements.default.txt "$SCRIPTS/"

DEST="$HOME/Applications/MeetingRecorder.app"
dr() { codesign -d -r- "$1" 2>/dev/null | grep 'designated =>'; }
NEW_DR="$(dr "$APP")"
OLD_DR="$(dr "$DEST" || true)"
if cmp -s "$APP/Contents/MacOS/MeetingRecorder" "$DEST/Contents/MacOS/MeetingRecorder" \
   && cmp -s "$APP/Contents/Info.plist" "$DEST/Contents/Info.plist" \
   && [[ "$NEW_DR" == "$OLD_DR" ]]; then
  echo "==> App 沒有變更，保留已安裝的版本（螢幕錄製授權不受影響）"
else
  LOCK="$HOME/Library/Application Support/MeetingRecorder/recording.lock"
  if [[ -f "$LOCK" ]] && kill -0 "$(head -n 1 "$LOCK")" 2>/dev/null; then
    echo "MeetingRecorder 正在錄製（$(sed -n 2p "$LOCK")），先停止錄製再重新安裝。" >&2
    exit 1
  fi
  echo "==> 安裝 App 到 $DEST"
  if [[ -n "$OLD_DR" && "$NEW_DR" == "$OLD_DR" && "$NEW_DR" != *cdhash* ]]; then
    echo "    指定需求沒變（$NEW_DR），螢幕錄製授權應可沿用。"
  else
    echo "    注意：簽章的指定需求變了，請到「系統設定 → 隱私權與安全性 → 螢幕與系統錄音」"
    echo "    選取 MeetingRecorder 按「−」移除，再按「+」加回 $DEST。"
  fi
  mkdir -p "$HOME/Applications"
  pkill -x MeetingRecorder 2>/dev/null || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
fi
echo "完成"
