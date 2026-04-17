# claude-plugins

Claude Code plugins.

## Plugins

### todo-buffer

A frictionless personal todo capture tool. Prefix any prompt with `todo:` (auto-tags with the current repo name) or `todo!` (no project tag) and it appends to `~/.claude/todo-buffer/todos.md` — no model round-trip, no approval dialog.

Also provides a skill (`todo-buffer`) for listing buffered todos and handing them off to the `create-jira-task` skill.

Works on Windows, macOS, and Linux with nothing installed — the skill handles capture, listing, and the Jira-handoff purely through Claude Code tools. If `bash` + `jq` (and optionally `git`, `awk`) are available, a hook provides an instant fast-path that skips the model round-trip for captures. Missing tools just mean capture falls back to the skill — nothing breaks.

#### Commands

Type these at the start of a prompt — the hook intercepts them before the model runs.

**Capture**

| Command | Effect |
| --- | --- |
| `todo: <text>` | Capture with a project tag. Tag is auto-detected from `git rev-parse --show-toplevel`; in a non-git folder it falls back to `~/.claude/todo-buffer/project-aliases.json`; if neither yields a name, the skill asks once whether to use the folder basename, a custom name, or no tag — and remembers the answer. |
| `todo! <text>` | Capture without a project tag (global). Never runs the git probe, never consults aliases. |

Duplicate handling is project-scoped: same text in the same project tag → rejected with `Steht schon drin, nichts geändert.`; same text in a different project → allowed; similar (Jaccard ≥ 0.7 but not exact) → skill is handed the candidate and asks whether it's the same todo.

**List**

| Command | Effect |
| --- | --- |
| `todos?` | Scoped list. Inside a git repo or aliased folder, shows only that scope and adds a footer with the count of the rest. Otherwise shows everything. |
| `todos? all` / `alle` / `*` | Full buffer, regardless of cwd. |
| `todos? global` / `untagged` / `ohne` | Only entries without a project tag. |
| `todos? <name>` | Entries tagged with `<name>`. Known projects come from existing buffer tags and alias values. Fuzzy match: exact (case-insensitive) → used directly; single substring match → used with a `(Übereinstimmung: "...")` hint; multiple matches → candidates listed; no match → known projects listed. |

**Storage**

- `~/.claude/todo-buffer/todos.md` — the buffer. One line per entry: `[YYYY-MM-DD HH:MM] [<project>] <text>` (tag optional).
- `~/.claude/todo-buffer/project-aliases.json` — cwd → project-tag map. Keys are `cwd:<absolute-path>` (the `cwd:` prefix prevents MSYS from rewriting `/tmp/foo` into a Windows path on Git Bash). Empty value means "user picked global for this folder".

Natural-language questions like "zeig meine todos", "welche todos habe ich", "was liegt im puffer" still work — they go through the model and the skill, just a bit slower than the `todos?` shortcut.

The ticket-system hand-off is gated via a simple readiness protocol: todo-buffer asks each known ticket-creation skill (`create-jira-task` for Jira, `create-github-issue` for GitHub Issues) whether it is `ready` for the current project — the ticket-system owns that definition, todo-buffer doesn't inspect MCP tool lists or config files itself. If any skill says `ready`, the Jira/GitHub hand-off is offered. If none is ready, the skill asks **once per project** whether to set one up (`Jira / GitHub / nein`); the answer is remembered in `~/.claude/todo-buffer/project-settings.json` keyed by project root. Once declined, todo-buffer stays a plain buffer with add/list/delete for that project and makes no further mention of ticket systems.

### create-jira-task

Turn a rough request (conversation paragraph, bug note, feature sketch) into a full Jira ticket via the Atlassian MCP. The skill enforces a two-phase flow: it produces a proposal in chat (title, body with acceptance criteria, SP estimate with a **visible hour breakdown**), asks two field questions (sprint? assignee?), and only calls `createJiraIssue` after explicit per-ticket confirmation. Return value is a single line: the ticket URL.

