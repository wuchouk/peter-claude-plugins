# capture-test — 通用測試情境建構工具

引導式的測試情境記錄 plugin，適用於任何專案。

## 功能

- `/capture-test` — 透過引導式訪談記錄測試情境，用驗證積木分解測試需求
- `/capture-test log` — 記錄每次測試的過程和結果
- `/capture-test optimize` — 分析並整併冗餘的測試情境

## 核心概念

### 驗證積木（Primitives）

不問開放式的「你怎麼測」，而是用預定義的驗證積木選單引導。每個專案首次使用時會根據技術棧自動初始化 `tests/primitives.yaml`。

### 專案層資料

所有測試資料存在專案的 `tests/` 目錄下，跟 code 一起版控：

```
{PROJECT_ROOT}/tests/
├── scenarios/              # 個別情境檔
├── test-log.md             # 測試日誌
├── scenario-index.md       # 情境索引
└── primitives.yaml         # 專案特定驗證積木
```

### 三種模式

1. **Record**（預設）— 記錄新的測試情境
2. **Log** — 記錄測試執行結果
3. **Optimize** — 分析並整併既有情境

## 安裝

此 plugin 已包含在 `peter-claude-plugins` marketplace 中。
