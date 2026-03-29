# SubAgent Verify — State Machine Reference

## State Diagram

```
pre-spawn
    │
    ▼  sv.sh register
in-progress          ← subagent is running
    │
    ▼  sv.sh complete
completed-unverified ← subagent returned, not yet checked
    │
    ├─► verified          ✅ all checks passed → safe to report done to Karl
    ├─► failed            ❌ checks failed → work is actually missing/broken
    ├─► verify-errored    ⚠️  the verify script itself crashed
    ├─► verify-blocked    🔁 external dep unavailable (GitHub down, etc.) → retry
    ├─► needs-human-review 🙋 timed out (>2h) or ambiguous → Karl decides
    └─► force-completed   🔑 Karl manually closed it with reason logged
```

## State Descriptions

| State | Meaning | Next action |
|-------|---------|-------------|
| `in-progress` | Subagent is working | Wait for return, then `sv.sh complete` |
| `completed-unverified` | Subagent returned | Run `sv.sh verify <id>` immediately |
| `verified` | All checks passed | Safe to tell Karl it's done. Write lesson to MEMORY.md |
| `failed` | Checks failed | Fix the work, re-run `sv.sh verify <id>` |
| `verify-errored` | Script crashed | Alert Karl. Check script error. Fix, then re-run verify |
| `verify-blocked` | External dep down | Retry after backoff. Do NOT mark failed |
| `needs-human-review` | Timed out (>2h) | Alert Karl via Telegram/Slack. Karl decides |
| `force-completed` | Karl override | Reason logged. Treated as closed |

## Timeout Rules

- Default timeout: 7200 seconds (2 hours)
- Heartbeat checks for tasks stuck `in-progress` or `completed-unverified` beyond timeout
- On timeout: auto-advance to `needs-human-review`, alert Karl

## Recovery Paths

### State file corrupt
```bash
sv.sh recover
# Restores from subagent-state.json.bak automatically
```

### Task stuck, want to retry
```bash
sv.sh reset <task-id> "reason"
# Sets back to in-progress, logs reason
```

### Work confirmed good but checks wrong
```bash
sv.sh force-complete <task-id> "checks were wrong — git pushed to different branch"
# Logs reason permanently in history
```

### All of the above from chat (no terminal)
Karl sends any of these to me via Telegram/Slack:
- `--sv status` → I run `sv.sh status` and report back
- `--sv reset <id> <reason>` → I run `sv.sh reset`
- `--sv force-complete <id> <reason>` → I run `sv.sh force-complete`
- `--sv recover` → I run `sv.sh recover`
- `--sv list-stuck` → I list all hung tasks

## File Locations

| File | Path | Purpose |
|------|------|---------|
| State | `~/.openclaw/workspace/memory/subagent-state.json` | Live task states |
| Backup | `~/.openclaw/workspace/memory/subagent-state.json.bak` | Auto-backup before every write |
| Script | `~/.openclaw/workspace/skills/subagent-verify/scripts/sv.sh` | The CLI |
| SKILL.md | `~/.openclaw/workspace/skills/subagent-verify/SKILL.md` | Protocol doc |

## Why User-Space?

All files live under `~/.openclaw/workspace/` — never under `/opt/homebrew/lib/node_modules/openclaw/`.
OpenClaw updates touch only the node_modules path. This skill, its scripts, and all state files
are completely safe from updates.
