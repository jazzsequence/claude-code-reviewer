# claude-code-reviewer

A portable reviewer workflow for [Claude Code](https://claude.ai/code) that enforces mandatory AI code review before every git commit.

## How it works

Every time Claude Code tries to run `git commit`, a three-layer enforcement chain fires:

1. **PreToolUse hook** — intercepts the commit _before_ git starts; blocks with clear instructions if no approval
2. **Pre-commit shell hook** — re-validates approval, enforces commit size limits, checks for secrets, runs your test suite
3. **CLAUDE.md instructions** — tells the AI to always spawn a reviewer and never self-approve

The reviewer agent runs your tests, checks code quality, then writes a timestamped approval file. The hooks validate that file. The approval expires after 5 minutes.

## Requirements

- Claude Code CLI
- Git
- Bash (macOS/Linux/WSL)
- Node.js (for the PreToolUse hook handler)

No npm packages. No external services.

## Quick start

```bash
# In your project directory:
curl -sSL https://raw.githubusercontent.com/jazzsequence/claude-code-reviewer/main/install.sh | bash
```

Or clone and run locally:

```bash
git clone https://github.com/jazzsequence/claude-code-reviewer
cd your-project
bash ../claude-code-reviewer/install.sh
```

The installer will ask for your test/lint/build commands and generate a `.reviewer-config.sh` for the project.

## Post-install

After running the installer, add two blocks to your project:

**1. Add to `CLAUDE.md`** — tells the AI how the reviewer workflow operates:

```
cat templates/claude-md-block.md >> your-project/CLAUDE.md
```

**2. Add to `AGENTS.md`** — the reviewer agent's instructions:

```
cat templates/reviewer-agent.md >> your-project/AGENTS.md
```

Then test it:

```bash
echo "test" >> README.md
git add README.md
git commit -m "test"               # should be BLOCKED
USER_COMMIT=1 git commit -m "test" # bypasses reviewer (your own commits)
git reset HEAD~1 && git checkout README.md
```

## Configuration

The installer generates `.reviewer-config.sh` in your project root:

```bash
REVIEWER_TEST_CMD="npm test -- --run"   # unit tests
REVIEWER_LINT_CMD="npm run lint"        # linter
REVIEWER_BUILD_CMD="npm run build"      # build
REVIEWER_E2E_CMD=""                     # E2E (empty = skip)

REVIEWER_MAX_FILES=5          # max staged files per AI commit
REVIEWER_MAX_INSERTIONS=500   # max inserted lines per AI commit
REVIEWER_APPROVAL_TIMEOUT=300 # seconds before approval expires
```

Leave any command empty (`""`) to skip that check.

## Approval flow

```
AI makes changes
  → AI spawns reviewer agent
  → Reviewer runs tests, checks quality
  → APPROVE: reviewer writes `reviewer-approved` timestamp
  → AI runs git commit
  → Hooks validate the timestamp
  → Commit allowed (flag deleted)
```

The **reviewer agent** writes the approval flag — not the main agent. This integrity separation means the same entity that evaluated the code creates the approval token.

## Bypassing (human commits only)

```bash
USER_COMMIT=1 git commit -m "your message"
```

This skips the reviewer requirement. Only use it for commits you write yourself, not AI-generated code.

## What gets enforced

| Check | Layer | Bypass |
|-------|-------|--------|
| Reviewer approval (presence) | PreToolUse hook | `USER_COMMIT=1` |
| Reviewer approval (expiry) | PreToolUse hook | `USER_COMMIT=1` |
| Commit size (AI only) | Pre-commit hook | `USER_COMMIT=1` |
| Unit tests | Pre-commit hook | `USER_COMMIT=1` |
| Linter | Pre-commit hook | `USER_COMMIT=1` |
| Build | Pre-commit hook | `USER_COMMIT=1` |
| Secrets check | Pre-commit hook | Never |

## Customizing the reviewer

Edit `templates/reviewer-agent.md` to add project-specific checks. The reviewer prompt is designed to be extended — add WordPress nonce checks, Python type hint requirements, or any other standards your project enforces.

## Per-developer setup

`.claude/settings.json` is typically gitignored. Each developer needs to run `install.sh` in their local clone to get the PreToolUse hook. The pre-commit hook and config file can be committed.

## Adapting with Claude

Open the `claude-code-reviewer` directory in Claude Code — the `CLAUDE.md` file explains the structure and lists common customization tasks. Claude can help you adapt the reviewer prompt for your stack, change test commands, add language-specific checks, or debug hook issues.

## License

MIT
