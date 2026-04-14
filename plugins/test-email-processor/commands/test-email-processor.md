---
description: Email processor 自動化測試 — 執行部署驗證、功能測試、回歸測試
allowed-tools: AskUserQuestion, Read, Write, Edit, Glob, Grep, Bash(curl:*), Bash(date:*), Bash(mkdir:*), Bash(jq:*), mcp__claude_ai_Gmail__gmail_search_messages, mcp__claude_ai_Gmail__gmail_read_message, mcp__claude_ai_Gmail__gmail_list_labels, mcp__claude_ai_Gmail__gmail_read_thread, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__get_page_text, mcp__claude-in-chrome__read_page, mcp__claude-in-chrome__javascript_tool, mcp__claude-in-chrome__find, mcp__claude-in-chrome__form_input, mcp__claude-in-chrome__computer, mcp__claude-in-chrome__read_console_messages, mcp__claude-in-chrome__gif_creator
---

# /test-email-processor — Email Processor 自動化測試

對 email processor 執行自動化測試。透過 HTTP trigger (doGet Web App) 觸發 Apps Script 函式，用 Gmail MCP 和 claude-in-chrome 驗證結果。

## 用法

```
/test-email-processor                    # 互動模式：選擇要跑的測試
/test-email-processor v3.2               # 只跑 v3.2 相關測試
/test-email-processor --verify-only      # 只驗證（不執行函式）
/test-email-processor --cleanup          # 清理測試資料
/test-email-processor --reset            # 清理 + 重建環境
/test-email-processor --ping             # 測試 Web App 連線
```

## 流程

執行 skill 時讀取以下參考文件取得詳細指引：

| 用途 | 參考文件 |
|------|----------|
| 完整測試邏輯 | `${CLAUDE_PLUGIN_ROOT}/skills/test-email-processor/SKILL.md` |
| 驗證策略 | `${CLAUDE_PLUGIN_ROOT}/skills/test-email-processor/references/verification.md` |
| 專案 URL | `${CLAUDE_PLUGIN_ROOT}/skills/test-email-processor/references/project-urls.md` |
| 報告模板 | `${CLAUDE_PLUGIN_ROOT}/skills/test-email-processor/templates/report.md` |

## 前置需求

1. Code.gs 已部署 `doGet` Web App（含測試 helper 函式）
2. `project-urls.md` 已填入客戶名稱、Web App URL、Sheet URL、Drive 根資料夾 URL
3. Chrome 已登入使用者的 Google 帳號（claude-in-chrome 驗證用）

## 注意事項

- 🔴 MANUAL 項目（paste Code.gs）會提示你手動操作
- 測試過程中截圖會存到報告中
- 遇到失敗不中斷，記錄後繼續下一項
- 測試結束會詢問是否清理測試資料
