# Playwright 模式操作細節

Scheduled 和 headless 模式使用。Playwright 自己開一個 Chromium，用 storageState JSON 載入 Google + X 的 cookies。完全不依賴真實 Chrome，不需要人在場。

## 前置：bootstrap auth（登入 Google + X，存 cookies）

首次使用或 cookies 過期時跑（約每半年一次）：

```bash
cd ~/Projects/justin-giveaway/scripts && node bootstrap-auth.mjs
```

它會：
1. 開 headed Chromium
2. 引導你登入 Google（ororov888@gmail.com）
3. 引導你登入 X（@diamondhanddie）
4. 兩個都完成後自動存 cookies 到 `~/.claude/justin-storage-state.json`

> ⚠️ Playwright 的 Chromium 不支援 Passkey。登入時選「用密碼登入」或手機驗證碼。

## Browser launch（每次執行時）

```js
const browser = await chromium.launch({
  headless: true,  // scheduled mode 用 headless
  args: ['--disable-blink-features=AutomationControlled'],
});

const context = await browser.newContext({
  storageState: '~/.claude/justin-storage-state.json',
  viewport: { width: 1440, height: 900 },
});
```

## 截圖存放位置

所有截圖存在 `~/Library/Logs/justin-giveaway/screenshots/`，不存 `/tmp/`。
每次新 run 開始前，清掉上週的截圖：

```bash
rm -f ~/Library/Logs/justin-giveaway/screenshots/*.png
mkdir -p ~/Library/Logs/justin-giveaway/screenshots
```

Peter 可在 Telegram 要求查看截圖，直到下週 run 才會被清掉。

## Step 1: 找最新影片

```js
const page = await context.newPage();
await page.goto('https://www.youtube.com/@justin-fu/videos', { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(3000);

const latest = await page.evaluate(() => {
  const item = document.querySelector('ytd-rich-item-renderer');
  const link = item?.querySelector('a#video-title-link');
  return {
    title: link?.textContent?.trim(),
    url: link?.href,
    videoId: link?.href?.match(/[?&]v=([^&]+)/)?.[1],
    publishedText: item?.querySelector('#metadata-line span:nth-child(2)')?.innerText
  };
});
```

## Step 2: pinned 留言 + form 連結

```js
await page.goto(latest.url, { waitUntil: 'domcontentloaded' });
await page.waitForTimeout(2000);

// 暫停影片（避免廣告和聲音）
await page.evaluate(() => document.querySelector('video')?.pause());

// 滾到留言區
await page.evaluate(() => window.scrollTo(0, 800));
await page.waitForTimeout(3000);

// 找 pinned 留言和 form 連結
const pinned = await page.evaluate(() => {
  const comments = document.querySelectorAll('ytd-comment-thread-renderer');
  for (const c of comments) {
    const badge = c.querySelector('#pinned-comment-badge, [id*="pinned"]');
    if (badge || c.querySelector('.ytd-pinned-comment-badge-renderer')) {
      const text = c.innerText || '';
      const formMatch = text.match(/https:\/\/(?:docs\.google\.com\/forms|forms\.gle)\/[^\s\]）]+/);
      return { isPinned: true, text: text.substring(0, 500), formUrl: formMatch?.[0] || null };
    }
  }
  // fallback: 第一條留言
  const first = comments[0];
  if (first) {
    const text = first.innerText || '';
    const formMatch = text.match(/https:\/\/(?:docs\.google\.com\/forms|forms\.gle)\/[^\s\]）]+/);
    return { isPinned: false, text: text.substring(0, 500), formUrl: formMatch?.[0] || null };
  }
  return { isPinned: false, text: '', formUrl: null };
});
```

## Step 4: 留言「謝謝J大」

```js
// 點留言框
await page.evaluate(() => document.querySelector('#simplebox-placeholder')?.click());
await page.waitForTimeout(500);

// 填入留言（contenteditable div，不是標準 input）
await page.evaluate(() => {
  const box = document.querySelector('ytd-commentbox #contenteditable-root');
  if (box) {
    box.focus();
    box.innerText = '謝謝J大';
    box.dispatchEvent(new Event('input', { bubbles: true }));
  }
});
await page.waitForTimeout(500);

// 點 Comment 按鈕
await page.evaluate(() => {
  const btn = document.querySelector('#submit-button button, #submit-button tp-yt-paper-button');
  btn?.click();
});
await page.waitForTimeout(3000);
```

**截圖（含置頂留言 + 自己的留言）：**

留完言後，自己的留言會出現在置頂留言下方（第二條）。截圖要同時包含這兩條：

```js
// 滾到留言區頂部，讓 pinned comment + 我的留言都在畫面中
await page.evaluate(() => {
  const commentsSection = document.querySelector('#comments');
  if (commentsSection) commentsSection.scrollIntoView({ block: 'start' });
});
await page.waitForTimeout(1000);

// 截 viewport（包含置頂 + 自己的留言）
await page.screenshot({
  path: `${screenshotDir}/comment-${dateStr}.png`,
  clip: { x: 0, y: 0, width: 1440, height: 900 }  // 整個 viewport
});
```

如果畫面裡看不到自己的留言（被其他留言推下去），適度向下滾一點讓兩條都可見再截。

## Step 5: X 分享

```js
const xPage = await context.newPage();
await xPage.goto(`https://x.com/intent/post?url=${encodeURIComponent(latest.url)}`, {
  waitUntil: 'domcontentloaded'
});
await xPage.waitForTimeout(3000);

// 點 Post
await xPage.locator('[data-testid="tweetButton"]').click();
await xPage.waitForTimeout(3000);

// 截圖：截 tweet 元素
await xPage.screenshot({ path: `${screenshotDir}/x-share-${dateStr}.png` });
```

> X 的 `[data-testid="tweetButton"]` selector 偶爾會改版。如果找不到，用 snapshot 找 Post/發佈 按鈕。

## Step 6: Google Form

**所有 mode 統一用 `fill-form.mjs`** 帶 `--submit` 一次到位（fill + upload + submit，無 pre-submit 確認）：

```bash
cd ~/Projects/justin-giveaway/scripts && node fill-form.mjs \
  --form-url "{form_url}" \
  --tv-name "sku772003" \
  --comment-screenshot "~/Library/Logs/justin-giveaway/screenshots/comment-*.png" \
  --share-screenshot "~/Library/Logs/justin-giveaway/screenshots/x-share-*.png" \
  --submit \
  --headless
```

## Cleanup

```js
await context.close();
await browser.close();
```

## 已知坑

1. **Google bot detection**：Playwright 的 Chromium 有 `navigator.webdriver=true`，Google 偶爾擋登入。用 `--disable-blink-features=AutomationControlled` 緩解。已有 cookies 的 session 通常沒事
2. **X 改版**：`[data-testid="tweetButton"]` selector 偶爾會變
3. **YouTube 留言後畫面沒更新**：等 3-5 秒再 scroll 回留言區頂部再截圖
4. **YouTube 廣告**：不影響。暫停影片後直接滾到留言區，廣告在播放器裡不擋留言
5. **Passkey 不支援**：bootstrap 時選密碼登入或手機驗證碼
