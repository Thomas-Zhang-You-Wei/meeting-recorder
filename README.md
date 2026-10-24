# Meeting Recorder

> **English summary** — A local-only meeting recorder for macOS 15+ on Apple Silicon. A menu bar app records your screen, system audio (the other side of a Teams / Meet / Zoom call) and microphone through ScreenCaptureKit. After you stop, it transcribes on-device with mlx-whisper, converts the text to Traditional Chinese (Taiwan) with OpenCC, and writes an MP4, SRT, Markdown transcript and a self-contained `player.html` where clicking a sentence jumps the video to that moment. Nothing is uploaded; the only network access is the one-time model download during install. The UI and docs are in Traditional Chinese; transcription language is currently fixed to Chinese (`language="zh"` in `scripts/mr_process.py`). MIT licensed.

純本機的 Mac 會議記錄工具：錄影、錄音、逐字稿，逐字稿可以跟影片時間對照。
不用訂閱、不上傳雲端，實體會議和 Teams / Google Meet / Zoom 線上會議都能用。

- **錄製**：選單列小程式，用 ScreenCaptureKit 一次錄下螢幕、系統音（會議裡對方的聲音）和麥克風；會中可按快捷鍵打時間書籤。
- **轉錄**：停止後在背景用 mlx-whisper（Apple Silicon GPU）轉錄，術語表餵給 Whisper 當 initial prompt，再用 OpenCC `s2twp` 轉台灣繁體，完成時發 macOS 通知。
- **產出**：`~/Movies/MeetingRecorder/YYYY-MM-DD_HHMM_<名稱>/`

```
recording.mp4     影片（第 1 條音軌是混音；第 2、3 條是系統音／麥克風原音）
transcript.srt    字幕檔，可以直接拖進 VLC、IINA
transcript.md     逐字稿，每句帶時間戳，書籤插在對應位置
transcript.json   同上的結構化資料
player.html       雙擊用瀏覽器開：左邊影片、右邊逐字稿，點句子跳到該秒
process.log       後處理紀錄（出錯時看這個）
```

## 系統需求

- macOS 15 以上（錄麥克風用的 ScreenCaptureKit API 從 macOS 15 才有）
- Apple Silicon（M1 之後；mlx-whisper 只支援 Apple Silicon）
- Homebrew、Xcode Command Line Tools（`xcode-select --install`）
- 約 2 GB 磁碟空間給 Whisper 模型

## 安裝

```bash
git clone <這個 repo 的網址> meeting-recorder
```

```bash
cd meeting-recorder
```

```bash
./install.sh
```

`install.sh` 會依序：

1. 確認有 ffmpeg（沒有就 `brew install ffmpeg`）
2. 用 Homebrew 的 Python（3.10 以上；系統內建的 3.9 太舊）在
   `~/Library/Application Support/MeetingRecorder/venv` 建虛擬環境，裝 `mlx-whisper`、`opencc`
3. 第一次安裝時建立可自訂的 `glossary.txt`（術語表）和 `replacements.txt`（轉換後修正表）；已經存在就不會覆蓋
4. 下載 Whisper 模型 `mlx-community/whisper-large-v3-turbo`（約 1.6 GB）。**只有這一步會連網**，之後轉錄全程離線（強制設定 `HF_HUB_OFFLINE=1`）
5. 執行 `build.sh`：編譯 App 裝到 `~/Applications/MeetingRecorder.app`，腳本裝到 `~/Library/Application Support/MeetingRecorder/scripts/`

選項：`./install.sh --skip-model`（模型已下載過）、`./install.sh --model mlx-community/whisper-large-v3-mlx`（換成較慢但稍準的完整版模型）。

## 第一次授權（螢幕錄製、麥克風）

