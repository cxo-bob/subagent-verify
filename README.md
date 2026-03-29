# SubAgent Verify (SAV)

**A persistent task verification gate for AI agent systems.**

SAV ensures that work delegated to sub-agents is actually verified complete before the orchestrating agent reports success to the user. It was built because AI agents lie — not intentionally, but because they lack a reliable mechanism to confirm their own work before declaring it done.

---

## The Problem

Modern AI orchestration systems delegate tasks to sub-agents: specialized agents that handle coding, writing, research, file operations, API calls, and more. These sub-agents return a completion signal when they finish. The problem is that **the completion signal and actual task completion are not the same thing.**

Common silent failures:

- A sub-agent commits to a local git repo but the push fails — work is "done" but never reaches remote
- A file is "written" but lands in the wrong path
- A deployment "succeeds" but the URL is unreachable
- An API call returns 200 but the data wasn't actually saved
- A sub-agent crashes mid-task and the orchestrator never finds out

The orchestrating agent then reports success to the user. The user believes the work is done. It isn't.

### The Compounding Problem

Even if the orchestrating agent has rules like "verify before reporting done," those rules are soft — stored in a text file, enforced only by the agent's discipline in the moment. Any of the following can cause the verification step to be skipped:

- A heartbeat or scheduled task fires mid-verification
- The context window is pruned during a long session
- The server restarts
- A new message arrives and shifts attention
- The sub-agent session itself consumes the context

There is no structural enforcement. "Check your work" written in a config file is not a gate — it's a suggestion.

---

## The Solution

SAV is a **disk-persisted state machine** that wraps every sub-agent task lifecycle. State lives in a JSON file on disk — not in the agent's memory. This means it survives heartbeats, context pruning, server restarts, and session death.

The protocol is simple:

1. **Before the sub-agent runs:** Register the task with a checklist of what "done" actually means
2. **After the sub-agent returns:** Mark it complete (but unverified)
3. **Before reporting success:** Run verification — every check must pass
4. **Only then:** Report success to the user

If verification fails, the agent fixes the work and re-verifies. It cannot skip to "done."

If the system is interrupted at any point, the state file persists on disk. The next heartbeat reads it, sees the unfinished state, and alerts. Blocked tasks auto-retry with exponential backoff. Recovery commands work from any channel — no terminal required.

---

## How It Works

### State Machine

```
pre-spawn
    │
    ▼  register
in-progress             ← sub-agent is running
    │
    ▼  complete
completed-unverified    ← sub-agent returned, checks not yet run
    │
    ├─► verified            ✅ all checks passed → safe to report done
    ├─► failed              ❌ checks failed, retries available → fix + re-verify
    ├─► verify-errored      ⚠️  verify script itself crashed
    ├─► verify-blocked      🔁 external dep unavailable → auto-retry with backoff
    ├─► needs-human-review  🙋 timed out or retries exhausted → human decides
    └─► force-completed     🔑 manual override, reason permanently logged
```

Every state transition is written to disk before proceeding. A backup (`.bak`) is created before every write. If the state file becomes corrupt, recovery restores from the backup automatically.

### Auto-Retry with Exponential Backoff

When a verification check fails due to a network or external dependency issue (GitHub unreachable, URL down, etc.), SAV enters `verify-blocked` and schedules an automatic retry:

```
Attempt 1: wait 60s
Attempt 2: wait 120s
Attempt 3: wait 240s
```

The backoff base and retry maximum are configurable per task. When the window elapses, the heartbeat's `auto-retry` command re-runs verification automatically. After all retries are exhausted, the task escalates to `needs-human-review` and fires a Slack alert.

This means transient failures (GitHub API blip, temporary network issue) resolve themselves without human intervention.

### Push Notifications

SAV fires a Slack alert automatically when any task enters a failure state:

- `failed` — checks failed
- `verify-errored` — the verify script itself crashed
- `verify-blocked` — external dependency unavailable
- `needs-human-review` — timeout or retries exhausted

Each alert includes the task ID, description, failure detail, and copy-paste recovery commands.

Configure with a Slack webhook URL in your agent's environment config.

### Audit Log

Every task writes a persistent log to `memory/sav-logs/<task-id>.log`. View the full history — state transitions, verify results, activity timestamps — with `sv.sh history <task-id>`.

### Check Types

Checks are defined when the task is registered and run automatically during verification:

| Type | What it verifies |
|------|-----------------|
| `file_exists` | A specific file exists on disk |
| `dir_exists` | A directory exists |
| `git_remote` | A git repo has a remote configured |
| `git_pushed` | Local HEAD matches remote branch (push confirmed) |
| `cmd_succeeds` | Any shell command exits with code 0 |
| `url_reachable` | A URL responds with HTTP 200 |

### Heartbeat Integration

On every heartbeat cycle:
1. `sv.sh auto-retry` — silently re-verifies any `verify-blocked` tasks whose backoff window has elapsed
2. `sv.sh list-stuck` — checks for tasks stuck in non-terminal states, alerts if found

### Chat-Based Recovery

Recovery commands work from any messaging surface — Telegram, Slack, WhatsApp, or any channel the orchestrating agent is connected to. No terminal access required.