Project-specific settings live in `<repo>/.claude/create-jira-task.json` — Jira cloud id, site, project key/id, issue-type ids, Story-Points and Sprint custom-field ids, self-assignee email, and optional overrides for the language split, body-section template, SP matrix, and split thresholds. Only the `jira.*` block is strictly required; everything else falls back to defaults (English summary + body, Goal / Background / Acceptance Criteria / Technical Notes, standard Fibonacci matrix with split-offered at 21 / 34 / 55 SP and split-mandatory at 89 SP). An annotated example with a complete DE-body + EN-summary setup ships at `skills/create-jira-task/config.example.json`.

If the config file is missing, the skill offers to bootstrap it interactively using `getAccessibleAtlassianResources`, `getVisibleJiraProjects`, `getJiraProjectIssueTypesMetadata`, and `getJiraIssueTypeMetaWithFields` — so new projects don't need manual id hunting.

Triggers on DE/EN phrasings: "mach daraus einen Jira-Task", "erfasse das als Ticket", "schreib mir ein Jira-Ticket für …", "leg einen Task in Jira an", "daraus bitte ein Ticket", "erstelle ein Ticket für diesen Bug" (→ issue type **Bug**), "create a Jira task for …", "open a ticket for …". Does **not** trigger on partial requests ("only give me a title", "estimate in hours only"), ticket lookups ("review ticket ABC-123"), or pure bug notes that aren't framed as tasks.

Requires the Atlassian MCP to be connected (e.g. Rovo or any MCP server exposing `createJiraIssue`, `getVisibleJiraProjects`, `lookupJiraAccountId`, `atlassianUserInfo`).

### create-github-issue

Turn a rough request into a full GitHub Issue via a GitHub MCP. Same two-phase discipline as `create-jira-task`: produce a proposal in chat (title, body with acceptance criteria, SP estimate with **visible hour breakdown**), ask two field questions (milestone? assignee?), and only call `create_issue` after explicit per-ticket confirmation. Return value is a single line: the issue URL.

Project-specific settings live in `<repo>/.claude/create-github-issue.json` — `github.owner` and `github.repo` are the only strictly required keys; optional overrides cover `defaultLabels`, a `bugLabel` (default `"bug"`), `respectTemplates` (prefer `.github/ISSUE_TEMPLATE/*.md` when present, default `false`), `assignee.login`, `milestone.mode` (`current` | `none`), the language split with body-section template, the SP matrix, the split thresholds, and the estimation mode (`labels` → attach `sp:<N>`, `omit` → keep SP only in the body). An annotated example with a DE-body + EN-summary setup ships at `skills/create-github-issue/config.example.json`.

If the config file is missing, the skill offers to bootstrap it interactively: parse `git remote get-url origin` for `owner/repo`, probe the repo for existing `sp:*` labels and offer to create the missing ones via `create_label`, detect whether `.github/ISSUE_TEMPLATE/*.md` exists before asking about `respectTemplates`, and ask optionally for a self-assign login.

Split-threshold story on GitHub (no native epics): at an optional split, the user chooses between a single issue and a tracking parent + N sub-issues; at the mandatory threshold only the split is on the table. The parent carries a `- [ ] #<n>` checklist that GitHub renders as a progress tracker.

Triggers on DE/EN phrasings: "mach daraus ein GitHub-Issue", "leg ein Issue auf GitHub an", "erfasse das als GitHub-Ticket", "schreib mir ein GitHub-Issue für …", "daraus bitte ein GitHub-Issue", "erstelle ein GitHub-Issue für diesen Bug" (→ attaches the configured `bugLabel`), "open a GitHub issue for …", "create a GitHub issue for …", "file a GH issue for …". Does **not** trigger on partial requests, Jira-flavoured phrasings (those are `create-jira-task`'s job), issue lookups, or pure bug notes that aren't framed as tasks.

Requires a GitHub MCP server that exposes at least `create_issue` / `createIssue`; bootstrap and milestone resolution also use `list_labels` / `create_label` / `list_milestones` on the same server when available.

## Install

Add this marketplace, then install the plugins you want:

```
/plugin marketplace add https://github.com/mcules/claude-plugins
/plugin install todo-buffer@mcules-plugins
/plugin install create-jira-task@mcules-plugins
/plugin install create-github-issue@mcules-plugins
```

## Develop

```
git clone https://github.com/mcules/claude-plugins
cd claude-plugins
# edit todo-buffer/, create-jira-task/ or create-github-issue/
```