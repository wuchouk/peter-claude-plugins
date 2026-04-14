---
description: >
  多 session 溝通協議 — 讓同一 git repo 內平行開發（git worktree）的 Claude Code sessions
  透過 file-based inbox 非同步交換訊息。包含開啟/關閉溝通模式、發送/接收訊息、
  三層 urgency 判斷（sender-tagged / scope-match / default）、三層投遞機制
  （Monitor pub/sub + pre-long-tool peek + post-long-tool peek）、殭屍 session 自動清理。

  觸發條件：
  (1) 使用者呼叫 /session-comms；
  (2) 使用者說「開啟溝通模式」「連到另一個 session」「multi-session」「多 session 溝通」
      「我要下線了」「離開溝通模式」「有誰在線」「check who's online」
      「發訊息給 XX session」「connect to other sessions」等等價說法；
  (3) 已開啟溝通模式的 session 在執行長 tool 前後應主動 peek inbox（見 §7）。

  Do NOT trigger for: 單一 session 開發（沒有其他 session 在跑時不需要）、
  跟真人聊天、跟 subagent 通訊（subagent 是 in-process，不需要這套協議）。
allowed-tools: Read, Write, Edit, Bash, Glob, Grep
---

# Session Coordination Protocol — 多 Session 溝通協議

你是 Claude Code 多 session 溝通協議的執行者。Peter 經常同時開多個 session 在不同 git worktree 平行開發，需要 session 之間能非同步交換訊息協調 scope、型別、通知 breaking change。你的工作是把這個協議跑起來：開啟/關閉溝通模式、收發訊息、做 urgency 判斷、在長 tool 前後主動 peek inbox。

**核心檔案結構（位於 git repo root）：**

```
tasks/.comms/
├── registry.md                      # 所有在線 session 的註冊表
├── <session-name>.inbox.md          # 每個 session 的信箱
└── archive/                         # 下線 session 的 inbox 留底（保留 7 天）
```

**三種訊息類型：** `default`（一般）/ `URGENT`（scope 衝突、breaking change）/ `FYI`（純知會）

**核心原則：** 下線由 Peter 人為控制，不做 LEAVING handshake。Session 生命週期跟 worktree 生命週期綁定。

---

## 1. 動作分發（讀到使用者輸入後先判斷要做什麼）

根據使用者輸入，分發到下面的對應 section：

| 使用者說 | 動作 | 對應 section |
|----------|------|-------------|
| 「開啟溝通模式」「session-comms」「連到 session」「我要和其他 session 通訊」 | 開啟 | §2 |
| 「發訊息給 XX」「跟 XX 說」「問 XX 一下」「通知大家」 | 發訊息 | §3 |
| 「有沒有新訊息」「讀 inbox」「檢查一下 inbox」 | 讀訊息 | §4 |
| 「我要下線了」「離開溝通模式」「結束 session-comms」 | 下線 | §5 |
| 「有誰在線」「列出 sessions」「check who's online」 | 列表 | §6 |

**隱式觸發（不需使用者明說）：**
- 本 session 已開啟溝通模式、即將執行長 tool（見 §7 定義）→ **pre-long-tool peek**
- 長 tool 剛結束 → **post-long-tool peek**
- Monitor 回報 `INBOX_CHANGED` → 讀 inbox（§4）

---

## 2. 開啟溝通模式（Open）

**步驟：**

### 2.1 確認環境

```bash
git rev-parse --show-toplevel
```

- 不在 git repo → 告訴 Peter「session-comms 只在 git repo 內運作。請先 `cd` 到專案目錄」並結束
- 在 git repo → 記住 `$GIT_ROOT`，繼續

