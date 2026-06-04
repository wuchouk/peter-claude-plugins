#!/usr/bin/env bash
# compute-staged-hash.sh — 算 staged diff 的 SHA256
# 空 staged 也會輸出穩定的 empty-string hash，不會 error
set -euo pipefail

git diff --cached 2>/dev/null | shasum -a 256 | awk '{print $1}'
