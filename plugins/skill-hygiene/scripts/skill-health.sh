#!/usr/bin/env bash
# /skill-health — audit all skill + plugin installs for silent failures
#
# Checks:
#   1. Global skills (~/.claude/skills/*/SKILL.md) — SKILL.md is regular file, has frontmatter
#   2. Peter's plugins (~/peter-claude-plugins/plugins/*) — plugin.json valid, each skill SKILL.md is real file with frontmatter
#   3. Plugin cache drift — cached copy matches source (byte-for-byte check on SKILL.md files)
#   4. Enabled vs installed — every enabledPlugins entry in ~/.claude/settings.json has a corresponding cache dir

set -uo pipefail

RED='\033[0;31m'
YELLOW='\033[0;33m'
GREEN='\033[0;32m'
DIM='\033[2m'
NC='\033[0m'

issues=0
checked=0

report_ok()  { echo -e "${GREEN}✅${NC} $*"; }
report_warn(){ echo -e "${YELLOW}⚠${NC}  $*"; issues=$((issues+1)); }
report_err() { echo -e "${RED}❌${NC} $*"; issues=$((issues+1)); }

check_skill_md() {
  # args: path to SKILL.md, context label
  local path="$1" label="$2"
  checked=$((checked+1))
  if [ ! -e "$path" ]; then
    report_err "$label — SKILL.md missing: $path"
    return
  fi
  if [ -L "$path" ] && [ ! -f "$path" ]; then
    report_err "$label — SKILL.md is broken symlink: $path -> $(readlink "$path")"
    return
  fi
  if [ ! -s "$path" ]; then
    report_err "$label — SKILL.md exists but is empty: $path"
    return
  fi
  # Check frontmatter: extract YAML block between first `---` pair, require `description:`
  # (name: is often omitted and inferred from directory name — don't report it)
  local missing
  missing=$(python3 - "$path" <<'PY' 2>/dev/null
import sys, re
path = sys.argv[1]
content = open(path, encoding='utf-8', errors='replace').read()
m = re.match(r'^---\s*\n(.*?)\n---\s*\n', content, re.DOTALL)
if not m:
    print("NO_FRONTMATTER")
    sys.exit()
fm = m.group(1)
if not re.search(r'^description\s*:', fm, re.MULTILINE):
    print("NO_DESCRIPTION")
PY
)
  case "$missing" in
    NO_FRONTMATTER) report_warn "$label — no YAML frontmatter (--- ... ---) at top" ;;
    NO_DESCRIPTION) report_warn "$label — frontmatter missing 'description:' field" ;;
  esac
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Global skills  ~/.claude/skills/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for skill_dir in "$HOME/.claude/skills"/*/; do
  [ -d "$skill_dir" ] || continue
  name=$(basename "$skill_dir")
  # Skip bundled system dirs
  case "$name" in
    anthropic-skills|.DS_Store) continue;;
  esac
  check_skill_md "$skill_dir/SKILL.md" "global:$name"
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Peter's plugins  ~/peter-claude-plugins/plugins/"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
PLUGIN_ROOT="$HOME/peter-claude-plugins/plugins"
CACHE_ROOT="$HOME/.claude/plugins/cache/peter-claude-plugins"

for plugin_dir in "$PLUGIN_ROOT"/*/; do
  [ -d "$plugin_dir" ] || continue
  plugin=$(basename "$plugin_dir")

  # Check plugin.json
  pj="$plugin_dir.claude-plugin/plugin.json"
  if [ ! -f "$pj" ]; then
    report_err "plugin:$plugin — .claude-plugin/plugin.json missing"
    continue
  fi
  if ! python3 -c "import json,sys; json.load(open('$pj'))" 2>/dev/null; then
    report_err "plugin:$plugin — .claude-plugin/plugin.json is not valid JSON"
    continue
  fi
  version=$(python3 -c "import json; print(json.load(open('$pj')).get('version','?'))" 2>/dev/null || echo "?")

  # Check each skill
  if [ -d "$plugin_dir/skills" ]; then
    for skill_dir in "$plugin_dir/skills"/*/; do
      [ -d "$skill_dir" ] || continue
      skill_name=$(basename "$skill_dir")
      check_skill_md "$skill_dir/SKILL.md" "plugin:$plugin/$skill_name"

      # Check cache drift
      cache_path="$CACHE_ROOT/$plugin/$version/skills/$skill_name/SKILL.md"
      src_path="$skill_dir/SKILL.md"
      if [ -f "$src_path" ] && [ -f "$cache_path" ]; then
        if ! cmp -s "$src_path" "$cache_path"; then
          report_warn "plugin:$plugin/$skill_name — source vs cache drift, run: claude plugins install $plugin@peter-claude-plugins"
        fi
      elif [ -f "$src_path" ] && [ ! -e "$cache_path" ]; then
        report_warn "plugin:$plugin/$skill_name — cache missing at v$version, run: claude plugins install $plugin@peter-claude-plugins"
      fi
    done
  fi
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Enabled vs installed  (~/.claude/settings.json)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
enabled_plugins=$(python3 -c "
import json
try:
    data = json.load(open('$HOME/.claude/settings.json'))
    for key, val in data.get('enabledPlugins', {}).items():
        print(f'{key}\\t{val}')
except Exception as e:
    pass
" 2>/dev/null)

while IFS=$'\t' read -r plugin_id enabled; do
  [ -z "$plugin_id" ] && continue
  plugin_name="${plugin_id%@*}"
  marketplace="${plugin_id#*@}"
  cache_dir="$HOME/.claude/plugins/cache/$marketplace/$plugin_name"
  if [ "$enabled" = "True" ] || [ "$enabled" = "true" ]; then
    if [ ! -d "$cache_dir" ]; then
      report_err "enabled:$plugin_id — no cache dir at $cache_dir, run: claude plugins install $plugin_id"
    fi
  fi
done <<<"$enabled_plugins"

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$issues" -eq 0 ]; then
  report_ok "No issues found. Checked $checked SKILL.md files."
else
  echo -e "${RED}${issues} issue(s) found.${NC} Checked $checked SKILL.md files."
  echo -e "${DIM}Run suggested fix commands above, then re-run /skill-health to verify.${NC}"
  exit 2
fi