1. 打開 `~/Applications/MeetingRecorder.app`，選單列右半邊會出現一個**麥克風圓圈**圖示（錄製中變成紅色實心，轉錄中變成聲波圓圈）。第一次啟動若跳出**麥克風**授權詢問，按「允許」。
2. 從選單開始任一種錄製。macOS 15 第一次**不會**跳出允許按鈕，而是直接失敗並把 App 加進清單，預設是關閉的。
3. 到「**系統設定 → 隱私權與安全性 → 螢幕與系統錄音**」，把 **MeetingRecorder** 打開。
4. 結束 App 再重新打開，就能錄了。

注意：

- **只錄麥克風的實體模式也需要「螢幕與系統錄音」授權**，因為麥克風也是走 ScreenCaptureKit 的同一條串流。
- 麥克風授權若被拒絕，可到「隱私權與安全性 → 麥克風」打開。
- App 的識別碼（bundle id）是 `io.github.meetingrecorder.MeetingRecorder`。**改了 bundle id，macOS 會當成全新的 App**，要重新授權一次，舊的授權項目可以在設定頁按「−」移除。

### 什麼時候需要重新授權

預設是本機 ad-hoc 簽章。macOS 用簽章的「指定需求（designated requirement）」認 App，ad-hoc 的指定需求綁在執行檔雜湊上，所以：

- **需要重新授權**：改了 Swift 程式碼、`Info.plist`（包括 bundle id）或 App 圖示，重新安裝 App 之後。這時只切開關沒用，要在設定頁選取 MeetingRecorder 按「−」移除，再按「+」加回 `~/Applications/MeetingRecorder.app`。
- **不需要**：改 Python 腳本、播放器範本、術語表、修正表（它們都裝在 Application Support，不在 App 裡），以及原始碼沒變的重新編譯（`build.sh` 比對到執行檔、`Info.plist`、指定需求都一樣時，不會覆蓋已安裝的 App）。

### 選用：建立固定的自簽憑證，以後改 Swift 也不用重新授權

改用固定憑證簽章後，指定需求會變成「bundle id＋憑證」，不再跟著執行檔雜湊變。依據是 Apple 工程師對 TCC 機制的說明，以及其他專案在輔助使用權限上的實測；**在「螢幕與系統錄音」權限上還沒實測過**。

1. 用 Spotlight 搜尋並打開「鑰匙圈存取」（Keychain Access，macOS 15 把它移到系統資料夾，啟動台裡可能找不到）→ 選單「鑰匙圈存取 → 憑證輔助程式 → 製作憑證⋯」。
2. 名稱填 `MeetingRecorder Local Signing`（要一字不差），身分類型選「自簽根憑證」，憑證類型選「程式碼簽署」，按「製作」。
3. 在終端機執行 `./build.sh`。第一次簽章時系統會問 codesign 能不能使用這把金鑰，選「永遠允許」。
4. 因為指定需求換了，這一次還是要在「螢幕與系統錄音」移除再加回一次；之後重編時，`build.sh` 會印出「指定需求沒變，授權應可沿用」。

要換成別的憑證名稱，執行前設 `MR_SIGN_IDENTITY="名稱"`。自簽憑證只解決授權延續，App 仍然只能在自己的 Mac 上用（沒有經過 Apple 公證）。

## 使用

### 選單列找不到圖示？

- MacBook 的瀏海會擋住選單列中間的圖示。App 第一次啟動時，會把圖示放在離右邊緣約 420 pt 的位置；之後按住 ⌘ 拖到哪裡，macOS 就記住哪裡。
- 有裝 Hidden Bar、Bartender、Ice 這類選單列整理工具時，新圖示可能被收進隱藏區：展開後按住 ⌘，把麥克風圓圈拖到分隔線右邊。
- 確認 App 有在執行：按 ⌘＋空白鍵，輸入 MeetingRecorder 打開。想開機自動啟動，到「系統設定 → 一般 → 登入項目」加入。

### 錄製

點選單列圖示：

| 選單 | 錄什麼 |
|---|---|
| 開始線上會議錄製 | 螢幕＋系統音（對方）＋麥克風（你） |
| 開始實體會議錄製（只錄麥克風） | 麥克風 |
| 開始實體會議錄製（麥克風＋螢幕） | 麥克風＋螢幕（例如邊討論邊開投影片） |

