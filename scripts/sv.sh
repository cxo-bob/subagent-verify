#!/usr/bin/env bash
# sv.sh — SubAgent Verify (SAV) CLI
# State:  ~/.openclaw/workspace/memory/subagent-state.json
# Backup: ~/.openclaw/workspace/memory/subagent-state.json.bak
#
# Usage:
#   sv.sh register <task-id> <description> <checks-json>
#   sv.sh complete <task-id>
#   sv.sh verify <task-id>
#   sv.sh status [task-id]
#   sv.sh reset <task-id> <reason>
#   sv.sh force-complete <task-id> <reason>
#   sv.sh recover
#   sv.sh list-stuck

set -euo pipefail

STATE_FILE="$HOME/.openclaw/workspace/memory/subagent-state.json"
BAK_FILE="${STATE_FILE}.bak"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }

backup_state() {
  [[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "$BAK_FILE"
}

init_state_if_missing() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"tasks":{}}' > "$STATE_FILE"
  fi
}

check_state_health() {
  python3 - "$STATE_FILE" << 'PYEOF'
import sys, json
try:
    json.load(open(sys.argv[1]))
    print("OK")
except Exception as e:
    print(f"CORRUPT:{e}")
PYEOF
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_register() {
  local task_id="$1" description="$2" checks_json="$3"
  init_state_if_missing
  local health; health=$(check_state_health)
  [[ "$health" != "OK" ]] && { echo "ERROR: state file corrupt — run: sv.sh recover"; exit 1; }

  local now; now=$(ts)
  backup_state
  python3 - "$STATE_FILE" "$task_id" "$description" "$now" << PYEOF
import sys, json
state_file, task_id, description, now = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
checks = $checks_json
data = json.load(open(state_file))
data.setdefault('tasks', {})[task_id] = {
    'id': task_id,
    'description': description,
    'status': 'in-progress',
    'checks': checks,
    'started': now,
    'updated': now,
    'timeout_after': 7200,
    'history': [{'status': 'in-progress', 'at': now, 'note': 'registered'}]
}
json.dump(data, open(state_file, 'w'), indent=2)
print(f"REGISTERED: {task_id} [in-progress]")
PYEOF
}

cmd_complete() {
  local task_id="$1"
  init_state_if_missing
  local now; now=$(ts)
  backup_state
  python3 - "$STATE_FILE" "$task_id" "$now" << 'PYEOF'
import sys, json
state_file, task_id, now = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(state_file))
t = data.get('tasks', {}).get(task_id)
if not t:
    print(f"ERROR: task {task_id} not found"); sys.exit(1)
t['status'] = 'completed-unverified'
t['updated'] = now
t['history'].append({'status': 'completed-unverified', 'at': now, 'note': 'subagent returned'})
json.dump(data, open(state_file, 'w'), indent=2)
print(f"COMPLETE: {task_id} [completed-unverified] — run: sv.sh verify {task_id}")
PYEOF
}

cmd_verify() {
  local task_id="$1"
  init_state_if_missing
  local now; now=$(ts)

  # Run all checks via Python — no bash/JSON quoting issues
  python3 - "$STATE_FILE" "$task_id" "$now" << 'PYEOF'
import sys, json, subprocess, os
from pathlib import Path

state_file, task_id, now = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(state_file))
t = data.get('tasks', {}).get(task_id)
if not t:
    print(f"ERROR: task {task_id} not found"); sys.exit(1)

checks = t.get('checks', [])
results = []
all_passed = True

print(f"Verifying {task_id}...")

for check in checks:
    ctype = check.get('type', '')
    passed = False
    msg = ''

    if ctype == 'file_exists':
        val = check.get('value', '')
        if Path(val).is_file():
            passed = True; msg = f"✅ file exists: {val}"
        else:
            msg = f"❌ file missing: {val}"

    elif ctype == 'dir_exists':
        val = check.get('value', '')
        if Path(val).is_dir():
            passed = True; msg = f"✅ dir exists: {val}"
        else:
            msg = f"❌ dir missing: {val}"

    elif ctype == 'git_remote':
        val = check.get('value', '')
        r = subprocess.run(['git', '-C', val, 'remote', '-v'],
                           capture_output=True, text=True)
        if r.returncode == 0 and 'origin' in r.stdout:
            passed = True; msg = f"✅ git remote set: {val}"
        else:
            msg = f"❌ no git remote in: {val}"

    elif ctype == 'git_pushed':
        d = check.get('dir', '.')
        branch = check.get('branch', 'main')
        local_sha = subprocess.run(['git', '-C', d, 'rev-parse', 'HEAD'],
                                   capture_output=True, text=True).stdout.strip()
        remote_sha = subprocess.run(['git', '-C', d, 'rev-parse', f'origin/{branch}'],
                                    capture_output=True, text=True).stdout.strip()
        if local_sha and local_sha == remote_sha:
            passed = True; msg = f"✅ git pushed: {d} ({branch})"
        else:
            msg = f"❌ git not pushed: {d} local={local_sha[:8] if local_sha else 'none'} remote={remote_sha[:8] if remote_sha else 'missing'}"

    elif ctype == 'cmd_succeeds':
        val = check.get('value', '')
        r = subprocess.run(val, shell=True, capture_output=True)
        if r.returncode == 0:
            passed = True; msg = f"✅ cmd ok: {val}"
        else:
            msg = f"❌ cmd failed (exit {r.returncode}): {val}"

    else:
        msg = f"⚠️  unknown check type: {ctype}"

    print(f"  {msg}")
    results.append(msg)
    if not passed:
        all_passed = False