| Command | Effect |
|---------|--------|
| `--sv status` | Show all task states |
| `--sv list-stuck` | Show only hung tasks |
| `--sv history <id>` | Full audit log for a task |
| `--sv reset <id> <reason>` | Reset to in-progress, reason logged |
| `--sv force-complete <id> <reason>` | Manual override, reason permanently logged |
| `--sv recover` | Restore corrupt state from backup |
| `--sv verify <id>` | Re-run verification |

---

## Quick Start

### 1. Install

```bash
git clone https://github.com/cxo-bob/subagent-verify ~/.openclaw/workspace/skills/subagent-verify
chmod +x ~/.openclaw/workspace/skills/subagent-verify/scripts/sv.sh
echo '{"tasks":{}}' > ~/.openclaw/workspace/memory/subagent-state.json
```

### 2. Configure Slack notifications (optional)

Add to your agent's `openclaw.json` under `env`:
```json
"SLACK_SAV_WEBHOOK": "https://hooks.slack.com/services/YOUR/WEBHOOK/URL",
"SLACK_SAV_CHANNEL": "#your-channel"
```

### 3. Register a task before spawning a sub-agent

```bash
bash skills/subagent-verify/scripts/sv.sh register \
  "book-polish-2026-03-29" \
  "Polish pass across all 14 chapters" \
  '[
    {"type": "git_remote", "value": "/path/to/repo"},
    {"type": "git_pushed", "dir": "/path/to/repo", "branch": "main"},
    {"type": "file_exists", "value": "/path/to/output/ch1-polished.md"}
  ]' \
  3 60
# 3 retries, 60s base backoff
```

### 4. After sub-agent returns

```bash
bash skills/subagent-verify/scripts/sv.sh complete "book-polish-2026-03-29"
```

### 5. Verify before reporting done

```bash
bash skills/subagent-verify/scripts/sv.sh verify "book-polish-2026-03-29"
# ✅ VERIFIED: book-polish-2026-03-29
# Only now report success to the user
```

### 6. Add to HEARTBEAT.md

```markdown
## Step 0 — SubAgent Verify
- Run: `bash skills/subagent-verify/scripts/sv.sh auto-retry`
- Run: `bash skills/subagent-verify/scripts/sv.sh list-stuck`
- Alert on any stuck tasks. Push notifications fire automatically on failures.
```

### 7. Add to AGENTS.md

```markdown
## SubAgent Verify Gate (unbreakable)
Before spawning: register with checks.
After returns: complete → verify.
Do not report done until status is `verified` or `force-completed`.
```

---

## Integration with OpenClaw

SAV is built as an [OpenClaw](https://openclaw.ai) AgentSkill. Place the skill directory under `~/.openclaw/workspace/skills/subagent-verify/` and OpenClaw will load `SKILL.md` automatically.

All files live in user-space (`~/.openclaw/workspace/`) and are never touched by OpenClaw updates.

---

## File Reference

```
subagent-verify/
├── SKILL.md                         # OpenClaw skill definition + full protocol
├── scripts/
│   └── sv.sh                        # The CLI — all state operations
└── references/
    ├── state-machine.md             # Full state diagram, retry logic, recovery paths
    └── check-types.md               # All check types with examples
```

Runtime state files (in your agent's memory directory):
```
memory/
├── subagent-state.json              # Live task state
├── subagent-state.json.bak          # Auto-backup before every write
└── sav-logs/
    └── <task-id>.log                # Per-task audit log
```

---

## Why This Exists

On March 29, 2026, a sub-agent completed a book manuscript polish pass across 14 chapters. It committed the work locally and reported success. The git push had silently failed — the remote had never been configured on a re-initialized local repository.

The work existed on one machine. The remote repo didn't have it. The agent didn't know. The user didn't know until they checked manually hours later.

SAV was built the same morning. With SAV in place, the `git_remote` and `git_pushed` checks would have caught the failure immediately, blocked the "done" report, and fired a Slack alert — before the agent said a word.

---

## Comparison with Existing Frameworks

| | SAV | LangGraph | Temporal | OpenAI Agents SDK |
|--|-----|-----------|----------|-------------------|
| Disk-persisted state | ✅ | ✅ (with config) | ✅ | ❌ in-memory |
| Framework lock-in | ❌ none | ✅ Python/LangChain | ✅ server + SDK | ✅ OpenAI SDK |
| Drop-in to existing setup | ✅ 5 min | ❌ rebuild required | ❌ infrastructure | ❌ rebuild required |
| Chat-based recovery | ✅ any channel | ❌ | ❌ | ❌ |
| Auto-retry with backoff | ✅ | ✅ | ✅ | ❌ |
| Push notifications | ✅ Slack | ✅ (custom) | ✅ (custom) | ❌ |
| Shell-native | ✅ bash/python | ❌ | ❌ | ❌ |
| Per-task audit log | ✅ | ✅ | ✅ | ❌ |

SAV occupies a unique niche: lightweight, connector-agnostic, shell-native, and drop-in to any existing agent setup without framework lock-in.

---

## License

MIT — use freely, attribution appreciated.

---

Built and maintained by [KD Ventures](https://github.com/KD-Ventures).  
OpenClaw: [openclaw.ai](https://openclaw.ai)
