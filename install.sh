#!/bin/bash
# 一次裝好所有相依：Python 虛擬環境（mlx-whisper、opencc）、Whisper 模型、術語表、App。
# 用法：./install.sh               全部
#       ./install.sh --skip-model  不下載模型（已經有了）
#       ./install.sh --model <HF repo>  改用別的模型（例如 mlx-community/whisper-large-v3-mlx）
set -euo pipefail
cd "$(dirname "$0")"

MODEL="mlx-community/whisper-large-v3-turbo"
SKIP_MODEL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-model) SKIP_MODEL=1; shift ;;
    --model) MODEL="${2:?--model 需要一個值}"; shift 2 ;;
    *) echo "不認得的參數：$1" >&2; exit 2 ;;
  esac
done

SUPPORT="$HOME/Library/Application Support/MeetingRecorder"
VENV="$SUPPORT/venv"
mkdir -p "$SUPPORT"

[[ "$(uname -m)" == "arm64" ]] || { echo "mlx-whisper 只支援 Apple Silicon" >&2; exit 1; }
command -v ffmpeg >/dev/null || { echo "==> 安裝 ffmpeg"; brew install ffmpeg; }

# mlx 需要較新的 Python；系統內建 3.9 太舊，優先用 Homebrew 的
PY=""
for c in /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 /opt/homebrew/bin/python3.11 /opt/homebrew/bin/python3.10; do
  [[ -x "$c" ]] && { PY="$c"; break; }
done
if [[ -z "$PY" ]]; then
  echo "==> 安裝 Python 3.12"
  brew install python@3.12
  PY=/opt/homebrew/bin/python3.12
fi

echo "==> 建立虛擬環境：$VENV（$PY）"
if command -v uv >/dev/null; then
  [[ -x "$VENV/bin/python" ]] || uv venv --python "$PY" "$VENV"
  uv pip install --python "$VENV/bin/python" mlx-whisper opencc
else
  [[ -x "$VENV/bin/python" ]] || "$PY" -m venv "$VENV"
  "$VENV/bin/pip" install --upgrade pip
  "$VENV/bin/pip" install mlx-whisper opencc
fi

if [[ ! -f "$SUPPORT/glossary.txt" ]]; then
  cp glossary.default.txt "$SUPPORT/glossary.txt"
  echo "==> 已建立術語表：$SUPPORT/glossary.txt"
fi
if [[ ! -f "$SUPPORT/replacements.txt" ]]; then
  cp replacements.default.txt "$SUPPORT/replacements.txt"
  echo "==> 已建立轉換後修正表：$SUPPORT/replacements.txt"
fi
if [[ "$MODEL" != "mlx-community/whisper-large-v3-turbo" ]]; then
  printf '{"model": "%s"}\n' "$MODEL" > "$SUPPORT/config.json"
else
  rm -f "$SUPPORT/config.json"   # 回到預設模型時清掉之前 --model 留下的設定
fi

if [[ $SKIP_MODEL -eq 0 ]]; then
  echo "==> 下載模型 $MODEL（只有這一步會連網，之後轉錄全程離線）"
  "$VENV/bin/python" -c "from huggingface_hub import snapshot_download as d; print(d('$MODEL'))"
fi

echo "==> 檢查"
"$VENV/bin/python" -c "import mlx_whisper, opencc; print('OpenCC s2twp:', opencc.OpenCC('s2twp').convert('这个软件的网络信息'))"

./build.sh
echo
echo "安裝完成。打開 ~/Applications/MeetingRecorder.app，第一次錄製前請依 README 授權螢幕錄製與麥克風。"
