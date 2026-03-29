# Contributing

SAV is intentionally minimal. Before adding complexity, ask: does this make the gate stronger or does it just add surface area?

## Adding a new check type

1. Add the type to the `cmd_verify` function in `scripts/sv.sh`
2. Document it in `references/check-types.md` with an example
3. Test it: register a task with the new check, complete it, verify it

## Reporting issues

Open an issue with:
- What state the task was in
- What check failed or what the script output
- Contents of `subagent-state.json` (redact sensitive paths if needed)

## Principles

- State must always be recoverable from the `.bak` file
- Every failure mode must produce a named state — nothing silently stalls
- Recovery must work from chat, not just the terminal
- The gate must be harder to accidentally bypass than to use correctly
