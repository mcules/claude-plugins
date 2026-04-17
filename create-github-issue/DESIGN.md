# create-github-issue — Design Sketch

**Status:** Idea / not yet implemented. This directory is a placeholder holding the design notes. It is **not** registered in `marketplace.json` and is **not** installable. When we flesh it out, fill in `.claude-plugin/plugin.json` + `skills/create-github-issue/SKILL.md` and add the entry to the marketplace.

## Goal

Mirror `create-jira-task` for GitHub Issues: turn a conversation paragraph / bug note / feature sketch into a full GitHub Issue through the same two-phase flow (proposal → per-ticket confirmation → create → return link).

## What stays the same as create-jira-task

- **Two-phase flow.** Proposal in chat first; never call the create API without an explicit per-ticket confirmation.
- **Hour-breakdown-first estimation.** Even though GitHub has no native Story-Points field, the hour breakdown itself is the value — it lets the user sanity-check the scope. SP get encoded via labels (see below) or dropped if the user opts out.
- **Per-project config** at `<repo-root>/.claude/create-github-issue.json`. Missing config → interactive bootstrap (see below). Only `github.*` strictly required; language/estimation fall back to defaults.
- **Readiness check** contract (ready / not-ready, silent probe, no side effects) — same shape as `create-jira-task`, so `todo-buffer`'s readiness protocol picks it up automatically.
- **Return-only-the-link discipline** after creation.
- **Split offer at configured SP thresholds** (default 21/34/55 optional, 89 mandatory) — GitHub has no native epic, so split = separate issues with a tracking parent (checklist in the parent body).

## What changes from Jira

### Backend

- **API:** GitHub's `POST /repos/{owner}/{repo}/issues` via the GitHub MCP (`mcp__github__create_issue` or equivalent). Detection pattern: `mcp__*github*` with `create_issue` / `createIssue` reachable.
- **No ADF dance:** issue body is GitHub-flavored markdown as-is.
- **No Story-Points custom field.** Two options, selectable in config:
  1. `estimation.mode: "labels"` — emit a label like `sp:3` on the issue. Requires the label to exist in the repo; bootstrap can offer to create `sp:1` / `sp:2` / `sp:3` / `sp:5` / `sp:8` / `sp:13` / `sp:21` / `sp:34` / `sp:55`.
  2. `estimation.mode: "omit"` — skip SP entirely; keep only the hour breakdown in the body for the user's benefit.
- **No Sprint field.** GitHub has *milestones* (date-bounded) and *Projects v2* (iterations). Config option `milestone.mode: "current" | "none"` — `current` resolves the milestone whose due date is closest ahead. Projects v2 iterations are out of scope for v0.1.
- **Assignee by GitHub username**, not email. Config: `assignee.login`. Lookup is trivial (just use the string).

### Config schema (draft)

```json
{
  "github": {
    "owner": "<org-or-user>",
    "repo": "<repo-name>",
    "defaultLabels": []
  },
  "assignee": { "login": "<gh-username>" },
  "milestone": { "mode": "current" },
  "language": {
    "summary": "en",
    "body": "en",
    "summaryStyle": "imperative, <= ~70 chars, no issue-number prefix",
    "bodySections": [ /* same shape as create-jira-task */ ],
    "estimateHeading": "Estimate",
    "fieldQuestions": {
      "milestone": "Milestone: add to current milestone, or leave empty?",
      "assignee": "Assignee: assign to you, or leave empty?"
    }
  },
  "estimation": {
    "mode": "labels",
    "matrix": [ /* same shape as create-jira-task */ ],
    "splitOptionalAt": [21, 34, 55],
    "splitMandatoryAt": [89],
    "subTicketTargetMaxSp": 13
  }
}
```

### Bootstrap

If config missing:

1. Detect repo from `git remote get-url origin` (parse `owner/repo`).
2. Ask the user whether to write `.claude/create-github-issue.json` with the detected owner/repo and sensible defaults.
3. If `estimation.mode: "labels"`, probe which `sp:*` labels already exist; offer to create the missing ones via the MCP (`listLabelsForRepo` + `createLabel`).
4. If multi-remote setup or the user's login isn't derivable, ask.

No MCP-based lookup needed for issue-type / custom-field IDs — GitHub doesn't have those.

## Split-ticket story

GitHub has no epics. When the SP threshold triggers a split:

- Create the sub-issues first (N separate `create_issue` calls).
- Then create the parent tracking issue with a body that links each sub-issue as a checklist item (`- [ ] #42 — Add exponential backoff retry`).
- Parent issue is not a formal epic, just a markdown checklist. GitHub renders the checkboxes as progress trackers.

Alternative future: use Projects v2 to group them. Not in v0.1.

## Open questions (for later)

- **Monorepo support.** A repo might host multiple logical products with different labelling conventions. For v0.1, one config = one `.claude/create-github-issue.json` = one target repo. A monorepo that wants multi-target would need a branch mechanism (config-per-subdir? explicit prompt?).
- **Issue templates.** GitHub repos may carry `ISSUE_TEMPLATE/*.md`. Should the skill prefer those over the body-section template in config? Leaning "no" for consistency across projects, but offer an opt-in `"respectTemplates": true`.
- **Comment threading.** `create-jira-task` creates a fresh issue. Should `create-github-issue` support "append as a comment on issue #X" instead? Probably a separate skill.
- **Rate limits.** GitHub's 5k/hr REST rate limit is usually fine for manual creation, but if someone uses this in a batch loop we should at least warn.
- **Cross-plugin readiness aggregation.** If both Jira and GitHub are ready in the same project (unusual but possible — monorepo with CI issues in GitHub and product tickets in Jira), `todo-buffer` should ask the user which one for each todo. That's already hinted at in `todo-buffer`'s list-step Case 1. Verify at build time.

## When to build

Trigger: user asks, or a project without Jira but with a GitHub workflow wants the same capture-to-ticket pipeline. No urgency — `create-jira-task` covers the current active projects.