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
# Always prefer /dev/tty so prompts block for real input even in curl | bash.
# /dev/tty is the controlling terminal of the process group; it works even
# when stdin is a pipe. Falls back to defaults (with a notice) only when
# no terminal is reachable at all (CI, containerized env, etc.).
if [ "${REVIEWER_SKIP_PROMPTS:-0}" != "1" ]; then
  if exec 3</dev/tty 2>/dev/null; then
    _TTY_FD=3
    # shellcheck disable=SC2064
    trap "exec 3>&-" EXIT
  elif [ -t 0 ]; then
    _TTY_FD=0
  else
    REVIEWER_SKIP_PROMPTS=1
    echo -e "${YELLOW}Note: no interactive terminal found — using defaults.${NC}"
    echo -e "${YELLOW}      Edit .reviewer-config.sh after install to customise.${NC}"
    echo ""
  fi
fi

# ── Helper ────────────────────────────────────────────────────────────────────
ask() {
  local prompt="$1" default="$2" var="$3" answer
  if [ "${REVIEWER_SKIP_PROMPTS:-0}" = "1" ]; then
    echo -e "${BLUE}?${NC} $prompt ${YELLOW}[$default]${NC} $default"
    printf -v "$var" '%s' "$default"
    return
  fi
  echo -ne "${BLUE}?${NC} $prompt "
  [ -n "$default" ] && echo -ne "${YELLOW}[$default]${NC} "
  read -r -u "$_TTY_FD" answer
  printf -v "$var" '%s' "${answer:-$default}"
}

ask_yn() {
  local prompt="$1" default="$2" var="$3" answer
  if [ "${REVIEWER_SKIP_PROMPTS:-0}" = "1" ]; then
    echo -e "${BLUE}?${NC} $prompt ${YELLOW}[$default]${NC} $default"
    printf -v "$var" '%s' "$default"
    return
  fi
  echo -ne "${BLUE}?${NC} $prompt ${YELLOW}[${default}]${NC} "
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
mkdir -p "$REPO_ROOT/.claude"

# The settings block we need present in the file
_SETTINGS_BLOCK='{
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
}'

if [ ! -f "$SETTINGS_FILE" ]; then
  echo "$_SETTINGS_BLOCK" > "$SETTINGS_FILE"
  echo -e "  ${GREEN}✅ .claude/settings.json created${NC}"
elif command -v jq >/dev/null 2>&1; then
  # Merge into existing file:
  #   permissions.allow → union (no duplicates)
  #   hooks.PreToolUse  → append our entry only if our command isn't already registered
  jq --argjson new "$_SETTINGS_BLOCK" '
    .permissions.allow = ((.permissions.allow // []) + $new.permissions.allow | unique) |
    if (.hooks.PreToolUse // []) | any(
      .matcher == "Bash" and
      (.hooks // [] | any(.command == "node .claude/helpers/hook-handler.cjs pre-bash"))
    )
    then .
    else .hooks.PreToolUse = ((.hooks.PreToolUse // []) + $new.hooks.PreToolUse)
    end
  ' "$SETTINGS_FILE" > "$SETTINGS_FILE.tmp" && mv "$SETTINGS_FILE.tmp" "$SETTINGS_FILE"
  echo -e "  ${GREEN}✅ .claude/settings.json merged${NC}"
else
  echo -e "  ${YELLOW}⚠️  .claude/settings.json already exists and jq is not available.${NC}"
  echo "     Install jq for automatic merging, or merge manually:"
  echo "     See templates/settings-addition.json for what to add"
fi

# ── CLAUDE.md ─────────────────────────────────────────────────────────────────
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && grep -q "Pre-Commit Reviewer Workflow" "$CLAUDE_MD" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠️  CLAUDE.md already has reviewer workflow block — skipping${NC}"
else
  # Extract content between ```markdown and closing ``` fences, then prepend
  _block=$(awk '/^```markdown$/{f=1; next} f && /^```$/{f=0; next} f{print}' \
    "$TEMPLATES_SRC/claude-md-block.md")
  if [ -f "$CLAUDE_MD" ]; then
    _existing=$(cat "$CLAUDE_MD")
    printf '%s\n\n%s\n' "$_block" "$_existing" > "$CLAUDE_MD"
  else
    printf '%s\n' "$_block" > "$CLAUDE_MD"
  fi
  echo -e "  ${GREEN}✅ Reviewer workflow block prepended to CLAUDE.md${NC}"
fi

# ── AGENTS.md ─────────────────────────────────────────────────────────────────
AGENTS_MD="$REPO_ROOT/AGENTS.md"
if [ -f "$AGENTS_MD" ] && grep -q "Reviewer Agent Instructions" "$AGENTS_MD" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠️  AGENTS.md already has reviewer agent — skipping${NC}"
else
  # Skip the human-facing preamble (before and including the first ---), then prepend
  _block=$(awk '/^---$/{if(!f){f=1; next}} f{print}' \
    "$TEMPLATES_SRC/reviewer-agent.md")
  if [ -f "$AGENTS_MD" ]; then
    _existing=$(cat "$AGENTS_MD")
    printf '%s\n\n%s\n' "$_block" "$_existing" > "$AGENTS_MD"
  else
    printf '%s\n' "$_block" > "$AGENTS_MD"
  fi
  echo -e "  ${GREEN}✅ Reviewer agent prompt prepended to AGENTS.md${NC}"
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
