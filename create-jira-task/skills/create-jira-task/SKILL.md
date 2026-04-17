---
name: create-jira-task
description: Turn a rough request into a full Jira ticket via the Atlassian MCP. Two-phase flow — proposal (title, body, SP estimate with visible hour breakdown) → per-ticket confirmation → `createJiraIssue` → return the link. Project (cloudId, keys, custom fields), language convention (summary/body), SP matrix and split thresholds are configured per-repo via `.claude/create-jira-task.json`; defaults apply when keys are absent. USE THIS WHENEVER the user asks — in English or German — to turn something into a Jira task / ticket / issue, e.g. "mach daraus einen Jira-Task", "erfasse das als Ticket", "schreib mir ein Jira-Ticket für …", "leg einen Task in Jira an", "create a Jira task for …", "open a ticket for …", "Task-Beschreibung für …", "Jira-Issue für …", "erstelle ein Ticket für diesen Bug", "daraus bitte ein Ticket". Do NOT use when the user only wants a partial artifact (title only, description only, SP only), when they only want an hour estimate without the SP matrix mapping, or for bug reports that are just notes with no task character.
---

# Create a Jira ticket

This is a two-phase interaction:

1. **Proposal phase** — produce title, body (acceptance criteria included), SP estimate with a visible hour breakdown. Show it to the user in chat. Ask the two field questions (Sprint? Assignee?).
2. **Creation phase** — only after explicit per-ticket confirmation, call `createJiraIssue` via the Atlassian MCP with the agreed fields, then return the link. Nothing else after that.

**Never collapse these phases** — the user wants the checkpoint.

## When to use

Invoke when the user's intent is: take a described piece of work and turn it into a real Jira ticket. Match intent, not exact wording.

**MUST trigger:**
- "mach daraus einen Jira-Task"
- "erfasse das als Ticket"
- "schreib mir ein Jira-Ticket für …"
- "leg einen Task in Jira an"
- "daraus bitte ein Ticket"
- "erstelle ein Ticket für diesen Bug" → use issue type **Bug**
- "create a Jira task for …"
- "open a ticket for the work above"
- "Task-Beschreibung + SP für …"
- "Jira-Issue anlegen"

**MUST NOT trigger:**
- "nur den Titel formulieren" / "only give me a title" → partial, answer directly
- "nur die Beschreibung, kein Ticket" → partial, answer directly
- "was würdest du schätzen in Stunden?" → hours-only, no SP matrix, no Jira
- "review ticket ABC-123" → not creation
- a pure bug note with no task character ("seltsam, dass X passiert") → first clarify, don't auto-ticket

## Step 0 — Preconditions

Run **both** checks below before drafting anything. If either fails, stop — drafting a proposal that can't be submitted is waste.

### 0a. Atlassian MCP must be connected

Every write and the sprint/assignee lookups go through the Atlassian MCP. Inspect the session's available tools for any entry whose name matches `mcp__*atlassian*`, `mcp__*jira*`, or `mcp__*rovo*` (common server names include `claude_ai_Atlassian_Rovo`, `atlassian`, `atlassian-mcp`, `rovo`, `jira`). Specifically, `createJiraIssue` must exist somewhere in the toolset.

**If no matching MCP tool is present**, reply exactly once and stop:

```
Kein Atlassian/Jira-MCP in dieser Session registriert — ich kann das Ticket nicht anlegen.
Installier einen Atlassian-MCP (z. B. Rovo) und lade die Session neu, dann geht's.
```

Don't produce a proposal as a "dry run": without the MCP the user can't act on it, and the draft just creates noise that has to be redone later.

### 0b. Load the project configuration


Read `<repo-root>/.claude/create-jira-task.json`. That file carries the Jira target and any project-specific overrides. Resolve `<repo-root>` from the current working directory (walk up to the git toplevel; if not in a repo, use cwd).

**If the file is missing:** ask the user once whether to create it. If yes, offer to bootstrap it via the Atlassian MCP:

