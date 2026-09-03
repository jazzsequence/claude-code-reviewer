#!/usr/bin/env bash
# approval.sh — reviewer approval flag validation.
#
# ONE implementation, used by both enforcement layers:
#   Layer 1  helpers/hook-handler.cjs  (PreToolUse, advisory, gitignored)
#   Layer 2  hooks/pre-commit              (git hook, gates the commit)
#
# Layer 1 is gitignored, so it can never be shipped or reviewed. Previously each
# layer reimplemented these checks, and keeping them in agreement was manual: the
# two drifted on leading whitespace, on interior whitespace, on parseInt leniency,
# and on whether a UTF-8 BOM counts as whitespace. Every one of those was a case
# where the advisory layer accepted a flag the gate rejected, or vice versa. Sourcing
# this file from both makes parity structural instead of maintained.
#
# Usage — sourced:
#     source "$(git rev-parse --show-toplevel)/hooks/lib/approval.sh"
#     reviewer_validate_approval "$APPROVAL_FILE" "$TIMEOUT" || exit 1
#
# Usage — executed (how Layer 1 calls it):
#     bash hooks/lib/approval.sh check [approval_file] [timeout]
#     # exit 0 = valid, 1 = rejected. Messages on stdout/stderr.
#
# APPROVAL FLAG FORMAT (v2):
#
#     <unix-timestamp> <index-fingerprint>
#
# The fingerprint binds the approval to the exact staged content. Without it the
# gate only ever answered "did someone approve recently", never "did someone approve
# THIS" — so any unconsumed flag authorised whatever happened to be staged next.
# That is not hypothetical: a reviewer issuing a flag and the agent then restaging
# produces a commit that looks approved and was not.
#
# v1 flags (bare timestamp) are REJECTED, not grandfathered. An accepted v1 flag is
# the same hole wearing a different hat, and the reviewer agent is the component that
# writes the flag — so this is a coordinated upgrade, not a third-party break. The
# remedy is one step: re-run the reviewer.

# Colours: honour the caller's if sourced, define them if executed standalone.
: "${RED:=$'\033[0;31m'}"
: "${GREEN:=$'\033[0;32m'}"
: "${YELLOW:=$'\033[1;33m'}"
: "${NC:=$'\033[0m'}"

REVIEWER_APPROVAL_FORMAT_VERSION=2

# Fingerprint the git index — i.e. exactly what a commit would record.
#
# `git ls-files -s | git hash-object --stdin` rather than `git write-tree`:
# write-tree creates tree objects in the object database as a side effect, and this
# runs on every commit attempt from a PreToolUse hook, where a read should not
# mutate anything. hash-object without -w writes nothing. Verified byte-stable
# across repeated invocations, and it changes when the staged set changes and
# returns to its prior value when a file is unstaged.
reviewer_index_fingerprint() {
    # `-C <root>`, `--full-name` and the `:/` pathspec are all load-bearing. Bare
    # `git ls-files -s` is scoped to the current directory subtree and prints paths
    # RELATIVE to cwd, so the fingerprint would depend on where it was invoked from.
    # The git hook runs at the repo root, but the PreToolUse handler uses
    # process.cwd(), which need not be. Worse than a mismatch: from a subdirectory
    # the fingerprint would cover only that subtree, so staging a file anywhere else
    # would not invalidate the approval — defeating the whole point of binding.
    local root
    root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
    git -C "$root" ls-files -s --full-name -- :/ 2>/dev/null | git hash-object --stdin 2>/dev/null
}

