#!/bin/bash
# encrypt.sh — 加密 YAML 資料檔 → data.enc + 提取 schema-keys.txt
# 加密工具：age (X25519 key-based, 256-bit random key)
# 金鑰保管：macOS Keychain (Touch ID / 系統密碼保護)
#
# 用法:
#   encrypt.sh --init              # 產生金鑰，存入 Keychain
#   encrypt.sh <yaml_file>         # 加密 YAML 檔案
#   encrypt.sh --decrypt           # 解密到暫存檔（僅供 fill 腳本內部使用）

set -euo pipefail

AUTOFILL_DIR="$HOME/.claude-autofill"
DATA_ENC="$AUTOFILL_DIR/data.enc"
SCHEMA_KEYS="$AUTOFILL_DIR/schema-keys.txt"
RECIPIENT_FILE="$AUTOFILL_DIR/recipient.pub"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

KEYCHAIN_SERVICE="claude-autofill"
KEYCHAIN_ACCOUNT="${USER}"

mkdir -p "$AUTOFILL_DIR"
mkdir -p "$AUTOFILL_DIR/mappings"

# 檢查 age 是否安裝
if ! command -v age &>/dev/null; then
  echo "❌ 需要安裝 age 加密工具: brew install age" >&2
  exit 1
fi

# 提取 YAML 的所有 key 路徑
extract_keys() {
  local yaml_file="$1"
  python3 -c "
import yaml, sys

def extract_paths(obj, prefix=''):
    paths = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            path = f'{prefix}.{k}' if prefix else k
            if isinstance(v, (dict, list)):
                paths.extend(extract_paths(v, path))
            else:
                paths.append(path)
    elif isinstance(obj, list):
        for i, item in enumerate(obj):
            if isinstance(item, (dict, list)):
                paths.extend(extract_paths(item, f'{prefix}[]'))
            else:
                paths.append(f'{prefix}[]')
            break  # 只處理第一個元素的結構
    return paths

with open('$yaml_file', 'r') as f:
    data = yaml.safe_load(f)

if data:
    for p in sorted(set(extract_paths(data))):
        print(p)
"
}

# 從 Keychain 取出 identity，寫入暫存檔，回傳路徑
get_identity() {
  local tmpkey
  tmpkey=$(mktemp /tmp/autofill-key-XXXXXXXXXX)
  chmod 600 "$tmpkey"

  local key_data
  key_data=$(security find-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null) || {
    rm -f "$tmpkey"
    echo "❌ Keychain 中找不到金鑰，請先執行 --init" >&2
    exit 1
  }

  echo "$key_data" > "$tmpkey"
  echo "$tmpkey"
}

# 取得 recipient（公鑰）
get_recipient() {
  if [[ -f "$RECIPIENT_FILE" ]]; then
    cat "$RECIPIENT_FILE"
    return
  fi

  # 從 identity 導出
  local id_file
  id_file=$(get_identity)
  local recipient
  recipient=$(age-keygen -y "$id_file" 2>/dev/null)
  rm -f "$id_file"

  echo "$recipient"
}

# 初始化金鑰
init_keys() {
  echo "🔑 產生 age 金鑰對 (X25519, 256-bit)..."

  # 產生金鑰
  local keygen_output
  keygen_output=$(age-keygen 2>&1)

  local identity
  identity=$(echo "$keygen_output" | grep "^AGE-SECRET-KEY-")
  local recipient
  recipient=$(echo "$keygen_output" | grep "^Public key:" | sed 's/Public key: //')

  if [[ -z "$identity" || -z "$recipient" ]]; then
    echo "❌ 金鑰產生失敗" >&2
    exit 1
  fi

  # 儲存公鑰（不含機密，可安全存磁碟）
  echo "$recipient" > "$RECIPIENT_FILE"
  echo "   公鑰: $recipient"
  echo "   已寫入 $RECIPIENT_FILE"

  # 儲存私鑰到 Keychain
  security delete-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" 2>/dev/null || true
  security add-generic-password -a "$KEYCHAIN_ACCOUNT" -s "$KEYCHAIN_SERVICE" -w "$identity"
  echo "   私鑰已存入 macOS Keychain (Touch ID 保護)"

  echo ""
  echo "✅ 金鑰已建立（Keychain 模式）"

  # 寫入 config
  cat > "$AUTOFILL_DIR/config.yaml" <<EOF
key_mode: keychain
encryption: age-x25519
encrypted_file: $DATA_ENC
schema_keys: $SCHEMA_KEYS
recipient: $recipient
created: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
}

