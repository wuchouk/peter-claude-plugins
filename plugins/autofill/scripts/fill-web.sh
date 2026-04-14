#!/bin/bash
# fill-web.sh — Web 表單填寫：解密資料 + osascript 注入 Chrome
# 用法: fill-web.sh <mapping.json>
#
# ⚠️ 此腳本的 stdout 只輸出狀態訊息，不輸出任何資料值
# ⚠️ Claude 不可直接讀取此腳本的輸出中的資料值

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AUTOFILL_DIR="$HOME/.claude-autofill"

MAPPING_FILE="${1:-}"

if [[ -z "$MAPPING_FILE" ]]; then
  echo "❌ 請提供映射 JSON 檔案路徑" >&2
  echo "用法: $0 <mapping.json>" >&2
  exit 1
fi

if [[ ! -f "$MAPPING_FILE" ]]; then
  echo "❌ 找不到映射檔: $MAPPING_FILE" >&2
  exit 1
fi

# 解密資料到暫存檔
echo "🔐 解密個人資料..."
TMPFILE=$(bash "$SCRIPT_DIR/encrypt.sh" --decrypt)

# 設定 trap 確保清除暫存
cleanup() {
  if [[ -n "${TMPFILE:-}" && -f "$TMPFILE" ]]; then
    rm -P "$TMPFILE" 2>/dev/null || rm -f "$TMPFILE"
    echo "🗑️  暫存檔已清除"
  fi
}
trap cleanup EXIT INT TERM

echo "✅ 解密成功"

