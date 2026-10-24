#!/bin/bash
# 重新產生 Resources/AppIcon.icns（改了 make_icon.swift 的設計時才需要跑）
set -euo pipefail
cd "$(dirname "$0")/.."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
CLT_INC=/Library/Developer/CommandLineTools/usr/include/swift
VFS_FLAGS=()
if [[ -f "$CLT_INC/module.modulemap" && -f "$CLT_INC/bridging.modulemap" ]]; then
  : > "$TMP/empty.modulemap"
  printf '{"version":0,"case-sensitive":"false","roots":[{"type":"file","name":"%s","external-contents":"%s"}]}\n' \
    "$CLT_INC/module.modulemap" "$TMP/empty.modulemap" > "$TMP/vfs.yaml"
  VFS_FLAGS=(-vfsoverlay "$TMP/vfs.yaml" -Xcc -ivfsoverlay -Xcc "$TMP/vfs.yaml")
fi
swiftc ${VFS_FLAGS[@]+"${VFS_FLAGS[@]}"} scripts/make_icon.swift -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/icon_1024.png"
SET="$TMP/AppIcon.iconset"
mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon_1024.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "完成：Resources/AppIcon.icns"
