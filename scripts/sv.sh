#!/usr/bin/env bash
# sv.sh — SubAgent Verify (SAV) CLI
# State:  ~/.openclaw/workspace/memory/subagent-state.json
# Backup: ~/.openclaw/workspace/memory/subagent-state.json.bak
#
# Usage:
#   sv.sh register <task-id> <description> <checks-json> [retry-max] [retry-backoff-base]
#   sv.sh complete <task-id>
#   sv.sh verify <task-id>
#   sv.sh status [task-id]
#   sv.sh reset <task-id> <reason>
#   sv.sh force-complete <task-id> <reason>
#   sv.sh recover
#   sv.sh list-stuck
#   sv.sh history <task-id>
#   sv.sh notify <task-id> <status>   (internal — called by verify on failure states)

set -euo pipefail

STATE_FILE="$HOME/.openclaw/workspace/memory/subagent-state.json"
BAK_FILE="${STATE_FILE}.bak"
LOG_DIR="$HOME/.openclaw/workspace/memory/sav-logs"

# ── Slack notification config ──────────────────────────────────────────────────
# Set SLACK_SAV_WEBHOOK in environment or openclaw.json to enable push alerts.
# Alert fires on: failed, verify-errored, needs-human-review
# Format: SLACK_SAV_WEBHOOK="https://hooks.slack.com/services/..."
# Channel override: SLACK_SAV_CHANNEL="#bobs-office" (default: webhook default)
ALERT_STATUSES=("failed" "verify-errored" "needs-human-review" "verify-blocked")

ts() { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_human() { date '+%Y-%m-%d %H:%M CT'; }

backup_state() {
  [[ -f "$STATE_FILE" ]] && cp "$STATE_FILE" "$BAK_FILE"
}

init_state_if_missing() {
  if [[ ! -f "$STATE_FILE" ]]; then
    echo '{"tasks":{}}' > "$STATE_FILE"
  fi
  mkdir -p "$LOG_DIR"
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

append_task_log() {
  local task_id="$1" entry="$2"
  local log_file="$LOG_DIR/${task_id}.log"
  echo "$(ts_human) | $entry" >> "$log_file"
}

# ── Slack push notification ────────────────────────────────────────────────────

cmd_notify() {
  local task_id="$1" status="$2" description="${3:-}" detail="${4:-}"

  # Always log to file
  append_task_log "$task_id" "NOTIFY status=$status detail=$detail"

  # Push to Slack if webhook configured
  local webhook="${SLACK_SAV_WEBHOOK:-}"
  if [[ -z "$webhook" ]]; then
    # Try reading from openclaw.json
    webhook=$(python3 -c "
import json, os
try:
    cfg = json.load(open(os.path.expanduser('~/.openclaw/openclaw.json')))
    print(cfg.get('env', {}).get('SLACK_SAV_WEBHOOK', ''))
except:
    print('')
" 2>/dev/null || echo "")
  fi

  [[ -z "$webhook" ]] && return 0  # No webhook configured — skip silently

  local icon
  case "$status" in
    failed)              icon="❌" ;;
    verify-errored)      icon="⚠️" ;;
    needs-human-review)  icon="🙋" ;;
    verify-blocked)      icon="🔁" ;;
    *)                   icon="ℹ️" ;;
  esac

  local channel="${SLACK_SAV_CHANNEL:-}"
  local payload
  payload=$(python3 -c "
import json
msg = {
    'text': '$icon *SAV Alert* — task \`$task_id\` entered \`$status\`',
    'blocks': [
        {
            'type': 'section',
            'text': {
                'type': 'mrkdwn',
                'text': '$icon *SAV Task Alert*\n*Task:* \`$task_id\`\n*Status:* \`$status\`\n*Desc:* $description\n*Detail:* $detail\n*Time:* $(ts_human)'
            }
        },
        {
            'type': 'section',
            'text': {
                'type': 'mrkdwn',
                'text': '*Recovery options:*\n• \`--sv reset $task_id <reason>\`\n• \`--sv force-complete $task_id <reason>\`\n• \`--sv verify $task_id\` (after fixing)'
            }
        }
    ]
}
if '$channel':
    msg['channel'] = '$channel'
print(json.dumps(msg))
" 2>/dev/null)

  curl -sf -X POST -H 'Content-type: application/json' \
    --data "$payload" "$webhook" > /dev/null 2>&1 || true
}

