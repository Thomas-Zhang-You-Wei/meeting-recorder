# -*- coding: utf-8 -*-
"""Meeting Recorder 後處理：合成影片 → 本機轉錄 → 產出逐字稿與播放器 → 通知。

用法：
    python mr_process.py <會議資料夾> [--skip-mux] [--skip-transcribe] [--keep-raw]
                         [--model <HF repo 或本機路徑>] [--glossary <檔案>] [--no-notify]

資料夾內預期有錄製端寫出的 video.mov（可無）、system.caf（可無）、mic.caf、session.json。
產出 recording.mp4、transcript.srt、transcript.md、transcript.json、player.html。

全程離線：HF_HUB_OFFLINE=1，模型需事先由 install.sh 下載。
"""
import argparse
import datetime as dt
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

os.environ.setdefault("HF_HUB_OFFLINE", "1")
os.environ.setdefault("TRANSFORMERS_OFFLINE", "1")
# mlx-whisper 內部會直接呼叫 `ffmpeg`；從選單列啟動時 PATH 沒有 Homebrew，先補上
os.environ["PATH"] = os.pathsep.join(["/opt/homebrew/bin", "/usr/local/bin", os.environ.get("PATH", "/usr/bin:/bin")])

HERE = Path(__file__).resolve().parent
SUPPORT = Path.home() / "Library/Application Support/MeetingRecorder"
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"

# Whisper 在靜音段常見的幻覺字幕（多半來自訓練資料裡的影片字幕）
# Whisper 在靜音段常見的幻覺字幕（多半來自訓練資料裡的影片字幕）。
# 強特徵：真實會議幾乎不可能講到，整段命中就整段丟掉（避免被句點切開後殘留半句）。
# 弱特徵：只丟掉命中的那一小句，不連累同一段裡的其他內容。
STRONG_MARKERS = ["Amara.org", "Amara", "請不吝點贊", "點贊訂閱", "點點欄目", "明鏡與點點", "訂閱我的頻道"]
HALLUCINATION_MARKERS = STRONG_MARKERS + ["字幕由", "字幕製作", "字幕提供", "感謝觀看", "謝謝收看", "中文字幕"]


def log(msg):
    print(f"[{dt.datetime.now():%H:%M:%S}] {msg}", flush=True)


def find_tool(name):
    p = shutil.which(name)
    if p:
        return p
    for d in ("/opt/homebrew/bin", "/usr/local/bin"):
        c = Path(d) / name
        if c.exists():
            return str(c)
    raise SystemExit(f"找不到 {name}，請先 brew install ffmpeg")


def run(cmd):
    log("$ " + " ".join(str(c) for c in cmd))
    r = subprocess.run([str(c) for c in cmd], capture_output=True, text=True)
    if r.returncode != 0:
        sys.stderr.write(r.stderr[-4000:])
        raise RuntimeError(f"{Path(cmd[0]).name} 失敗（{r.returncode}）")
    return r.stdout


def probe(path):
    out = run([find_tool("ffprobe"), "-v", "error", "-show_entries",
               "stream=index,codec_type,channels:format=duration", "-of", "json", path])
    return json.loads(out)


def notify(title, message):
    esc = lambda s: s.replace("\\", "\\\\").replace('"', '\\"')
    subprocess.run(["osascript", "-e",
                    f'display notification "{esc(message)}" with title "{esc(title)}" sound name "Glass"'],
                   capture_output=True)


def hms(t, millis=False, sep=","):
    t = max(0.0, float(t))
    h, rem = divmod(int(t), 3600)
    m, s = divmod(rem, 60)
    if millis:
        ms = int(round((t - int(t)) * 1000))
        if ms == 1000:
            ms = 999
        return f"{h:02d}:{m:02d}:{s:02d}{sep}{ms:03d}"
    return f"{h:02d}:{m:02d}:{s:02d}"


# ---------------------------------------------------------------- 1. 合成影片

def has_audio(path):
    return path.exists() and path.stat().st_size > 8192


def mux(d: Path, keep_raw: bool, warnings: list):
    video, system, mic = d / "video.mov", d / "system.caf", d / "mic.caf"
    out = d / "recording.mp4"
    tmp = d / "recording.tmp.mp4"
    has_v = video.exists() and video.stat().st_size > 0
    has_s, has_m = has_audio(system), has_audio(mic)
    if not (has_v or has_s or has_m):
        raise RuntimeError("資料夾裡沒有可用的錄製檔")
    try:
        info = _mux_once(d, tmp, has_v, has_s, has_m)
    except RuntimeError as e:
        if not has_v or not (has_s or has_m):
            raise
        # 影片檔壞掉（例如錄到一半當機）時，至少把聲音救回來、照常轉錄
        msg = f"影片檔無法讀取（{e}），改成只合成聲音；video.mov 保留在資料夾裡"
        log(msg)
        warnings.append(msg)
        info = _mux_once(d, tmp, False, has_s, has_m)
        has_v = False
        keep_video = True
    else:
        keep_video = False
    kinds = [s["codec_type"] for s in info["streams"]]
    tmp.replace(out)
    log(f"recording.mp4 完成：{kinds}，長度 {float(info['format']['duration']):.1f}s")
    if not keep_raw:
        for f in (system, mic) + (() if keep_video else (video,)):
            if f.exists():
                f.unlink()
    return out


