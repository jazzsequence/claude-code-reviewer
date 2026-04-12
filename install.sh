#!/usr/bin/env bash
# install.sh — claude-code-reviewer setup
# Source: https://github.com/jazzsequence/claude-code-reviewer
#
# Usage:
#   ./install.sh                  # interactive (first install or update)
#   REVIEWER_SKIP_PROMPTS=1 ./install.sh  # non-interactive (uses defaults)
#
# Re-running is safe: managed files update automatically if unmodified,
# customised files are preserved with a diff showing what changed upstream.
#
# Or via curl:
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
MANIFEST="$REPO_ROOT/.reviewer-manifest"

echo ""
echo -e "${BOLD}🔍 claude-code-reviewer installer${NC}"
echo "=================================="
echo ""

# ── TTY setup ─────────────────────────────────────────────────────────────────
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

# ── Prompt helpers ─────────────────────────────────────────────────────────────
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
  printf -v "$var" '%s' "${answer:-$default}"
}

# ── Manifest helpers ──────────────────────────────────────────────────────────
# Hash a file cross-platform (sha256 preferred, md5 fallback)
_hash() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q "$file"
  else
    md5sum "$file" | awk '{print $1}'
  fi
}

# Read stored hash for a file (keyed by path relative to REPO_ROOT)
_manifest_hash() {
  local relpath="${1#"$REPO_ROOT"/}"
  grep -m1 "^${relpath}:" "$MANIFEST" 2>/dev/null | cut -d: -f2-
}

# Write hash to manifest
_manifest_set() {
  local dest="$1" hash="$2"
  local relpath="${dest#"$REPO_ROOT"/}"
  touch "$MANIFEST"
  { grep -v "^${relpath}:" "$MANIFEST" 2>/dev/null || true; } > "$MANIFEST.tmp"
  echo "${relpath}:${hash}" >> "$MANIFEST.tmp"
  mv "$MANIFEST.tmp" "$MANIFEST"
}

