#!/bin/bash
# keychain-helper.sh — macOS Keychain 存取 autofill 金鑰（age identity）
# 用法:
#   keychain-helper.sh store <identity>   # 儲存 age identity 到 Keychain
#   keychain-helper.sh get                # 從 Keychain 取得 identity
#   keychain-helper.sh delete             # 從 Keychain 刪除 identity
#   keychain-helper.sh exists             # 檢查 identity 是否存在

set -euo pipefail

SERVICE_NAME="claude-autofill"
ACCOUNT_NAME="${USER}"

case "${1:-}" in
  store)
    IDENTITY="${2:-}"
    if [[ -z "$IDENTITY" ]]; then
      echo "❌ 請提供 age identity (AGE-SECRET-KEY-...)" >&2
      exit 1
    fi

    # 刪除舊金鑰（如果存在）
    security delete-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" 2>/dev/null || true

    # 儲存新金鑰
    security add-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" -w "$IDENTITY"
    echo "✅ 金鑰已儲存到 macOS Keychain"
    ;;

  get)
    IDENTITY=$(security find-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" -w 2>/dev/null) || {
      echo "❌ Keychain 中找不到金鑰，請先執行 --init --keychain" >&2
      exit 1
    }
    echo "$IDENTITY"
    ;;

  delete)
    security delete-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" 2>/dev/null && \
      echo "✅ 金鑰已從 Keychain 刪除" || \
      echo "⚠️  Keychain 中沒有找到金鑰"
    ;;

  exists)
    if security find-generic-password -a "$ACCOUNT_NAME" -s "$SERVICE_NAME" >/dev/null 2>&1; then
      echo "yes"
    else
      echo "no"
    fi
    ;;

  *)
    echo "用法: $0 {store <identity>|get|delete|exists}" >&2
    exit 1
    ;;
esac