def _mux_once(d: Path, tmp: Path, has_v: bool, has_s: bool, has_m: bool):
    ffmpeg = find_tool("ffmpeg")
    video, system, mic = d / "video.mov", d / "system.caf", d / "mic.caf"
    cmd = [ffmpeg, "-y", "-hide_banner", "-loglevel", "error"]
    idx = 0
    vi = si = mi = None
    if has_v:
        cmd += ["-i", video]; vi = idx; idx += 1
    if has_s:
        cmd += ["-i", system]; si = idx; idx += 1
    if has_m:
        cmd += ["-i", mic]; mi = idx; idx += 1

    maps, meta = [], []
    if vi is not None:
        maps += ["-map", f"{vi}:v:0", "-c:v", "copy"]
    if si is not None and mi is not None:
        # 第 1 軌：兩路混音（瀏覽器與一般播放器預設播這軌）
        # 第 2、3 軌：原始系統音／麥克風，事後要單聽某一方時用
        fc = (f"[{si}:a]aresample=48000,aformat=channel_layouts=stereo[s];"
              f"[{mi}:a]aresample=48000,aformat=channel_layouts=stereo[m];"
              f"[s][m]amix=inputs=2:duration=longest:normalize=0,"
              f"dynaudnorm=f=250:g=15,alimiter=limit=0.95[mix]")
        cmd += ["-filter_complex", fc]
        maps += ["-map", "[mix]", "-map", f"{si}:a:0", "-map", f"{mi}:a:0",
                 "-c:a", "aac", "-b:a:0", "160k", "-b:a:1", "128k", "-b:a:2", "96k"]
        meta += ["-metadata:s:a:0", "title=混音", "-metadata:s:a:1", "title=系統音（對方）",
                 "-metadata:s:a:2", "title=麥克風（我方）",
                 "-disposition:a:0", "default", "-disposition:a:1", "0", "-disposition:a:2", "0"]
    else:
        ai = si if si is not None else mi
        if ai is not None:
            maps += ["-map", f"{ai}:a:0", "-af", "dynaudnorm=f=250:g=15,alimiter=limit=0.95",
                     "-c:a", "aac", "-b:a", "128k"]
    cmd += maps + meta + ["-movflags", "+faststart", tmp]
    run(cmd)
    info = probe(tmp)
    if not any(s["codec_type"] in ("audio", "video") for s in info["streams"]):
        raise RuntimeError("合成結果沒有任何軌道")
    return info


# ---------------------------------------------------------------- 2. 轉錄

def load_glossary(path_arg):
    candidates = [Path(path_arg)] if path_arg else []
    candidates += [SUPPORT / "glossary.txt", HERE / "glossary.default.txt", HERE.parent / "glossary.default.txt"]
    for p in candidates:
        if p and p.exists():
            terms = []
            for line in p.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#"):
                    terms.append(line)
            log(f"術語表：{p}（{len(terms)} 個詞）")
            return terms
    log("沒有術語表，略過")
    return []


def build_prompt(terms):
    # Whisper 只保留 prompt 最後約 220 個 token，所以把「繁體中文」的指示放在最後，
    # 詞太多時被截掉的是最前面的術語，不是指示。
    tail = "以下是會議逐字稿，使用繁體中文，可能夾雜英文術語。"
    if not terms:
        return tail
    return "術語：" + "、".join(terms) + "。" + tail


def resolve_model(arg):
    if arg:
        return arg
    if os.environ.get("MR_WHISPER_MODEL"):
        return os.environ["MR_WHISPER_MODEL"]
    cfg = SUPPORT / "config.json"
    if cfg.exists():
        try:
            m = json.loads(cfg.read_text(encoding="utf-8")).get("model")
            if m:
                return m
        except ValueError:
            pass
    return DEFAULT_MODEL


def load_replacements():
    """轉換後修正表：s2twp 的詞彙替換偶爾會改到意思（例如「參數」被換成「引數」），
    在這裡改回來。格式：一行 `錯誤 => 正確`，# 開頭是註解。"""
    for p in (SUPPORT / "replacements.txt", HERE / "replacements.default.txt",
              HERE.parent / "replacements.default.txt"):
        if p.exists():
            pairs = []
            for line in p.read_text(encoding="utf-8").splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=>" in line:
                    a, b = (x.strip() for x in line.split("=>", 1))
                    if a:
                        pairs.append((a, b))
            return pairs
    return []