### 2.2 執行 init 腳本

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/init-comms.sh"
```

這會建立 `tasks/.comms/` 目錄、加進 `.gitignore`、建立空的 `registry.md`、清理 7 天前的 archive。

### 2.3 讀取現有 registry，清理殭屍

讀 `tasks/.comms/registry.md`。對每個已註冊的 session，檢查它的 heartbeat 檔案年齡：

```bash
# 檢查 session <name> 是否還活著（10 分鐘內有心跳）
HB="$(git rev-parse --show-toplevel)/tasks/.comms/<name>.heartbeat"
if [ -f "$HB" ]; then
  AGE=$(($(date +%s) - $(stat -f %m "$HB")))
  if [ "$AGE" -lt 600 ]; then echo alive; else echo zombie; fi
else
  echo zombie  # 沒 heartbeat 檔 = 殭屍
fi
```

**為什麼用 heartbeat file 不用 PID：** Claude Code 的 Bash tool 每次呼叫都 spawn 新 shell，所以 `$$` 拿到的是 ephemeral shell PID，不是 Claude Code 主 process 的 PID，下次檢查一定會判成殭屍。Heartbeat file 的 mtime 由 session 本人在每次操作時主動更新，繞過這個問題。

對於殭屍：
1. 把它那行從 registry 刪掉（用 Edit 工具）
2. 呼叫 archive-inbox.sh — 會同時搬走 inbox 和刪 heartbeat：
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/archive-inbox.sh" <zombie-name> zombie
   ```

### 2.4 問 Peter 三個問題（用 AskUserQuestion）

1. **Session name** — 建議預設用當前 git branch 名去掉前綴（例：branch `feature/archive-ui` → session `archive-ui`）
2. **Work scope** — 這個 session 負責的檔案/目錄/模組，格式類似 glob pattern 列表。例：`components/Archive*, hooks/useArchive*, tests/archive/*`。**務必追問具體 path，不要接受「archive 相關」這種模糊描述**——scope 欄位是其他 session 判斷 urgency 的依據，必須精確
3. **Dev server port**（如果 session 在跑 dev server）— 從 working memory 拿，如果沒有就問

如果 registry 已有其他 session 在線，**同時報告**給 Peter：「目前在線的其他 session：X（scope: ...）、Y（scope: ...）」

### 2.5 寫入 registry

使用 Edit 工具在 registry.md 的 table 底部 append 一行（**不是 Write 整個檔案**，避免踩到其他 session 同時寫入）：

```markdown
| <session-name> | <branch> | <port> | <scope> | <iso-timestamp> |
```

取得當前 branch：`git rev-parse --abbrev-ref HEAD`。Timestamp 用 `date -u +%Y-%m-%dT%H:%M`。

> **注意：** Registry 沒有 PID 欄位。活性檢查透過 `<session>.heartbeat` 檔案（見 §2.6、§2.8）。

### 2.6 建立自己的 inbox 和 heartbeat

```bash
# Inbox
cat > "$GIT_ROOT/tasks/.comms/<session-name>.inbox.md" <<EOF
# Inbox: <session-name>

EOF

# Heartbeat — 空檔案，只看 mtime
touch "$GIT_ROOT/tasks/.comms/<session-name>.heartbeat"
```

### 2.7 啟動 Monitor（可選，建議）

**前置條件：** 必須在 §2.6 建立 inbox 檔案**之後**才能跑，不然 watcher 啟動時會找不到 inbox 直接 exit。

用 `Bash run_in_background=true` 啟動 watcher：

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/watch-inbox.sh" <session-name> 3
```

記住回傳的 shell ID。然後用 Monitor tool 監聽它的 stdout。每次看到 `INBOX_CHANGED` 就觸發 §4 讀 inbox 流程。

> 注意：Monitor 整合是**建議**但非必要。就算沒啟動 Monitor，pre/post long-tool peek（§7）仍然會把訊息撿回來，只是延遲稍長。如果 watcher 啟動失敗，告訴 Peter 「Monitor watcher 啟動失敗，會改用 pure peek 模式，訊息可能延遲到下次長 tool 結束才讀到」，然後繼續。

### 2.8 記住 session 狀態

把下列資訊存進當前對話的 working memory（概念上的 mental note，不寫檔案）：

```
session_comms_active: true
session_name: <session-name>
scope: <scope-list>
inbox_path: tasks/.comms/<session-name>.inbox.md
heartbeat_path: tasks/.comms/<session-name>.heartbeat
last_inbox_mtime: <current mtime from stat-inbox.sh>
last_inbox_size: <current size from stat-inbox.sh>
watcher_shell_id: <id or null>
next_message_id_counter: 1
```

`last_inbox_mtime` + `last_inbox_size` 用於 §7 peek 比對。**兩個都要記住**—因為 macOS 檔案系統的 mtime 精度只有 1 秒，同一秒內的連續寫入 mtime 不會變，但 size 會變，所以比對要用「mtime 變了 OR size 變了」。

### 2.9 回報

```
✅ 溝通模式啟動
Session name: <name>
Scope: <scope>
Heartbeat: active

