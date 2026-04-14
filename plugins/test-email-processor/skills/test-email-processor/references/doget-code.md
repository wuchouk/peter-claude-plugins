# doGet + 測試 Helper 函式

以下程式碼需要加到 Code.gs 的最後面。部署為 Web App 後，所有函式都可以透過 HTTP 呼叫。

## 重要說明

- `trialRun()` 依賴 `SpreadsheetApp.getUi()` 的 prompt 對話框，Web App 下無法使用
- doGet 直接呼叫底層的 `_processEmailBatch(query, limit, shouldDownload)` 繞過 UI
- `setupAll()` 的 UI alert 有 try/catch 保護，Web App 下會靜默跳過但核心邏輯正常
- `processEmails()` 會 schedule 後續 trigger，測試時建議用 `trialRun` action 更可控

## Sheet 欄位對應（處理紀錄）

```
Col 0: messageId        Col 11: 來源確認狀態
Col 1: 日期             Col 12: 資料夾連結
Col 2: 原始標題         Col 13: 最終收發碼
Col 3: sender           Col 14: 修正後名稱
Col 4: AI收發碼         Col 15: 修正原因
Col 5: AI推斷角色       Col 16: 修正時間
Col 6: 歸檔案號         Col 17: 修正來源
Col 7: 內文案號         Col 18: 重試次數
Col 8: AI語義名         Col 19: Input Tokens
Col 9: AI信心           Col 20: Output Tokens
Col 10: AI案件類別      Col 21: dates_found
                        Col 22: 錯誤備註
```

## Sender 名單欄位

```
Col 0: Email 或 Domain
Col 1: 角色（C/A/G/S）
Col 2: 名稱備註
```

---

## 程式碼（貼到 Code.gs 最後面）