# 加密模式
encrypt_file() {
  local yaml_file="$1"

  if [[ ! -f "$yaml_file" ]]; then
    echo "❌ 找不到檔案: $yaml_file" >&2
    exit 1
  fi

  # 驗證 YAML 格式
  python3 -c "import yaml; yaml.safe_load(open('$yaml_file'))" 2>/dev/null || {
    echo "❌ YAML 格式錯誤，請檢查檔案" >&2
    exit 1
  }

  # 如果還沒有金鑰，先初始化
  if [[ ! -f "$RECIPIENT_FILE" ]]; then
    echo "⚠️  尚未建立金鑰，自動初始化..."
    init_keys
    echo ""
  fi

  # 提取 schema keys
  echo "📋 提取欄位結構..."
  extract_keys "$yaml_file" > "$SCHEMA_KEYS"
  echo "   已寫入 $SCHEMA_KEYS ($(wc -l < "$SCHEMA_KEYS" | tr -d ' ') 個欄位)"

  # 加密（用公鑰，不需要密碼）
  echo "🔐 加密中 (age X25519)..."
  local recipient
  recipient=$(cat "$RECIPIENT_FILE")

  age -r "$recipient" -o "$DATA_ENC" "$yaml_file" || {
    echo "❌ 加密失敗" >&2
    exit 1
  }

  echo "✅ 加密完成: $DATA_ENC"

  # 安全刪除原始檔
  echo "🗑️  安全刪除明文檔..."
  rm -P "$yaml_file" 2>/dev/null || rm "$yaml_file"
  echo "✅ 明文檔已刪除"

  echo ""
  echo "📁 檔案結構:"
  echo "   $DATA_ENC (age 加密資料)"
  echo "   $SCHEMA_KEYS (欄位名稱，Claude 可讀)"
  echo "   $AUTOFILL_DIR/config.yaml (設定)"
}

# 解密模式（僅供 fill 腳本內部使用）
_DECRYPT_TMPFILE=""
_DECRYPT_TMPKEY=""

_decrypt_cleanup() {
  [[ -n "$_DECRYPT_TMPFILE" && -f "$_DECRYPT_TMPFILE" ]] && { rm -P "$_DECRYPT_TMPFILE" 2>/dev/null || rm -f "$_DECRYPT_TMPFILE"; }
  [[ -n "$_DECRYPT_TMPKEY" && -f "$_DECRYPT_TMPKEY" ]] && rm -f "$_DECRYPT_TMPKEY"
}

decrypt_to_temp() {
  if [[ ! -f "$DATA_ENC" ]]; then
    echo "❌ 找不到加密檔: $DATA_ENC" >&2
    exit 1
  fi

  # 從 Keychain 取出 identity 到暫存檔
  local id_file
  id_file=$(get_identity)
  _DECRYPT_TMPKEY="$id_file"

  # 建立安全暫存檔
  _DECRYPT_TMPFILE=$(mktemp /tmp/autofill-data-XXXXXXXXXX.yaml)
  chmod 600 "$_DECRYPT_TMPFILE"

  # 設定 trap 確保清除暫存
  trap _decrypt_cleanup EXIT INT TERM

  # 解密
  age -d -i "$id_file" -o "$_DECRYPT_TMPFILE" "$DATA_ENC" 2>/dev/null || {
    _decrypt_cleanup
    echo "❌ 解密失敗，金鑰可能不正確" >&2
    exit 1
  }

  # 立即清除暫存金鑰
  rm -f "$_DECRYPT_TMPKEY"
  _DECRYPT_TMPKEY=""

  # 輸出暫存檔路徑（供 fill 腳本使用）
  # 呼叫端的 fill 腳本負責最終清除此暫存檔
  trap - EXIT
  echo "$_DECRYPT_TMPFILE"
}

# 主邏輯
case "${1:-}" in
  --init)
    init_keys
    ;;
  --decrypt)
    decrypt_to_temp
    ;;
  --help|-h)
    echo "用法:"
    echo "  $0 --init              產生加密金鑰（存入 macOS Keychain）"
    echo "  $0 <yaml_file>         加密 YAML 檔案"
    echo "  $0 --decrypt           解密到暫存檔"
    echo ""
    echo "加密: age (X25519, 256-bit random key)"
    echo "金鑰: macOS Keychain (Touch ID / 系統密碼保護)"
    ;;
  *)
    if [[ -z "${1:-}" ]]; then
      echo "❌ 請提供 YAML 檔案路徑" >&2
      echo "用法: $0 <yaml_file>" >&2
      exit 1
    fi
    encrypt_file "$1"
    ;;
esac
