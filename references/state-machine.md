# SAV — State Machine Reference

## State Diagram

```
pre-spawn
    │
    ▼  sv.sh register
in-progress             ← sub-agent is running
    │
    ▼  sv.sh complete
completed-unverified    ← sub-agent returned, checks not yet run
    │
    ├─► verified            ✅ all checks passed → safe to report done to Karl
    ├─► failed              ❌ checks failed, retries available → re-verify after fix
    ├─► verify-errored      ⚠️  verify script itself crashed
    ├─► verify-blocked      🔁 external dep unavailable → auto-retry with backoff
    ├─► needs-human-review  🙋 timed out (>2h) or retries exhausted → Karl decides
    └─► force-completed     🔑 Karl manual override, reason permanently logged
```

## State Descriptions

| State | Meaning | Next action |
|-------|---------|-------------|
| `in-progress` | Sub-agent is working | Wait, then `sv.sh complete` |
| `completed-unverified` | Returned, not checked | `sv.sh verify <id>` immediately |
| `verified` | All checks passed ✅ | Tell Karl it's done. Write lesson to MEMORY.md |
| `failed` | Checks failed | Fix work, re-run `sv.sh verify`. Retry scheduled |
| `verify-errored` | Script crashed | Alert Karl. Fix script, re-run verify |
| `verify-blocked` | External dep down | Auto-retry scheduled. Do NOT mark failed |
| `needs-human-review` | Timeout or retries exhausted | Alert Karl. Karl decides next step |
| `force-completed` | Karl override | Reason logged permanently. Treated as closed |

## Auto-Retry (Exponential Backoff)

For `verify-blocked` (network/external failures):
- retry_max: configurable per task (default: 3)
- retry_backoff_base: configurable per task (default: 60s)
- Backoff schedule: `base * 2^(retry_count-1)`
  - Attempt 1: 60s
  - Attempt 2: 120s
  - Attempt 3: 240s
- Heartbeat `auto-retry` command triggers re-verify when window elapses
- After retry_max exhausted → `needs-human-review` + Slack alert

## Slack Push Notifications

Fires automatically on: `failed`, `verify-errored`, `verify-blocked`, `needs-human-review`

Configure:
```json
"SLACK_SAV_WEBHOOK": "https://hooks.slack.com/services/...",
"SLACK_SAV_CHANNEL": "#bobs-office"
```

Each alert includes:
- Task ID and description
- Current status
- Last failure detail
- Recovery commands (copy-paste ready)

## Audit Logs

Each task writes a persistent log: `memory/sav-logs/<task-id>.log`

View with: `sv.sh history <task-id>`  
Includes: full state transition history + last verify check results + timestamped activity log

## Timeout Rules

- Default timeout: 7200 seconds (2 hours)
- Heartbeat checks for tasks stuck beyond timeout
- On timeout: auto-advance to `needs-human-review`, alert Karl

## Recovery Paths

### State file corrupt
```
--sv recover
```
Restores from `.bak` automatically.

### Task stuck, want to retry
```
--sv reset <task-id> "reason"
```
Sets back to `in-progress`, clears retry timer, logs reason.

### Work confirmed good but checks wrong
```
--sv force-complete <task-id> "checks were wrong — git pushed to different branch"
```
Logs reason permanently in history.

### See full history on a task
```
--sv history <task-id>
```
Shows state transitions, last verify results, activity log.

### All recovery works from chat
Karl sends `--sv <command>` via Telegram, Slack, or any connector.  
No terminal access required. I execute and report back.

## File Locations

| File | Path |
|------|------|
| State | `~/.openclaw/workspace/memory/subagent-state.json` |
| Backup | `~/.openclaw/workspace/memory/subagent-state.json.bak` |
| Logs | `~/.openclaw/workspace/memory/sav-logs/<task-id>.log` |
| Script | `~/.openclaw/workspace/skills/subagent-verify/scripts/sv.sh` |
| SKILL.md | `~/.openclaw/workspace/skills/subagent-verify/SKILL.md` |

All paths under `~/.openclaw/workspace/` — never touched by OpenClaw updates.