CJK = "㐀-鿿"
PUNCT_FULL = {",": "，", "?": "？", "!": "！", ";": "；", ":": "："}


def polish(text, cc, replacements):
    text = cc.convert(text.strip())
    for a, b in replacements:
        text = text.replace(a, b)
    # 中文旁邊的半形標點改全形
    for half, full in PUNCT_FULL.items():
        text = re.sub(rf"(?<=[{CJK}])\s*{re.escape(half)}\s*|\s*{re.escape(half)}\s*(?=[{CJK}])", full, text)
    return text


SPLIT_AFTER = set("，。？！；,.?!;")


def split_by_words(seg):
    """用逐字時間戳在標點處把長段切成短句，點句跳轉才準。"""
    words = seg.get("words") or []
    if not words:
        return [(float(seg["start"]), float(seg["end"]), seg.get("text", ""), 1.0)]
    out, buf, start, probs = [], "", None, []
    for i, w in enumerate(words):
        if start is None:
            start = float(w["start"])
        buf += w["word"]
        probs.append(float(w.get("probability", 1.0)))
        nxt = words[i + 1]["word"].lstrip() if i + 1 < len(words) else ""
        if nxt[:1].isdigit() and buf.rstrip()[-1:] in ".,":   # 802.15.4、1,000 這類數字不切
            continue
        if buf.strip() and buf.rstrip()[-1] in SPLIT_AFTER and len(buf.strip()) >= 6:
            out.append((start, float(w["end"]), buf, sum(probs) / len(probs)))
            buf, start, probs = "", None, []
    if buf.strip():
        out.append((start, float(words[-1]["end"]), buf, sum(probs) / max(1, len(probs))))
    return out


def clean_segments(raw, cc, replacements):
    segs = []
    for s in raw:
        if any(m in polish(s.get("text", ""), cc, []) for m in STRONG_MARKERS):
            continue
        if s.get("no_speech_prob", 0) > 0.8 and s.get("avg_logprob", 0) < -1.0:
            continue
        for start, end, text, prob in split_by_words(s):
            text = polish(text, cc, replacements).strip("，, ")
            if not text or any(m in text for m in HALLUCINATION_MARKERS):
                continue
            low = prob < 0.35   # 整句幾乎每個字都沒把握：可能是幻覺，也可能是聽不清楚的術語
            if segs and segs[-1]["text"] == text:   # 重複迴圈：併成一句
                segs[-1]["end"] = round(end, 2)
                continue
            seg = {"start": round(start, 2), "end": round(end, 2), "text": text}
            if low:
                seg["low"] = True
            segs.append(seg)
    return segs


def transcribe(d: Path, media: Path, model: str, glossary_arg):
    ffmpeg = find_tool("ffmpeg")
    wav = d / "audio16k.wav"
    run([ffmpeg, "-y", "-hide_banner", "-loglevel", "error", "-i", media,
         "-map", "0:a:0", "-ac", "1", "-ar", "16000", wav])
    import mlx_whisper   # 延後 import，合成影片不需要它
    import opencc
    prompt = build_prompt(load_glossary(glossary_arg))
    log(f"模型：{model}")
    log(f"prompt：{prompt}")
    t = time.time()
    try:
        result = mlx_whisper.transcribe(
            str(wav),
            path_or_hf_repo=model,
            language="zh",
            task="transcribe",
            # 術語表只影響第一個 30 秒視窗：condition_on_previous_text=False 時，mlx-whisper
            # 在每個視窗之後會把 prompt 重設。曾試過每個視窗都帶術語表，實測整段漏字，所以不採用。
            initial_prompt=prompt,
            condition_on_previous_text=False,   # 降低幻覺一路重複下去的機率
            word_timestamps=True,               # 用來把長段切成短句
            verbose=False,
        )
    finally:
        wav.unlink(missing_ok=True)
    log(f"轉錄耗時 {time.time() - t:.1f}s")
    return clean_segments(result.get("segments", []), opencc.OpenCC("s2twp"), load_replacements())


# ---------------------------------------------------------------- 3. 產出