1. `getAccessibleAtlassianResources` → pick the cloudId + site
2. `getVisibleJiraProjects` → pick the project key + id
3. `getJiraProjectIssueTypesMetadata` → resolve Task / Bug issue-type ids
4. `getJiraIssueTypeMetaWithFields` → find the Story Points custom field id and the Sprint custom field id
5. **Probe the Sprint field schema** to decide cardinality. In the `getJiraIssueTypeMetaWithFields` response, look at the sprint field's `schema`:
   - `schema.type == "array"` → write `"sprintCardinality": "array"` (standard Jira default — the field holds a list of sprint ids).
   - `schema.type == "number"` (or any non-array scalar) → write `"sprintCardinality": "scalar"` (the field holds a single sprint id, no wrapping array).
   - If the schema is ambiguous or unreadable, default to `"array"` and note it — the user can correct it by hand after the first failed create.

Write the result to `.claude/create-jira-task.json` and continue. If the user declines, stop and explain that the Jira target is required — don't guess IDs.

**If the file exists but is missing required keys (`jira.cloudId`, `jira.site`, `jira.projectKey`, `jira.issueTypes.task`, `jira.customFields.storyPoints`):** stop and ask the user to fill them, pointing at `config.example.json` in this skill directory for reference.

## Readiness check (lightweight probe, for other skills)

Other skills (e.g. `todo-buffer`) may want to know whether create-jira-task is "ready for this project" before routing work here. This section defines that contract. When invoked as a readiness probe:

- **Input:** none — the caller just wants a yes/no answer for the current project.
- **Output:** exactly one token: `ready` or `not-ready`. No explanation, no plan, no proposal.
- **Side effects:** none. Don't ask the user anything. Don't start a bootstrap. Don't write files. Don't emit a draft.

**Procedure (read-only):**

