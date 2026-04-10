#!/usr/bin/env bash
# install.sh — claude-code-reviewer setup
# Source: https://github.com/jazzsequence/claude-code-reviewer
#
# Usage:
#   ./install.sh                  # interactive
#   REVIEWER_SKIP_PROMPTS=1 ./install.sh  # non-interactive (uses defaults)
#
# Or via curl (replace URL with your fork/tag):
#   curl -sSL https://raw.githubusercontent.com/jazzsequence/claude-code-reviewer/main/install.sh | bash

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"

echo ""
echo -e "${BOLD}🔍 claude-code-reviewer installer${NC}"
echo "=================================="
echo ""

# ── TTY setup ─────────────────────────────────────────────────────────────────
# Open a dedicated fd pointing at the real terminal so read blocks for user
# input even when stdin is a pipe (curl | bash). /dev/tty is the controlling
# terminal of the process group and is available in curl-pipe context.
# Falls back to defaults silently when no terminal exists (CI, etc.).
if [ "${REVIEWER_SKIP_PROMPTS:-0}" != "1" ]; then
  if [ -t 0 ]; then
    _TTY_FD=0
  elif exec 3</dev/tty 2>/dev/null; then
    _TTY_FD=3
    # shellcheck disable=SC2064
    trap "exec 3>&-" EXIT
  else
    REVIEWER_SKIP_PROMPTS=1
  fi
fi

# ── Helper ────────────────────────────────────────────────────────────────────
ask() {
  local prompt="$1" default="$2" var="$3" answer
  echo -ne "${BLUE}?${NC} $prompt "
  [ -n "$default" ] && echo -ne "${YELLOW}[$default]${NC} "
  if [ "${REVIEWER_SKIP_PROMPTS:-0}" = "1" ]; then
    echo "$default"
    printf -v "$var" '%s' "$default"
    return
  fi
  read -r -u "$_TTY_FD" answer
  printf -v "$var" '%s' "${answer:-$default}"
}

ask_yn() {
  local prompt="$1" default="$2" var="$3" answer
  echo -ne "${BLUE}?${NC} $prompt ${YELLOW}[${default}]${NC} "
  if [ "${REVIEWER_SKIP_PROMPTS:-0}" = "1" ]; then
    echo "$default"
    printf -v "$var" '%s' "$default"
    return
  fi
  read -r -u "$_TTY_FD" answer
  answer="${answer:-$default}"
  printf -v "$var" '%s' "$answer"
}

# ── Gather config ─────────────────────────────────────────────────────────────
echo "Let's configure the reviewer workflow for this project."
echo ""

ask "Unit test command:" "npm test -- --run" TEST_CMD
ask "Lint command:" "npm run lint" LINT_CMD
ask "Build command:" "npm run build" BUILD_CMD
ask_yn "Run E2E tests? (y/n)" "n" RUN_E2E

if [[ "$RUN_E2E" =~ ^[Yy] ]]; then
  ask "E2E test command:" "npm run test:e2e" E2E_CMD
else
  E2E_CMD=""
fi

ask "Max staged files per AI commit:" "5" MAX_FILES
ask "Max inserted lines per AI commit:" "500" MAX_INSERTIONS
ask "Approval timeout (seconds):" "300" TIMEOUT

echo ""
echo "Configuration:"
echo "  Test:         ${TEST_CMD:-<skip>}"
echo "  Lint:         ${LINT_CMD:-<skip>}"
echo "  Build:        ${BUILD_CMD:-<skip>}"
echo "  E2E:          ${E2E_CMD:-<skip>}"
echo "  Max files:    $MAX_FILES"
echo "  Max lines:    $MAX_INSERTIONS"
echo "  Timeout:      ${TIMEOUT}s"
echo ""

