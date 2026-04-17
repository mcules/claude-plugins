---
name: create-github-issue
description: Turn a rough request into a full GitHub Issue via a GitHub MCP. Two-phase flow — proposal (title, body, estimate with visible hour breakdown, SP encoded as `sp:<N>` label) → per-ticket confirmation → `create_issue` → return the link. Repo (owner/repo), default labels, bug-label, milestone mode, language convention (summary/body), estimation matrix, split thresholds and optional Issue-Template respect are configured per-repo via `.claude/create-github-issue.json`; defaults apply when keys are absent. USE THIS WHENEVER the user asks — in English or German — to turn something into a GitHub Issue / Ticket, e.g. "mach daraus ein GitHub-Issue", "leg ein Issue auf GitHub an", "erfasse das als GitHub-Ticket", "schreib mir ein GitHub-Issue für …", "open a GitHub issue for …", "create a GitHub issue for …", "erstelle ein GitHub-Issue für diesen Bug" (→ add the configured bug label). Do NOT use when the user only wants a partial artifact (title only, description only, SP only), when they only want an hour estimate without the SP mapping, for Jira-flavoured phrasings (those belong to `create-jira-task`), for issue lookups ("review issue #42"), or for bug reports that are just notes with no task character.
---

# Create a GitHub Issue

This is a two-phase interaction:

1. **Proposal phase** — produce title, body (acceptance criteria included), SP estimate with a visible hour breakdown. Show it to the user in chat. Ask the two field questions (Milestone? Assignee?).
2. **Creation phase** — only after explicit per-ticket confirmation, call `create_issue` via the GitHub MCP with the agreed fields, then return the link. Nothing else after that.

**Never collapse these phases** — the user wants the checkpoint.

## When to use

Invoke when the user's intent is: take a described piece of work and turn it into a real GitHub Issue. Match intent, not exact wording.

**MUST trigger:**
- "mach daraus ein GitHub-Issue"
- "leg ein Issue auf GitHub an"
- "erfasse das als GitHub-Ticket"
- "schreib mir ein GitHub-Issue für …"
- "daraus bitte ein GitHub-Issue"
- "erstelle ein GitHub-Issue für diesen Bug" → add configured `github.bugLabel`
- "open a GitHub issue for …"
- "create a GitHub issue for the work above"
- "file a GH issue for …"

**MUST NOT trigger:**
- "nur den Titel formulieren" / "only give me a title" → partial, answer directly
- "nur die Beschreibung, kein Ticket" → partial, answer directly
- "was würdest du schätzen in Stunden?" → hours-only, no SP matrix, no issue
- "mach daraus einen Jira-Task" / "open a Jira ticket" → that's `create-jira-task`
- "review issue #42" → not creation
- a pure bug note with no task character ("seltsam, dass X passiert") → first clarify, don't auto-issue

## Step 0 — Preconditions

Run **all three** checks below before drafting anything. If any fails, stop — drafting a proposal that can't be submitted is waste.

### 0a. GitHub MCP must be connected

Every write goes through a GitHub MCP. Inspect the session's available tools for any entry whose name matches `mcp__*github*` (common server names include `github`, `github-official`, `gh-mcp`). Specifically, one of `create_issue` or `createIssue` must exist somewhere in the toolset. The same server will usually also expose `list_labels` / `create_label` / `list_milestones` / `search_users` — those are needed for bootstrap and milestone resolution but not for the readiness gate itself.

**If no matching MCP tool is present**, reply exactly once and stop:

```
Kein GitHub-MCP in dieser Session registriert — ich kann das Issue nicht anlegen.
Installier einen GitHub-MCP und lade die Session neu, dann geht's.
```

Don't produce a proposal as a "dry run": without the MCP the user can't act on it, and the draft just creates noise that has to be redone later.

### 0b. Load the project configuration

Read `<repo-root>/.claude/create-github-issue.json`. That file carries the GitHub target and any project-specific overrides. Resolve `<repo-root>` from the current working directory (walk up to the git toplevel; if not in a repo, use cwd).

**If the file is missing:** ask the user once whether to create it. If yes, bootstrap it:

