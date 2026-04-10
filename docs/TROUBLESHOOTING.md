# Troubleshooting

## Hook doesn't block commits

**Check 1:** Is the pre-commit hook installed and executable?
```bash
ls -la .git/hooks/pre-commit
# Must show: -rwxr-xr-x
```
If not: `chmod +x .git/hooks/pre-commit`

**Check 2:** Is `hook-handler.cjs` in place?
```bash
ls .claude/helpers/hook-handler.cjs
```

**Check 3:** Is the PreToolUse hook registered in `.claude/settings.json`?
```json
"hooks": { "PreToolUse": [{ "matcher": "Bash", ... }] }
```

**Check 4:** Does `.claude/settings.json` have `Write(*)`?
Without it, the reviewer agent will be prompted for permission every time it tries to write the approval flag, breaking the automated flow.

## "Write tool requires manual approval"

The reviewer agent is trying to write the approval flag but Claude Code is asking for permission.

Fix: Add `"Write(*)"` to the `permissions.allow` array in `.claude/settings.json`. Restart Claude Code to reload settings.

## "Approval expired (Xs old)"

The reviewer approved more than `REVIEWER_APPROVAL_TIMEOUT` seconds ago (default: 300s / 5 minutes). Spawn the reviewer again and commit promptly.

To increase the timeout, set `REVIEWER_APPROVAL_TIMEOUT` in `.reviewer-config.sh`.

## "Approval file is corrupted"

The `reviewer-approved` file exists but contains an invalid timestamp. Delete it:
```bash
rm reviewer-approved
```
Then get a fresh approval.

## Reviewer approval keeps getting consumed before commit

The pre-commit hook deletes the approval file after a successful commit (by design — single use). If you need to retry a failed commit (e.g., merge conflict), you'll need a fresh approval.

## Tests run even for doc-only changes

Check `REVIEWER_TEXT_ONLY_PATTERN` in `.reviewer-config.sh`. Default: `'\.(md|txt|rst)$'`. If your docs use different extensions (`.mdx`, `.adoc`), add them:
```bash
REVIEWER_TEXT_ONLY_PATTERN='\.(md|mdx|txt|rst|adoc)$'
```

## Pre-commit hook runs but doesn't use my test commands

The hook sources `.reviewer-config.sh` from the project root (detected via `git rev-parse --show-toplevel`). Make sure the file exists there — it won't be found if you're in a subdirectory without a git root.

## `USER_COMMIT=1` not working

The bypass must be set as an environment variable when calling git:
```bash
USER_COMMIT=1 git commit -m "message"
```

It won't work if set in a separate shell command:
```bash
export USER_COMMIT=1
git commit -m "message"  # ← this works too, but only for the session
```

## Hook runs but Claude Code doesn't see the error

PreToolUse hooks communicate through exit codes and stderr. If `hook-handler.cjs` exits 1 but Claude Code proceeds anyway, check the hook registration in `.claude/settings.json` — specifically that `"matcher": "Bash"` is correct and the `command` path points to the right file.

## Running the hook handler manually for debugging

```bash
echo '{"command":"git commit -m test"}' | node .claude/helpers/hook-handler.cjs pre-bash
```

Expected output when no approval exists:
```
[BLOCKED] No reviewer approval found
...
```

Expected output with valid approval:
```
[OK] Reviewer approved (3s ago)
```
