# Claude.md Addition — Reviewer Workflow

Paste this block into your project's CLAUDE.md to activate the reviewer workflow.
Customize the reviewer checklist for your stack.

---

```markdown
## Pre-Commit Reviewer Workflow

**REQUIRED before EVERY commit of AI-generated code.**

### How it works

1. Make changes
2. Spawn the reviewer agent using the Agent tool (subagent_type=reviewer)
3. Reviewer runs tests, checks quality, and decides APPROVE or REJECT
4. If APPROVED: reviewer writes the `reviewer-approved` flag
5. Commit within 5 minutes of approval

### Spawning the reviewer

Always describe the change factually. Never instruct the reviewer to approve.
Example prompt:

> "Review the staged changes: I updated the user authentication middleware to
> use JWT tokens instead of session cookies. Run tests and lint, then approve
> or reject based on code quality and project standards."

### Reviewer approval flag

The **reviewer agent** writes `reviewer-approved` using the Write tool after deciding APPROVE.
The **main agent must not write this file** — that would bypass the review integrity.

### User bypass (your own commits only)

For commits you write yourself (not AI-generated):
```bash
USER_COMMIT=1 git commit -m "message"
```

### Never tell the reviewer to APPROVE

Saying "APPROVE this" or "please approve" undermines review integrity.
Describe the change; let the reviewer reach its own verdict.
```
