---
name: load-jira-task
description: Start work on a Jira task — fetch the ticket via the Atlassian MCP, create a matching feature branch off the latest sprint branch, and transition the issue to "In Progress" / "In Arbeit". Project (cloudId, site, key) and branch/sprint/status conventions are configured per-repo via `.claude/load-jira-task.json`; defaults apply when keys are absent. USE WHENEVER — DE or EN — the user says something like "lade jira task PROJ-123", "hol den Task PROJ-123", "starte Arbeit an PROJ-123", "leg branch für PROJ-123 an", "beginne mit PROJ-123", "pick up PROJ-123", "load PROJ-123", "start PROJ-123", "begin work on PROJ-123". Branch name pattern is `<KEY>-<id>-<sanitised-title>` (e.g. `PROJ-123-Fix-dashed-borders-on-sync-action-checkboxes`). Do NOT use when the user only wants ticket info (read-only look-up), when the ticket is outside the configured project, or when the working tree is dirty — in the dirty case the skill aborts and asks the user to commit/stash first.
---

# Load a Jira task and start working on it

This skill bundles the three things that always happen together at the start of a ticket:

1. Fetch the ticket from Jira (to get its title).
2. Create a feature branch off the **latest sprint branch** — refreshed from origin first.
3. Transition the Jira issue to **"In Progress"** (or the configured equivalent, e.g. German "In Arbeit").

## When to use

Invoke when the user wants to begin work on a specific ticket in the configured project. Match **intent**, not exact wording.

**MUST trigger:**
- "lade jira task PROJ-123"
- "hol mir PROJ-123"
- "starte Arbeit an PROJ-123"
- "leg einen Branch für PROJ-123 an"
- "beginne mit PROJ-123"
- "pick up PROJ-123"
- "start work on PROJ-123"
- "load PROJ-124 and start"

**MUST NOT trigger:**
- "was steht in PROJ-123?" / "show me PROJ-123" → read-only look-up, just call the MCP and report
- "review PROJ-123" → not a start-of-work flow
- Ticket outside the configured project (e.g. `OTHER-12` when `projectKey` is `PROJ`) → tell the user this skill is scoped to the configured project
- Working tree has uncommitted changes → skill aborts in Step 2 and asks the user to commit/stash first; do **not** carry dirty changes onto the new branch silently

## Step 0 — Preconditions

Run **both** checks below before touching git or Jira. If either fails, stop — creating a branch that can't be linked, or fetching a ticket you can't locate, is waste.

### 0a. Atlassian MCP must be connected

The ticket fetch and the status transition go through the Atlassian MCP. Inspect the session's available tools for any entry whose name matches `mcp__*atlassian*`, `mcp__*jira*`, or `mcp__*rovo*` (common server names include `claude_ai_Atlassian_Rovo`, `atlassian`, `atlassian-mcp`, `rovo`, `jira`). Specifically, `getJiraIssue`, `getTransitionsForJiraIssue`, and `transitionJiraIssue` must exist somewhere in the toolset.

**If no matching MCP tool is present**, reply exactly once and stop:

```
No Atlassian/Jira MCP registered in this session — I can't fetch the ticket or transition its status.
Install an Atlassian MCP (e.g. Rovo) and reload the session, then we're good to go.
```

Do not proceed to create a branch "anyway": without the MCP the ticket title is unknown, the status transition won't happen, and the user will have to undo the branch manually.

### 0b. Load the project configuration

Read `<repo-root>/.claude/load-jira-task.json`. That file carries the Jira target and any project-specific overrides. Resolve `<repo-root>` from the current working directory (walk up to the git toplevel; if not in a repo, use cwd).

**If the file is missing:** ask the user once whether to create it. If yes, offer to bootstrap it via the Atlassian MCP:

1. `getAccessibleAtlassianResources` → pick the cloudId + site.
2. `getVisibleJiraProjects` → pick the project key.

Write the result to `.claude/load-jira-task.json` and continue. If the user declines, stop and explain that the Jira target is required — don't guess IDs.

**If the file exists but is missing required keys (`jira.cloudId`, `jira.site`, `jira.projectKey`):** stop and ask the user to fill them, pointing at `config.example.json` in this skill directory for reference.

## Readiness check (lightweight probe, for other skills)

Other skills may want to know whether load-jira-task is "ready for this project" before routing work here. When invoked as a readiness probe:

- **Input:** none — the caller just wants a yes/no answer for the current project.
- **Output:** exactly one token: `ready` or `not-ready`. No explanation.
- **Side effects:** none. Don't ask the user anything. Don't bootstrap. Don't write files.

**Procedure (read-only):**

