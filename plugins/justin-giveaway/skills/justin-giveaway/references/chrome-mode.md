# chrome-devtools 模式操作細節

預設模式。用 Chrome DevTools Protocol（CDP）直接連本地 Chrome（localhost:9222），操控 Peter 已登入的真實 Chrome profile。所有 YouTube/X/Google 都已 cookie 認證。

**優勢：** 純本地連線，`claude -p`（scheduled mode）也能用，不依賴 cloud relay。

## Browser 連線（自動）

chrome-devtools MCP 啟動時自動連接 Chrome 的 DevTools port（9222），不需要手動 discovery 或 switch。

1. **`mcp__chrome-devtools__list_pages`** → 取得所有開啟的 tab（每個 tab 有 `pageId`）
2. **`mcp__chrome-devtools__select_page`** → 選擇要操作的 tab（用 `pageId`）
3. **`mcp__chrome-devtools__new_page`** → 開新 tab

**Interactive mode：** 列出 tabs 給使用者確認要用哪個
**Scheduled mode：** 直接開新 tab 操作，完成後 close

## 元素定位方式（重要！）

chrome-devtools 用 **uid**（從 `take_snapshot` 的 a11y tree 取得）來定位元素，不是 CSS selector。

操作流程：
1. `take_snapshot` → 取得頁面的 a11y tree，每個元素有 `uid`
2. 找到目標元素的 `uid`
3. 用 `click`、`fill`、`type_text` 等工具操作該 `uid`

如果 snapshot 裡找不到需要的元素，用 `evaluate_script` 執行 JS。

## Step 1: 找最新影片

1. 開新 tab：`new_page` url=`https://www.youtube.com/@justin-fu/videos`
2. 等頁面載入：`wait_for` text=["@justin-fu"]（等 channel 名稱出現）
3. `take_snapshot` 抓頁面元素
4. 從 snapshot 找第一個影片的 title 和 link
5. 如果 snapshot 不夠清楚，用 `evaluate_script` 抓更精確的資料：
   ```js
   () => {
     const item = document.querySelector('ytd-rich-item-renderer');
     const link = item?.querySelector('a#video-title-link');
     return {
       title: link?.textContent?.trim(),
       url: link?.href,
       publishedText: item?.querySelector('#metadata-line span:nth-child(2)')?.innerText
     };
   }
   ```

## Step 2: 抓 pinned 留言 + form 連結

1. `navigate_page` type=url url=影片 URL
2. 立刻暫停影片：
   ```js
   () => { document.querySelector('video')?.pause(); }
   ```
3. 滾到留言區：
   ```js
   () => { window.scrollTo(0, 800); }
   ```
4. `wait_for` text=["Comments", "留言", "pinned", "Pinned"]（等留言區載入，timeout 10秒）
5. `take_snapshot` 抓留言區
6. 從 snapshot 或用 `evaluate_script` 找 pinned 留言和 form 連結：
   ```js
   () => {
     const comments = document.querySelectorAll('ytd-comment-thread-renderer');
     for (const c of comments) {
       const pinned = c.querySelector('#pinned-comment-badge, [id*="pinned"]');
       if (pinned || c.querySelector('.ytd-pinned-comment-badge-renderer')) {
         const text = c.innerText || '';
         const formMatch = text.match(/https:\/\/(?:docs\.google\.com\/forms|forms\.gle)\/[^\s\]）]+/);
         return { isPinned: true, text: text.substring(0, 500), formUrl: formMatch?.[0] || null };
       }
     }
     // fallback: 第一條留言可能就是 pinned
     const first = comments[0];
     if (first) {
       const text = first.innerText || '';
       const formMatch = text.match(/https:\/\/(?:docs\.google\.com\/forms|forms\.gle)\/[^\s\]）]+/);
       return { isPinned: false, text: text.substring(0, 500), formUrl: formMatch?.[0] || null };
     }
     return { isPinned: false, text: '', formUrl: null };
   }
   ```

## Step 4: 留言「謝謝J大」

1. `evaluate_script` 點留言框：
   ```js
   () => { document.querySelector('#simplebox-placeholder')?.click(); }
   ```
2. 等 0.5 秒
3. `take_snapshot` 找到留言輸入框的 uid
4. `fill` uid=留言框uid value="謝謝J大"
   - 如果 `fill` 不行（contenteditable 不是標準 input），改用 `evaluate_script`：
   ```js
   () => {
     const box = document.querySelector('ytd-commentbox #contenteditable-root');
     if (box) { box.focus(); box.innerText = '謝謝J大'; box.dispatchEvent(new Event('input', {bubbles: true})); }
   }
   ```
5. `take_snapshot` 找 Comment/留言 按鈕的 uid → `click` uid
6. 等 2 秒
7. **截圖**：`take_screenshot` filePath="/tmp/justin-comment-{timestamp}.png"

## Step 5: X 分享

1. `new_page` url=`https://x.com/intent/post?url={video_url}`
2. `wait_for` text=["Post", "發佈"]（等 post 按鈕出現）
3. `take_snapshot` 找 Post 按鈕的 uid → `click` uid
4. 等 3 秒
5. **截圖**：`take_screenshot` filePath="/tmp/justin-x-share-{timestamp}.png"

## Step 7: Google Form 操作

> ⚠️ **不要用 chrome-devtools 填 Google Form 的 file upload。** Drive picker 是 cross-origin iframe，無法操作。已有 Playwright 腳本 `fill-form.mjs` 專門處理。

chrome-devtools 只負責到 Step 5（留言 + X 分享），之後的 Google Form 由 `fill-form.mjs`（Playwright）接手。

## Cleanup

1. `close_page` 關掉自己這次開的新 tab（用 `list_pages` 找到 pageId）
2. 不關掉使用者原本的 tab
