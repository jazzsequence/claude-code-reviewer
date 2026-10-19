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

Fix: Add `"Write(*)"` and `"Bash(bash .githooks/lib/approval.sh fingerprint)"` to the `permissions.allow` array in `.claude/settings.json` (`date*` is already there). Restart Claude Code to reload settings.

The reviewer must write the flag with the Write tool, as three separate steps: `date +%s`, the fingerprint script, then `Write` of `<timestamp> <fingerprint>`. A `printf ... > reviewer-approved` redirect is not allow-listed and prompts every time, so make sure your `.claude/agents/reviewer.md` and `docs/REVIEWER_CHECKLIST.md` use the Write form.

## Reviewer approves but the flag is never written ("Self-Approval", "Auto-Mode Bypass")

Symptom: every checklist item passes, but the reviewer reports that writing `reviewer-approved` (or running the fingerprint script) was denied, citing a label such as `Self-Approval`, `Auto-Mode Bypass`, `Security Weaken` or `Self-Modification`, even though the commands are on `permissions.allow`.

Cause: these denials come from Claude Code's auto-mode classifier, not from the permission rules. It treats an agent writing the approval for the main agent's own commit as self-approval, and ordinary `permissions.allow` rules do not override it.

Fix: run the session outside auto mode (for example the default permission mode). The Write flow above then goes through with no prompts. This is the only fix verified so far: an `autoMode.allow` entry in `~/.claude/settings.json` (user-level only; the classifier ignores project settings for this) did not make the write succeed in testing with auto mode on.

Do not retry the write through a different path (a redirect, a different tool, another command) after a denial: the classifier counts that as an attempt to bypass it and the denials get worse.

Two related symptoms: if `claude auto-mode critique` reports "No custom auto mode rules found" after you added rules, check that `~/.claude/settings.json` is valid JSON (a missing comma silently drops the whole block); and if permission prompts flash and vanish, a background subagent is raising requests that replace yours, so avoid running commands that need a prompt while a subagent is running.

## "Approval expired (Xs old)"

The reviewer approved more than `REVIEWER_APPROVAL_TIMEOUT` seconds ago (default: 300s / 5 minutes). Spawn the reviewer again and commit promptly.

To increase the timeout, set `REVIEWER_APPROVAL_TIMEOUT` in `.reviewer-config.sh`.

## "Approval file is corrupted"

The `reviewer-approved` file exists but is not a valid flag. The hook distinguishes three
cases, and the remedies differ:

- **"has no tree fingerprint"** — a pre-binding (v1) flag. Update claude-code-reviewer,
  then re-run the reviewer agent.
- **"does not match the staged changes"** — the approval was valid, but something was
  staged or unstaged after the review. Re-run the reviewer so the approval covers what
  you are actually committing.
- **"corrupted (invalid timestamp)"** — the file contents are not a plain integer.

In the last case, delete it:
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

PreToolUse hooks communicate through exit codes and stderr, and **only exit code 2
blocks a tool call**. Any other non-zero code is treated as a non-blocking error: Claude
Code shows a `hook error` notice and *proceeds with the tool call anyway*. From the
[hooks guide](https://code.claude.com/docs/en/hooks-guide):

> **Exit 2**: Claude Code blocks the action. Write a reason to stderr.

So a handler that exits 1 on its block paths will print `[BLOCKED]` and let the commit
through. `hook-handler.cjs` uses `exit 2` for all four block paths (USER_COMMIT, missing
approval, corrupt timestamp, expired approval) and reserves `exit 1` for internal errors
such as an unknown hook command.

If a block still doesn't take effect, check two things beyond the exit code:

1. **The registration** in `.claude/settings.json` — `"matcher": "Bash"` is correct and
   the `command` path points at the right file.
2. **The command isn't swallowing the exit code.** A wrapper like
   `test -f handler.cjs && node handler.cjs pre-bash || true` always exits 0, so the
   hook can never block. Drop the `|| true`, or use
   `test -f handler.cjs && node handler.cjs pre-bash` alone.

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
