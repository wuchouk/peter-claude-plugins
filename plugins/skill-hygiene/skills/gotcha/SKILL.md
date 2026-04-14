---
description: >
  記錄 skill 的 gotcha（踩過的坑、注意事項、修正建議）。當使用者發現 skill 行為不符預期、
  產出有誤、或流程有改進空間時觸發。觸發詞：gotcha、踩坑、不對、錯了、skill 問題、
  記個 gotcha、這個 skill 應該、下次記得。
---

# /gotcha — 記錄 Skill Gotcha

## 概覽

Gotcha 是對 skill 的修正記錄。每次踩坑都記下來，讓 skill 隨使用越來越好。
資料存在 `~/.claude/skill-hygiene/gotchas.yaml`，跨專案共享。

## 流程

### Step 1 — 確認目標 skill

如果使用者指定了 skill 名稱 → 直接使用。
否則：

1. 讀取 `~/.claude/skill-hygiene/usage.log` 取得最近使用的 skills（最近 5 個）
2. 列出選單：

   > 哪個 skill 出了問題？
   >
   > 最近使用的：
   > 1. /devlog（10 分鐘前）
   > 2. /capture-test（1 小時前）
   > 3. /idea（昨天）
   >
   > 或直接輸入 skill 名稱。

### Step 2 — 收集問題描述

問：「什麼錯了？」

讓使用者自由描述。從描述中提取：
- **問題**：發生了什麼
- **預期**：應該怎樣
- **影響**：這導致了什麼後果

### Step 3 — 確認修正方式

問：「正確做法是什麼？」

收集使用者的修正建議。

### Step 4 — 分類

自動判斷 gotcha 類別：

| 類別 | 描述 |
|------|------|
| `behavior` | Skill 行為不符預期 |
| `output` | 產出格式或內容有誤 |
| `flow` | 流程順序或邏輯問題 |
| `missing` | 缺少功能或步驟 |
| `trigger` | 觸發條件不對（該觸發沒觸發，或不該觸發卻觸發） |

### Step 5 — 寫入 gotchas.yaml

檢查 `~/.claude/skill-hygiene/gotchas.yaml` 是否存在：
- **不存在** → 建立新檔
- **存在** → 追加

格式：

```yaml
gotchas:
  - id: "{skill}-{date}-{seq}"
    skill: "{skill_name}"
    date: "{YYYY-MM-DD}"
    category: "{behavior|output|flow|missing|trigger}"
    problem: "{問題描述}"
    expected: "{預期行為}"
    fix: "{修正建議}"
    status: "pending"  # pending | applied | wont-fix
```

### Step 6 — 建議注入

問使用者：

> 要我現在把這個 gotcha 加到 {skill_name} 的 SKILL.md 嗎？

**是** → 找到對應的 SKILL.md，在「注意事項」section 追加 gotcha 內容，更新 status 為 `applied`
**否** → 保持 `pending`，下次 `/skill-stats` 會提醒

---

## 注意事項

- **繁體中文**溝通
- gotchas.yaml 是全域檔案，不在任何專案目錄下
- 同一個 skill 的同一個問題不要重複記錄（檢查既有 gotchas）
- 如果使用者描述模糊，追問具體例子
