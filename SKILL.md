---
name: subagent-verify
description: Mandatory subagent lifecycle gate. Use this skill for EVERY subagent spawn — before spawning (register the task), after it returns (mark complete), and before reporting done to Karl (verify). Prevents silent failures where subagents claim success but work is missing, git wasn't pushed, files don't exist, or external calls failed. Also handles recovery when tasks get stuck due to heartbeat interruption, context pruning, server restart, or any other disruption. Trigger on any subagent spawn, any coding task, any git operation delegated to a subagent, or any `--sv` command from Karl.
---

# SubAgent Verify (SAV)

Persistent task state machine. Survives heartbeats, context pruning, server restarts, and session death. State lives on disk — not in memory.

## Script

All operations go through `skills/subagent-verify/scripts/sv.sh`. Run it from the workspace root.

## Protocol: Every Subagent Task

### Step 1 — Before spawning
```bash
bash skills/subagent-verify/scripts/sv.sh register "<task-id>" "<description>" '<checks-json>'
```
- `task-id`: short slug, e.g. `book-polish-2026-03-29`
- `checks-json`: JSON array of what to verify when done (see references/check-types.md)
- State → `in-progress`

### Step 2 — After subagent returns
```bash
bash skills/subagent-verify/scripts/sv.sh complete "<task-id>"
```
- State → `completed-unverified`

### Step 3 — Verify (GATE — do not skip)
```bash
bash skills/subagent-verify/scripts/sv.sh verify "<task-id>"
```
- Runs all checks. State → `verified` or `failed`
- **DO NOT report completion to Karl until state is `verified` or `force-completed`**

### Step 4 — Write lesson
After `verified`: append a one-line lesson to `MEMORY.md` noting what was done and confirmed. Even if nothing went wrong.

## Heartbeat Integration

On every heartbeat, run:
```bash
bash skills/subagent-verify/scripts/sv.sh list-stuck
```
- Any task stuck in `in-progress`, `completed-unverified`, `verify-errored`, `verify-blocked`, or `needs-human-review` → alert Karl in #bobs-office via Slack
- Include: task ID, description, how long it's been stuck, last known state

## Karl's Chat Commands (no terminal needed)

Karl sends these via Telegram or Slack — I execute the script and report back:

| Karl sends | I run |
|-----------|-------|
| `--sv status` | `sv.sh status` |
| `--sv list-stuck` | `sv.sh list-stuck` |
| `--sv reset <id> <reason>` | `sv.sh reset <id> <reason>` |
| `--sv force-complete <id> <reason>` | `sv.sh force-complete <id> <reason>` |
| `--sv recover` | `sv.sh recover` |
| `--sv verify <id>` | `sv.sh verify <id>` |

## State File Integrity

- Every write auto-backs up to `subagent-state.json.bak` first
- If state file is corrupt: `sv.sh recover` restores from `.bak`
- If `.bak` also missing: initializes clean empty state
- Heartbeat should alert if `.bak` is older than 2 hours (means no recent activity or backup failed)

## States Quick Reference

`in-progress` → `completed-unverified` → `verified` ✅  
`in-progress` → `completed-unverified` → `failed` ❌ (re-verify after fix)  
Any state → `force-completed` 🔑 (Karl override, reason logged)  
Any state → `needs-human-review` 🙋 (timeout >2h)  

Full state machine: see references/state-machine.md  
Check type definitions: see references/check-types.md

## Where Everything Lives

| Item | Path |
|------|------|
| This skill | `~/.openclaw/workspace/skills/subagent-verify/` |
| Script | `skills/subagent-verify/scripts/sv.sh` |
| State file | `memory/subagent-state.json` |
| State backup | `memory/subagent-state.json.bak` |
| State machine doc | `skills/subagent-verify/references/state-machine.md` |
| Check types doc | `skills/subagent-verify/references/check-types.md` |

All paths are under `~/.openclaw/workspace/` — safe from OpenClaw updates.