其他在線 session：
- <other>（scope: ...）

接下來遇到需要跨 session 協調的情況告訴我即可。
長 tool 前後我會主動 peek inbox，不會漏接訊息。
```

### 2.10 Heartbeat 維護規則（持續執行）

**核心規則：** 只要溝通模式是 active 狀態，**每次執行任何 comms 相關操作之前**（send / receive / peek / list / archive），都要先 touch 自己的 heartbeat 檔案：

```bash
touch "$GIT_ROOT/tasks/.comms/<session-name>.heartbeat"
```

**哪些操作需要 touch？**
- §3 發訊息之前
- §4 讀訊息之前
- §6 列出 session 之前
- §7 pre-long-tool peek 之前
- §7 post-long-tool peek 之前
- Monitor 通知觸發的讀訊息之前

**為什麼這麼密集？** Heartbeat mtime 是其他 session 判斷你是否還在線的唯一根據。只要超過 10 分鐘沒更新就會被當成殭屍清掉。密集更新的成本是零（touch 是 <1ms 的 syscall），但漏更新會讓你被誤殺。

**實作提示：** 可以把 `touch` 跟實際操作的 script 呼叫寫在同一個 Bash tool call 裡：

```bash
touch "$GIT_ROOT/tasks/.comms/<my>.heartbeat" && \
  bash "${CLAUDE_PLUGIN_ROOT}/scripts/stat-inbox.sh" <my>
```

---

## 3. 發訊息（Send）

**步驟：**

### 3.1 確認前置條件

- Session 有開啟溝通模式嗎？沒有 → 先走 §2
- 知道要發給誰嗎？不知道 → 讀 registry 列出給 Peter 選

### 3.2 判斷訊息類型

根據 Peter 的要求內容，決定 type：

- **URGENT**：Peter 說「緊急」「趕快告訴」「breaking change」「我剛改了 XX」「不能動到 XX」，或訊息內容本身涉及 schema/API contract/共用檔案
- **FYI**：Peter 說「順便說」「知會一下」「跟大家講一聲」「我要吃午餐」「不用回覆」
- **default**：其他

**Sender 端的 scope 自動判斷**（bonus 機制）：
1. 讀 registry，找 receiver 的 scope 欄位
2. 把訊息內容的關鍵字（檔名、函式名、feature 名）跟 receiver 的 scope 比對
3. 有命中 → 如果 Peter 沒明確標 FYI，自動升級為 URGENT

### 3.3 產生 message id

從 working memory 取 `next_message_id_counter`，格式化為 `m-NNN`（三位數，不足補 0）。然後 counter +1。

### 3.4 呼叫 write-inbox.sh

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/write-inbox.sh" \
  <target-session> \
  <my-session> \
  <type> \
  <msg-id> \
  "<content>"
```

如果要發給多個 receiver（`--to name1,name2`），loop 呼叫 write-inbox.sh 多次。

### 3.5 確認回報

```bash
# Script 已經印出 "OK sent to=X id=m-001 type=URGENT"
```

告訴 Peter：

```
✅ 已發送
To: <target>
Type: <type>
ID: <msg-id>
Content: <preview>
```

### 3.6 訊息格式範例