- 開始前會問會議名稱，用在資料夾名稱。
- 錄製中選單列顯示紅色圖示和經過時間。
- **⌃⌥B（Control＋Option＋B）打時間書籤**，任何 App 在前景都有效，會「叮」一聲。選單裡也有「加書籤」。
- 「停止錄製並轉錄」後在背景合成與轉錄，選單會顯示「轉錄中」，完成時跳通知。實測 2 分 15 秒的錄音約 20 秒轉完（M 系列 MacBook Air）。
- 還在排隊、尚未開始轉錄就結束 App 的會議，下次打開 App 會自動補做。已經開始轉錄卻中途被中斷、或轉錄失敗的會議不會自動重跑（資料夾裡已有 process.log），請照「重跑轉錄」手動執行。
- 錄製中出錯（例如螢幕錄製權限被收回）時，會先把已錄的內容存好、送去轉錄，再跳出提示。
- 錄影每 10 秒寫入一次，App 當掉或被強制結束時，已錄的部分仍然打得開；影片檔真的壞掉時，後處理會改成只合成聲音、照常轉錄，並在逐字稿開頭的「注意」區說明。
- 「麥克風」子選單可指定麥克風。**戴藍牙耳機時建議選 Mac 內建麥克風**：用藍牙耳機的麥克風會讓耳機切到低音質的通話模式。

### 線上會議（Teams / Meet / Zoom）的注意事項

- 系統音由 ScreenCaptureKit 在 macOS 層直接擷取，不是靠麥克風收喇叭的聲音，所以戴耳機開會時對方的聲音照樣錄得到（已實測，見下方「驗證紀錄」）。所有 App 的聲音都會錄進去，通知音也是。
- 錄製前請先告知與會者，並遵守所在單位與當地法規的錄音規定。

### 播放器 `player.html`

用 Finder 雙擊就能開（`file://`，不需要伺服器），要跟 `recording.mp4` 放在同一個資料夾。

- 點句子或時間：跳到該秒並播放
- 播放時目前那句會高亮，並自動捲到中間（可關掉「自動捲動」）
- 搜尋：輸入關鍵字，Enter／Shift+Enter 跳下一個／上一個
- 快捷鍵：空白 播放／暫停、← → 前後 5 秒、`/` 搜尋、Esc 清除搜尋
- 書籤顯示在影片下方，也會插在逐字稿對應位置
- 前面有 ⚠️ 的句子是辨識信心很低的句子（可能聽錯，也可能是靜音裡冒出來的幻覺），保留下來讓你對照影片判斷，不會默默刪掉
- 瀏覽器只會播 mp4 的預設音軌，所以預設音軌就是「系統音＋麥克風」的混音，兩方的聲音都聽得到。要單聽某一方，用 VLC／IINA 打開 `recording.mp4` 切換第 2、3 條音軌

### 術語表與修正表

- `~/Library/Application Support/MeetingRecorder/glossary.txt`：一行一個詞，選單「編輯術語表」可直接打開。這些詞會串成 Whisper 的 initial prompt，讓它更容易拼對英文術語。repo 附的 `glossary.default.txt` 只是通用範例，請換成你的會議常講的詞。prompt 上限約 220 個 token，超過時截掉的是最前面的詞。**目前只對錄音開頭約 30 秒有效**，原因見「已知限制」。
- `~/Library/Application Support/MeetingRecorder/replacements.txt`：一行 `錯誤 => 正確`，在轉成繁體之後套用。OpenCC `s2twp` 會做台灣用語的詞彙替換，偶爾改到意思（預設已加「引數 => 參數」）；Whisper 固定聽錯的詞也可以放這裡。

### 重跑轉錄

改了術語表、換了模型，或轉錄失敗時（`--skip-mux` 表示沿用已經合成好的 `recording.mp4`；如果是合成這一步就失敗、資料夾裡還沒有 `recording.mp4`，把 `--skip-mux` 拿掉）：

