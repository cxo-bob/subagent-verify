---
name: subagent-verify
description: Mandatory subagent lifecycle gate. Use this skill for EVERY subagent spawn — before spawning (register the task), after it returns (mark complete), and before reporting done to Karl (verify). Prevents silent failures where subagents claim success but work is missing, git wasn't pushed, files don't exist, or external calls failed. Also handles recovery when tasks get stuck due to heartbeat interruption, context pruning, server restart, or any other disruption. Features: auto-retry with exponential backoff for network/external failures, push Slack notifications on failure states, full audit log per task, chat-based recovery commands. Trigger on any subagent spawn, any coding task, any git operation delegated to a subagent, or any `--sv` command from Karl.
---

# SubAgent Verify (SAV)

Persistent task state machine. Survives heartbeats, context pruning, server restarts, session death. State lives on disk. Slack alerts fire automatically on failure. Blocked tasks auto-retry with exponential backoff.

## Script

All operations: `skills/subagent-verify/scripts/sv.sh`

## Protocol: Every Subagent Task

### Step 1 — Before spawning
```bash
bash skills/subagent-verify/scripts/sv.sh register "<task-id>" "<description>" '<checks-json>' [retry-max] [retry-backoff-base-seconds]
```
- Default: 3 retries, 60s base backoff (doubles each attempt: 60s → 120s → 240s)
- State → `in-progress`

### Step 2 — After subagent returns
```bash
bash skills/subagent-verify/scripts/sv.sh complete "<task-id>"
```
- State → `completed-unverified`

### Step 3 — Verify (GATE — never skip)
```bash
bash skills/subagent-verify/scripts/sv.sh verify "<task-id>"
```
- All checks pass → `verified` ✅
- Checks fail (retries available) → `failed` ❌ with next retry scheduled
- Network error → `verify-blocked` 🔁 auto-retry after backoff
- **Slack alert fires automatically** on `failed`, `verify-errored`, `verify-blocked`, `needs-human-review`
- **DO NOT report completion to Karl until state is `verified` or `force-completed`**

### Step 4 — Write lesson
After `verified`: append a one-line lesson to `MEMORY.md`.

## Slack Notifications

Configure in `openclaw.json` under `env`:
```json
"SLACK_SAV_WEBHOOK": "https://hooks.slack.com/services/...",
"SLACK_SAV_CHANNEL": "#bobs-office"
```
Alert fires on: `failed`, `verify-errored`, `verify-blocked`, `needs-human-review`  
Each alert includes task ID, description, detail, and recovery command options.

## Auto-Retry (verify-blocked)

When a verify check fails due to a network/external dependency issue:
- State → `verify-blocked`
- Retry scheduled at: `now + backoff_base * 2^(retry_count-1)` seconds
- Heartbeat step 0 runs `sv.sh auto-retry` — triggers re-verify when window elapses
- After `retry_max` exhausted → `failed` + Slack alert

## Audit Log

Every task writes a log to `memory/sav-logs/<task-id>.log`  
View with: `sv.sh history <task-id>` (shows state history + verify results + activity log)

## Heartbeat Integration

Step 0 on every heartbeat:
```bash
bash skills/subagent-verify/scripts/sv.sh auto-retry   # retry due blocked tasks
bash skills/subagent-verify/scripts/sv.sh list-stuck   # check for hung tasks
```

## Karl's Chat Commands (no terminal needed)

| Karl sends | I run |
|-----------|-------|
| `--sv status` | `sv.sh status` |
| `--sv list-stuck` | `sv.sh list-stuck` |
| `--sv history <id>` | `sv.sh history <id>` |
| `--sv reset <id> <reason>` | `sv.sh reset <id> <reason>` |
| `--sv force-complete <id> <reason>` | `sv.sh force-complete <id> <reason>` |
| `--sv recover` | `sv.sh recover` |
| `--sv verify <id>` | `sv.sh verify <id>` |

## State Quick Reference

`in-progress` → `completed-unverified` → `verified` ✅  
`completed-unverified` → `failed` ❌ (re-verify after fix, auto-retry scheduled)  
`completed-unverified` → `verify-blocked` 🔁 (network issue, auto-retries)  
Any → `force-completed` 🔑 (Karl override, reason logged)  
Any → `needs-human-review` 🙋 (timeout >2h)  

Full state machine: `references/state-machine.md`  
Check types: `references/check-types.md`

## File Locations

| Item | Path |
|------|------|
| Skill | `~/.openclaw/workspace/skills/subagent-verify/` |
| Script | `skills/subagent-verify/scripts/sv.sh` |
| State | `memory/subagent-state.json` |
| Backup | `memory/subagent-state.json.bak` |
| Logs | `memory/sav-logs/<task-id>.log` |

All paths under `~/.openclaw/workspace/` — safe from OpenClaw updates.