# 用 Python 產生 JS 填表指令
echo "📝 產生填表指令..."
JS_CODE=$(python3 <<'PYEOF'
import json, yaml, sys, os, re
from datetime import datetime

def resolve_key(data, key):
    """解析 dot notation key，支援陣列 [index]"""
    parts = re.split(r'\.|\[(\d+)\]', key)
    parts = [p for p in parts if p is not None and p != '']
    current = data
    for part in parts:
        if part.isdigit():
            idx = int(part)
            if isinstance(current, list) and idx < len(current):
                current = current[idx]
            else:
                return None
        elif isinstance(current, dict) and part in current:
            current = current[part]
        else:
            return None
    return current

def apply_transform(value, transform):
    """套用值轉換"""
    if not transform or not value:
        return value

    value = str(value)

    if transform.startswith("date_format:"):
        fmt = transform.split(":", 1)[1]
        try:
            dt = datetime.strptime(value, "%Y-%m-%d")
            result = fmt
            result = result.replace("YYYY", str(dt.year))
            result = result.replace("YY", str(dt.year)[-2:])
            result = result.replace("MM", f"{dt.month:02d}")
            result = result.replace("DD", f"{dt.day:02d}")
            result = result.replace("month_name", dt.strftime("%B"))
            result = result.replace("month_abbr", dt.strftime("%b"))
            return result
        except ValueError:
            return value

    if transform.startswith("date_part:"):
        part = transform.split(":", 1)[1]
        try:
            dt = datetime.strptime(value, "%Y-%m-%d")
            parts_map = {
                "year": str(dt.year),
                "month": f"{dt.month:02d}",
                "day": f"{dt.day:02d}",
                "month_name": dt.strftime("%B"),
                "month_abbr": dt.strftime("%b"),
            }
            return parts_map.get(part, value)
        except ValueError:
            return value

    if transform.startswith("select_map:"):
        map_str = transform.split(":", 1)[1].strip("{}")
        mapping = {}
        for pair in map_str.split(","):
            k, v = pair.split(":", 1)
            mapping[k.strip()] = v.strip()
        return mapping.get(value, mapping.get("*", value))

    if transform == "uppercase":
        return value.upper()

    if transform == "lowercase":
        return value.lower()

    if transform == "phone_format":
        return re.sub(r'[\s\-\(\)]', '', value)

    if transform == "phone_international":
        match = re.match(r'(\+\d{1,3})(0+)(.*)', value)
        if match:
            return match.group(1) + match.group(3)
        return value

    if transform.startswith("truncate:"):
        n = int(transform.split(":", 1)[1])
        return value[:n]

    return value

# 讀取資料和映射
tmpfile = os.environ.get("TMPFILE", "")
mapping_file = os.environ.get("MAPPING_FILE", "")

with open(tmpfile, "r") as f:
    data = yaml.safe_load(f)

with open(mapping_file, "r") as f:
    mappings = json.load(f)

# 產生 JS 填表程式碼
# ⚠️ 使用者需要在此處實作 React 相容的 value 設定方式
js_lines = []
js_lines.append("(function() {")
js_lines.append("  var filled = 0, errors = [];")

for m in mappings:
    selector = m["selector"]
    transform = m.get("transform", "")

    if "keys" in m:
        values = [resolve_key(data, k) for k in m["keys"]]
        values = [str(v) for v in values if v is not None]
        if not values:
            continue
        value = m.get("join", " ").join(values)
    else:
        value = resolve_key(data, m["key"])
        if value is None:
            continue

    value = apply_transform(value, transform)
    if value is None:
        continue

    # 跳脫 JS 字串
    escaped = str(value).replace("\\", "\\\\").replace("'", "\\'").replace("\n", "\\n")

    js_lines.append(f"  try {{")
    js_lines.append(f"    var el = document.querySelector('{selector}');")
    js_lines.append(f"    if (el) {{")
    js_lines.append(f"      // === USER CODE START: React-compatible value setter ===")
    js_lines.append(f"      // TODO: 使用者請在此實作 React controlled component 的值設定方式")
    js_lines.append(f"      // 預設使用基本的 value + event dispatch")
    js_lines.append(f"      var nativeInputValueSetter = Object.getOwnPropertyDescriptor(")
    js_lines.append(f"        window.HTMLInputElement.prototype, 'value')?.set ||")
    js_lines.append(f"        Object.getOwnPropertyDescriptor(")
    js_lines.append(f"        window.HTMLTextAreaElement.prototype, 'value')?.set;")
    js_lines.append(f"      if (nativeInputValueSetter) {{")
    js_lines.append(f"        nativeInputValueSetter.call(el, '{escaped}');")
    js_lines.append(f"      }} else {{")
    js_lines.append(f"        el.value = '{escaped}';")
    js_lines.append(f"      }}")
    js_lines.append(f"      el.dispatchEvent(new Event('input', {{bubbles: true}}));")
    js_lines.append(f"      el.dispatchEvent(new Event('change', {{bubbles: true}}));")
    js_lines.append(f"      // === USER CODE END ===")
    js_lines.append(f"      filled++;")
    js_lines.append(f"    }} else {{")
    js_lines.append(f"      errors.push('未找到: {selector}');")
    js_lines.append(f"    }}")
    js_lines.append(f"  }} catch(e) {{")
    js_lines.append(f"    errors.push('{selector}: ' + e.message);")
    js_lines.append(f"  }}")

js_lines.append("  var msg = '✅ 填入 ' + filled + ' 個欄位';")
js_lines.append("  if (errors.length > 0) msg += '\\n⚠️ ' + errors.length + ' 個錯誤:\\n' + errors.join('\\n');")
js_lines.append("  msg;")
js_lines.append("})();")

print("\n".join(js_lines))
PYEOF
)

if [[ -z "$JS_CODE" ]]; then
  echo "❌ 產生 JS 失敗" >&2
  exit 1
fi

# 用 osascript 注入 Chrome
echo "🌐 填寫 Chrome 表單..."
RESULT=$(osascript -e "
tell application \"Google Chrome\"
  set activeTab to active tab of front window
  set result to execute activeTab javascript \"$JS_CODE\"
  return result
end tell
" 2>&1) || {
  echo "❌ Chrome 執行失敗，請確認 Chrome 已開啟並有活動分頁" >&2
  exit 1
}

echo "$RESULT"
echo ""
echo "✅ Web 填表完成"
