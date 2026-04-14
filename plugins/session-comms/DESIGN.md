# session-comms Plugin — Design Document

> **狀態：** v0.1 shipped 2026-04-11
> **日期：** 2026-04-11
> **作者：** Peter + Claude（協議設計討論見 session `d75f7f39`）
>
> **已鎖定的決策（§11 開放問題的 Peter 選擇）：**
> 1. Session name 預設用 git branch 名，Peter 可覆寫
> 2. `tasks/.comms/` 加進 `.gitignore`
> 3. Archive 保留 7 天，`open-session` 時順便清理超過 7 天的
> 4. Peek 機制寫在 SKILL.md（選項 B，依賴 Claude 自律），不做 PreToolUse hook
> 5. v0.1 廣播：用 `--to name1,name2` 多目標，不做 `--broadcast`
> 6. Scope 衝突主動偵測：v0.1 不做
> 7. Monitor tick 間隔：3 秒
> 8. Cross-project 支援：v0.1 不做
>
> **實作期間對 DESIGN.md 的偏離（以 SKILL.md 為最終真相）：**
> - **§3 Registry 欄位** 不含 `PID`，改用 **heartbeat file**（`<session>.heartbeat`）做活性檢查。原因：Claude Code 的 Bash tool 每次 spawn 新 shell，`$$` 不穩定，PID 做不到
> - **§4 mtime 比對** 升級為 mtime + size 雙重比對。原因：macOS 檔案系統 mtime 精度 1 秒，同秒內多次寫入靠 mtime 偵測不到
> - **§10 原子性** v0.1 shipped 即支援原子 append。`write-inbox.sh` 用 mkdir-based spinlock（5 秒 timeout），macOS 不需要 `flock`。Stale lock 有 §10.7 recovery 流程

---

## 1. 目的與使用情境

**問題：** Peter 經常同時開多個 Claude Code session 平行開發不同功能（通常透過 git worktree 隔離）。這些 session 之間有時會遇到需要互相協調的情境：

- **Scope 衝突確認** — 「我要改 `Header.tsx`，你那邊有動嗎？」
- **共用資源變更** — 「我剛改了 `schema.ts` 的 emails table，你 pull 一下」
- **型別協商** — 「你的 API response 型別是 `Email[]` 還是 `{ emails: Email[] }`？」
- **完工通知** — 「archive UI 完成了，你可以開始接 API 了」

**現狀：** Peter 目前是手動在兩個 terminal 之間 copy-paste 訊息，或是 ESC 打斷另一個 session 輸入訊息。很慢、很痛、容易出錯。

**目標：** 讓 session 之間可以**非同步通訊**，不需要 Peter 當中間人。

**非目標（out of scope）：**
- 跨機器通訊（只支援同一台 Mac 上的 session）
- Session 自主下線決策（下線由 Peter 人為控制，詳見 §6）
- Realtime 即時傳訊（非同步訊息佇列就夠了）
- 取代 git 作為資料同步機制（protocol 只傳遞「意圖」和「訊息」，不傳 code）

---

## 2. 整體架構

**核心概念：file-based message queue**，利用 git worktree 已經 symlink 的 `tasks/` 目錄作為共享通道。

```
<project-root>/tasks/.comms/
├── registry.md                      ← 所有在線 session 的註冊表（唯一全域檔）
├── <session-name>.inbox.md          ← 每個 session 一個信箱（只有 owner 讀，任何人寫）
├── <session-name>.inbox.md          ← ...
└── archive/                         ← 離線 session 的 inbox 留底（除錯用）
    └── <session-name>-<ts>.inbox.md
```

**為什麼選 file-based：**

1. ✅ **免基礎設施** — 不需要 socket、DB、中央 server
2. ✅ **利用既有 symlink** — worktree 已經把 `tasks/` symlink 到主目錄，免費跨 worktree 共享
3. ✅ **Git 友善** — 可以 `.gitignore` 排除，不會污染 commit
4. ✅ **易除錯** — 純 markdown，人類可讀
5. ✅ **崩潰安全** — session 崩了 inbox 還在，重開就接得回去

**已評估但捨棄的替代方案：**

| 方案 | 捨棄原因 |
|------|---------|
| Unix socket | 需要背景 daemon、崩潰難恢復 |
| SQLite | 過度設計，兩個 session 根本不需要 ACID |
| Redis / 中央 broker | 基礎設施成本 |
| Git branch 當訊息佇列 | commit 噪音太大、延遲過高 |
| 直接寫入對方 terminal | 沒有這種 API |

---

## 3. Registry 格式