```bash
"$HOME/Library/Application Support/MeetingRecorder/venv/bin/python" "$HOME/Library/Application Support/MeetingRecorder/scripts/mr_process.py" "$HOME/Movies/MeetingRecorder/2026-10-23_1400_週會" --skip-mux
```

其他選項：`--model <HF repo>`、`--glossary <檔案>`、`--keep-raw`（保留合成前的原始分軌）、`--no-notify`。

### 命令列錄製（測試用）

```bash
open -n -W --stdout /tmp/mr.log ~/Applications/MeetingRecorder.app --args record --mode online --seconds 120 --name 測試 --mic MacBook --bookmark-at 30,60
```

要用 `open` 啟動，這樣授權對象才是 MeetingRecorder 本身；直接從終端機執行執行檔時，授權對象會變成終端機。錄製中可對程序送 `SIGUSR1` 打書籤。`record --mode physical [--screen]` 是實體模式，`list-mics` 列出麥克風，`--mic` 用麥克風名稱的關鍵字選裝置。

## 運作方式

```
SCStream（一條串流，macOS 15+）
 ├─ .screen      → AVAssetWriter → video.mov（H.264，15 fps，最寬 1920）
 ├─ .audio       → system.caf（48 kHz 立體聲）
 └─ .microphone  → mic.caf（麥克風原生格式）
        三路的時間戳都在同一個主機時鐘上，以開始錄製的瞬間 t0 為 0；
        音訊遇到空檔會補靜音，所以三個檔案的第 N 秒對應同一刻。
停止 → mr_process.py
 ├─ ffmpeg：合成 recording.mp4（混音軌＋兩條原音軌，影像不重新編碼）
 ├─ mlx-whisper：language=zh、initial prompt＝術語表、逐字時間戳 → 在標點處切成短句
 ├─ OpenCC s2twp ＋ 修正表 ＋ 中文旁的半形標點改全形
 └─ 產出 srt / md / json / player.html → osascript 通知
```

程式碼：

- `Sources/MeetingRecorder/`：Swift。`Recorder.swift`（擷取與寫檔）、`AudioSink.swift`（音訊對齊補靜音、格式轉換）、`AppDelegate.swift`（選單列）、`HotKey.swift`（全域快捷鍵，用 Carbon，不需要輔助使用權限）、`main.swift`（命令列模式）、`Paths.swift`、`PostProcess.swift`
- `scripts/mr_process.py`：後處理；`scripts/player_template.html`：播放器範本
- `scripts/make_icon.swift`、`scripts/make_icon.sh`：畫 App 圖示並產生 `Resources/AppIcon.icns`（改設計後重跑 `./scripts/make_icon.sh`，再 `./build.sh`；圖示在 App 裡，所以換圖示也要重新授權）
- `build.sh`：直接用 `swiftc` 編譯（`./build.sh --no-install` 只編譯不安裝）。錄製中（`~/Library/Application Support/MeetingRecorder/recording.lock` 對應的程序還活著）會拒絕重新安裝，以免把正在錄的 App 砍掉；確定沒在錄卻被擋下時（例如當機後留下的舊鎖剛好碰上重複的 pid），手動刪掉這個檔即可。有些 Command Line Tools 會殘留舊的 `usr/include/swift/module.modulemap`，跟新版重複定義 `SwiftBridging`，SwiftPM 與 swiftc 都會編譯失敗；`build.sh` 偵測到時會用 VFS overlay 把它遮掉，不需要動系統檔。

## 隱私

- 錄影與逐字稿只存在 `~/Movies/MeetingRecorder/`，不在 repo 裡；`.gitignore` 也排除所有影音、字幕、逐字稿檔案。
- 轉錄在本機 GPU 執行，模型下載完之後不連網。
- 檔案未加密。要更保險，請確認已開啟 FileVault，並避免讓 iCloud 或其他雲端同步 `~/Movies/MeetingRecorder`。

## 驗證紀錄（2026-10，M 系列 MacBook Air、macOS 15.7）

測試素材是用 macOS 內建中文語音（`say`）產生的一段中英夾雜技術討論，做成測試影片當「對方」的聲音，另一段從內建喇叭播出給麥克風收音。