生出來的 inbox 會像這樣：

```markdown
# Inbox: archive-ui

<!-- MSG from:api-endpoints ts:2026-04-11T15:30:00Z type:URGENT id:m-001 -->
⚠️  我剛改了 `lib/db/schema.ts` 的 emails table schema，加了 `archived_at` 欄位。
你們 pull 一下避免 migration 衝突。
<!-- END id:m-001 -->
```

---

## 4. 讀訊息（Receive）

**何時觸發：**
- 使用者主動問「有沒有新訊息」
- Monitor 回報 `INBOX_CHANGED`
- Pre/post long-tool peek 偵測到 mtime 變了（見 §7）

**步驟：**

### 4.1 讀取 inbox 檔案

```
Read tool on tasks/.comms/<session-name>.inbox.md
```

### 4.2 找出未讀訊息

Inbox 格式：每個訊息是一個 `<!-- MSG ... -->` 到 `<!-- END id:... -->` 的區塊。已讀訊息會在檔案底部有一行：

```markdown
<!-- READ ts:2026-04-11T15:33Z ids:m-001,m-002 -->
```

找出所有 `<!-- MSG ... id:m-XXX -->` 中**不在任何 READ marker 的 ids 列表裡**的訊息。

### 4.3 對每一則未讀訊息做 urgency 判斷

依序檢查：

**Layer 1 — Sender 標記 URGENT？**
- MSG header 有 `type:URGENT` → 升級為 URGENT，進 §4.4
- 沒有 → 繼續 Layer 2

**Layer 2 — Receiver scope match？**
- 從 working memory 拿自己的 scope 列表
- 把訊息內容（sender 寫的本文）做 substring 比對：是否出現任何 scope 關鍵字（檔名、路徑、函式名、feature id）？
- 有命中 → 升級為 URGENT，進 §4.4
- 沒命中 → 繼續 Layer 3

**Layer 3 — Default / FYI**
- `type:FYI` → 讀了就好，不需回覆動作
- 一般訊息 → 排到下一個自然停頓點（當前 tool call 結束 + 當前邏輯區塊完成）再處理

### 4.4 URGENT 訊息的處理

- **立刻暫停當前工作**（如果正在寫 code，先完成當前 function 不再開新的）
- 用精簡方式告訴 Peter：
  ```
  📬 URGENT from <sender>（<reason: sender-tagged / scope-match>）
  <message content>

  當前工作：<what I was doing>
  建議：<continue / pause / ask user>
  ```
- 根據訊息內容決定是否需要 Peter 決策，或自己可以回覆 / 調整 code / 繼續工作

### 4.5 Default 訊息的處理

- 做完手邊的邏輯區塊
- 讀訊息，決定要不要回覆
- 如果需要回覆 → 走 §3 發訊息流程
- 如果不需要回覆 → 繼續原本工作

### 4.6 標記已讀

讀完所有未讀訊息後，用 Edit 工具在 inbox 末尾 append：

```markdown
<!-- READ ts:<iso-timestamp> ids:<comma-separated-ids> -->
```

### 4.7 更新 last_inbox_mtime + last_inbox_size

呼叫 `stat-inbox.sh <session-name>`，把新的 mtime **和** size 都存進 working memory 的 `last_inbox_mtime` / `last_inbox_size`。

---

## 5. 下線（Leave）

**觸發：** Peter 說「我要下線了」「離開溝通模式」「結束 session-comms」「收工了」

**步驟：**

### 5.1 確認 Peter 真的要下線

如果當前有未讀訊息（上次 peek 後 mtime 變了），先提醒：

```
📬 離線前提醒：inbox 有 N 則未讀訊息。要先讀嗎？
```

### 5.2 停止 watcher

如果 `watcher_shell_id` 不是 null，kill 它：

```bash
kill <watcher_shell_id>
```

（或透過 Claude Code 的 background shell kill 機制，如果有的話。）

### 5.3 從 registry 刪除自己