new_status = 'verified' if all_passed else 'failed'
t['status'] = new_status
t['updated'] = now
t['last_verify_results'] = results
t['history'].append({'status': new_status, 'at': now, 'note': 'verification run'})
json.dump(data, open(state_file, 'w'), indent=2)

if all_passed:
    print(f"✅ VERIFIED: {task_id}")
else:
    print(f"❌ FAILED: {task_id} — fix issues and re-run verify")

print(new_status)
PYEOF
}

cmd_status() {
  local task_id="${1:-}"
  init_state_if_missing
  python3 - "$STATE_FILE" "$task_id" << 'PYEOF'
import sys, json
state_file = sys.argv[1]
task_id = sys.argv[2] if len(sys.argv) > 2 else ''
data = json.load(open(state_file))
tasks = data.get('tasks', {})
icons = {
    'verified':'✅','failed':'❌','in-progress':'🔄',
    'completed-unverified':'⏳','verify-errored':'⚠️',
    'verify-blocked':'🔁','needs-human-review':'🙋','force-completed':'🔑'
}
if task_id:
    t = tasks.get(task_id)
    if not t:
        print(f"Task {task_id} not found"); sys.exit(0)
    print(f"  id:     {t['id']}")
    print(f"  status: {t['status']}")
    print(f"  desc:   {t['description']}")
    print(f"  since:  {t['started']}")
    print(f"  checks: {len(t.get('checks', []))} defined")
else:
    if not tasks:
        print("No tasks registered."); sys.exit(0)
    for tid, t in tasks.items():
        icon = icons.get(t['status'], '❓')
        print(f"{icon} {tid}: {t['status']} — {t['description'][:60]}")
PYEOF
}

cmd_reset() {
  local task_id="$1" reason="$2"
  init_state_if_missing
  local now; now=$(ts)
  backup_state
  python3 - "$STATE_FILE" "$task_id" "$now" "$reason" << 'PYEOF'
import sys, json
state_file, task_id, now, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(state_file))
t = data.get('tasks', {}).get(task_id)
if not t:
    print(f"ERROR: task {task_id} not found"); sys.exit(1)
t['status'] = 'in-progress'
t['updated'] = now
t['history'].append({'status': 'reset', 'at': now, 'note': reason})
json.dump(data, open(state_file, 'w'), indent=2)
print(f"RESET: {task_id} → in-progress (reason: {reason})")
PYEOF
}

cmd_force_complete() {
  local task_id="$1" reason="$2"
  init_state_if_missing
  local now; now=$(ts)
  backup_state
  python3 - "$STATE_FILE" "$task_id" "$now" "$reason" << 'PYEOF'
import sys, json
state_file, task_id, now, reason = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
data = json.load(open(state_file))
t = data.get('tasks', {}).get(task_id)
if not t:
    print(f"ERROR: task {task_id} not found"); sys.exit(1)
t['status'] = 'force-completed'
t['updated'] = now
t['force_complete_reason'] = reason
t['history'].append({'status': 'force-completed', 'at': now, 'note': reason})
json.dump(data, open(state_file, 'w'), indent=2)
print(f"FORCE-COMPLETED: {task_id} (reason: {reason})")
PYEOF
}

cmd_recover() {
  if [[ ! -f "$STATE_FILE" ]] && [[ -f "$BAK_FILE" ]]; then
    cp "$BAK_FILE" "$STATE_FILE"
    echo "RECOVERED: restored from .bak"
  elif [[ -f "$STATE_FILE" ]]; then
    local health; health=$(check_state_health)
    if [[ "$health" != "OK" ]]; then
      if [[ -f "$BAK_FILE" ]]; then
        cp "$BAK_FILE" "$STATE_FILE"
        echo "RECOVERED: state was corrupt, restored from .bak"
      else
        echo '{"tasks":{}}' > "$STATE_FILE"
        echo "RESET: no backup found, initialized empty state"
      fi
    else
      echo "OK: state file is healthy"
    fi
  else
    echo '{"tasks":{}}' > "$STATE_FILE"
    echo "INITIALIZED: new empty state file"
  fi
}

cmd_list_stuck() {
  init_state_if_missing
  local now_epoch; now_epoch=$(date +%s)
  python3 - "$STATE_FILE" "$now_epoch" << 'PYEOF'
import sys, json
from datetime import datetime, timezone
state_file, now_epoch = sys.argv[1], int(sys.argv[2])
data = json.load(open(state_file))
tasks = data.get('tasks', {})
stuck = {'in-progress', 'completed-unverified', 'verify-errored', 'verify-blocked', 'needs-human-review'}
found = False
for tid, t in tasks.items():
    if t['status'] in stuck:
        try:
            s = datetime.fromisoformat(t['started'].replace('Z', '+00:00'))
            age = now_epoch - int(s.timestamp())
            timeout = t.get('timeout_after', 7200)
            flag = ' ⏰ TIMED OUT' if age > timeout else ''
        except:
            age = 0; flag = ''
        print(f"  {tid}: [{t['status']}] age={age}s{flag} — {t['description'][:60]}")
        found = True
if not found:
    print("No stuck tasks.")
PYEOF
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

CMD="${1:-status}"
case "$CMD" in
  register)       cmd_register "$2" "$3" "$4" ;;
  complete)       cmd_complete "$2" ;;
  verify)         cmd_verify "$2" ;;
  status)         cmd_status "${2:-}" ;;
  reset)          cmd_reset "$2" "$3" ;;
  force-complete) cmd_force_complete "$2" "$3" ;;
  recover)        cmd_recover ;;
  list-stuck)     cmd_list_stuck ;;
  *) echo "Usage: sv.sh <register|complete|verify|status|reset|force-complete|recover|list-stuck>"; exit 1 ;;
esac
