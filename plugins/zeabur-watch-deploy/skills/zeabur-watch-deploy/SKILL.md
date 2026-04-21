---
name: zeabur-watch-deploy
description: Poll the latest Zeabur deployment for a service and report success or extract build log error snippets on failure. Use immediately after a git push / /ship to a Zeabur-deployed project (currently email-processor), or when the user asks "部署成功了嗎", "線上活的嗎", "check the deploy", "deploy 完了沒". Replaces the retired zeabur-mcp watch_latest tool.
---

# Zeabur Deploy Watcher

Wraps a bash script (`watch.sh`) that calls Zeabur's GraphQL API directly, reusing `~/.config/zeabur/{token,services.json}`. Zero MCP, zero subprocess lifecycle.

## When to invoke

**Proactive triggers (run without asking):**
- Just pushed to `main` or completed `/ship` on a Zeabur-deployed project
- User says 「部署成功了嗎」「線上活的嗎」「deploy 完了沒」 or English equivalents

**Do NOT run:**
- Changes only touched `apps-script-phase1/` (Phase 1 lives on Apps Script, not Zeabur — see feedback memory)
- No Zeabur service is configured for this project (check `~/.config/zeabur/services.json`)

## Usage

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/zeabur-watch-deploy/watch.sh <service-name>
```

Default service: `email-processor`. Env knobs: `ZEABUR_POLL_INTERVAL` (default 15s), `ZEABUR_MAX_WAIT` (default 1800s).

## Exit codes

| Code | Meaning | What to tell the user |
|------|---------|----------------------|
| 0 | Success | One-line ✅ report with commit SHA |
| 1 | Config error (missing token/services) | Flag the missing file |
| 2 | Deployment failed | ❌ + the error snippets the script printed (don't dump raw log) |
| 3 | Timeout waiting | Still `BUILDING` after 30min — suggest checking Zeabur dashboard |

## Reporting rules

- **Success** → one line: `✅ 部署成功（commit abc1234）`. Nothing else.
- **Failure** → one-line diagnosis + the already-filtered snippets. Don't add raw log.
- **Never** paste the full build log to the user. The script already extracts <20 error lines.

## Other Zeabur operations (delegate to official plugin)

For anything beyond watching the latest deployment, use the **official `zeabur@zeabur` plugin skills**:

| Need | Skill |
|------|-------|
| View runtime/build logs of any deployment | `zeabur-deployment-logs` |
| Restart a stuck service | `zeabur-restart` |
| Redeploy after env var change | `zeabur-update-service` |
| Manage env vars | `zeabur-variables` |
| List services | `zeabur-service-list` |
| Check runtime performance | `zeabur-service-metric` |
| Exec into container (one-off DB queries) | `zeabur-service-exec` |

Full list: 23 skills. This watcher covers **only** the push-then-poll case.

## Adding a new Zeabur service

1. Confirm deployment succeeded once via Zeabur dashboard
2. Add entry to `~/.config/zeabur/services.json`:
   ```json
   {
     "my-service": {
       "projectId": "…",
       "serviceId": "…",
       "environmentId": "…",
       "description": "…"
     }
   }
   ```
3. Test: `watch.sh my-service`
4. Add reminder to the project's `CLAUDE.md` that this skill handles post-push verification.