1. **Detect owner/repo** from `git remote get-url origin`. Accept both SSH (`git@github.com:owner/repo.git`) and HTTPS (`https://github.com/owner/repo(.git)?`) formats; strip a trailing `.git`. If the parse fails, or the repo has multiple remotes and `origin` doesn't look like GitHub, ask the user to name `owner` and `repo` explicitly.
2. **Decide SP-encoding mode.** Default is `"labels"`. With the user's permission, call the MCP's `list_labels` (or equivalent) on `owner/repo` and check which `sp:*` labels already exist. Offer to create the missing ones from the standard Fibonacci set (`sp:1`, `sp:2`, `sp:3`, `sp:5`, `sp:8`, `sp:13`, `sp:21`, `sp:34`, `sp:55`) via `create_label` (any neutral colour, e.g. `ededed`, is fine). If the user declines label creation, write `"estimation": { "mode": "omit" }` — the SP then lives only in the issue body, not as a label.
3. **Assignee.** Ask for the GitHub login to self-assign (default: leave empty → no self-assign). No lookup needed; GitHub accepts the login string directly.
4. **Milestone mode.** Default `"current"` (resolve the nearest-future open milestone at creation time). If the user prefers never to touch milestones, write `"none"`.
5. **respectTemplates.** Only offer this if `.github/ISSUE_TEMPLATE/*.md` actually exists in the current checkout. Ask whether to prefer those templates over the skill's body-sections. Default `false` — most projects want the consistent body-section template across their tickets.
6. **Bug label.** Default `"bug"` — a near-universal GitHub convention. Offer to change or leave empty.

Write the result to `.claude/create-github-issue.json` and continue. If the user declines the whole bootstrap, stop and explain that the GitHub target is required — don't guess.

### 0c. Required keys present

If the file exists but is missing required keys (`github.owner`, `github.repo`): stop and ask the user to fill them, pointing at `config.example.json` in this skill directory for reference.

## Readiness check (lightweight probe, for other skills)

Other skills (e.g. `todo-buffer`) may want to know whether create-github-issue is "ready for this project" before routing work here. This section defines that contract. When invoked as a readiness probe:

- **Input:** none — the caller just wants a yes/no answer for the current project.
- **Output:** exactly one token: `ready` or `not-ready`. No explanation, no plan, no proposal.
- **Side effects:** none. Don't ask the user anything. Don't start a bootstrap. Don't write files. Don't emit a draft.

**Procedure (read-only):**

