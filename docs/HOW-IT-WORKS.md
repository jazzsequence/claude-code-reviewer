# How the Three-Layer Enforcement Works

## Layer 1: PreToolUse Hook (`hook-handler.cjs`)

**When:** Before any `Bash` tool call executes in Claude Code

**File:** `.claude/helpers/hook-handler.cjs` (copied to your project)

**Registered via:** `.claude/settings.json` → `hooks.PreToolUse`

When Claude Code calls `Bash({ command: "git commit ..." })`, the hook handler fires first. It reads the approval file, checks the timestamp, and either:
- Exits 0 → commit proceeds
- Exits 1 → commit is blocked before git even starts

This layer gives the clearest error messages and fires earliest.

**Why `Write(*)` in permissions:**
The reviewer agent uses the `Write` tool to create the approval flag. Without `Write(*)` in `.claude/settings.json`, Claude Code will prompt the human for permission on every write — breaking the automated flow. The `*` is required because more specific paths like `Write(reviewer-approved)` don't work with Claude Code's glob matching.

## Layer 2: Pre-commit Shell Hook (`pre-commit`)

**When:** After `git commit` starts, before the commit is finalized

**File:** `.git/hooks/pre-commit` (installed from `.githooks/pre-commit`)

This hook re-validates the approval file (defense in depth), then:
- Enforces commit size limits (AI commits only)
- Runs unit tests, linter, build, and optionally E2E tests
- Checks for secrets in staged files
- Deletes the approval flag (single-use)

The pre-commit hook reads `.reviewer-config.sh` for all commands and limits, making it project-agnostic.

**Text-only shortcut:** If all staged files match `REVIEWER_TEXT_ONLY_PATTERN` (default: `.md`, `.txt`, `.rst`), the test suite is skipped — only the approval check and secrets check run.

## Layer 3: Behavioral Instructions (CLAUDE.md + AGENTS.md)

**When:** Whenever the AI receives a task that involves writing code

**Files:** Your project's `CLAUDE.md` and `AGENTS.md`

The hooks enforce that an approval exists, but they don't *trigger* the reviewer — the AI must decide to spawn one. These instructions tell Claude:
1. Always spawn the reviewer before committing
2. Describe the change factually; don't tell the reviewer to approve
3. The reviewer (not the main agent) writes the approval flag
4. Wait for the flag before running `git commit`

Without this layer, a sufficiently persistent AI could keep retrying after blocked commits without actually fixing the underlying problem.

## Why reviewer integrity matters

The reviewer agent writes the approval flag; the main agent does not. This separation means:
- The entity that *evaluated* the code is the same entity that *approved* it
- The main agent cannot self-approve by writing the file directly
- If the reviewer rejects, the main agent must fix issues and get a new review

## What `USER_COMMIT=1` bypasses

All reviewer-related checks, but **not** the secrets check (which never has a bypass). It's intended only for human-authored commits where the developer is taking personal responsibility for the change.

---

## How the manifest-based update system works

`install.sh` is safe to re-run. It tracks installed files in `.reviewer-manifest`
(a plain-text file at the project root, one `relative/path:sha256hash` entry per line)
and uses three-way comparison to decide what to do on each re-run:

```
current local hash  vs  manifest hash  → "did the user touch this file?"
current local hash  vs  new upstream hash  → "is this file already at the latest version?"
```

**Fully-managed files** (`.githooks/pre-commit`, `hook-handler.cjs`, `.claude/agents/reviewer.md`):

| Current == manifest | Current == upstream | Action |
|---------------------|---------------------|--------|
| ✅ yes | ✅ yes | Already up to date — no action |
| ✅ yes | ❌ no  | No local changes, upstream changed → **update automatically** |
| ❌ no  | ✅ yes | User changed it to match upstream exactly → record in manifest |
| ❌ no  | ❌ no  | **User modified** → skip, show upstream diff for manual merge |

The manifest stores hashes of what was installed *locally* — not what is in the
upstream repo. When upstream ships a new version of a file, the new file's hash
differs from both the manifest and the current file (assuming no local edits),
so the "current == manifest, current != upstream" row applies and the file is
updated automatically.

**User-editable files** (`.reviewer-config.sh`, `docs/REVIEWER_CHECKLIST.md`):

These are never overwritten. On re-run, install.sh generates the new template
version (with current config values substituted) and diffs it against what's
on disk. If they differ, it prints the diff so you can manually merge any
upstream improvements you want to keep.