def write_outputs(d: Path, session: dict, segs: list, model: str, warnings: list):
    bookmarks = sorted(session.get("bookmarks", []), key=lambda b: b["t"])
    name = session.get("name") or d.name
    started = session.get("started_at", "")
    duration = float(session.get("duration", 0) or 0)
    if not duration and segs:
        duration = segs[-1]["end"]
    mode = session.get("mode", "")
    mode_label = {"online": "線上（螢幕＋系統音＋麥克風）",
                  "physical": "實體（麥克風＋螢幕）" if session.get("capture_screen") else "實體（只錄麥克風）"}.get(mode, mode)

    data = {
        "meta": {"name": name, "started_at": started, "duration": duration, "mode": mode_label,
                 "model": model, "generated_at": dt.datetime.now().isoformat(timespec="seconds"),
                 "warnings": warnings},
        "bookmarks": bookmarks,
        "segments": segs,
    }
    (d / "transcript.json").write_text(json.dumps(data, ensure_ascii=False, indent=1), encoding="utf-8")

    # SRT
    lines = []
    for i, s in enumerate(segs, 1):
        lines += [str(i), f"{hms(s['start'], True)} --> {hms(s['end'], True)}", s["text"], ""]
    (d / "transcript.srt").write_text("\n".join(lines), encoding="utf-8")

    # Markdown
    try:
        when = dt.datetime.fromisoformat(started).strftime("%Y-%m-%d %H:%M")
    except ValueError:
        when = started
    md = [f"# {name}", "",
          f"- 日期：{when}", f"- 長度：{hms(duration)}", f"- 模式：{mode_label}",
          "- 檔案：[recording.mp4](recording.mp4)　·　[player.html](player.html)（點句子跳到影片）",
          f"- 轉錄：{model}（本機），OpenCC s2twp", ""]
    if warnings:
        md += ["## 注意", ""] + [f"- {w}" for w in warnings] + [""]
    if any(s.get("low") for s in segs):
        md += ["> ⚠️ 標記的句子辨識信心很低，可能聽錯，也可能是靜音裡冒出來的幻覺，請對照影片。", ""]
    md += ["## 書籤", ""]
    md += [f"- `[{hms(b['t'])}]` {b['label']}" for b in bookmarks] or ["（無）"]
    md += ["", "## 逐字稿", ""]
    bi = 0
    for s in segs:
        while bi < len(bookmarks) and bookmarks[bi]["t"] <= s["start"]:
            md += [f"> 🔖 `[{hms(bookmarks[bi]['t'])}]` **{bookmarks[bi]['label']}**", ""]
            bi += 1
        md += [f"`[{hms(s['start'])}]` {'⚠️ ' if s.get('low') else ''}{s['text']}  "]
    for b in bookmarks[bi:]:
        md += ["", f"> 🔖 `[{hms(b['t'])}]` **{b['label']}**"]
    (d / "transcript.md").write_text("\n".join(md) + "\n", encoding="utf-8")

    # 播放器：資料直接嵌進 HTML，file:// 開啟不需要 fetch
    tpl_path = next(p for p in (HERE / "player_template.html", HERE.parent / "scripts/player_template.html") if p.exists())
    tpl = tpl_path.read_text(encoding="utf-8")
    # 嵌在 <script> 裡：把 < 全部跳脫，任何文字都不可能提早結束 script 或開出註解
    blob = json.dumps(data, ensure_ascii=False).replace("<", "\\u003c")
    # 先換標題再嵌資料：逐字稿裡就算出現「__TITLE__」也不會被換掉
    html = tpl.replace("__TITLE__", escape_html(name)).replace("/*__DATA__*/null", blob)
    (d / "player.html").write_text(html, encoding="utf-8")
    log(f"產出完成：{len(segs)} 句、{len(bookmarks)} 個書籤")


def escape_html(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace('"', "&quot;")


# ---------------------------------------------------------------- main

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("dir")
    ap.add_argument("--skip-mux", action="store_true", help="已有 recording.mp4，只重跑轉錄")
    ap.add_argument("--skip-transcribe", action="store_true")
    ap.add_argument("--keep-raw", action="store_true", help="保留 video.mov / system.caf / mic.caf")
    ap.add_argument("--model")
    ap.add_argument("--glossary")
    ap.add_argument("--no-notify", action="store_true")
    a = ap.parse_args()

    d = Path(a.dir).expanduser().resolve()
    session_path = d / "session.json"
    session = json.loads(session_path.read_text(encoding="utf-8")) if session_path.exists() else {}
    name = session.get("name") or d.name
    model = resolve_model(a.model)
    warnings = list(session.get("warnings") or [])
    try:
        media = d / "recording.mp4"
        if not a.skip_mux:
            media = mux(d, a.keep_raw, warnings)
        if a.skip_transcribe:
            return 0
        segs = transcribe(d, media, model, a.glossary)
        write_outputs(d, session, segs, model, warnings)
        if not a.no_notify:
            notify("Meeting Recorder", f"逐字稿完成：{name}（{len(segs)} 句）")
        return 0
    except Exception as e:  # noqa: BLE001 — 任何失敗都要通知使用者
        log(f"失敗：{e}")
        if not a.no_notify:
            notify("Meeting Recorder 失敗", f"{name}：{e}（詳見 process.log）")
        return 1


if __name__ == "__main__":
    sys.exit(main())