```javascript
// ===================== doGet — HTTP Trigger for Automated Testing =====================

/**
 * Web App 入口：透過 HTTP GET 觸發任何函式
 *
 * 用法：curl -sL "https://script.google.com/macros/s/{DEPLOY_ID}/exec?action=ping"
 *
 * 部署：Apps Script Editor → 部署 → 新增部署 → 網頁應用程式
 *       執行身分：我 / 存取權限：只有自己
 */
function doGet(e) {
  var action = (e && e.parameter && e.parameter.action) || '';
  var params = (e && e.parameter) || {};
  var result;
  var startTime = new Date();
  try {
    switch(action) {
      // === 核心函式 ===
      case 'trialRun':
        // 繞過 UI prompt，直接呼叫底層 _processEmailBatch
        var query = params.query || '';
        var limit = parseInt(params.limit) || 50;
        result = _processEmailBatch(query, limit, true);
        break;
      case 'runFeedback':        result = runFeedback(); break;
      case 'processEmails':
        // 注意：processEmails 會 schedule 後續 trigger
        result = _processEmailBatch(params.query || '', parseInt(params.limit) || 20, true);
        break;
      case 'setupAll':           setupAll(); result = {status: 'success', note: 'setupAll completed'}; break;
      case 'resetAllAILabels':   resetAllAILabels(); result = {status: 'success'}; break;
      case 'setLabelColors':     _setLabelColors(); result = {status: 'success'}; break;
      case 'migrateSenderDropdown': _migrateSenderDropdown(); result = {status: 'success'}; break;
      case 'consolidateLearning': result = consolidateLearning(); break;
      case 'seedGoldenSet':      seedGoldenSetFromExisting(); result = {status: 'success'}; break;
      case 'runEvaluation':      result = runEvaluation(); break;
      case 'updateCorrectionStats': _updateCorrectionStats(); result = {status: 'success'}; break;
      case 'exportPromptDoc':    exportPromptDoc(); result = {status: 'success'}; break;

      // === 測試前置操作（Gmail 標籤） ===
      case 'addLabel':    result = _testAddLabel(params); break;
      case 'removeLabel': result = _testRemoveLabel(params); break;
      case 'swapLabels':  result = _testSwapLabels(params); break;

      // === 測試前置操作（Sheet 資料） ===
      case 'setSenderRole':    result = _testSetSenderRole(params); break;
      case 'setCorrectedName': result = _testSetCorrectedName(params); break;
      case 'setFinalCode':     result = _testSetFinalCode(params); break;
      case 'modifyGoldenSet':  result = _testModifyGoldenSet(params); break;

      // === 測試驗證（讀取狀態） ===
      case 'getSheetData':  result = _testGetSheetData(params); break;
      case 'getDriveFiles': result = _testGetDriveFiles(params); break;
      case 'getLastLog':    result = _testGetLastLog(params); break;

      // === 清理 ===
      case 'cleanup':    result = _testCleanup(); break;
      case 'fullReset':  result = _testFullReset(); break;
      case 'ping':       result = {status: 'ok', timestamp: new Date().toISOString()}; break;
      default: result = {error: 'Unknown action: ' + action};
    }
  } catch(err) {
    result = {error: err.message, stack: err.stack};
  }

  // 統一加入 metadata
  if (typeof result === 'object' && result !== null) {
    result._action = action;
    result._duration_ms = new Date() - startTime;
    if (!result.status) result.status = result.error ? 'error' : 'success';
  }

  return ContentService.createTextOutput(JSON.stringify(result))
    .setMimeType(ContentService.MimeType.JSON);
}


// ===================== Gmail 標籤操作（測試前置） =====================

function _testAddLabel(params) {
  if (!params.messageId || !params.label) return {error: 'Required: messageId, label'};
  var message = GmailApp.getMessageById(params.messageId);
  if (!message) return {error: 'Message not found: ' + params.messageId};
  var thread = message.getThread();
  var label = GmailApp.getUserLabelByName(params.label);
  if (!label) return {error: 'Label not found: ' + params.label};
  label.addToThread(thread);
  return {added: params.label, messageId: params.messageId};
}

function _testRemoveLabel(params) {
  if (!params.messageId || !params.label) return {error: 'Required: messageId, label'};
  var message = GmailApp.getMessageById(params.messageId);
  if (!message) return {error: 'Message not found: ' + params.messageId};
  var thread = message.getThread();
  var label = GmailApp.getUserLabelByName(params.label);
  if (!label) return {error: 'Label not found: ' + params.label};
  label.removeFromThread(thread);
  return {removed: params.label, messageId: params.messageId};
}

function _testSwapLabels(params) {
  if (!params.messageId || !params.remove || !params.add) return {error: 'Required: messageId, remove, add'};
  var message = GmailApp.getMessageById(params.messageId);
  if (!message) return {error: 'Message not found: ' + params.messageId};
  var thread = message.getThread();
  var removeLabel = GmailApp.getUserLabelByName(params.remove);
  var addLabel = GmailApp.getUserLabelByName(params.add);
  if (!removeLabel) return {error: 'Label not found: ' + params.remove};
  if (!addLabel) return {error: 'Label not found: ' + params.add};
  removeLabel.removeFromThread(thread);
  addLabel.addToThread(thread);
  return {removed: params.remove, added: params.add, messageId: params.messageId};
}


// ===================== Sheet 資料操作（測試前置） =====================

function _testSetSenderRole(params) {
  if (!params.email || !params.role) return {error: 'Required: email, role'};
  // 使用現有的 _addSender 函式（已處理新增/更新邏輯）
  _addSender(params.email, params.role, params.note || '(test)');
  return {email: params.email, role: params.role};
}

function _testSetCorrectedName(params) {
  // params: row（1-based）, value
  if (!params.row || !params.value) return {error: 'Required: row, value'};
  var ss = _getSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG.SHEET_NAMES.LOG);
  if (!sheet) return {error: 'Sheet not found: ' + CONFIG.SHEET_NAMES.LOG};
  var row = parseInt(params.row);
  sheet.getRange(row, 15).setValue(params.value);  // Col 15 = 修正後名稱 (1-based)
  return {row: row, col: 15, colName: '修正後名稱', value: params.value};
}

function _testSetFinalCode(params) {
  // params: row（1-based）, value
  if (!params.row || !params.value) return {error: 'Required: row, value'};
  var ss = _getSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG.SHEET_NAMES.LOG);
  if (!sheet) return {error: 'Sheet not found: ' + CONFIG.SHEET_NAMES.LOG};
  var row = parseInt(params.row);
  sheet.getRange(row, 14).setValue(params.value);  // Col 14 = 最終收發碼 (1-based)
  return {row: row, col: 14, colName: '最終收發碼', value: params.value};
}

function _testModifyGoldenSet(params) {
  // params: row（1-based）, col（1-based）, value
  if (!params.row || !params.col || !params.value) return {error: 'Required: row, col, value'};
  var ss = _getSpreadsheet();
  var sheet = ss.getSheetByName(CONFIG.SHEET_NAMES.GOLDEN_SET);
  if (!sheet) return {error: 'Sheet not found: ' + CONFIG.SHEET_NAMES.GOLDEN_SET};
  sheet.getRange(parseInt(params.row), parseInt(params.col)).setValue(params.value);
  return {tab: CONFIG.SHEET_NAMES.GOLDEN_SET, row: params.row, col: params.col, value: params.value};
}


// ===================== 驗證用讀取函式 =====================

function _testGetSheetData(params) {
  if (!params.tab) return {error: 'Required: tab'};
  var ss = _getSpreadsheet();
  var sheet = ss.getSheetByName(params.tab);
  if (!sheet) return {error: 'Sheet not found: ' + params.tab};

  var data;
  if (params.range) {
    data = sheet.getRange(params.range).getValues();
  } else if (params.lastRows) {
    // 讀取最後 N 行（避免讀取整個大表）
    var lastRow = sheet.getLastRow();
    var n = parseInt(params.lastRows);
    var startRow = Math.max(1, lastRow - n + 1);
    data = sheet.getRange(startRow, 1, lastRow - startRow + 1, sheet.getLastColumn()).getValues();
  } else {
    data = sheet.getDataRange().getValues();
  }

  // 如果有搜尋關鍵字，過濾
  if (params.search) {
    var keyword = params.search;
    data = data.filter(function(row) {
      return row.some(function(cell) {
        return String(cell).indexOf(keyword) !== -1;
      });
    });
  }

  return {tab: params.tab, range: params.range || 'all', rowCount: data.length, data: data};
}

function _testGetDriveFiles(params) {
  var folder;
  try {
    if (params.folderId) {
      folder = DriveApp.getFolderById(params.folderId);
    } else if (params.folderPath) {
      // 從專案根資料夾按路徑找
      var parts = params.folderPath.split('/');
      folder = _getProjectFolder();
      for (var i = 0; i < parts.length; i++) {
        if (!parts[i]) continue;  // 跳過空字串
        var subFolders = folder.getFoldersByName(parts[i]);
        if (!subFolders.hasNext()) return {error: 'Folder not found: ' + parts[i], searchedIn: folder.getName()};
        folder = subFolders.next();
      }
    } else {
      // 預設：專案根資料夾
      folder = _getProjectFolder();
    }
  } catch(e) {
    return {error: 'Drive error: ' + e.message};
  }

  var files = folder.getFiles();
  var list = [];
  while (files.hasNext()) {
    var f = files.next();
    list.push({
      name: f.getName(),
      size: f.getSize(),
      mimeType: f.getMimeType(),
      date: f.getDateCreated().toISOString(),
      lastUpdated: f.getLastUpdated().toISOString()
    });
  }

  // 也列出子資料夾
  var subfolders = [];
  var sf = folder.getFolders();
  while (sf.hasNext()) {
    var sub = sf.next();
    subfolders.push({name: sub.getName(), id: sub.getId()});
  }

  return {
    folder: folder.getName(),
    folderId: folder.getId(),
    fileCount: list.length,
    files: list,
    subfolderCount: subfolders.length,
    subfolders: subfolders
  };
}

function _testGetLastLog(params) {
  // 從 PropertiesService 讀取儲存的 log
  var props = PropertiesService.getScriptProperties();
  var savedLog = props.getProperty('_testLastLog');

  if (!savedLog) {
    return {
      status: 'no_log',
      note: 'No saved log. Core functions need _testSaveLog() calls.',
      hint: 'Add _testSaveLog(logMessages) at end of core functions, or check Apps Script Execution Log manually.'
    };
  }

  var logData;
  try {
    logData = JSON.parse(savedLog);
  } catch(e) {
    return {status: 'parse_error', raw: savedLog};
  }

  // 如果有搜尋關鍵字，過濾
  if (params.search) {
    var filtered = logData.messages.filter(function(line) {
      return line.indexOf(params.search) !== -1;
    });
    return {search: params.search, matchCount: filtered.length, matches: filtered, totalLines: logData.messages.length, savedAt: logData.savedAt};
  }

  return logData;
}

/**
 * 核心函式呼叫此函式儲存 log（給 getLastLog 用）
 * 用法：在 _processEmailBatch / runFeedback 結尾加上
 *   _testSaveLog(['訊息1', '訊息2', ...]);
 */
function _testSaveLog(messages) {
  var props = PropertiesService.getScriptProperties();
  props.setProperty('_testLastLog', JSON.stringify({
    savedAt: new Date().toISOString(),
    messages: messages
  }));
}


// ===================== 清理函式 =====================

function _testCleanup() {
  var log = [];

  // 1. 清 Drive 測試資料（未分類資料夾內的檔案和子資料夾）
  try {
    var rootFolder = _getProjectFolder();
    var unclassified = null;
    var iter = rootFolder.getFoldersByName('未分類');
    if (iter.hasNext()) unclassified = iter.next();

    if (unclassified) {
      // 清「未分類/垃圾」內的檔案
      var spamFolder = null;
      var spamIter = unclassified.getFoldersByName('垃圾');
      if (spamIter.hasNext()) spamFolder = spamIter.next();
      if (spamFolder) {
        var spamFiles = spamFolder.getFiles();
        var count = 0;
        while (spamFiles.hasNext()) { spamFiles.next().setTrashed(true); count++; }
        log.push('Drive: trashed ' + count + ' files in 未分類/垃圾');
      }

      // 清「未分類」直接的檔案
      var uncFiles = unclassified.getFiles();
      var uncCount = 0;
      while (uncFiles.hasNext()) { uncFiles.next().setTrashed(true); uncCount++; }
      if (uncCount > 0) log.push('Drive: trashed ' + uncCount + ' files in 未分類');
    }
  } catch(e) {
    log.push('Drive cleanup error: ' + e.message);
  }

  // 2. 清 Sheet 處理紀錄 rows（保留標題行）
  try {
    var ss = _getSpreadsheet();
    var recordSheet = ss.getSheetByName(CONFIG.SHEET_NAMES.LOG);
    if (recordSheet && recordSheet.getLastRow() > 1) {
      var rowCount = recordSheet.getLastRow() - 1;
      recordSheet.deleteRows(2, rowCount);
      log.push('Sheet: cleared ' + rowCount + ' rows from ' + CONFIG.SHEET_NAMES.LOG);
    }
  } catch(e) {
    log.push('Sheet cleanup error: ' + e.message);
  }

  // 3. 移除所有 Gmail AI/* 標籤（從信件上移除，不刪標籤本身）
  try {
    var labels = GmailApp.getUserLabels().filter(function(l) {
      return l.getName().startsWith(CONFIG.LABEL_PREFIX + '/');
    });
    labels.forEach(function(label) {
      var threads = label.getThreads(0, 100);
      if (threads.length > 0) {
        label.removeFromThreads(threads);
      }
      log.push('Gmail: removed ' + label.getName() + ' from ' + threads.length + ' threads');
    });
  } catch(e) {
    log.push('Gmail cleanup error: ' + e.message);
  }

  // 4. 清除 log cache
  try {
    PropertiesService.getScriptProperties().deleteProperty('_testLastLog');
    log.push('Props: cleared _testLastLog');
  } catch(e) {
    log.push('Props cleanup error: ' + e.message);
  }

  return {status: 'cleaned', steps: log};
}

function _testFullReset() {
  var cleanResult = _testCleanup();
  setupAll();  // 重建 Sheet tabs + Drive 資料夾 + 標籤
  return {status: 'reset complete', cleanup: cleanResult};
}
```

## 部署步驟（只做一次）

1. 把以上 `// ===================== doGet` 開始到檔案結尾的程式碼，貼到 Code.gs 最後面
2. Apps Script Editor → 部署 → 新增部署
3. 類型：「網頁應用程式」
4. 執行身分：「我」
5. 存取權限：「只有自己」
6. 點部署 → 複製 URL
7. 把 URL 填入 `project-urls.md` 的 `WEBAPP_URL`

## 更新步驟（每次改 Code.gs 後）

1. Apps Script Editor → 部署 → 管理部署
2. 點鉛筆圖示 → 版本下拉選「新版本」
3. 點「部署」

## 可選：在核心函式加入 log capture

要讓 `getLastLog` 能用，在核心函式結尾加一行：

```javascript
// 在 _processEmailBatch 的 return stats 之前加入：
_testSaveLog(Logger.getLog().split('\n').filter(Boolean));

// 在 runFeedback 的 return 之前加入：
_testSaveLog(Logger.getLog().split('\n').filter(Boolean));
```

這樣 `curl ?action=getLastLog&search=碼改名` 就能搜尋 log 內容。
