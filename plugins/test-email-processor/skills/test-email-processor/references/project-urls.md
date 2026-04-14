# 專案設定

部署後填入以下資訊。這些值會在測試執行時被讀取。

## 客戶資訊

- **CLIENT_NAME**: `ipwinner`
- **CLIENT_DISPLAY**: `IP Winner`

## URLs

- **WEBAPP_URL**: `https://script.google.com/a/macros/ipwinner.com/s/AKfycbygfO2wno9sBmCBuUBc7th6OCuKMhCjHYE2BW44tDu4pk8D5XRn99YdF0dctZZ6KQB5Mg/exec`
  <!-- 格式：https://script.google.com/macros/s/{DEPLOY_ID}/exec -->
- **SHEET_URL**: `https://docs.google.com/spreadsheets/d/1FjwC_mk-B08ecFWVCvqUuC0-USPIfJi3LDtiDcsmlw0/edit`
  <!-- 格式：https://docs.google.com/spreadsheets/d/{SHEET_ID}/edit -->
- **DRIVE_ROOT_URL**: `https://drive.google.com/drive/u/2/folders/1bTEe8cz4lcyTDP8GmrYduXHWoca6labw`
  <!-- 格式：https://drive.google.com/drive/folders/{FOLDER_ID} -->
- **APPS_SCRIPT_URL**: `https://script.google.com/u/2/home/projects/1GwfBySxgEYbi3QrfRf1udpx0NVfawPZmuoRaSG0McuPGxPyA-i-Q3uL2/edit`
  <!-- 格式：https://script.google.com/home/projects/{PROJECT_ID}/edit -->

## 專案路徑

- **PROJECT_ROOT**: `/Users/cubie/Desktop/IPWinner`
  <!-- TODO.md 位於 {PROJECT_ROOT}/email-processor/TODO.md -->

## Drive 資料夾 ID

- **DRIVE_ROOT_FOLDER_ID**: ``
- **DRIVE_SPAM_FOLDER_ID**: ``
  <!-- 未分類/垃圾/ 資料夾 ID -->

## 備註

- WEBAPP_URL 必須是已部署的 Web App URL（不是 Apps Script Editor URL）
- 部署時選「執行身分：我」、「存取權限：只有自己」
- 每次更新 Code.gs 後需要在「管理部署」更新版本號
