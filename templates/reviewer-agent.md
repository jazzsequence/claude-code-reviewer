# Reviewer Agent — AGENTS.md Snippet

Paste this block into your project's `AGENTS.md` to document the reviewer agent.
The actual agent definition lives in `.claude/agents/reviewer.md` and the checklist
in `docs/REVIEWER_CHECKLIST.md` — do not duplicate instructions here.

---

```markdown
## reviewer

Pre-commit code review agent. Spawned by the main agent before every commit of
AI-generated code.

**Definition:** `.claude/agents/reviewer.md`
**Checklist:** `docs/REVIEWER_CHECKLIST.md`

### How to spawn

Always describe the change factually. Never instruct the reviewer to approve.

```
Agent({
  subagent_type: "reviewer",
  prompt: "Review the staged changes: [describe what changed and why]. Run all checks per the project checklist and approve or reject."
})
```

### Constraints

- Only the reviewer writes `reviewer-approved` — the main agent must not
- Never tell the reviewer to approve — describe the change and let it decide
- User bypass for manual commits: `USER_COMMIT=1 git commit -m "message"`
```