`tasks/.comms/registry.md`：

```markdown
# Session Registry

> 多 session 平行開發時的註冊表。session-comms plugin 自動維護。

| Session Name | Branch | Port | Scope | Started | PID |
|--------------|--------|------|-------|---------|-----|
| archive-ui | feature/archive-ui | 3001 | `components/Archive*`, `hooks/useArchive*` | 2026-04-11T14:20 | 82341 |
| api-endpoints | feature/api-archive | 3002 | `app/api/archive/*`, `lib/db/schema.ts` | 2026-04-11T14:22 | 82456 |
```

**欄位說明：**
- **Session Name** — Peter 在啟動溝通模式時指定（例：`archive-ui`）
- **Branch** — 當前 git branch（自動偵測）
- **Port** — dev server port（從 session working memory 讀，詳見 CLAUDE.md Port 隔離規則）
- **Scope** — 這個 session 負責的檔案/目錄 glob patterns（由 Peter 明確告知 Claude，由 Claude 寫進去）
- **Started** — ISO 8601 timestamp
- **PID** — Claude Code 的 process ID（用來偵測殭屍 session — 如果 PID 不存在了，其他 session 可以主動清理）

**併發寫入處理：** Registry 採用 **append + rewrite** 模式。寫入前先讀整個檔案、改完再整個寫回。如果偵測到寫入時 mtime 變了（race condition），重試一次。兩個 session 同時開溝通模式的機率極低，簡單鎖就夠。

---

## 4. Inbox 格式

`tasks/.comms/<session-name>.inbox.md`：

```markdown
# Inbox: archive-ui

<!-- MSG from:api-endpoints ts:2026-04-11T15:30 type:URGENT id:m-001 -->
⚠️  我剛改了 `lib/db/schema.ts` 的 emails table schema，
加了 `archived_at` 欄位。你們 pull 一下避免 migration 衝突。
<!-- END id:m-001 -->

<!-- MSG from:api-endpoints ts:2026-04-11T15:32 id:m-002 -->
你的 Header type 有沒有處理 multi-value headers（同一個 key 多個值）？
我 API response 那邊需要確認。
<!-- END id:m-002 -->

<!-- READ ts:2026-04-11T15:33 ids:m-001,m-002 -->
```

**關鍵設計：**

- **一次寫完才 flush** — sender 產生完整 `<!-- MSG ... --> ... <!-- END --> ` 區塊再一次 append，避免 reader 讀到半截訊息
- **`id` 欄位唯一** — 格式 `m-{流水號}`，讓「讀過標記」可以明確指涉哪些訊息
- **`<!-- READ ... -->` 標記已讀** — reader 讀完後 append 一行 READ marker，sender 可以查詢對方是否已讀（類似 Line/WhatsApp 的已讀功能，用於 debug）
- **只 append，不修改** — 避免 race condition
- **檔案逐漸長大** — 每次 session 結束 leave 時整個 archive 掉，下次開新 session 從空檔案開始

---

## 5. 訊息類型

砍掉原本的 LEAVING（下線改人控），剩三種：

| Type | 用途 | 接收行為 | 範例 |
|------|------|---------|------|
| **default**（預設，省略 type） | 一般問答、閒聊、非阻塞通知 | 做完手邊邏輯區塊再讀 | 「你的 Header type 長怎樣？」 |
| **URGENT** | Scope 衝突、breaking change、阻塞對方的事情 | 盡快暫停當前 tool call，優先讀 | 「我改了 schema，你 pull」 |
| **FYI** | 純知會，不需回覆 | 讀了就好，不回覆 | 「我要吃午餐 30 分鐘」 |

**URGENT 不是 sender 單獨決定的** — 還有第二層判斷，見 §7。

---

## 6. Session 生命週期

### 6.1 開啟溝通模式

**觸發：** Peter 對 session 說「開啟溝通模式」/「connect to other sessions」/「session-comms」/ 呼叫 `/session-comms` command

**Claude 執行：**
1. 確認當前在 git repo 內
2. 建立 `tasks/.comms/` 目錄（如果不存在）+ 加進 `.gitignore`（如果還沒）
3. 讀 `registry.md`，看有哪些其他 session 在線
4. **問 Peter 三個問題**（用 `AskUserQuestion`）：
   - 「這個 session 叫什麼名字？」（例：`archive-ui`，預設可用 branch 名）
   - 「這個 session 的 work scope 是什麼？」（例：`components/Archive*, hooks/useArchive*` — 會寫進 registry 的 scope 欄位給其他 session 看）
   - 「要看看現在有哪些 session 在線嗎？」（如果 registry 不空才問）
5. 把自己加進 `registry.md`
6. 建立自己的 `<session-name>.inbox.md`（只有 header，沒有訊息）
7. 啟動 Monitor 監聽自己的 inbox
8. 回報：「溝通模式啟動。你是 `archive-ui`，目前在線的 session：api-endpoints (scope: `app/api/archive/*`)」

### 6.2 開發中的訊息收發

詳見 §7 和 §8。

### 6.3 下線（人為控制）

**觸發：** Peter 說「我要下線了」/「結束溝通模式」/「leave」/ 或 session 結束前主動提醒 Peter

**Claude 執行：**
1. 讀 `registry.md`，把自己那行刪掉
2. 把自己的 inbox 檔 `mv` 到 `archive/<session-name>-<timestamp>.inbox.md`
3. 停止 Monitor
4. 回報：「已離線。inbox 留底在 `archive/archive-ui-20260411-1530.inbox.md`」

**不做 LEAVING 廣播** — Peter 決定何時下線，不需要問其他 session 是否需要自己。

### 6.4 殭屍 session 清理

其他 session 開溝通模式時，掃 `registry.md` 的每個 PID，用 `kill -0 <pid>` 檢查是否還在。不在就自動清理那行 + 把 inbox 搬進 archive。

---

## 7. Receiver 端的 urgency 判斷（三層）

收到訊息後，依序判斷：

```
讀到訊息
  ↓
┌─────────────────────────────────────┐
│ Layer 1: Sender 標 URGENT？          │
│   YES → 立刻暫停當前工作，優先處理    │
│   NO  → ↓                           │
└─────────────────────────────────────┘
  ↓
┌─────────────────────────────────────┐
│ Layer 2: Receiver scope match？      │
│   訊息內容提到我正在改的檔案/函式/    │
│   feature？                         │
│   YES → 升級為 URGENT → 暫停         │
│   NO  → ↓                           │
└─────────────────────────────────────┘
  ↓
┌─────────────────────────────────────┐
│ Layer 3: Default                    │
│   排到下一個自然停頓點再讀            │
│   （當前 tool call 結束 +            │
│    當前邏輯區塊完成）                │
└─────────────────────────────────────┘
```

**Layer 2 的「我在改什麼」從哪來？** 三個來源，優先順序：

1. **Registry 裡自己的 scope 欄位**（最可靠 — Peter 在 §6.1 步驟 4 明確告知）
2. **`tasks/todo.md` 的 Active section 中標 in-progress 的 task**
3. **`git diff --name-only HEAD` + `git status`**（最近動到的檔案）

**Scope match 的判斷邏輯：** 把訊息內容 tokenize，查是否命中任一 scope 關鍵字（檔名、函式名、feature id）。**簡單 substring 比對就好，寧可誤判也不要漏接。**

**Bonus — Sender 端也做 scope 判斷：** Sender 準備發訊息前，先讀 `registry.md` 看 receiver 的 scope。如果訊息內容跟 receiver scope 強相關，sender 自動標 URGENT。這樣兩端互相兜底。

---

## 8. 訊息投遞機制（三層）

短 tool（Read、Edit、Glob、Grep）**不做 peek**，開銷不值得。只有這三層：

### Layer 1: Monitor pub/sub（主機制）

- Monitor 在背景持續跑，每 **3 秒** tick 一次
- 每次 tick 檢查 `<session-name>.inbox.md` 的 mtime
- mtime 變了 → fire notification → Claude 在**當前 tool call 結束後**讀取 inbox
- 非阻塞：不會打斷正在跑的 tool call

### Layer 2: Pre-long-tool peek（兜底 1）

- **觸發：** 即將跑「長 tool」前（定義見下）
- **動作：** `stat -f %m inbox.md` 檢查 mtime（<10ms）
- mtime 沒變 → 直接跑 tool
- mtime 變了 → **先讀 inbox** → 走 §7 的 urgency 判斷 → 決定是否繼續跑原 tool

**「長 tool」定義：**
- `Bash` 且 command 匹配 `npm test`, `npm run build`, `playwright`, `pytest`, `vitest`, `jest`, `curl`, `wget`, `git clone`, `docker`, `npm install`, `pip install`
- 任何 `mcp__claude-in-chrome__*`（browser automation）
- 任何 `mcp__chrome-devtools__*`
- `WebFetch`, `WebSearch`
- `Agent` (subagent calls)
- `Bash` 帶 `&&`, `;`, `|` 的 compound command（很可能跑久）

**「短 tool」清單（不做 peek）：** `Read`, `Edit`, `Write`, `Glob`, `Grep`, `LS`, `TodoWrite`, 簡單的 `Bash ls/cat/mkdir/mv/rm`

### Layer 3: Post-long-tool peek（兜底 2）

- **觸發：** 長 tool 結束後
- **動作：** 再 `stat` 一次，撿 tool 執行過程中抵達的訊息
- 有新訊息 → 讀 → 走 §7 urgency 判斷 → 決定下一步

**為什麼兩層都需要？** Monitor 有 tick 間隔（3 秒）。如果訊息剛好在 tick 之間抵達，且 Claude 馬上要跑一個 3 分鐘的 browser test，光靠 Monitor 會漏掉 3 分鐘。Pre/post peek 就是為了把這些漏接的訊息撿回來。

---

## 9. 檔案結構與 Plugin 實作

```
~/peter-claude-plugins/plugins/session-comms/
├── DESIGN.md                           ← 這份文件
├── .claude-plugin/
│   └── plugin.json
├── commands/
│   └── session-comms.md                ← /session-comms command（觸發溝通模式）
├── skills/
│   └── session-comms/
│       └── SKILL.md                    ← 完整協議文件，使用者說關鍵字時自動載入
└── scripts/
    ├── open-session.sh                 ← 建目錄、加 .gitignore、寫 registry
    ├── leave-session.sh                ← 從 registry 刪除、搬 inbox 到 archive
    ├── send-message.sh                 ← 寫入對方 inbox（原子 append）
    ├── peek-inbox.sh                   ← 快速 stat mtime check
    ├── read-inbox.sh                   ← 讀取未讀訊息 + 寫 READ marker
    ├── list-sessions.sh                ← 列 registry（帶殭屍清理）
    └── check-scope-match.sh            ← 簡單 substring 匹配 scope 關鍵字
```

**Skill 觸發詞（SKILL.md description）：** 「Multi-session coordination protocol. Enables parallel Claude Code sessions in different git worktrees to exchange messages via file-based inbox. Triggers: '開啟溝通模式', '連到另一個 session', 'connect to other sessions', 'session-comms', '多 session 溝通'.」

**CLAUDE.md pointer（只加一行）：** 在 `### Parallel Development with Worktrees` 底下加：

> 多 session 需要互相溝通時，呼叫 `/session-comms` 或說「開啟溝通模式」。詳見 `session-comms` plugin。

---

## 10. Monitor 實作細節

**問題：** Claude Code 的 Monitor tool 是 stream-based，怎麼用它監聽檔案？

**方案 A — 背景 bash script + file watch：**
```bash
# scripts/watch-inbox.sh
INBOX="$1"
LAST_MTIME=$(stat -f %m "$INBOX" 2>/dev/null || echo 0)
while true; do
  CURRENT_MTIME=$(stat -f %m "$INBOX" 2>/dev/null || echo 0)
  if [ "$CURRENT_MTIME" != "$LAST_MTIME" ]; then
    echo "INBOX_CHANGED ts=$CURRENT_MTIME"
    LAST_MTIME=$CURRENT_MTIME
  fi
  sleep 3
done
```
Claude 用 `Bash run_in_background=true` 跑這個 script，然後用 `Monitor` tool 讀它的 stdout。每次看到 `INBOX_CHANGED` 就知道要讀 inbox。

**方案 B — fswatch（brew install fswatch）：**
```bash
fswatch -o "$INBOX"
```
更有效率，但多一個依賴。

**建議先用方案 A**（零依賴），之後如果效能不夠再換 B。

---

## 11. 開放問題（需 Peter 拍板）

1. **Session name 命名慣例？**
   - 建議：預設用 git branch 名（`feature/archive-ui` → `archive-ui`）
   - Peter 可以覆寫

2. **`.comms/` 要不要加進 `.gitignore`？**
   - 建議：**要**。Registry 和 inbox 是 ephemeral state，不該進版控
   - 如果 repo 已經 ignore 了 `tasks/*.local` 或類似 pattern 可能要調整

3. **Archive 保留多久？**
   - 建議：保留 7 天，每次 `open-session` 時順便清理超過 7 天的 archive
   - 或完全不清理，由 Peter 手動 `trash ~/tasks/.comms/archive/*`

4. **Peek 的 mtime 檢查是在 hook 還是 skill 內？**
   - 選項 A：寫成 PreToolUse hook（最可靠，但污染所有 session）
   - 選項 B：寫在 SKILL.md 指示 Claude 「即將跑長 tool 前自覺 peek」（依賴 Claude 自律）
   - 建議：**選項 B**（hook 會影響沒開溝通模式的 session，成本不值）。依賴自律可接受，因為 Monitor pub/sub 是主機制，peek 只是兜底

5. **多於 2 個 session 的廣播怎麼辦？**
   - 建議：`send-message.sh` 支援 `--broadcast` flag，寫入 registry 裡所有其他 session 的 inbox
   - 或支援 `--to <name1>,<name2>` 多目標

6. **Scope 衝突的主動偵測？**
   - 進階功能：開 session 時，如果自己宣告的 scope 跟 registry 中其他 session 的 scope 有交集，自動發 URGENT 提醒兩邊
   - 建議：**v0.1 不做**，先看實際用起來會不會遇到

7. **Monitor tick 間隔？**
   - 建議 **3 秒**
   - 太短（1 秒）→ 太吵，系統負擔
   - 太長（10 秒）→ 回覆感覺遲鈍
   - Peter 有偏好嗎？

8. **Cross-project 支援？**
   - 目前設計假設所有 session 都在同一個 git repo（透過 `tasks/` symlink 共享）
   - 如果 Peter 要讓兩個不同專案的 session 互通，得用絕對路徑而不是相對 `tasks/`
   - 建議：**v0.1 不支援**，99% 情境都是同專案 worktree

---

## 12. v0.1 範圍（最小可用版本）

為了快速 ship，v0.1 只做：

- ✅ Open / leave session（§6.1, §6.3）
- ✅ Registry 讀寫（§3）
- ✅ Inbox 讀寫 with MSG/READ markers（§4）
- ✅ 三種訊息類型（§5）
- ✅ Receiver-side urgency judgment（§7）
- ✅ Monitor 主機制（方案 A, §10）
- ✅ Pre/post long-tool peek（§8 Layer 2/3）
- ✅ 殭屍 session 清理（§6.4）
- ✅ `/session-comms` command + SKILL.md

**不做（留到 v0.2+）：**
- ❌ Broadcast to all（用 `--to` 一個個指定就夠）
- ❌ Scope 衝突主動偵測
- ❌ Cross-project 支援
- ❌ fswatch 優化
- ❌ 已讀狀態 UI（debug 用原始 markdown 就行）

---

## 13. 測試計畫

**手動測試：**

1. **Happy path：** 開兩個 worktree，各自啟動溝通模式，互相發訊息，確認都收到
2. **Urgency：** A 發 URGENT 給 B（B 正在跑長 tool），確認 B 在 tool 結束後優先處理
3. **Scope match：** A 發訊息提到 B 的 scope 關鍵字（未標 URGENT），確認 B 升級為 URGENT
4. **FYI：** A 發 FYI，確認 B 讀了但沒回覆
5. **Leave：** B 離線後，A 發訊息給 B 應該噴錯提醒 B 不在線
6. **殭屍清理：** 手動 `kill -9` 一個 session，另一個開溝通模式時應該自動清理

**自動化測試：** v0.1 不做。file-based 很難寫穩定的自動測試，手動測就夠了。

---

## 14. 成功標準

v0.1 算成功的條件：

- [ ] Peter 同時開兩個 worktree session 時，不再需要手動 copy-paste 訊息
- [ ] 至少一次因為 scope-match urgency 成功避免了 scope 衝突
- [ ] 崩潰後（任一 session 當掉）能自動恢復，不需要手動清 registry
- [ ] 無溝通需求的 session 完全不受影響（不會誤觸發）

---

## 15. Review 重點

Peter 請特別 review 以下決策：

1. §2 — **file-based vs socket/DB** — 選 file-based 對嗎？
2. §6 — **下線改人控** — 這個簡化 OK 嗎？
3. §7 — **三層 urgency 判斷** — Layer 2 的 scope match 邏輯夠不夠聰明？
4. §8 — **Pre/post long-tool peek** — 長 tool 清單完整嗎？有漏嗎？
5. §11 — **開放問題 1-8** — 這些你有偏好嗎？
6. §12 — **v0.1 範圍** — 太大？太小？

---

**Review 後的下一步：**

1. Peter 標記 §15 review items + §11 開放問題的決定
2. Claude 根據 feedback 更新 DESIGN.md
3. 執行 `plugin-dev:create-plugin` 按 DESIGN.md 建出實際 plugin
4. 執行 `plugin-dev:plugin-validator` 驗證結構
5. 加進 `marketplace.json` + `claude plugins install session-comms@peter-claude-plugins`
6. 開兩個 worktree 跑 §13 手動測試
7. CLAUDE.md 加 §9 最後提到的 pointer line
