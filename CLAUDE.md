# claude-code-reviewer — Claude Code Context

**Project**: A portable reviewer workflow toolkit for Claude Code projects.

It enforces a mandatory AI code review before every git commit using three
layers: a PreToolUse hook (Layer 1), a pre-commit shell hook (Layer 2), and
CLAUDE.md/AGENTS.md behavioral instructions (Layer 3).

---

## Repository Structure

```
claude-code-reviewer/
├── install.sh                      # Interactive installer (run in target project)
├── hooks/
│   └── pre-commit                  # Shell hook — Layer 2 enforcement
├── helpers/
│   └── hook-handler.cjs            # Node.js PreToolUse handler — Layer 1
├── templates/
│   ├── reviewer.md                 # Agent definition → .claude/agents/reviewer.md
│   ├── REVIEWER_CHECKLIST.md       # Checklist template → docs/REVIEWER_CHECKLIST.md
│   ├── reviewer-config.sh          # Per-project config template
│   ├── reviewer-agent.md           # Spawn prompt documentation → AGENTS.md
│   ├── claude-md-block.md          # Workflow block → CLAUDE.md
│   └── settings-addition.json     # Merge into .claude/settings.json
├── docs/
│   ├── HOW-IT-WORKS.md             # Three-layer architecture detail
│   └── TROUBLESHOOTING.md          # Common issues and fixes
├── CLAUDE.md                       # This file
└── README.md                       # User-facing docs
```

### Key relationship between templates

- **`templates/reviewer.md`** → installed as `.claude/agents/reviewer.md` in the target project.
  This is the reviewer agent's runtime definition. It tells the reviewer to `Read()` the checklist
  file rather than embedding items inline. `{{PROJECT_ROOT}}` is substituted with the actual
  absolute path by `install.sh` so the approval flag is always written to a known location.

- **`templates/REVIEWER_CHECKLIST.md`** → generated as `docs/REVIEWER_CHECKLIST.md` in the target
  project. Contains all checklist items with placeholders (`{{TEST_CMD}}`, `{{PROJECT_ROOT}}`, etc.)
  substituted by `install.sh`. Section A items always run; Section B items are conditional with
  explicit skip conditions. Per-item ✅/❌/⏭️ output is required.

---

## How the Workflow Works

```
AI makes changes
     ↓
AI spawns reviewer agent (Agent tool, subagent_type=reviewer)
     ↓
Reviewer runs tests/lint/checks
     ↓  REJECT → AI fixes → loop
     ↓  APPROVE
Reviewer writes `reviewer-approved` (timestamp) using Write tool
     ↓
AI calls `git commit`
     ↓
PreToolUse hook (hook-handler.cjs) fires — validates approval file
     ↓  missing/expired → BLOCKED with instructions
     ↓  valid
Git pre-commit hook fires — re-validates + checks secrets + runs tests
     ↓
Commit succeeds, approval flag deleted
```

### The approval file

- Written by the **reviewer agent** (not the main agent) on APPROVE
- Path: `<project-root>/reviewer-approved` (configurable via `.reviewer-config.sh`)
- Contains a Unix timestamp
- Expires after `REVIEWER_APPROVAL_TIMEOUT` seconds (default: 300 = 5 min)
- Deleted by the pre-commit hook after a successful commit
- Listed in `.gitignore` — never committed

### User bypass

`USER_COMMIT=1 git commit -m "message"` skips the reviewer requirement for
human-written commits. Only the human should use this — AI agents must not.

---

## Common Tasks for Claude

### Add project-specific checklist items

After installation, edit `docs/REVIEWER_CHECKLIST.md` in the target project.
Add items to the "Project-specific checks" section at the bottom of the file.
Examples: WordPress nonce checks, Python type hints, required documentation files.

To change the template for future installs, edit `templates/REVIEWER_CHECKLIST.md`
in the same section (marked with an HTML comment).

### Change what commands the hook runs

Edit `templates/reviewer-config.sh`. The variables are:
- `REVIEWER_TEST_CMD` — unit tests
- `REVIEWER_LINT_CMD` — linter
- `REVIEWER_BUILD_CMD` — build step
- `REVIEWER_E2E_CMD` — E2E tests (empty string = skip)

### Add support for a new package manager / language

The hook sources `.reviewer-config.sh` and is otherwise shell-agnostic.
For non-Node.js projects, update the `REVIEWER_EXCLUDED_FILES` pattern in
`templates/reviewer-config.sh` to match the language's lock file(s).

### Change the approval timeout

Update `REVIEWER_APPROVAL_TIMEOUT` in `.reviewer-config.sh`. Also update
`CONFIG.approvalTimeout` in `helpers/hook-handler.cjs` if you want the
Layer 1 hook to pick it up without sourcing the shell config.

### Prepare the package for a new project

1. Run `install.sh` in the target project directory
2. Help the user add `templates/claude-md-block.md` to their `CLAUDE.md`
3. Help the user add `templates/reviewer-agent.md` to their `AGENTS.md`
4. Customize the reviewer prompt for the project's stack
5. Verify the hook works: `echo test >> README.md && git add README.md && git commit -m test`
   (should be BLOCKED)

### Debug a hook that isn't blocking commits

Check in order:
1. Is `.git/hooks/pre-commit` executable? `ls -la .git/hooks/pre-commit`
2. Is `hook-handler.cjs` in `.claude/helpers/`?
3. Is the PreToolUse hook in `.claude/settings.json`?
4. Is `Write(*)` in the allowed permissions?
5. Run `node .claude/helpers/hook-handler.cjs pre-bash` with stdin `{"command":"git commit -m test"}`

---

## Design Principles

- **No external dependencies** — pure bash + Node.js (available everywhere)
- **Stack-agnostic** — test commands are configuration, not code
- **Defense in depth** — two independent enforcement layers
- **Clear error messages** — blocked commits explain exactly what to do
- **Human escape hatch** — `USER_COMMIT=1` for manual commits
- **Reviewer integrity** — only the reviewer writes the approval flag

---

## Files Claude Should NOT Modify

- `hooks/pre-commit` — core enforcement logic; changes break the workflow
- `helpers/hook-handler.cjs` — Layer 1 enforcement; changes must be tested carefully

## Files Claude Should Freely Modify

- `templates/*` — these are templates, meant to be customized
- `install.sh` — adding new prompts or language detection is encouraged
- `docs/*` — documentation always welcome
- `README.md` — keep updated with any feature changes