1. **MCP probe** — check the session tool list for `mcp__*atlassian*` / `mcp__*jira*` / `mcp__*rovo*`, and confirm `createJiraIssue` is reachable. (Same detection as Step 0a, but without the user-facing error message.)
2. **Config probe** — check that `<repo-root>/.claude/create-jira-task.json` exists and contains all required `jira.*` keys. (Same check as Step 0b, but silent — don't offer to bootstrap.)
3. Both pass → emit `ready`. Either fails → emit `not-ready`.

This is a pure probe. If the caller wants to act on a `not-ready` result (e.g. offer a bootstrap), it must do so in its own flow — don't take that decision here. Step 0's interactive bootstrap flow only runs when the user explicitly triggered create-jira-task to create a ticket, not when another skill is probing readiness.

**Schema (all keys below `jira` are required; everything else is optional and falls back to the defaults in the next section):**

```json
{
  "jira": {
    "cloudId": "<uuid>",
    "site": "<subdomain>.atlassian.net",
    "projectKey": "<KEY>",
    "projectId": "<numeric>",
    "issueTypes": { "task": "<id>", "bug": "<id>" },
    "customFields": { "storyPoints": "customfield_<n>", "sprint": "customfield_<n>" },
    "sprintCardinality": "array|scalar"
  },
  "assignee": { "email": "<user email>" },
  "language": {
    "summary": "en|de|…",
    "body": "en|de|…",
    "summaryStyle": "<one-line instruction, e.g. 'imperative, <= ~70 chars, no ticket prefix'>",
    "bodySections": [
      { "heading": "<h2 text>", "purpose": "<what belongs here>", "required": true|false, "format": "checkbox-list|freeform" (optional), "skipWhen": "<condition>" (optional) }
    ],
    "estimateHeading": "<h2 text>",
    "fieldQuestions": { "sprint": "<question>", "assignee": "<question>" },
    "confirmPhrases": ["ja", "anlegen", "ok", "create it", "mach", "leg an"]
  },
  "estimation": {
    "matrix": [ { "sp": 1, "label": "<budget>" }, … ],
    "splitOptionalAt": [21, 34, 55],
    "splitMandatoryAt": [89],
    "subTicketTargetMaxSp": 13
  }
}
```

## Defaults (apply when a config key is absent)

**Language** — summary `en`, body `en`, summary style `"imperative, <= ~70 chars, no ticket prefix"`. Body sections:

| Heading             | Purpose                                                              | Required | Skip when            |
|---------------------|----------------------------------------------------------------------|----------|----------------------|
| Goal                | what should exist afterwards — the WHAT + WHY                        | yes      | —                    |
| Background          | context, what already exists, why now                                | no       | trivial bugfix       |
| Acceptance Criteria | checkbox list of testable points                                     | yes      | —                    |
| Technical Notes     | concrete file paths, function names, migrations, config keys         | no       | trivial ticket       |

Estimate heading: `Estimate`. Field questions: `Sprint: add to current sprint, or leave empty?` / `Assignee: assign to you, or leave empty?`. Confirm phrases: `yes, create it, ok, do it, create, go`.

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

Split thresholds: optional at 21 / 34 / 55 SP (offer both paths, user decides); **mandatory** at 89 SP (don't offer the single ticket). Sub-tickets in a split should target ≤ 13 SP each.

## Non-negotiable rules

1. **Language split is from config.** If `language.summary` ≠ `language.body`, keep them strictly in their configured languages (e.g. EN summary + DE body). Don't mix within a part.
2. **Title format follows `language.summaryStyle`.** For the default style: imperative verb, ≤ ~70 chars, no ticket prefix (tickets have no key until Jira assigns one).
3. **SP estimate only with a visible hour breakdown.** First list subtasks with hour budgets, sum them, **then** map the sum onto the project matrix. Never pick an SP number first and rationalise afterwards.
4. **Round up at matrix boundaries.** If the sum lands between two SP values, take the larger.
5. **At `estimation.splitOptionalAt` values, always offer a split — but let the user decide.** Those ticket sizes *can* exist; they just shouldn't do so silently. Alongside the normal proposal, sketch a concrete split into smaller tickets (each ≤ `subTicketTargetMaxSp` if possible) and ask the user which route they want. Do not create the single ticket without hearing back. This applies equally to Task and Bug.
6. **At `estimation.splitMandatoryAt` values, split is mandatory.** Do not offer the single-ticket route; propose a split and make clear that "one big ticket" is not on the table.
7. **One ticket = one explicit confirmation.** No batch approval. The user must say something from `language.confirmPhrases` (or an obvious equivalent) for each ticket individually before any `createJiraIssue` call.
8. **Never fill in fields the user didn't ask for.** No labels, components, fix versions, priority, parent, attachments, team. Project-side defaults handle themselves.
9. **After creation, return only the ticket link.** No recap, no "I created X with …", no summary of what you just agreed on two messages ago.
10. **Max 1–2 clarifying questions.** If scope is genuinely unclear, ask. Otherwise proceed with stated assumptions and note them in the Background section.
11. **Title never repeats the project key.** Jira adds `<KEY>-xxx` itself.

## Workflow

### Step 1 — Extract the work to be ticketed

The input is usually conversation context: a feature request, a bug report, a piece of discussion, or a paragraph the user just pasted. Before proposing anything:

- Identify the **WHAT** (what should exist afterwards) and the **WHY** (user value or constraint behind it).
- Note concrete artifacts the user already mentioned: file paths, function names, migrations, UI views, config flags. These go into the "Technical Notes" (or equivalent) section if configured.
- If the character is clearly a bug (something regressed / misbehaves), plan to use issue type **Bug** (`jira.issueTypes.bug`). Otherwise **Task** (`jira.issueTypes.task`).

If the scope is too fuzzy to write a sane title, ask one clarifying question. Don't ask two if one would do.

### Step 2 — Draft the proposal in chat

Build the proposal from config:

- **Title label:** localised to `language.summary` (e.g. `**Title (EN):**` for English, `**Titel (EN):**` for German UI with EN summary).
- **Body label:** localised to `language.body`.
- **Body sections:** use `language.bodySections` in the order listed, each as an H2. Omit non-required sections when their `skipWhen` condition applies; otherwise fill them.
- **Acceptance Criteria format:** if a section has `"format": "checkbox-list"`, render as `- [ ] …` items; otherwise freeform.
- **Estimate block:** `**${language.estimateHeading}:**` followed by a table of subtasks + hours, summed, then one line mapping the sum to SP with a matrix-based justification, and one line with the next-higher SP hedge.

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

Then immediately ask the field questions on separate lines — render them from `language.fieldQuestions.sprint` and `language.fieldQuestions.assignee`. Do not ask about issue type, project, priority, labels, or anything else. If the user clearly flagged it as a bug, pick Bug and add a leading line `<Type-label>: Bug` (in body lang) to the proposal.

**If the mapped SP is in `estimation.splitOptionalAt`**, add a third block *after* the field questions (localised to body lang):

```
**Alternatively — split into smaller tickets:**

1. <Title 1 in summary lang> — ~<hours>h → <SP>
2. <Title 2 in summary lang> — ~<hours>h → <SP>
3. <…>

Create the single ticket with <N> SP, or split into the <K> tickets above?
```

Each sub-ticket in the split should target ≤ `subTicketTargetMaxSp` SP if possible (one of 1 / 2 / 3 / 5 / 8 / 13). Don't fully expand each sub-ticket's description yet — a one-liner title + hour estimate + mapped SP is enough at this stage. The user picks the route first; you flesh out the chosen one(s) afterwards.

**If the mapped SP is in `estimation.splitMandatoryAt`**, skip the single-ticket proposal entirely. Only emit the split block and say explicitly: "<N> SP is not an option for this project — here are the split tickets." (in body lang).

### Step 3 — Wait for confirmation + field decisions

The user will respond with:

- A confirmation phrase (from `language.confirmPhrases` or an obvious equivalent) or a rejection / edit request.
- Their sprint decision (affirmative → use current sprint, silence / "no" / "empty" → leave empty).
- Their assignee decision (affirmative → self-assign via `assignee.email`, silence / "no" → leave empty).

If the user edits something ("make the title shorter", "add X in Background"), apply and re-show only the changed part, then ask again for confirmation. Don't call the API before an explicit green light.

If the user confirms without answering the field questions, assume both are "empty" and proceed — don't stall.

### Step 4 — Resolve the current sprint (only if needed)

Skip this step if the user declined or didn't mention sprint, or if `jira.customFields.sprint` is absent in config (sprint not tracked for this project).

If the user wants the current sprint:

1. Call `getVisibleJiraProjects` with `cloudId` to confirm access.
2. Locate the board / sprint for the project. Use the Agile endpoints via the MCP — look for a function that lists sprints for the project's board, and pick the one with `state: "active"`.
3. Use the **sprint id** (number), not the sprint name. The sprint custom field takes an array of numeric ids (common Jira convention; verify with `getJiraIssueTypeMetaWithFields` if unsure).

If exactly one active sprint exists → use it silently. If zero or multiple active sprints exist → show them to the user and ask which one (or fall back to leaving the field empty).

### Step 5 — Build the createJiraIssue payload

Call `createJiraIssue` on the Atlassian MCP with `cloudId = jira.cloudId` and these fields (substituting from config):

```
fields:
  project:      { key: "<jira.projectKey>" }
  issuetype:    { id: "<jira.issueTypes.task or .bug>" }
  summary:      "<title>"
  description:  "<body as markdown>"               # MCP handles ADF conversion
  <jira.customFields.storyPoints>: <SP number>
  <jira.customFields.sprint>: <sprint-id>          # only if user confirmed and sprint field is configured — SHAPE depends on jira.sprintCardinality (see below)
  assignee:     { accountId: "<lookup>" }          # only if user said self-assign
```

**Sprint field shape** — driven by `jira.sprintCardinality` (defaults to `"array"` when absent):

- `"array"` (Jira default, multi-select sprint field) → send `[<sprint-id>]` — a list with one numeric id.
- `"scalar"` (single-select sprint field, found in some customized projects) → send just `<sprint-id>` — the number itself, no wrapping array.

Sending an array where the field expects a scalar (or vice versa) produces a type error from Jira. If the config doesn't declare the cardinality, probe the field schema via `getJiraIssueTypeMetaWithFields` the same way bootstrap does, but don't silently write to the config file from here — just use the probed value for this call and tell the user to add `"sprintCardinality"` to the config for next time.

Only include the sprint custom field and `assignee` when the user actually asked for them. Omit every other field entirely — don't send `null`, don't send empty arrays.

For the assignee lookup, use `lookupJiraAccountId` or `atlassianUserInfo` against `assignee.email` from config. Always look it up fresh — don't cache the accountId.

### Step 6 — Return the link, stop talking

Extract the issue key from the `createJiraIssue` response and reply with a single line:

```
https://<jira.site>/browse/<ISSUE-KEY>
```

No "I've created …", no description echo, no "let me know if …". The user will ask if they want more.

### Step 7 — Error handling

If `createJiraIssue` fails:

- **Permission / field error** (unknown custom field, forbidden transition, required field missing) → report the raw MCP error message to the user and stop. Do not retry with a different payload unless the user asks. If the error mentions a custom field id that isn't in config, don't silently substitute — ask the user to update `.claude/create-jira-task.json`.
- **Network / transient** → retry once. If it fails again, report and stop.
- **Sprint id mismatch** (the sprint we resolved no longer exists) → report and ask whether to retry without the sprint field.

Never silently drop fields the user asked for. If you can't set the sprint, ask; don't create the ticket without it.

## Common pitfalls

- **Drafting a proposal when the Atlassian MCP isn't connected** — Step 0a must pass first. A beautifully written proposal is useless if the creation call will never reach Jira; stop with a clear message instead.
- **Skipping Step 0b** and proceeding with guessed IDs when the config file is missing — always load or bootstrap the config first.
- **Hardcoding a project key** that you remember from a previous conversation — always read it from `.claude/create-jira-task.json`; different repos = different projects.
- **Skipping the hour breakdown** and just writing "3 SP" — the breakdown is the whole point of the estimate, not decoration. Without it, the number is unjustified.
- **Picking the SP first, then reverse-engineering subtask hours to match** — this defeats the purpose. Hours first, number second.
- **Mixing languages within a part** — if summary is EN and body is DE, keep them strictly separate. Don't put an EN acceptance criteria list under a DE body.
- **Adding a `[KEY-xxx]` prefix to the title** — Jira assigns the key after creation; the summary field holds only the sentence.
- **Calling `createJiraIssue` right after showing the proposal** — always wait for explicit confirmation.
- **Sending `assignee: null` or the sprint field as `[]`** — omit the fields entirely when the user didn't ask for them.
- **Recapping the ticket after creation** — just the link. The user wanted a checkpoint for creation, not a retrospective.
- **Treating every bug-shaped note as a ticket** — if the user hasn't framed it as an actionable task, ask first.
- **Silently emitting a split-optional-threshold ticket without a split option** — the user wants to *see* the split alternative every time, even when they might ultimately keep the single ticket. Omitting the split is paternalistic.
- **Offering a single-ticket option at a split-mandatory threshold** — it's off the project matrix. Only the split is on the table.
- **Using the sprint name instead of the sprint id** in the sprint custom field — Jira expects a numeric id.
- **Ignoring `jira.sprintCardinality`** and always wrapping the sprint id in an array — in Jira projects configured as single-select sprint, the field expects the raw number and rejects `[42]` with a type error. Bootstrap auto-detects this; if your config predates the option, add `"sprintCardinality": "scalar"` or `"array"` explicitly.
- **Hardcoding `accountId` for the assignee** — look it up each time via the MCP; accountIds can change, and the skill shouldn't carry personal data.