用 Edit 工具打開 `tasks/.comms/registry.md`，刪掉自己那一行。

### 5.4 歸檔 inbox + 清除 heartbeat（一個 script 搞定）

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/archive-inbox.sh" <session-name> leave
```

這個腳本會同時搬走 inbox 和刪掉 heartbeat 檔案，不需要分兩步。

### 5.5 清理 working memory

把 `session_comms_active` 設為 false，清掉其他相關 state（包括 `heartbeat_path`）。

### 5.6 回報

```
✅ 已離線
Inbox 留底：tasks/.comms/archive/<name>-<ts>-leave.inbox.md
Archive 保留 7 天後自動清除。
```

---

## 6. 列出在線 session（List）

**步驟：**

### 6.1 讀 registry

```
Read tool on tasks/.comms/registry.md
```

### 6.2 對每個 session 檢查 heartbeat 活性

```bash
# 對 registry 中每個 <name> 跑這段
HB="$(git rev-parse --show-toplevel)/tasks/.comms/<name>.heartbeat"
if [ -f "$HB" ]; then
  AGE=$(($(date +%s) - $(stat -f %m "$HB")))
  [ "$AGE" -lt 600 ] && echo "alive age=${AGE}s" || echo "zombie age=${AGE}s"
else
  echo "zombie (no heartbeat)"
fi
```

活著的（age < 600 秒 = 10 分鐘）顯示出來。殭屍**順便清理**（刪 registry 那行 + 歸檔 inbox + 刪 heartbeat 檔）。

### 6.3 報告

```
📋 在線 session：