1. **MCP probe** — check the session tool list for `mcp__*github*`, and confirm `create_issue` or `createIssue` is reachable. (Same detection as Step 0a, but without the user-facing error message.)
2. **Config probe** — check that `<repo-root>/.claude/create-github-issue.json` exists and contains `github.owner` and `github.repo`. (Same check as Step 0c, but silent — don't offer to bootstrap.)
3. Both pass → emit `ready`. Either fails → emit `not-ready`.

This is a pure probe. If the caller wants to act on a `not-ready` result (e.g. offer a bootstrap), it must do so in its own flow — don't take that decision here. Step 0's interactive bootstrap flow only runs when the user explicitly triggered create-github-issue to create an issue, not when another skill is probing readiness.

**Schema (`github.owner` + `github.repo` are required; everything else is optional and falls back to the defaults in the next section):**

```json
{
  "github": {
    "owner": "<org-or-user>",
    "repo": "<repo>",
    "defaultLabels": [],
    "bugLabel": "bug",
    "respectTemplates": false
  },
  "assignee": { "login": "<gh-username>" },
  "milestone": { "mode": "current|none" },
  "language": {
    "summary": "en|de|…",
    "body": "en|de|…",
    "summaryStyle": "<one-line instruction, e.g. 'imperative, <= ~70 chars, no issue-number prefix'>",
    "bodySections": [
      { "heading": "<h2 text>", "purpose": "<what belongs here>", "required": true|false, "format": "checkbox-list|freeform" (optional), "skipWhen": "<condition>" (optional) }
    ],
    "estimateHeading": "<h2 text>",
    "fieldQuestions": { "milestone": "<question>", "assignee": "<question>" },
    "confirmPhrases": ["ja", "anlegen", "ok", "create it", "mach", "leg an"]
  },
  "estimation": {
    "mode": "labels|omit",
    "matrix": [ { "sp": 1, "label": "<budget>" }, … ],
    "splitOptionalAt": [21, 34, 55],
    "splitMandatoryAt": [89],
    "subTicketTargetMaxSp": 13
  }
}
```

## Defaults (apply when a config key is absent)

**Language** — summary `en`, body `en`, summary style `"imperative, <= ~70 chars, no issue-number prefix"`. Body sections:

| Heading             | Purpose                                                              | Required | Skip when            |
|---------------------|----------------------------------------------------------------------|----------|----------------------|
| Goal                | what should exist afterwards — the WHAT + WHY                        | yes      | —                    |
| Background          | context, what already exists, why now                                | no       | trivial bugfix       |
| Acceptance Criteria | checkbox list of testable points                                     | yes      | —                    |
| Technical Notes     | concrete file paths, function names, migrations, config keys         | no       | trivial issue        |

Estimate heading: `Estimate`. Field questions: `Milestone: add to current milestone, or leave empty?` / `Assignee: assign to you, or leave empty?`. Confirm phrases: `yes, create it, ok, do it, create, go`.

**SP matrix** (Fibonacci, the standard team interpretation):

| SP | Budget                          |
|----|---------------------------------|
|  1 | ≈ 1 h or less                   |
|  2 | up to 2 h                       |
|  3 | up to 1/2 day                   |
|  5 | up to 1 day                     |
|  8 | at least 1 day                  |
| 13 | at most 2 days                  |
| 21 | at least 2 days                 |
| 34 | at least 3 days                 |
| 55 | at least 1 week                 |

Split thresholds: optional at 21 / 34 / 55 SP (offer both paths, user decides); **mandatory** at 89 SP (don't offer the single issue). Sub-issues in a split should target ≤ 13 SP each.

Estimation encoding default: `labels` — a single `sp:<N>` label is attached to the issue. Set `estimation.mode: "omit"` to skip the label and keep SP only in the issue body.

Milestone mode default: `current` — at creation time, resolve the open milestone with the nearest-future due date. Set `milestone.mode: "none"` to never attach a milestone.

Bug-label default: `"bug"`. Set `"github.bugLabel": ""` (empty) to skip the bug label entirely even for bug-shaped issues.

`respectTemplates` default: `false`. Set to `true` to prefer `.github/ISSUE_TEMPLATE/*.md` over the body-sections template when the repo actually carries templates.

## Non-negotiable rules

1. **Language split is from config.** If `language.summary` ≠ `language.body`, keep them strictly in their configured languages (e.g. EN summary + DE body). Don't mix within a part.
2. **Title format follows `language.summaryStyle`.** For the default style: imperative verb, ≤ ~70 chars, no issue-number prefix (GitHub assigns `#<n>` itself after creation).
3. **SP estimate only with a visible hour breakdown.** First list subtasks with hour budgets, sum them, **then** map the sum onto the project matrix. Never pick an SP number first and rationalise afterwards.
4. **Round up at matrix boundaries.** If the sum lands between two SP values, take the larger.
5. **At `estimation.splitOptionalAt` values, always offer a split — but let the user decide.** Those issue sizes *can* exist; they just shouldn't do so silently. Alongside the normal proposal, sketch a concrete split into smaller issues (each ≤ `subTicketTargetMaxSp` if possible) and ask the user which route they want. Do not create the single issue without hearing back. This applies equally to regular and bug-flavoured work.
6. **At `estimation.splitMandatoryAt` values, split is mandatory.** Do not offer the single-issue route; propose a split and make clear that "one big issue" is not on the table.
7. **One issue = one explicit confirmation.** No batch approval. The user must say something from `language.confirmPhrases` (or an obvious equivalent) for each issue individually before any `create_issue` call.
8. **Never fill in fields the user didn't ask for.** No priority labels, no area/component labels, no projects, no attachments. The only labels the skill attaches are: `github.defaultLabels` (always), `github.bugLabel` (only when the user signalled a bug and the label is configured), `sp:<N>` (only when `estimation.mode: "labels"`). Nothing else.
9. **SP-label mode is binary.** With `estimation.mode: "labels"` attach exactly one `sp:<N>` label with the mapped number. With `estimation.mode: "omit"`, keep SP only in the body and do not invent a label.
10. **After creation, return only the issue link.** No recap, no "I created X with …", no summary of what you just agreed on two messages ago.
11. **Max 1–2 clarifying questions.** If scope is genuinely unclear, ask. Otherwise proceed with stated assumptions and note them in the Background section.
12. **Don't reuse the title as a body heading.** GitHub renders the title above the body; repeating it is noise.

## Workflow

### Step 1 — Extract the work to be ticketed

The input is usually conversation context: a feature request, a bug report, a piece of discussion, or a paragraph the user just pasted. Before proposing anything:

- Identify the **WHAT** (what should exist afterwards) and the **WHY** (user value or constraint behind it).
- Note concrete artifacts the user already mentioned: file paths, function names, migrations, UI views, config flags. These go into the "Technical Notes" (or equivalent) section if configured.
- If the character is clearly a bug (something regressed / misbehaves), plan to attach `github.bugLabel` (when non-empty). Otherwise no bug label.

If the scope is too fuzzy to write a sane title, ask one clarifying question. Don't ask two if one would do.

### Step 2 — Draft the proposal in chat

Build the proposal from config:

- **Title label:** localised to `language.summary` (e.g. `**Title (EN):**` for English, `**Titel (EN):**` for German UI with EN summary).
- **Body label:** localised to `language.body`.
- **Body sections:** use `language.bodySections` in the order listed, each as an H2. Omit non-required sections when their `skipWhen` condition applies; otherwise fill them.
- **Respect-templates branch:** if `github.respectTemplates` is `true` **and** the repo actually carries `.github/ISSUE_TEMPLATE/*.md`, load the templates (prefer local Read; fall back to the MCP's file-fetch tool if no local checkout). If a single template exists, use its body as the proposal body scaffold; if several exist, ask the user once which template to apply, then use that one. Strip any YAML frontmatter (`---` block at the top) before rendering — it's GitHub form metadata, not part of the body. Keep the template placeholders as-is (don't invent user input) and fill in only what the user actually provided.
- **Acceptance Criteria format:** if a section has `"format": "checkbox-list"`, render as `- [ ] …` items; otherwise freeform.
- **Estimate block:** `**${language.estimateHeading}:**` followed by a table of subtasks + hours, summed, then one line mapping the sum to SP with a matrix-based justification, and one line with the next-higher SP hedge.
- **Bug marker:** if a bug was signalled and `github.bugLabel` is non-empty, add a leading line `<Type-label>: Bug (Label: <github.bugLabel>)` (in body lang) to the proposal so the user sees the label will be attached.
- **SP-label marker:** if `estimation.mode: "labels"`, show the resolved label on its own line right below the estimate block, e.g. `SP-Label: sp:3`. On `omit`, skip this line.

Output exactly this shape (no preamble, no extra sections):

```
**<Title-label>:** <title in language.summary, following summaryStyle>

**<Body-label>:**

## <section 1 heading>
<content>

## <section 2 heading>
<content>

…

**<estimateHeading>:**

| Subtask | <hours label matching body lang> |
|---------|-------|
| …       | <h>   |
| …       | <h>   |
| **<sum label>** | **<h>** |

<mapping sentence in body lang> → **<N> SP** (<one-sentence matrix justification>).
<hedge sentence: could become <M> SP if <concrete edge>.>
```

Then immediately ask the field questions on separate lines — render them from `language.fieldQuestions.milestone` and `language.fieldQuestions.assignee`. Do not ask about issue type, labels (beyond the implicit bug/SP decisions above), priority, or anything else. If `milestone.mode: "none"`, skip the milestone question entirely.

**If the mapped SP is in `estimation.splitOptionalAt`**, add a third block *after* the field questions (localised to body lang):

```
**Alternatively — split into smaller issues:**

1. <Title 1 in summary lang> — ~<hours>h → <SP>
2. <Title 2 in summary lang> — ~<hours>h → <SP>
3. <…>

Create the single issue with <N> SP, or split into the <K> issues above (plus a tracking parent)?
```

Each sub-issue in the split should target ≤ `subTicketTargetMaxSp` SP if possible (one of 1 / 2 / 3 / 5 / 8 / 13). Don't fully expand each sub-issue's description yet — a one-liner title + hour estimate + mapped SP is enough at this stage. The user picks the route first; you flesh out the chosen one(s) afterwards.

**If the mapped SP is in `estimation.splitMandatoryAt`**, skip the single-issue proposal entirely. Only emit the split block and say explicitly: "<N> SP is not an option for this project — here are the split issues (plus a tracking parent)." (in body lang).

### Step 3 — Wait for confirmation + field decisions

The user will respond with:

- A confirmation phrase (from `language.confirmPhrases` or an obvious equivalent) or a rejection / edit request.
- Their milestone decision (affirmative → attach current milestone, silence / "no" / "empty" → leave empty).
- Their assignee decision (affirmative → self-assign via `assignee.login`, silence / "no" → leave empty).

If the user edits something ("make the title shorter", "add X in Background"), apply and re-show only the changed part, then ask again for confirmation. Don't call the API before an explicit green light.

If the user confirms without answering the field questions, assume both are "empty" and proceed — don't stall.

### Step 4 — Resolve the current milestone (only if needed)

Skip this step if the user declined milestones, or if `milestone.mode: "none"` in config.

If the user wants the current milestone:

1. Call the MCP's `list_milestones` (or equivalent) on `owner/repo` with state `open`.
2. Pick the milestone with the **nearest-future `due_on`** (skip milestones with no due date and milestones whose `due_on` is already in the past). Use its numeric `number` (the API identifier), not its title.
3. If zero open milestones have a future due date, ask the user whether to fall back to "no milestone" or pick one by hand from the list.
4. If two milestones are tied on due date, show both and ask.

### Step 5 — Build the create_issue payload

Call the MCP's `create_issue` (or `createIssue`) with:

```
owner:      "<github.owner>"
repo:       "<github.repo>"
title:      "<title as plain text — no leading #number, no KEY-prefix>"
body:       "<body as GitHub-flavoured markdown, as-is — no ADF conversion>"
labels:     [<defaultLabels…>, <github.bugLabel if bug>, <"sp:<N>" if estimation.mode == "labels">]
assignees:  ["<assignee.login>"]    # only if user said self-assign
milestone:  <number>                 # only if user confirmed milestone and Step 4 resolved one
```

Rules:

- **Labels** — compose the list from `github.defaultLabels` (always), plus `github.bugLabel` if the user signalled a bug **and** the label is non-empty, plus the `sp:<N>` label if `estimation.mode: "labels"`. Deduplicate. Don't invent any other labels.
- **assignees** — a list of login strings, not objects. Include only when the user confirmed self-assign. Omit the field entirely otherwise (don't send `[]`, don't send `null`).
- **milestone** — the numeric `number` from Step 4, not the title. Omit entirely when not set.
- Don't send `null` for any omitted field. Omit the key.

### Step 6 — Return the link, stop talking

Extract the issue URL from the `create_issue` response (most MCPs return the full `html_url`; if yours only returns the number, construct `https://github.com/<owner>/<repo>/issues/<number>`). Reply with a single line:

```
https://github.com/<owner>/<repo>/issues/<number>
```

No "I've created …", no description echo, no "let me know if …". The user will ask if they want more.

### Step 7 — Error handling

If `create_issue` fails:

- **404 / permission error** (repo not found, no write access, MCP not authenticated for this repo) → report the raw MCP error message and stop. Don't retry with a different owner/repo — the config is what it is.
- **Invalid label** (a label in the payload doesn't exist on the repo) → report which label was rejected. Ask the user whether to (a) retry without that label, or (b) create the label via `create_label` first and then retry. Prefer (b) for `sp:<N>` labels when `estimation.mode: "labels"` (the bootstrap was supposed to create them; this is a drift signal).
- **Invalid milestone** (the resolved number no longer exists) → ask whether to retry without the milestone field.
- **Invalid assignee** (the login doesn't exist or isn't a collaborator) → ask whether to retry without assignees.
- **Rate limit** (HTTP 403 with `x-ratelimit-remaining: 0` or explicit "secondary rate limit" message) → report the reset time from the response and stop. Don't burn retries against the limit.
- **Network / transient** → retry once. If it fails again, report and stop.

Never silently drop fields the user asked for. If you can't set a field, ask; don't create the issue without it.

## Split-ticket workflow (GitHub-specific)

When the user picks the split route (Step 2 alt-block) or a mandatory split triggers:

1. **Create each sub-issue first.** One `create_issue` call per sub-issue. Each follows the normal body-sections template — don't skimp, the sub-issues are the actual work. Collect the returned issue numbers in order.
2. **Then create the tracking parent.** Title = the original aggregated scope (one sentence). Body carries the same body-sections (Goal, Background, …) plus a trailing checklist referencing each sub-issue:

   ```markdown
   ## Sub-issues

   - [ ] #<n1> — <title of sub 1>
   - [ ] #<n2> — <title of sub 2>
   - …
   ```

   GitHub renders `- [ ]` items as progress trackers and the `#<n>` references as live links that reflect open/closed state.
3. **No labels on the parent except `defaultLabels`** — skip the SP label (the parent isn't sized on its own), skip the bug label (individual sub-issues carry it if applicable).
4. **Return only the parent link** at the end. The sub-issue links are reachable from the checklist; handing the user 4+ links is noise.

If creation of any sub-issue fails, stop immediately and report — don't create a parent that references issues that don't exist. The user can then retry the failed sub-issue and tell the skill to proceed.

## Common pitfalls

- **Drafting a proposal when the GitHub MCP isn't connected** — Step 0a must pass first. A beautifully written proposal is useless if the creation call will never reach GitHub; stop with a clear message instead.
- **Skipping Step 0b** and proceeding with guessed owner/repo when the config file is missing — always load or bootstrap the config first.
- **Hardcoding an owner/repo** that you remember from a previous conversation — always read it from `.claude/create-github-issue.json`; different repos = different targets.
- **Skipping the hour breakdown** and just writing "3 SP" — the breakdown is the whole point of the estimate, not decoration. Without it, the number is unjustified.
- **Picking the SP first, then reverse-engineering subtask hours to match** — this defeats the purpose. Hours first, number second.
- **Mixing languages within a part** — if summary is EN and body is DE, keep them strictly separate. Don't put an EN acceptance-criteria list under a DE body.
- **Adding a `#<number>` prefix or `owner/repo#` prefix to the title** — GitHub assigns the number after creation; the title holds only the sentence.
- **Calling `create_issue` right after showing the proposal** — always wait for explicit confirmation.
- **Sending `assignees: []` or `labels: null`** — omit the fields entirely when there's nothing to send. GitHub accepts `[]` but the empty array is noise on audit logs and on the created issue's JSON.
- **Recapping the issue after creation** — just the link. The user wanted a checkpoint for creation, not a retrospective.
- **Treating every bug-shaped note as an issue** — if the user hasn't framed it as an actionable task, ask first.
- **Silently emitting a split-optional-threshold issue without a split option** — the user wants to *see* the split alternative every time, even when they might ultimately keep the single issue. Omitting the split is paternalistic.
- **Offering a single-issue option at a split-mandatory threshold** — it's off the project matrix. Only the split is on the table.
- **Attaching more than one `sp:<N>` label** — bootstrap creates the full set; the skill must pick exactly one at creation time. Don't leave stale SP labels on the issue after edits either (not a v0.1 concern — but don't worsen it).
- **Sending a milestone title instead of the numeric `number`** — GitHub's API takes the integer ID; the title is display-only.
- **Leaking YAML frontmatter from an issue template** — strip the leading `---` block before rendering the body. The frontmatter governs GitHub's form UI, not the markdown body.
- **Inventing labels that the repo doesn't carry** — only use labels that exist (default set + bug label + `sp:*`). If you think a "priority" or "area" label would be nice, it's not your call; don't add it.
- **Creating a tracking parent before the sub-issues exist** — order matters. Sub-issues first so their numbers can be embedded in the parent's checklist.
- **Returning every sub-issue link plus the parent** at the end of a split — just the parent. The checklist in the parent body makes all sub-issues one click away.
- **Mixing `create-github-issue` with `create-jira-task`** — these are sibling skills, not fallbacks for each other. If the user says "Jira", that's the Jira skill's turn; if they say "GitHub", it's this skill's. Don't open a GH issue for a todo the user wanted in Jira just because the MCP is handier.
