#!/usr/bin/env node
/**
 * PreToolUse hook handler for claude-code-reviewer
 * Source: https://github.com/jazzsequence/claude-code-reviewer
 *
 * Intercepts git commit Bash calls in Claude Code and validates reviewer
 * approval before the command executes. This is Layer 1 enforcement —
 * it fires before git even starts, giving clearer error messages than the
 * pre-commit hook alone.
 *
 * Configure via .reviewer-config.sh in the project root.
 * Install via .claude/settings.json (see templates/settings-addition.json).
 */

'use strict';

const fs = require('fs');
const path = require('path');

// ── Read project config ───────────────────────────────────────────────────────
// Defaults match the pre-commit hook defaults
const CONFIG = {
  approvalFile: 'reviewer-approved',
  approvalTimeout: 300, // seconds
};

// Try to load shell config — parse KEY="value" lines only
const configPath = path.join(process.cwd(), '.reviewer-config.sh');
if (fs.existsSync(configPath)) {
  const raw = fs.readFileSync(configPath, 'utf8');
  const fileMatch = raw.match(/^REVIEWER_APPROVAL_FILE="?([^"\n]+)"?/m);
  const timeoutMatch = raw.match(/^REVIEWER_APPROVAL_TIMEOUT="?(\d+)"?/m);
  if (fileMatch) CONFIG.approvalFile = fileMatch[1].trim();
  if (timeoutMatch) CONFIG.approvalTimeout = parseInt(timeoutMatch[1], 10);
}

// ── Main ─────────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);

if (args[0] === 'pre-bash') {
  let toolInput;
  try {
    const stdin = fs.readFileSync(0, 'utf8');
    toolInput = JSON.parse(stdin);
  } catch {
    // Not JSON or no stdin — not a Bash tool call, allow it
    process.exit(0);
  }

  const cmd = (toolInput.command || '').trim();

  if (cmd.includes('git commit')) {
    const isUserCommit = process.env.USER_COMMIT === '1';

    if (isUserCommit) {
      console.log('[OK] User commit (bypassing reviewer requirement)');
      process.exit(0);
    }

    const approvalFile = path.join(process.cwd(), CONFIG.approvalFile);

    if (!fs.existsSync(approvalFile)) {
      console.error('[BLOCKED] No reviewer approval found');
      console.error('');
      console.error('Before committing AI-generated code:');
      console.error('  1. Spawn reviewer agent with Claude Code Agent tool');
      console.error('  2. Get APPROVE decision from the agent');
      console.error('  3. Reviewer writes the approval flag');
      console.error(`  4. Commit within ${CONFIG.approvalTimeout}s`);
      console.error('');
      console.error('For your own manual commits:');
      console.error('  USER_COMMIT=1 git commit -m "message"');
      process.exit(1);
    }

    const raw = fs.readFileSync(approvalFile, 'utf8').trim();
    const approvalTime = parseInt(raw, 10);

    if (isNaN(approvalTime) || approvalTime <= 0) {
      console.error('[BLOCKED] Approval file is corrupted (invalid timestamp)');
      console.error('  Delete reviewer-approved and get a fresh approval.');
      process.exit(1);
    }

    const currentTime = Math.floor(Date.now() / 1000);
    const timeDiff = currentTime - approvalTime;

    if (timeDiff >= CONFIG.approvalTimeout) {
      console.error(`[BLOCKED] Reviewer approval expired (${timeDiff}s old, max ${CONFIG.approvalTimeout}s)`);
      console.error('');
      console.error('Spawn the reviewer agent again and get a fresh approval.');
      process.exit(1);
    }

    console.log(`[OK] Reviewer approved (${timeDiff}s ago)`);
    process.exit(0);
  }

  // Not a git commit — allow through
  console.log('[OK] Command validated');
  process.exit(0);
}

console.error('[ERROR] Unknown hook command:', args[0]);
process.exit(1);