# ── Managed file installer ────────────────────────────────────────────────────
# Files we fully own. On re-run:
#   - unchanged from last install → update to new version automatically
#   - modified by user            → skip, show diff of upstream changes
#   - not in manifest             → skip if file exists (untracked), install if absent
#
# Args: src dest description [executable=false]
install_managed() {
  local src="$1" dest="$2" desc="$3" executable="${4:-false}"
  local new_hash current_hash installed_hash

  new_hash=$(_hash "$src")

  if [ ! -f "$dest" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    [ "$executable" = "true" ] && chmod +x "$dest"
    _manifest_set "$dest" "$new_hash"
    echo -e "  ${GREEN}✅ $desc installed${NC}"
    return
  fi

  current_hash=$(_hash "$dest")

  if [ "$current_hash" = "$new_hash" ]; then
    # Already at the latest version — just ensure it's in the manifest
    _manifest_set "$dest" "$new_hash"
    echo -e "  ${GREEN}✅ $desc already up to date${NC}"
    return
  fi

  installed_hash=$(_manifest_hash "$dest")

  if [ -z "$installed_hash" ]; then
    # File exists but was never tracked (pre-manifest install or manual)
    echo -e "  ${YELLOW}⚠️  $desc exists but is untracked — skipping${NC}"
    echo "     Remove it and re-run install.sh to get the latest version."
    return
  fi

  if [ "$current_hash" = "$installed_hash" ]; then
    # No local changes — safe to update
    cp "$src" "$dest"
    [ "$executable" = "true" ] && chmod +x "$dest"
    _manifest_set "$dest" "$new_hash"
    echo -e "  ${GREEN}✅ $desc updated${NC}"
  else
    # Local modifications — preserve, show what changed upstream
    echo -e "  ${YELLOW}⚠️  $desc has local changes — skipping${NC}"
    echo "     Upstream changes you may want to merge:"
    diff "$dest" "$src" 2>/dev/null | grep '^[<>]' | head -20 | sed 's/^/     /' || true
    echo ""
  fi
}

# ── User-editable file handler ────────────────────────────────────────────────
# For files the user is expected to customise (.reviewer-config.sh,
# docs/REVIEWER_CHECKLIST.md). We never overwrite them, but on re-run we
# generate the new template version and show what's different so the user
# can manually merge any upstream improvements.
#
# Args: current new_version_file description
check_user_editable() {
  local current="$1" new_file="$2" desc="$3"
  [ ! -f "$current" ] && return  # handled by install step below

  if diff -q "$current" "$new_file" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✅ $desc already current${NC}"
  else
    echo -e "  ${YELLOW}⚠️  $desc has been customised — preserving your version${NC}"
    echo "     New template differs here (your file on left, new template on right):"
    diff "$current" "$new_file" 2>/dev/null | head -25 | sed 's/^/     /' || true
    echo "     Merge manually if you want upstream improvements."
    echo ""
  fi
}

# ── Gather config ──────────────────────────────────────────────────────────────
# On re-run, load existing config as defaults so the user can just press Enter
# to keep their current values.
if [ -f "$REPO_ROOT/.reviewer-config.sh" ]; then
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.reviewer-config.sh"
  _DEFAULT_TEST="${REVIEWER_TEST_CMD:-npm test -- --run}"
  _DEFAULT_LINT="${REVIEWER_LINT_CMD:-npm run lint}"
  _DEFAULT_BUILD="${REVIEWER_BUILD_CMD:-npm run build}"
  _DEFAULT_E2E="${REVIEWER_E2E_CMD:-}"
  _DEFAULT_FILES="${REVIEWER_MAX_FILES:-5}"
  _DEFAULT_LINES="${REVIEWER_MAX_INSERTIONS:-500}"
  _DEFAULT_TIMEOUT="${REVIEWER_APPROVAL_TIMEOUT:-300}"
  echo "Existing configuration detected. Press Enter to keep current values."
else
  _DEFAULT_TEST="npm test -- --run"
  _DEFAULT_LINT="npm run lint"
  _DEFAULT_BUILD="npm run build"
  _DEFAULT_E2E=""
  _DEFAULT_FILES="5"
  _DEFAULT_LINES="500"
  _DEFAULT_TIMEOUT="300"
  echo "Let's configure the reviewer workflow for this project."
fi
echo ""

ask "Unit test command:" "$_DEFAULT_TEST" TEST_CMD
ask "Lint command:" "$_DEFAULT_LINT" LINT_CMD
ask "Build command:" "$_DEFAULT_BUILD" BUILD_CMD
ask_yn "Run E2E tests? (y/n)" "${_DEFAULT_E2E:+y}" RUN_E2E

if [[ "$RUN_E2E" =~ ^[Yy] ]]; then
  ask "E2E test command:" "${_DEFAULT_E2E:-npm run test:e2e}" E2E_CMD
else
  E2E_CMD=""
fi

ask "Max staged files per AI commit:" "$_DEFAULT_FILES" MAX_FILES
ask "Max inserted lines per AI commit:" "$_DEFAULT_LINES" MAX_INSERTIONS
ask "Approval timeout (seconds):" "$_DEFAULT_TIMEOUT" TIMEOUT

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

# ── Resolve source files ──────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}Installing / updating files...${NC}"

if [ -d "$SCRIPT_DIR/hooks" ]; then
  HOOKS_SRC="$SCRIPT_DIR/hooks"
  HELPERS_SRC="$SCRIPT_DIR/helpers"
  TEMPLATES_SRC="$SCRIPT_DIR/templates"
else
  echo "  Downloading files..."
  TMP_DIR=$(mktemp -d)
  BASE_URL="${REVIEWER_BASE_URL:-https://raw.githubusercontent.com/jazzsequence/claude-code-reviewer/main}"
  curl -sSL "$BASE_URL/hooks/pre-commit"                -o "$TMP_DIR/pre-commit"
  curl -sSL "$BASE_URL/helpers/hook-handler.cjs"        -o "$TMP_DIR/hook-handler.cjs"
  curl -sSL "$BASE_URL/templates/reviewer-config.sh"    -o "$TMP_DIR/reviewer-config.sh"
  curl -sSL "$BASE_URL/templates/claude-md-block.md"    -o "$TMP_DIR/claude-md-block.md"
  curl -sSL "$BASE_URL/templates/reviewer-agent.md"     -o "$TMP_DIR/reviewer-agent.md"
  curl -sSL "$BASE_URL/templates/reviewer.md"           -o "$TMP_DIR/reviewer.md"
  curl -sSL "$BASE_URL/templates/REVIEWER_CHECKLIST.md" -o "$TMP_DIR/REVIEWER_CHECKLIST.md"
  HOOKS_SRC="$TMP_DIR"
  HELPERS_SRC="$TMP_DIR"
  TEMPLATES_SRC="$TMP_DIR"
fi

# Prepare a temp directory for generated files (substitutions applied)
GEN_DIR=$(mktemp -d)
trap 'rm -rf "$GEN_DIR"' EXIT

# ── pre-commit hook ───────────────────────────────────────────────────────────
cp "$HOOKS_SRC/pre-commit" "$GEN_DIR/pre-commit"
chmod +x "$GEN_DIR/pre-commit"

mkdir -p "$REPO_ROOT/.githooks"
install_managed "$GEN_DIR/pre-commit" "$REPO_ROOT/.githooks/pre-commit" "pre-commit hook" true

# Always sync .git/hooks from .githooks (not manifest-tracked — derived file)
cp "$REPO_ROOT/.githooks/pre-commit" "$REPO_ROOT/.git/hooks/pre-commit"
chmod +x "$REPO_ROOT/.git/hooks/pre-commit"

# ── hook-handler.cjs ─────────────────────────────────────────────────────────
cp "$HELPERS_SRC/hook-handler.cjs" "$GEN_DIR/hook-handler.cjs"
install_managed "$GEN_DIR/hook-handler.cjs" \
  "$REPO_ROOT/.claude/helpers/hook-handler.cjs" "hook-handler.cjs" true

# ── .claude/agents/reviewer.md ───────────────────────────────────────────────
# Substitute {{PROJECT_ROOT}} so the approval flag path is unambiguous.
sed "s|{{PROJECT_ROOT}}|$REPO_ROOT|g" "$TEMPLATES_SRC/reviewer.md" \
  > "$GEN_DIR/reviewer.md"
mkdir -p "$REPO_ROOT/.claude/agents"
install_managed "$GEN_DIR/reviewer.md" \
  "$REPO_ROOT/.claude/agents/reviewer.md" ".claude/agents/reviewer.md"

# ── .reviewer-config.sh ──────────────────────────────────────────────────────
cat > "$GEN_DIR/reviewer-config.sh" <<EOF
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

if [ ! -f "$REPO_ROOT/.reviewer-config.sh" ]; then
  cp "$GEN_DIR/reviewer-config.sh" "$REPO_ROOT/.reviewer-config.sh"
  echo -e "  ${GREEN}✅ .reviewer-config.sh created${NC}"
else
  check_user_editable "$REPO_ROOT/.reviewer-config.sh" \
    "$GEN_DIR/reviewer-config.sh" ".reviewer-config.sh"
fi

# ── docs/REVIEWER_CHECKLIST.md ───────────────────────────────────────────────
if [ -n "$E2E_CMD" ]; then
  _E2E_ITEM="4. E2E tests pass (\`$E2E_CMD\`) — run LAST; read output directly, not hook summary"
else
  _E2E_ITEM="4. ⏭️ E2E: not configured for this project"
fi

sed \
  -e "s|{{TEST_CMD}}|$TEST_CMD|g" \
  -e "s|{{LINT_CMD}}|$LINT_CMD|g" \
  -e "s|{{BUILD_CMD}}|$BUILD_CMD|g" \
  -e "s|{{E2E_CMD}}|${E2E_CMD:-<not configured>}|g" \
  -e "s|{{E2E_ITEM}}|$_E2E_ITEM|g" \
  -e "s|{{PROJECT_ROOT}}|$REPO_ROOT|g" \
  -e "s|{{FILE_ORG_ITEMS}}|5. No stray files created in repo root (config files are the exception)|g" \
  -e "s|{{CODE_QUALITY_NUM}}|6|g" \
  -e "s|{{CODE_QUALITY_NUM_PLUS1}}|7|g" \
  -e "s|{{SECURITY_NUM}}|8|g" \
  -e "s|{{SECURITY_NUM_PLUS1}}|9|g" \
  -e "s|{{GIT_NUM}}|10|g" \
  -e "s|{{GIT_NUM_PLUS1}}|11|g" \
  -e "s|{{GIT_NUM_PLUS2}}|12|g" \
  -e "s|{{TDD_NUM}}|13|g" \
  -e "s|{{TDD_NUM_PLUS1}}|14|g" \
  -e "s|{{DEP_NUM}}|15|g" \
  -e "s|{{REVIEWER_APPROVAL_FILE}}|$REPO_ROOT/reviewer-approved|g" \
  "$TEMPLATES_SRC/REVIEWER_CHECKLIST.md" > "$GEN_DIR/REVIEWER_CHECKLIST.md"

mkdir -p "$REPO_ROOT/docs"
if [ ! -f "$REPO_ROOT/docs/REVIEWER_CHECKLIST.md" ]; then
  cp "$GEN_DIR/REVIEWER_CHECKLIST.md" "$REPO_ROOT/docs/REVIEWER_CHECKLIST.md"
  echo -e "  ${GREEN}✅ docs/REVIEWER_CHECKLIST.md generated${NC}"
else
  check_user_editable "$REPO_ROOT/docs/REVIEWER_CHECKLIST.md" \
    "$GEN_DIR/REVIEWER_CHECKLIST.md" "docs/REVIEWER_CHECKLIST.md"
fi

# ── .gitignore ────────────────────────────────────────────────────────────────
GITIGNORE="$REPO_ROOT/.gitignore"
if [ -f "$GITIGNORE" ] && ! grep -q "reviewer-approved" "$GITIGNORE"; then
  printf '\n# claude-code-reviewer approval flag\nreviewer-approved\n' >> "$GITIGNORE"
  echo -e "  ${GREEN}✅ Added reviewer-approved to .gitignore${NC}"
fi

# ── .claude/settings.json ─────────────────────────────────────────────────────
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
mkdir -p "$REPO_ROOT/.claude"
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
  echo -e "  ${YELLOW}⚠️  .claude/settings.json exists and jq is unavailable — merge manually${NC}"
  echo "     See templates/settings-addition.json"
fi

# ── CLAUDE.md ─────────────────────────────────────────────────────────────────
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
if [ -f "$CLAUDE_MD" ] && grep -q "Pre-Commit Reviewer Workflow" "$CLAUDE_MD" 2>/dev/null; then
  echo -e "  ${YELLOW}⚠️  CLAUDE.md already has reviewer block — skipping${NC}"
else
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
  echo -e "  ${YELLOW}⚠️  AGENTS.md already has reviewer block — skipping${NC}"
else
  _block=$(awk '/^---$/{if(!f){f=1; next}} f{print}' "$TEMPLATES_SRC/reviewer-agent.md")
  if [ -f "$AGENTS_MD" ]; then
    _existing=$(cat "$AGENTS_MD")
    printf '%s\n\n%s\n' "$_block" "$_existing" > "$AGENTS_MD"
  else
    printf '%s\n' "$_block" > "$AGENTS_MD"
  fi
  echo -e "  ${GREEN}✅ Reviewer agent block prepended to AGENTS.md${NC}"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "=================================="
echo -e "${BOLD}${GREEN}✅ Done!${NC}"
echo ""

if [ -f "$MANIFEST" ] && grep -qv "^#" "$MANIFEST" 2>/dev/null; then
  echo -e "${BOLD}Re-run anytime${NC} to pick up upstream updates to managed files."
  echo "Customised files (.reviewer-config.sh, docs/REVIEWER_CHECKLIST.md) are always preserved."
  echo ""
else
  echo -e "${BOLD}Next steps:${NC}"
  echo ""
  echo "1. Test that the hook blocks commits:"
  echo "   echo 'test' >> README.md && git add README.md"
  echo "   git commit -m 'test'              # should be BLOCKED"
  echo "   USER_COMMIT=1 git commit -m 'test'  # should pass"
  echo "   git reset HEAD~1 && git checkout README.md"
  echo ""
  echo "2. Commit the installed files:"
  echo "   git add .githooks/pre-commit .reviewer-config.sh .reviewer-manifest"
  echo "   git add .claude/helpers/hook-handler.cjs"
  echo "   git add docs/REVIEWER_CHECKLIST.md CLAUDE.md AGENTS.md"
  echo "   USER_COMMIT=1 git commit -m 'chore: add claude-code-reviewer workflow'"
  echo ""
fi

echo -e "${YELLOW}Note:${NC} .claude/settings.json and .claude/agents/ are typically gitignored."
echo "Each developer runs install.sh in their own clone."
echo ""
