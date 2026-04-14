# session-comms

多 session 溝通協議 — 讓平行開發的 Claude Code sessions 透過 file-based inbox 非同步交換訊息。

## 使用情境

你同時開多個 Claude Code session 在不同 git worktree 裡平行開發，需要協調 scope、確認型別、通知 breaking change，但又不想 ESC 打斷對方或手動 copy-paste。

## 快速開始

在每個 session 說：

```
開啟溝通模式
```

Claude 會問你 session 名稱 + work scope，自動建立 `tasks/.comms/` 底下的 registry 和 inbox。之後就可以：

- **發訊息給另一個 session**：「幫我問 api-endpoints，他的 Email type 長怎樣」
- **下線前留訊息**：「跟大家說我要下線了，archive UI 完工」
- **查看在線 session**：「現在有哪些 session 在線？」

## 三種訊息類型

| Type | 用途 | Receiver 行為 |
|------|------|--------------|
| `default` | 一般問答 | 做完手邊邏輯區塊再讀 |
| `URGENT` | Scope 衝突、breaking change | 盡快暫停當前 tool call，優先處理 |
| `FYI` | 純知會 | 讀了就好，不回覆 |

**Receiver 端會自動升級 urgency**：如果訊息內容提到你正在改的檔案/函式/feature（從 registry 的 scope 欄位判斷），即使 sender 沒標 URGENT，receiver 也會升級處理。

## 檔案結構

```
<project-root>/tasks/.comms/          ← 自動建立，已加入 .gitignore
├── registry.md                       ← 所有在線 session 的註冊表
├── <session-name>.inbox.md           ← 每個 session 一個信箱
└── archive/                          ← 離線 session 的 inbox 留底（保留 7 天）
```

## 安裝

```bash
claude plugins install session-comms@peter-claude-plugins
```

## 下線

下線由你人為控制（跟 worktree 生命週期綁定）：

```
我要下線了
```

Claude 會：
1. 從 registry 刪除自己
2. 把 inbox 搬到 `archive/`
3. 停止 Monitor

## 完整設計

詳見 `DESIGN.md` — 包含架構決策、三層投遞機制、三層 urgency 判斷、開放問題等。

## 已知限制（v0.1）

- 只支援同 git repo 內的 session（跨 project 不支援）
- 廣播用 `--to name1,name2` 多目標，沒有 `--broadcast` 全部
- Scope 衝突不會主動偵測（reader 讀到訊息時才算）
- 需要 `tasks/` 目錄存在（或會自動建立）

## 授權

Personal use by Peter Kuo.