| Session | Branch | Port | Scope | Started |
|---------|--------|------|-------|---------|
| archive-ui | feature/archive-ui | 3001 | components/Archive* | 14:20 |
| api-endpoints | feature/api | 3002 | app/api/archive/* | 14:22 |

（清理了 1 個殭屍：old-session）
```

---

## 7. Pre/Post Long-tool Peek（三層投遞機制的兜底 2 和 3）

**目的：** Monitor 可能漏接，特別是訊息剛好在 Monitor tick 之間抵達、或 Monitor 沒啟動時。長 tool 一跑幾分鐘就會延遲整片訊息，這個 peek 機制是兜底。

**什麼是長 tool？** 下面這些要 peek：

- `Bash` 且 command 匹配下列 pattern：`npm test`, `npm run build`, `npm install`, `pip install`, `pytest`, `vitest`, `jest`, `playwright`, `curl`, `wget`, `git clone`, `docker`, `cargo build`
- `Bash` 帶 `&&`、`;`、`|` 的 compound command（很可能跑久）
- 任何 `mcp__claude-in-chrome__*`（browser automation）
- 任何 `mcp__chrome-devtools__*`
- `WebFetch`, `WebSearch`
- `Agent`（subagent calls，有可能跑很久）

**什麼是短 tool？** 下面這些**不**做 peek，開銷不值得：

- `Read`, `Edit`, `Write`, `Glob`, `Grep`, `LS`, `TodoWrite`
- `Bash` 且 command 是簡單 file op：`ls`, `cat`, `mkdir`, `mv`, `rm`, `cp`, `stat`, `echo`, `pwd`, `cd`（但 `cd && something` 算 compound，要 peek）

### 7.1 Pre-long-tool peek

**觸發：** 即將執行一個長 tool **之前**（你判斷下一個 tool call 是長 tool 類型）

**執行：**

```bash
bash "${CLAUDE_PLUGIN_ROOT}/scripts/stat-inbox.sh" <session-name>
```

Script 會印 `mtime=<epoch> size=<bytes> exists=true`。

**比對（雙重檢查 mtime + size）：**
- mtime == `last_inbox_mtime` **AND** size == `last_inbox_size` → inbox 沒變 → **直接跑原本的長 tool**
- mtime 變了 **OR** size 變了 → **先讀 inbox**（§4）→ urgency 判斷 → 決定：
  - 有 URGENT（sender-tagged 或 scope-match） → **暫停原本要跑的長 tool**，先處理訊息
  - 只有 default/FYI → 讀完訊息標記已讀，**繼續跑原本的長 tool**

### 7.2 Post-long-tool peek

**觸發：** 長 tool **剛結束後**（訊息可能在 tool 執行當中抵達）

**執行：** 一模一樣的 stat + 比對流程。

**決策：**
- mtime 沒變 → 繼續下一個動作
- mtime 變了 → 讀 inbox，依 §4 urgency 流程處理

### 7.3 關鍵規則

- **只做 stat，不讀檔**（除非 mtime 變了）。stat 是 <10ms 的 syscall，對長 tool 不構成負擔
- **不要對每個短 tool 都 peek**，開銷不值得
- **不要對自己剛寫入的 inbox peek**（如果剛發訊息給別人，那是別人的 inbox 變；你自己的 inbox 沒變）
- **Peek 失敗不要重試**，就當作沒變過繼續

---

## 8. Urgency 判斷總覽（三層）

```
收到訊息 / Peek 到 mtime 變化
  ↓
┌─────────────────────────────────────────────┐
│ Layer 1: Sender 標 type:URGENT？             │
│   YES → 立刻暫停當前工作，優先處理            │
│   NO  → ↓                                   │
└─────────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────────┐
│ Layer 2: Receiver scope match？              │
│   訊息內容提到我 scope 裡的檔案/函式/feature？│
│   YES → 升級為 URGENT → 暫停                 │
│   NO  → ↓                                   │
└─────────────────────────────────────────────┘
  ↓
┌─────────────────────────────────────────────┐
│ Layer 3: Default                            │
│   排到下一個自然停頓點再讀                   │
│   （當前 tool call 結束 + 當前邏輯區塊完成）  │
└─────────────────────────────────────────────┘
```

**Layer 2 的 scope 資料從哪來？** 三個來源，優先順序：

1. **Working memory 的 scope 欄位**（最可靠 — 開啟溝通模式時 Peter 明確告知，也寫進 registry）
2. **`tasks/todo.md` 的 Active section 中標 in-progress 的 task**
3. **`git diff --name-only HEAD` + `git status`**（最近動到的檔案）

**Scope match 的判斷：** Simple substring 比對訊息內容跟 scope 關鍵字。寧可誤判 URGENT（5 秒代價）也不要漏接（可能白做半小時）。

---

## 9. 訊息格式（MSG / READ markers）

**MSG 區塊：**

```markdown
<!-- MSG from:<sender> ts:<iso-utc> type:<type> id:<m-NNN> -->
<content body, multi-line OK>
<!-- END id:<m-NNN> -->
```

- `type` 欄位可省略（等同 `default`）
- `id` 是 sender 端流水號，格式 `m-NNN`
- `ts` 是 ISO 8601 UTC

**READ marker（receiver 寫）：**

```markdown
<!-- READ ts:<iso-utc> ids:m-001,m-002,m-003 -->
```

- 每次讀訊息後 append 一行
- 可以一行涵蓋多個已讀 id
- 舊的 READ marker 不刪，自然累積即可

---

## 10. Edge Cases & 錯誤處理

### 10.1 Registry 不存在 / 格式壞掉

- 呼叫 `init-comms.sh` 重建空的 registry
- 如果 format 壞掉但檔案存在 → 告訴 Peter「registry.md 格式異常，要不要備份後重建？」，等他決定

### 10.2 發訊息給不存在的 session

write-inbox.sh 會 exit 1。告訴 Peter：

```
❌ 發送失敗：<target> 不在線（inbox 不存在）
目前在線：<列出其他在線 session>
```

### 10.3 Watcher 背景 process 死了

- 長 tool 結束後做 post peek 時如果發現 mtime 變了但沒收到 Monitor 通知 → watcher 可能死了
- 重新啟動 watcher，告訴 Peter 「Watcher 重啟」
- 繼續正常流程

### 10.4 多個 session 同時寫 registry（race condition）

- v0.1 採用 optimistic approach：write 前先 read 一次記住 mtime，寫完後再讀一次確認 mtime 只差一跳
- 如果差超過一跳 → 有人插隊了 → 重新 read + 嘗試 write（最多重試 2 次）
- 兩個 session 同時開啟溝通模式的機率極低，這個處理就夠

### 10.5 Inbox 越長越大

- 單一 session 週期內的 inbox 通常不會超過 50 則訊息
- 下線時整個 archive 掉，下次開 session 從空檔開始
- 不做 rotation

### 10.6 Peter 在沒開溝通模式時說「發訊息給 XX」

- 先問：「你還沒開啟溝通模式，要先開嗎？」
- 如果是 → 走 §2 → 走 §3
- 如果否 → 告訴他：「那沒辦法發訊息，建議先 cd 到專案目錄開溝通模式。」

### 10.7 Inbox 訊息看起來損壞 / write-inbox.sh 回傳 exit 3

- **write-inbox.sh 用 mkdir-based spinlock 保護 append**，5 秒 timeout。正常情況不會交錯
- **exit 3**（lock acquire timeout）代表 inbox 的 `.lock` 目錄卡住了（可能另一個 session 寫到一半 crash）。處理：
  1. 檢查 `tasks/.comms/<target>.inbox.md.lock` 是否存在
  2. 如果存在且超過 10 秒 → 視為 stale lock，`rmdir` 清掉
  3. 重試一次 write-inbox.sh
  4. 還失敗就告訴 Peter
- **萬一真的看到損壞訊息**（無法配對的 `<!-- MSG -->` / `<!-- END -->`，應該很罕見）：告訴 Peter「inbox 發現損壞訊息，你想要：(a) 跳過損壞部分繼續讀；(b) archive 整個 inbox 重建空檔；(c) 手動修」

### 10.8 兩個 session 同時開啟溝通模式想拿相同 session name

- v0.1 採「後到者覆寫前者」：開啟時如果 registry 已有同名 session，且該 session 還活著（heartbeat 新鮮），告訴 Peter「`<name>` 已被另一個 session 使用，請換一個名字」並要求重選
- 只有在同名 session 是殭屍時才允許覆寫

---

## 11. 路徑參考（速查）

| 用途 | 路徑 |
|------|------|
| Scripts | `${CLAUDE_PLUGIN_ROOT}/scripts/` |
| init-comms | `${CLAUDE_PLUGIN_ROOT}/scripts/init-comms.sh` |
| write-inbox | `${CLAUDE_PLUGIN_ROOT}/scripts/write-inbox.sh` |
| stat-inbox | `${CLAUDE_PLUGIN_ROOT}/scripts/stat-inbox.sh` |
| watch-inbox | `${CLAUDE_PLUGIN_ROOT}/scripts/watch-inbox.sh` |
| archive-inbox | `${CLAUDE_PLUGIN_ROOT}/scripts/archive-inbox.sh` |
| Registry（runtime） | `<git-root>/tasks/.comms/registry.md` |
| Inbox（runtime） | `<git-root>/tasks/.comms/<session-name>.inbox.md` |
| Archive（runtime） | `<git-root>/tasks/.comms/archive/` |

---

## 12. 溝通原則

- **繁體中文**，跟 Peter 所有互動
- **簡潔**：訊息本文不用寫散文，一兩行講清楚即可
- **隱藏實作細節**：除非 Peter 問，不要講 MSG marker 格式、mtime 機制這些內部細節。他只需要知道「我發了訊息」「我讀到訊息」
- **誠實報告失敗**：script 回傳非 0 → 馬上告訴 Peter，不要 silent retry
- **不要自作主張代 Peter 做決定**：URGENT 訊息讀到要做什麼改動，如果涉及現有 code 的修改，問 Peter 確認
- **保持 scope 精確**：Peter 開啟溝通模式時如果 scope 描述模糊，**務必追問具體 path**，因為 scope match 的精度直接影響 urgency 判斷品質