if [ "${REVIEWER_SKIP_PROMPTS:-0}" != "1" ]; then
  echo -ne "${BLUE}?${NC} Proceed with installation? ${YELLOW}[Y/n]${NC} "
  read -r -u "$_TTY_FD" confirm
  if [[ "$confirm" =~ ^[Nn] ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# ── Install hooks ─────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Installing hooks...${NC}"

# Determine source directory
if [ -d "$SCRIPT_DIR/hooks" ]; then
  HOOKS_SRC="$SCRIPT_DIR/hooks"
  HELPERS_SRC="$SCRIPT_DIR/helpers"
  TEMPLATES_SRC="$SCRIPT_DIR/templates"
else
  # Running via curl — download files
  echo "  Downloading hook files..."
  TMP_DIR=$(mktemp -d)
  BASE_URL="${REVIEWER_BASE_URL:-https://raw.githubusercontent.com/jazzsequence/claude-code-reviewer/main}"

  curl -sSL "$BASE_URL/hooks/pre-commit"                -o "$TMP_DIR/pre-commit"
  curl -sSL "$BASE_URL/helpers/hook-handler.cjs"        -o "$TMP_DIR/hook-handler.cjs"
  curl -sSL "$BASE_URL/templates/reviewer-config.sh"    -o "$TMP_DIR/reviewer-config.sh"
  curl -sSL "$BASE_URL/templates/claude-md-block.md"    -o "$TMP_DIR/claude-md-block.md"
  curl -sSL "$BASE_URL/templates/reviewer-agent.md"     -o "$TMP_DIR/reviewer-agent.md"

  HOOKS_SRC="$TMP_DIR"
  HELPERS_SRC="$TMP_DIR"
  TEMPLATES_SRC="$TMP_DIR"
fi

# Copy git hook
mkdir -p "$REPO_ROOT/.githooks"
cp "$HOOKS_SRC/pre-commit" "$REPO_ROOT/.githooks/pre-commit"
chmod +x "$REPO_ROOT/.githooks/pre-commit"

# Install to .git/hooks
cp "$REPO_ROOT/.githooks/pre-commit" "$REPO_ROOT/.git/hooks/pre-commit"
chmod +x "$REPO_ROOT/.git/hooks/pre-commit"

echo -e "  ${GREEN}✅ pre-commit hook installed${NC}"

# Copy Claude Code hook handler
mkdir -p "$REPO_ROOT/.claude/helpers"
cp "$HELPERS_SRC/hook-handler.cjs" "$REPO_ROOT/.claude/helpers/hook-handler.cjs"
chmod +x "$REPO_ROOT/.claude/helpers/hook-handler.cjs"

echo -e "  ${GREEN}✅ hook-handler.cjs installed${NC}"

# ── Generate .reviewer-config.sh ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}Generating .reviewer-config.sh...${NC}"

cat > "$REPO_ROOT/.reviewer-config.sh" <<EOF
# .reviewer-config.sh — claude-code-reviewer configuration
# Generated by install.sh on $(date '+%Y-%m-%d')
# Edit to match your project. Source: https://github.com/jazzsequence/claude-code-reviewer

REVIEWER_TEST_CMD="${TEST_CMD}"
REVIEWER_LINT_CMD="${LINT_CMD}"
REVIEWER_BUILD_CMD="${BUILD_CMD}"
REVIEWER_E2E_CMD="${E2E_CMD}"

REVIEWER_MAX_FILES=${MAX_FILES}
REVIEWER_MAX_INSERTIONS=${MAX_INSERTIONS}
REVIEWER_APPROVAL_TIMEOUT=${TIMEOUT}
REVIEWER_APPROVAL_FILE="reviewer-approved"

REVIEWER_TEXT_ONLY_PATTERN='\.(md|txt|rst)$'
REVIEWER_EXCLUDED_FILES='^package-lock\.json\$|^yarn\.lock\$|^pnpm-lock\.yaml\$|^composer\.lock\$|^Gemfile\.lock\$'
EOF

echo -e "  ${GREEN}✅ .reviewer-config.sh created${NC}"

# ── .gitignore ────────────────────────────────────────────────────────────────
GITIGNORE="$REPO_ROOT/.gitignore"
if [ -f "$GITIGNORE" ]; then
  if ! grep -q "reviewer-approved" "$GITIGNORE"; then
    echo "" >> "$GITIGNORE"
    echo "# claude-code-reviewer approval flag" >> "$GITIGNORE"
    echo "reviewer-approved" >> "$GITIGNORE"
    echo -e "  ${GREEN}✅ Added reviewer-approved to .gitignore${NC}"
  fi
fi

# ── .claude/settings.json ─────────────────────────────────────────────────────
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
if [ ! -f "$SETTINGS_FILE" ]; then
  mkdir -p "$REPO_ROOT/.claude"
  cat > "$SETTINGS_FILE" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(git commit*)",
      "Bash(git add*)",
      "Bash(date*)",
      "Write(*)",
      "Agent(subagent_type=reviewer)"
    ]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node .claude/helpers/hook-handler.cjs pre-bash",
            "timeout": 5000
          }
        ]
      }
    ]
  }
}
EOF
  echo -e "  ${GREEN}✅ .claude/settings.json created${NC}"
else
  echo -e "  ${YELLOW}⚠️  .claude/settings.json already exists — merge manually:${NC}"
  echo "     See templates/settings-addition.json for what to add"
fi

# ── CLAUDE.md ─────────────────────────────────────────────────────────────────
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && grep -q "Pre-Commit Reviewer Workflow" "$CLAUDE_MD" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠️  CLAUDE.md already has reviewer workflow block — skipping${NC}"
else
  # Extract content between ```markdown and closing ``` fences
  echo "" >> "$CLAUDE_MD"
  awk '/^```markdown$/{f=1; next} f && /^```$/{f=0; next} f{print}' \
    "$TEMPLATES_SRC/claude-md-block.md" >> "$CLAUDE_MD"
  echo -e "  ${GREEN}✅ Reviewer workflow block appended to CLAUDE.md${NC}"
fi

# ── AGENTS.md ─────────────────────────────────────────────────────────────────
AGENTS_MD="$REPO_ROOT/AGENTS.md"
if [ -f "$AGENTS_MD" ] && grep -q "Reviewer Agent Instructions" "$AGENTS_MD" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠️  AGENTS.md already has reviewer agent — skipping${NC}"
else
  # Skip the human-facing preamble (before and including the first ---)
  echo "" >> "$AGENTS_MD"
  awk '/^---$/{if(!f){f=1; next}} f{print}' \
    "$TEMPLATES_SRC/reviewer-agent.md" >> "$AGENTS_MD"
  echo -e "  ${GREEN}✅ Reviewer agent prompt appended to AGENTS.md${NC}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=================================="
echo -e "${BOLD}${GREEN}✅ Installation complete!${NC}"
echo ""
echo -e "${BOLD}Next steps:${NC}"
echo ""
echo "1. Test that the hook blocks commits correctly:"
echo "   echo 'test' >> README.md"
echo "   git add README.md"
echo "   git commit -m 'test'   # should be BLOCKED"
echo "   USER_COMMIT=1 git commit -m 'test'  # should pass"
echo "   git reset HEAD~1 && git checkout README.md"
echo ""
echo "2. Optional — commit the config:"
echo "   git add .githooks/pre-commit .reviewer-config.sh .claude/helpers/hook-handler.cjs"
echo "   git add CLAUDE.md AGENTS.md"
echo "   USER_COMMIT=1 git commit -m 'chore: add claude-code-reviewer workflow'"
echo ""
echo -e "${YELLOW}Note:${NC} .claude/settings.json is typically gitignored."
echo "Each developer runs install.sh in their local clone."
echo ""
