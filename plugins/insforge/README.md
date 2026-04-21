# insforge — InsForge development skills

Bundled skills for working with InsForge projects.

## Skills

| Skill | Purpose |
|-------|---------|
| `insforge` | Frontend SDK (`@insforge/sdk`) — database queries, auth, storage, real-time, AI features |
| `insforge-cli` | Backend infrastructure via CLI — tables, migrations, edge functions, storage buckets, secrets, cron, logs |
| `insforge-debug` | Troubleshooting — SDK errors, HTTP 4xx/5xx, performance, unexpected behavior |
| `insforge-integrations` | Third-party provider integration — auth (Clerk, Auth0, WorkOS, Kinde, Stytch) and payment facilitators (OKX x402) |

## Installation

Installed via `~/peter-claude-plugins/.claude-plugin/marketplace.json`:

```bash
claude plugins install insforge@peter-claude-plugins
```

## Per-project enablement

This plugin defaults to **disabled** at the user level (`~/.claude/settings.json`). Projects that use InsForge enable it explicitly in their `<project>/.claude/settings.json`:

```json
{
  "enabledPlugins": {
    "insforge@peter-claude-plugins": true
  }
}
```

This keeps the 4 skill descriptions out of context for projects that don't use InsForge.