# ── Commands ───────────────────────────────────────────────────────────────────

cmd_register() {
  local task_id="$1" description="$2" checks_json="$3"
  local retry_max="${4:-3}"
  local retry_backoff_base="${5:-60}"   # seconds — doubles each attempt: 60, 120, 240...

  init_state_if_missing
  local health; health=$(check_state_health)
  [[ "$health" != "OK" ]] && { echo "ERROR: state file corrupt — run: sv.sh recover"; exit 1; }

  local now; now=$(ts)
  backup_state
  python3 - "$STATE_FILE" "$task_id" "$description" "$now" "$retry_max" "$retry_backoff_base" << PYEOF
import sys, json
state_file, task_id, description, now = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
retry_max, retry_backoff_base = int(sys.argv[5]), int(sys.argv[6])
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
    'retry_max': retry_max,
    'retry_count': 0,
    'retry_backoff_base': retry_backoff_base,
    'retry_next_after': None,
    'history': [{'status': 'in-progress', 'at': now, 'note': 'registered'}]
}
json.dump(data, open(state_file, 'w'), indent=2)
print(f"REGISTERED: {task_id} [in-progress] (retry_max={retry_max}, backoff_base={retry_backoff_base}s)")
PYEOF
  append_task_log "$task_id" "REGISTERED desc=$description retry_max=$retry_max backoff_base=${retry_backoff_base}s"
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
  append_task_log "$task_id" "COMPLETE subagent returned"
}

