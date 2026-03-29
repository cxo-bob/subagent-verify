# SubAgent Verify — Check Types Reference

Checks are defined as JSON arrays when registering a task.

## Available Check Types

### `file_exists`
Verify a specific file exists on disk.
```json
{"type": "file_exists", "value": "/Users/boblang/bookforge/manuscript/polished/ch1-raw-2026-03-28.md"}
```

### `dir_exists`
Verify a directory exists.
```json
{"type": "dir_exists", "value": "/Users/boblang/bookforge/manuscript/polished"}
```

### `git_remote`
Verify a git repo has a remote configured (catches the re-init problem).
```json
{"type": "git_remote", "value": "/Users/boblang/bookforge"}
```

### `git_pushed`
Verify local HEAD matches remote branch (catches silent push failures).
```json
{"type": "git_pushed", "dir": "/Users/boblang/bookforge", "branch": "main"}
```

### `cmd_succeeds`
Run any shell command — passes if exit code is 0.
```json
{"type": "cmd_succeeds", "value": "gh repo view cxo-bob/hustle-doesnt-scale"}
```

## Example Check Arrays

### Book polish pass
```json
[
  {"type": "git_remote", "value": "/Users/boblang/bookforge"},
  {"type": "git_pushed", "dir": "/Users/boblang/bookforge", "branch": "main"},
  {"type": "file_exists", "value": "/Users/boblang/bookforge/manuscript/polished/ch1-raw-2026-03-28.md"}
]
```

### Dashboard deploy
```json
[
  {"type": "cmd_succeeds", "value": "curl -sf https://oc-dashboard.vercel.app > /dev/null"},
  {"type": "git_pushed", "dir": "/Users/boblang/.openclaw/workspace/oc-dashboard", "branch": "main"}
]
```

### Skill installation
```json
[
  {"type": "dir_exists", "value": "/Users/boblang/.openclaw/workspace/skills/new-skill"},
  {"type": "file_exists", "value": "/Users/boblang/.openclaw/workspace/skills/new-skill/SKILL.md"}
]
```
