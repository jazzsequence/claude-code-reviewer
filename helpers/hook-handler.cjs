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
const { spawnSync } = require('child_process');
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

  // USER_COMMIT is a human-only escape hatch — AI agents must never use it
  if (cmd.includes('USER_COMMIT')) {
    console.error('[BLOCKED] USER_COMMIT is reserved for human use only — AI agents must not use it.');
    console.error('');
    console.error('This bypass exists so humans can commit without reviewer approval.');
    console.error('AI-generated code must go through the reviewer agent before committing.');
    process.exit(2);  // 2 = block the tool call
  }

  if (cmd.includes('git commit')) {
    const isUserCommit = process.env.USER_COMMIT === '1';

    if (isUserCommit) {
      console.log('[OK] User commit (bypassing reviewer requirement)');
      process.exit(0);
    }

    const approvalFile = path.join(process.cwd(), CONFIG.approvalFile);

    // Delegate to lib/approval.sh — the SAME code the git hook runs. This file is
    // gitignored in consuming projects, so it can never be reviewed or shipped; while
    // it reimplemented the checks in JS the two drifted repeatedly. One implementation
    // makes parity structural rather than maintained.
    //
    // `peek`, not `check`: peek does not consume the flag. This runs BEFORE git commit,
    // so consuming here would make the commit that follows fail with "no approval found".
    const libPath = path.join(process.cwd(), '.githooks', 'lib', 'approval.sh');

    if (!fs.existsSync(libPath)) {
      console.error('[BLOCKED] .githooks/lib/approval.sh is missing');
      console.error('  Re-run install.sh to repair the hook installation.');
      process.exit(2);
    }

    const result = spawnSync(
      'bash',
      [libPath, 'peek', approvalFile, String(CONFIG.approvalTimeout)],
      { encoding: 'utf8' }
    );

    // An advisory layer reporting "looks fine" when it could not actually check is
    // worse than one reporting nothing — the misleading pass is the harm. The git hook
    // re-checks at commit time regardless.
    if (result.error || typeof result.status !== 'number') {
      console.error('[BLOCKED] Could not verify reviewer approval');
      console.error('  ' + (result.error ? result.error.message : 'no exit status'));
      console.error('  The git hook will re-check at commit time.');
      process.exit(2);
    }

    if (result.status !== 0) {
      process.stderr.write(result.stdout || '');
      process.stderr.write(result.stderr || '');
      process.exit(2);
    }

    process.stdout.write(result.stdout || '');
    console.log(`[OK] Reviewer approved (${timeDiff}s ago)`);
    process.exit(0);
  }

  // Not a git commit — allow through
  console.log('[OK] Command validated');
  process.exit(0);
}

console.error('[ERROR] Unknown hook command:', args[0]);
process.exit(1);