cmd_verify() {
  local task_id="$1"
  init_state_if_missing
  local now; now=$(ts)
  local now_epoch; now_epoch=$(date +%s)

  python3 - "$STATE_FILE" "$task_id" "$now" "$now_epoch" << 'PYEOF'
import sys, json, subprocess, os
from pathlib import Path
from datetime import datetime, timezone

state_file, task_id, now, now_epoch = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
data = json.load(open(state_file))
t = data.get('tasks', {}).get(task_id)
if not t:
    print(f"ERROR: task {task_id} not found"); sys.exit(1)

checks = t.get('checks', [])
results = []
all_passed = True
network_error = False

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
        remote_r = subprocess.run(['git', '-C', d, 'rev-parse', f'origin/{branch}'],
                                   capture_output=True, text=True)
        remote_sha = remote_r.stdout.strip()
        if remote_r.returncode != 0:
            # Could be network issue or remote doesn't exist
            network_error = True
            msg = f"🔁 git remote unreachable or branch missing: {d} ({branch})"
        elif local_sha and local_sha == remote_sha:
            passed = True; msg = f"✅ git pushed: {d} ({branch})"
        else:
            msg = f"❌ git not pushed: {d} local={local_sha[:8] if local_sha else 'none'} remote={remote_sha[:8] if remote_sha else 'missing'}"

    elif ctype == 'cmd_succeeds':
        val = check.get('value', '')
        r = subprocess.run(val, shell=True, capture_output=True)
        if r.returncode == 0:
            passed = True; msg = f"✅ cmd ok: {val}"
        elif r.returncode in (6, 7, 28, 35, 56):  # curl network error codes
            network_error = True; msg = f"🔁 network error (exit {r.returncode}): {val}"
        else:
            msg = f"❌ cmd failed (exit {r.returncode}): {val}"

    elif ctype == 'url_reachable':
        val = check.get('value', '')
        r = subprocess.run(['curl', '-sf', '--max-time', '10', val],
                           capture_output=True)
        if r.returncode == 0:
            passed = True; msg = f"✅ url reachable: {val}"
        elif r.returncode in (6, 7, 28, 35, 56):
            network_error = True; msg = f"🔁 network error reaching: {val}"
        else:
            msg = f"❌ url unreachable (exit {r.returncode}): {val}"

    else:
        msg = f"⚠️  unknown check type: {ctype}"

    print(f"  {msg}")
    results.append(msg)
    if not passed:
        all_passed = False

# Determine new status
retry_count = t.get('retry_count', 0)
retry_max = t.get('retry_max', 3)
retry_backoff_base = t.get('retry_backoff_base', 60)

if all_passed:
    new_status = 'verified'
elif network_error and not all_passed:
    # Network issues get verify-blocked + auto-retry scheduling
    new_status = 'verify-blocked'
    retry_count += 1
    backoff = retry_backoff_base * (2 ** (retry_count - 1))
    retry_after = now_epoch + backoff
    t['retry_count'] = retry_count
    t['retry_next_after'] = retry_after
    print(f"🔁 VERIFY-BLOCKED: network issue. Auto-retry #{retry_count}/{retry_max} in {backoff}s")
elif not all_passed and retry_count < retry_max:
    new_status = 'failed'
    retry_count += 1
    backoff = retry_backoff_base * (2 ** (retry_count - 1))
    retry_after = now_epoch + backoff
    t['retry_count'] = retry_count
    t['retry_next_after'] = retry_after
    print(f"❌ FAILED: {task_id} — retry {retry_count}/{retry_max} available (backoff {backoff}s)")
else:
    new_status = 'failed'
    print(f"❌ FAILED: {task_id} — max retries ({retry_max}) exhausted. Needs human review.")

t['status'] = new_status
t['updated'] = now
t['last_verify_results'] = results
t['history'].append({'status': new_status, 'at': now, 'note': f'verify run, retry_count={retry_count}'})
json.dump(data, open(state_file, 'w'), indent=2)

if new_status == 'verified':
    print(f"✅ VERIFIED: {task_id}")

print(f"STATUS:{new_status}")
print(f"DESC:{t['description']}")
print(f"DETAIL:{'; '.join(r for r in results if not r.startswith('✅'))}")
PYEOF

  # Parse output for notification trigger
  local output
  output=$(cat /tmp/sv_verify_out 2>/dev/null || true)
  local new_status desc detail
  new_status=$(python3 -c "
import json
data = json.load(open('$STATE_FILE'))
print(data['tasks'].get('$task_id', {}).get('status', 'unknown'))
")
  desc=$(python3 -c "
import json
data = json.load(open('$STATE_FILE'))
print(data['tasks'].get('$task_id', {}).get('description', ''))
")

  append_task_log "$task_id" "VERIFY status=$new_status"

  # Push notification on alert states
  for alert_status in "${ALERT_STATUSES[@]}"; do
    if [[ "$new_status" == "$alert_status" ]]; then
      cmd_notify "$task_id" "$new_status" "$desc" "See sv.sh history $task_id for details"
      break
    fi
  done
}

cmd_status() {
  local task_id="${1:-}"
  init_state_if_missing
  python3 - "$STATE_FILE" "$task_id" << 'PYEOF'
import sys, json
from datetime import datetime, timezone
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
    print(f"  id:          {t['id']}")
    print(f"  status:      {t['status']}")
    print(f"  desc:        {t['description']}")
    print(f"  started:     {t['started']}")
    print(f"  retries:     {t.get('retry_count', 0)}/{t.get('retry_max', 3)}")
    nxt = t.get('retry_next_after')
    if nxt:
        print(f"  next_retry:  epoch {nxt}")
    print(f"  checks:      {len(t.get('checks', []))} defined")
else:
    if not tasks:
        print("No tasks registered."); sys.exit(0)
    for tid, t in tasks.items():
        icon = icons.get(t['status'], '❓')
        retry_info = f" [retry {t.get('retry_count',0)}/{t.get('retry_max',3)}]" if t.get('retry_count', 0) > 0 else ""
        print(f"{icon} {tid}: {t['status']}{retry_info} — {t['description'][:55]}")
PYEOF
}

cmd_history() {
  local task_id="$1"
  init_state_if_missing

  echo "=== State history for $task_id ==="
  python3 - "$STATE_FILE" "$task_id" << 'PYEOF'
import sys, json
state_file, task_id = sys.argv[1], sys.argv[2]
data = json.load(open(state_file))
t = data.get('tasks', {}).get(task_id)
if not t:
    print(f"Task {task_id} not found"); sys.exit(0)
for entry in t.get('history', []):
    print(f"  {entry.get('at','?')}  [{entry.get('status','?')}]  {entry.get('note','')}")
if t.get('last_verify_results'):
    print("\n=== Last verify results ===")
    for r in t['last_verify_results']:
        print(f"  {r}")
PYEOF

  # Also show log file if it exists
  local log_file="$LOG_DIR/${task_id}.log"
  if [[ -f "$log_file" ]]; then
    echo ""
    echo "=== Activity log ==="
    cat "$log_file"
  fi
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
t['retry_next_after'] = None
t['history'].append({'status': 'reset', 'at': now, 'note': reason})
json.dump(data, open(state_file, 'w'), indent=2)
print(f"RESET: {task_id} → in-progress (reason: {reason})")
PYEOF
  append_task_log "$task_id" "RESET reason=$reason"
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
  append_task_log "$task_id" "FORCE-COMPLETED reason=$reason"
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
        # Check if auto-retry is due
        retry_due = ''
        nxt = t.get('retry_next_after')
        if nxt and now_epoch >= nxt and t['status'] == 'verify-blocked':
            retry_due = ' 🔄 RETRY DUE'
        retries = f" retry={t.get('retry_count',0)}/{t.get('retry_max',3)}" if t.get('retry_count',0) > 0 else ""
        print(f"  {tid}: [{t['status']}]{retries} age={age}s{flag}{retry_due} — {t['description'][:55]}")
        found = True
if not found:
    print("No stuck tasks.")
PYEOF
}

# Auto-retry: called by heartbeat for verify-blocked tasks whose backoff has elapsed
cmd_auto_retry() {
  init_state_if_missing
  local now_epoch; now_epoch=$(date +%s)

  local due_tasks
  due_tasks=$(python3 - "$STATE_FILE" "$now_epoch" << 'PYEOF'
import sys, json
state_file, now_epoch = sys.argv[1], int(sys.argv[2])
data = json.load(open(state_file))
for tid, t in data.get('tasks', {}).items():
    if t.get('status') == 'verify-blocked':
        nxt = t.get('retry_next_after')
        retry_count = t.get('retry_count', 0)
        retry_max = t.get('retry_max', 3)
        if nxt and now_epoch >= nxt and retry_count <= retry_max:
            print(tid)
PYEOF
)

  if [[ -z "$due_tasks" ]]; then
    return 0
  fi

  while IFS= read -r task_id; do
    [[ -z "$task_id" ]] && continue
    echo "Auto-retrying verify for: $task_id"
    cmd_verify "$task_id"
  done <<< "$due_tasks"
}

# ── Dispatch ───────────────────────────────────────────────────────────────────

CMD="${1:-status}"
case "$CMD" in
  register)       cmd_register "$2" "$3" "$4" "${5:-3}" "${6:-60}" ;;
  complete)       cmd_complete "$2" ;;
  verify)         cmd_verify "$2" ;;
  status)         cmd_status "${2:-}" ;;
  reset)          cmd_reset "$2" "$3" ;;
  force-complete) cmd_force_complete "$2" "$3" ;;
  recover)        cmd_recover ;;
  list-stuck)     cmd_list_stuck ;;
  history)        cmd_history "$2" ;;
  auto-retry)     cmd_auto_retry ;;
  notify)         cmd_notify "$2" "$3" "${4:-}" "${5:-}" ;;
  *) echo "Usage: sv.sh <register|complete|verify|status|reset|force-complete|recover|list-stuck|history|auto-retry>"; exit 1 ;;
esac