| 驗證項目 | 方法 | 結果 |
|---|---|---|
| 三路都錄得到、時間對齊 | 線上模式錄 135 秒：播測試影片，再從喇叭講話 | 螢幕、系統音、麥克風三個檔都有資料；第一筆資料離起點 0.07–0.16 秒，三路同一個時鐘 |
| 系統音不經喇叭也錄得到 | 線上模式錄 82 秒：A 段把預設輸出（內建喇叭）設成靜音再播影片；B 段解除靜音從喇叭講話當對照 | A 段系統音軌約 -15 dB，單獨轉錄可完整轉出影片講稿；同段麥克風軌只有底噪，單獨轉錄只出現 Whisper 的靜音幻覺句。B 段麥克風比 A 段高 10–20 dB |
| 兩條獨立音軌＋混音預設軌 | `ffprobe` 看 `recording.mp4` | 第 1 軌混音（default）、第 2 軌系統音、第 3 軌麥克風，全部從 0 秒開始 |
| Chrome 播放兩方都聽得到 | Google Chrome 播 player.html，以 Web Audio 量輸出音量。素材是兩方內容不重疊的合成會議 | Chrome 不支援 `audioTracks`，只播預設軌；只有系統音的段落與只有麥克風的段落都量得到聲音（中位數 -13.8 dB／-17.9 dB） |
| 逐字稿是繁體、點句跳轉正確 | Google Chrome 以 `file://` 開 player.html，透過 DevTools 協定點 4 句，各等 1.5 秒 | 播放位置都等於「句子起點＋約 1.4 秒」、正在播放、高亮在被點的那句；搜尋、書籤跳轉也正常 |
| 影片壞掉時仍有逐字稿 | 把 video.mov 換成亂碼再跑後處理 | 自動改成只合成聲音、照常轉錄，逐字稿開頭的「注意」區有說明 |

還沒驗證：選單列的實際點擊流程（開始、輸入名稱、停止）、⌃⌥B 全域快捷鍵、錄製中換麥克風的格式轉換、真人（非 TTS）中英夾雜的辨識率、超過 1 小時的長時間錄製。

## 已知限制

- **英文術語辨識**：測試素材是中文 TTS 硬唸英文單字，專有名詞與縮寫常被聽錯；真人中英夾雜的辨識率尚未實測。可用術語表與修正表改善。
- **術語表只影響開頭約 30 秒。** mlx-whisper 在 `condition_on_previous_text=False`（為了避免幻覺一路重複下去）時，每個 30 秒視窗之後都會把 prompt 重設。曾試過讓每個視窗都帶術語表，結果同一段 135 秒的測試錄音裡，有一段 26 秒的講話整段沒轉出來（0 句，原本 7 句），所以不採用。之後的視窗靠的是模型本身，固定聽錯的詞請用修正表處理。
- 開頭偶爾會冒出術語表裡的詞（initial prompt 洩漏），是 Whisper 的已知行為；這種句子通常會被標上 ⚠️。
- 轉錄語言目前固定為中文（`scripts/mr_process.py` 裡的 `language="zh"`），輸出一律轉台灣繁體。
- 只錄主螢幕；外接螢幕上的視窗不會錄進去。
- 剛授權後的第一次錄製，曾觀察到麥克風延遲幾秒（2.8 秒、7.3 秒）才送出第一筆資料，這段麥克風聲音沒錄到；之後的錄製都在 0.13 秒內。時間軸有補靜音，所以不會錯位。建議授權後先錄一段短測試。
- 錄製中換麥克風、或藍牙耳機切到通話模式時，會自動轉回原本的取樣率繼續錄，並在逐字稿的「注意」區記下從第幾秒開始；這個轉換路徑還沒有實機測過。
- 麥克風與主機的時鐘若有些微誤差，長時間錄製時麥克風軌可能慢慢偏移（推估 2 小時內在 1 秒以下，未實測）。

## 授權條款

[MIT](LICENSE)