1. **MCP probe** — check the session tool list for `mcp__*atlassian*` / `mcp__*jira*` / `mcp__*rovo*`, and confirm `getJiraIssue` + `transitionJiraIssue` are reachable. (Same detection as Step 0a, but without the user-facing error message.)
2. **Config probe** — check that `<repo-root>/.claude/load-jira-task.json` exists and contains all required `jira.*` keys. (Same check as Step 0b, but silent — don't offer to bootstrap.)
3. Both pass → emit `ready`. Either fails → emit `not-ready`.

Step 0's interactive bootstrap flow only runs when the user explicitly triggered load-jira-task, not when another skill is probing.

**Schema (all keys below `jira` are required; everything else is optional and falls back to the defaults in the next section):**

```json
{
  "jira": {
    "cloudId": "<uuid>",
    "site": "<subdomain>.atlassian.net",
    "projectKey": "<KEY>"
  },
  "branch": {
    "prefix": "<KEY>-",
    "sanitiseCase": "preserve|lower",
    "maxLength": 60
  },
  "sprint": {
    "pattern": "Sprint_YYYY_WW"
  },
  "status": {
    "inProgressTargets": ["In Progress", "In Arbeit"],
    "inProgressTransitionNames": ["In Progress", "In Arbeit", "In Bearbeitung"],
    "alreadyStarted": ["In Progress", "In Arbeit", "Done", "Fertig", "Erledigt", "Closed"]
  }
}
```

## Defaults (apply when a config key is absent)

- `branch.prefix` — derived at runtime from `jira.projectKey` + `-` (e.g. projectKey `PROJ` → `PROJ-`).
- `branch.sanitiseCase` — `preserve` (keep the original case from the Jira summary; don't lowercase).
- `branch.maxLength` — `60` (truncate at the last `-` before that char).
- `sprint.pattern` — `Sprint_YYYY_WW` (branch names like `Sprint_2026_12`; sorted descending by `(YYYY, WW)`).
- `status.inProgressTargets` — `["In Progress", "In Arbeit"]` (target status names, case-insensitive match on `transition.to.name`).
- `status.inProgressTransitionNames` — `["In Progress", "In Arbeit", "In Bearbeitung"]` (fallback match on `transition.name` when no `to.name` matches — some Jira projects name the transition differently from the target status).
- `status.alreadyStarted` — `["In Progress", "In Arbeit", "Done", "Fertig", "Erledigt", "Closed"]` (if the ticket is already in one of these, skip the transition step — don't re-transition to the same status).

## Non-negotiable rules

1. **Dirty working tree = abort.** Never run `git checkout -b` with uncommitted changes — `checkout -b` carries them onto the new branch, which pollutes the diff on the new ticket. If `git status` shows anything, stop and ask the user to commit / stash.
2. **Always refresh the sprint branch from origin first** (`git fetch origin --prune`, then `git pull --ff-only` on the sprint branch). Branching off a stale local sprint produces merge pain later.
3. **Never branch off `main`.** If no sprint branch matching `sprint.pattern` can be found, stop and ask.
4. **If the current branch is not the latest sprint**, show the user which sprint the skill will use and ask for confirmation before switching. Don't jump off their current branch silently.
5. **Transition matching is case-insensitive** and checks the **target status** (`transition.to.name`), not the transition's own display name — some projects name the transition differently from the target status (e.g. transition "In Bearbeitung" moves the ticket to status "In Arbeit"). Accept `to.name` in `status.inProgressTargets`; as a fallback, match `transition.name` in `status.inProgressTransitionNames`. If nothing matches, report the available transitions and ask.
6. **Do not create the branch before the Jira fetch succeeds**, and do not transition before the branch is created — these are independent; do them in order (ticket → branch → transition) and report all outcomes. If the transition fails after the branch exists, keep the branch and report the failure; don't try to roll back.
7. **Branch name is `<branch.prefix><id>-<sanitised-title>`** — see sanitisation rules below. Never include the description body or a suffix like `-wip`.
8. **Configured project only.** If the user asks to load a ticket in a different project, stop and tell them this skill is scoped to `jira.projectKey`.

## Workflow

### Step 1 — Parse the ticket key

The user's message contains a ticket ID that should start with `jira.projectKey` (case-insensitive — users often type lowercase like `proj-123`). Normalise to uppercase `<KEY>-<number>`. If no matching ID is extractable, ask for it. If the extracted key's project prefix doesn't match `jira.projectKey`, stop and tell the user this skill is scoped to `<KEY>` — don't auto-switch projects.

### Step 2 — Check the working tree

```bash
git status --porcelain
git branch --show-current
```

If `git status --porcelain` has any output (modified, staged, or untracked files), **stop**. Tell the user (in their language):

> Working tree is not clean — please commit or stash first. Changed files: <short list>.

Do not proceed with `checkout -b`. Resume only after the user resolves it.

### Step 3 — Fetch the Jira issue (minimal fields)

Use the Atlassian MCP: `getJiraIssue` with `cloudId = jira.cloudId` and `issueIdOrKey = <KEY>-<id>`. At this stage only request the fields needed for branching:

```
fields: ["summary", "status", "issuetype"]
```

Extract:
- `fields.summary` → used for branch name
- `fields.status.name` → informational; if it's already in `status.alreadyStarted`, mention that in the plan (still OK to branch, but skip the transition in Step 7 to avoid a no-op)
- `fields.issuetype.name` → informational for the plan output

The full description and any links are **deliberately not fetched here** — only reload them later (Step 9) if the user wants to plan the implementation. This keeps the start-of-work flow lean.

If the MCP returns 404 / permission denied, stop and report.

### Step 4 — Sanitise the title into a branch-safe segment

Rules, applied in order:

1. Transliterate German umlauts and ß: `ä→ae`, `ö→oe`, `ü→ue`, `Ä→Ae`, `Ö→Oe`, `Ü→Ue`, `ß→ss`. (Extend with other scripts' transliterations as needed for your project.)
2. Replace every whitespace run with a single `-`.
3. Drop any character that is not `[A-Za-z0-9-_.]`. In particular: drop `/`, `\`, `:`, `?`, `!`, `,`, `;`, `(`, `)`, `[`, `]`, `{`, `}`, `"`, `'`, `` ` ``, `&`, `%`, `#`, `@`, `$`, `*`, `+`, `=`, `<`, `>`, `|`, `~`.
4. Collapse repeated `-` into a single `-`.
5. Trim leading/trailing `-` and `.`.
6. Case: respect `branch.sanitiseCase` — `preserve` (default) keeps the original case from the Jira summary; `lower` lowercases the whole segment. Don't slugify aggressively.
7. If the resulting segment is longer than `branch.maxLength` characters, truncate at the last `-` before char `maxLength` (so you don't cut mid-word).

Final branch name: `<branch.prefix><id>-<sanitised-segment>`.

Example — Jira summary `Fix dashed borders on sync action checkboxes` (projectKey `PROJ`, id `123`) → `PROJ-123-Fix-dashed-borders-on-sync-action-checkboxes`.

Example — Jira summary `Prüfen: Warum läuft der Import nicht?` → sanitised segment `Pruefen-Warum-laeuft-der-Import-nicht` → `PROJ-124-Pruefen-Warum-laeuft-der-Import-nicht`.

### Step 5 — Determine the latest sprint branch

Sprints follow the pattern in `sprint.pattern` (default `Sprint_YYYY_WW`).

```bash
git fetch origin --prune
```

Then list remote sprint branches and pick the highest `YYYY_WW`:

```bash
git branch -r --list 'origin/Sprint_*'
```

Sort descending by `(YYYY, WW)` and pick the first. Call this `<latest-sprint>`.

If no match is found, stop and ask the user which branch to use as base (never default to `main`).

**Decide whether to confirm with the user:**

- If `git branch --show-current` already equals `<latest-sprint>` → proceed silently.
- Else → tell the user: "Will branch off `<latest-sprint>` (current branch: `<current>`). OK?" and wait for confirmation. The user might say "ja", "yes", "OK", "go" — proceed. If they name a different sprint, use theirs instead.

### Step 6 — Refresh the sprint branch and create the feature branch

Once the sprint branch is confirmed:

```bash
git checkout <sprint-branch>
git pull --ff-only
git checkout -b <branch.prefix><id>-<sanitised-segment>
```

Use `--ff-only` so a diverged local sprint branch fails loudly instead of producing a merge commit. If `pull --ff-only` fails, stop and report — don't try `git pull` without `--ff-only`, don't rebase, don't reset. The user decides how to reconcile.

### Step 7 — Transition the Jira issue to "In Progress"

Only skip this step if `fields.status.name` (case-insensitive) is in `status.alreadyStarted`. In that case, report the current status and move on.

Otherwise:

1. `getTransitionsForJiraIssue` with `cloudId` and `issueIdOrKey = <KEY>-<id>`.
2. From the returned transitions, pick the one where **`transition.to.name`** (case-insensitive, trimmed) matches one of `status.inProgressTargets`. If multiple transitions lead to that status (some projects have a normal transition plus a variant that forces a field prompt, e.g. for Story Points), prefer the one that has `hasScreen: false` **and** whose `name` matches one of `status.inProgressTransitionNames`; skip transitions whose name includes "Story Points" or "estimate".
3. If no `to.name` match exists, fall back to matching `transition.name` (case-insensitive) against `status.inProgressTransitionNames`.
4. Call `transitionJiraIssue` with the transition id.
5. If nothing matches → report all available transitions (name + target status) and ask the user which one to pick. Do **not** pick a similar-sounding one on your own.

### Step 8 — Report

Reply with a compact status line in the user's language (DE if the trigger was German, EN otherwise). Include:

- The Jira ticket link: `https://<jira.site>/browse/<KEY>-<id>`
- The new branch name
- The status transition result (transitioned / skipped because already started / failed)

Example output (EN):

```
✓ PROJ-123 — Fix dashed borders on sync action checkboxes
  Branch: PROJ-123-Fix-dashed-borders-on-sync-action-checkboxes (from Sprint_2026_12)
  Status: To Do → In Progress
  https://your-org.atlassian.net/browse/PROJ-123
```

Do not recap further yet — move on to Step 9.

### Step 9 — Offer to start planning the implementation

Immediately after the status line, ask a single question (in the user's language):

> Soll ich direkt mit dem Plan für die Umsetzung beginnen?  *(DE)*
> Want me to start planning the implementation now?  *(EN)*

Then wait. Three possible outcomes:

- **User says yes** ("ja", "gerne", "los", "yes", "go") → proceed to Step 10.
- **User says no** ("nein", "später", "no", "not yet") → stop; the skill is done.
- **User sends something else** (e.g. a new question, a different task) → treat it as the new instruction; the skill is done.

### Step 10 — Load full ticket context and draft a plan

Only reached if the user said yes in Step 9.

Re-call `getJiraIssue`, this time with a **wide field set** to pull everything that informs a plan. Use `responseContentFormat: "markdown"` so the description comes back as plain markdown, not ADF:

```
fields: [
  "summary", "description", "status", "issuetype",
  "priority", "labels", "components", "fixVersions",
  "assignee", "reporter", "created", "updated",
  "parent", "subtasks", "issuelinks",
  "attachment"
]
responseContentFormat: "markdown"
```

(If your project tracks Story Points and Sprint in custom fields, add their ids to this list — the skill doesn't need them for branching, but a plan often benefits from the sprint context.)

Also pull linked context that is often relevant:

- **Remote links** (Confluence, external URLs, PR references) via `getJiraIssueRemoteIssueLinks`.
- **Linked issues** from `fields.issuelinks` — note key + link type (blocks, relates, duplicates …), but **do not recursively fetch their descriptions** unless the plan clearly needs it. If the user wants a linked ticket expanded, they'll ask.

Then hand off into planning. Do **not** write the plan inline as free prose — use the plan tooling: either invoke `EnterPlanMode` / return an `ExitPlanMode` proposal, or hand the draft to a planning subagent, depending on which is available in the user's setup. A reasonable first move is to spawn a plan subagent with:

- The full Jira description (markdown, in the ticket's original language).
- Acceptance criteria extracted from the description (look for a "Acceptance Criteria" / "Akzeptanzkriterien" heading or a checkbox list).
- Linked issues + remote links as context pointers.
- The new branch name (so the plan knows where the work will land).
- The current sprint branch (as the merge target).

Tell the plan subagent the output audience: the user — match their language, terse plans that cite file paths and line numbers over narrative prose. No boilerplate "Summary / Approach / Testing" sections unless they carry real content.

After the plan comes back, present it to the user for review — don't start executing. The user decides whether to accept, tweak, or discard.

## Common pitfalls

- **Running `git checkout -b` with a dirty working tree** — the uncommitted changes follow onto the new branch and pollute the ticket's diff. Always hard-stop in Step 2.
- **Branching off the local sprint branch without `git pull`** — forces later conflicts. Always fetch and fast-forward first.
- **Guessing the transition name** (e.g. transitioning to "Ready" because "In Progress" isn't listed) — ask instead.
- **Lowercasing the sanitised title** when `branch.sanitiseCase` is `preserve` — don't slugify aggressively. Respect the configured case mode.
- **Hardcoding a specific sprint name** like `Sprint_2026_12` — sprints roll over. Always resolve the latest from remote.
- **Forgetting to transition the issue** because "I already made the branch" — both steps are part of the skill; a branch without the status update leaves the board wrong.
- **Falling back to `main`** when no sprint branch is found — stop and ask instead.
- **Including the long, wrapped Jira summary verbatim in the branch name** — if the sanitised segment exceeds `branch.maxLength`, truncate at a word boundary (last `-` before the limit).
- **Loading the full description in Step 3** — Step 3 needs only `summary` + `status` + `issuetype`. The big fetch (description, links, attachments) happens in Step 10, and *only* if the user wants to plan now.
- **Jumping into implementation after the user says "ja"** in Step 9 — "ja" means "start planning", not "start coding". Produce a plan first, let the user review it.
- **Writing the plan as free prose** instead of going through the plan tooling / plan subagent — if the user has a planning workflow, use it.
- **Loading a ticket outside `jira.projectKey`** — the skill is project-scoped. If the user wants a different project, they need a separate config (or a separate invocation in a different repo).