# Trim leading and trailing whitespace only, matching JS .trim() semantics.
#
# $(cat) alone strips just trailing newlines, so a leading space survives into the
# regex and fails it. `tr -d '[:space:]'` overcorrects the other way: it also strips
# INTERIOR whitespace, so "1788 387445" would collapse into a valid-looking
# timestamp. Both were real divergences between the two layers.
reviewer_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# reviewer_validate_approval <approval_file> <timeout_seconds> [consume]
#   consume=1 (default) — on success the flag is deleted, so one approval buys one
#                         commit. This is what the git hook wants.
#   consume=0           — validate without deleting. Layer 1 runs BEFORE git commit,
#                         so if it consumed the flag the commit that follows would
#                         fail with "no approval found". An advisory check must not
#                         destroy the thing the gate is about to check.
#
#   0 = approved
#   1 = rejected. A rejected flag is ALWAYS deleted regardless of `consume`: it is
#       invalid, and leaving it on disk lets it be silently retried.
reviewer_validate_approval() {
    local approval_file="$1"
    local timeout="${2:-300}"
    local consume="${3:-1}"

    if [ ! -f "$approval_file" ]; then
        echo -e "${RED}❌ BLOCKED: No reviewer agent approval found${NC}"
        echo "   For AI-generated changes: spawn the reviewer agent and get APPROVE"
        echo "   For your own changes: USER_COMMIT=1 git commit -m \"message\""
        return 1
    fi

    local raw approval_time approval_tree
    raw=$(reviewer_trim "$(cat "$approval_file")")

    # Split on the first whitespace run. Field 2 absent => v1 flag.
    approval_time="${raw%%[[:space:]]*}"
    if [ "$raw" = "$approval_time" ]; then
        approval_tree=""
    else
        approval_tree=$(reviewer_trim "${raw#*[[:space:]]}")
    fi

    # Reject non-numeric before arithmetic: $(()) on garbage yields 0, which reads
    # as a brand-new approval rather than an invalid one. The regex also closes
    # parseInt leniency on the JS side — parseInt('1756800000junk') is a valid-looking
    # timestamp, so both layers require plain digits.
    if ! [[ "$approval_time" =~ ^[0-9]{1,11}$ ]] || [ "$approval_time" -le 0 ]; then
        echo -e "${RED}❌ BLOCKED: Approval flag is corrupted (invalid timestamp)${NC}"
        echo "   Value was: '${approval_time}'"
        echo "   Getting a fresh approval is required"
        rm -f "$approval_file"
        return 1
    fi

    # Distinct message from a mismatch below: the remedies are different, and a
    # generic "invalid flag" costs someone a confused debugging session.
    if [ -z "$approval_tree" ]; then
        echo -e "${RED}❌ BLOCKED: Approval flag has no tree fingerprint${NC}"
        echo "   This is the pre-binding (v1) format, which cannot prove the approval"
        echo "   was for the content you are committing."
        echo "   Fix: update claude-code-reviewer, then re-run the reviewer agent."
        rm -f "$approval_file"
        return 1
    fi

    if ! [[ "$approval_tree" =~ ^[0-9a-f]{40}$ ]]; then
        echo -e "${RED}❌ BLOCKED: Approval flag fingerprint is malformed${NC}"
        echo "   Expected 40 hex characters, got: '${approval_tree}'"
        rm -f "$approval_file"
        return 1
    fi

    local current_tree
    current_tree=$(reviewer_index_fingerprint)
    if [ -z "$current_tree" ]; then
        echo -e "${RED}❌ BLOCKED: Could not fingerprint the git index${NC}"
        echo "   Refusing to approve a commit whose content cannot be verified."
        rm -f "$approval_file"
        return 1
    fi

    if [ "$approval_tree" != "$current_tree" ]; then
        echo -e "${RED}❌ BLOCKED: Approval does not match the staged changes${NC}"
        echo "   Approved:  ${approval_tree}"
        echo "   Staged:    ${current_tree}"
        echo "   The staged content changed after the review. Re-run the reviewer"
        echo "   agent so the approval covers what you are actually committing."
        rm -f "$approval_file"
        return 1
    fi

    local current_time time_diff
    current_time=$(date +%s)
    time_diff=$((current_time - approval_time))

    # Two-sided. Without the lower bound a future-dated flag yields a negative diff,
    # passes the upper bound, and never expires.
    if [ "$time_diff" -lt 0 ]; then
        echo -e "${RED}❌ BLOCKED: Approval flag is dated in the future (${time_diff}s)${NC}"
        echo "   A future timestamp would never expire — rejecting"
        rm -f "$approval_file"
        return 1
    fi

    if [ "$time_diff" -ge "$timeout" ]; then
        echo -e "${RED}❌ BLOCKED: Reviewer approval expired (${time_diff}s old)${NC}"
        echo "   Spawn the reviewer agent again and get fresh approval"
        rm -f "$approval_file"
        return 1
    fi

    echo -e "${GREEN}✅ Reviewer agent approved (${time_diff}s ago, tree ${current_tree:0:12})${NC}"
    [ "$consume" = "1" ] && rm -f "$approval_file"
    return 0
}

# Executed rather than sourced: run the check and exit with its status.
# ${BASH_SOURCE[0]} != $0 when sourced.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-check}" in
        check)
            REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            reviewer_validate_approval "${2:-$REPO_ROOT/reviewer-approved}" "${3:-300}" 1
            exit $?
            ;;
        peek)
            # Non-consuming. Layer 1 uses this: it must not spend the approval that
            # the git hook is about to require.
            REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
            reviewer_validate_approval "${2:-$REPO_ROOT/reviewer-approved}" "${3:-300}" 0
            exit $?
            ;;
        fingerprint)
            reviewer_index_fingerprint
            exit $?
            ;;
        version)
            echo "$REVIEWER_APPROVAL_FORMAT_VERSION"
            exit 0
            ;;
        *)
            echo "usage: approval.sh {check|peek [file] [timeout]|fingerprint|version}" >&2
            exit 64
            ;;
    esac
fi
