---
name: todo-buffer
description: Lightweight personal todo buffer stored in a single markdown file. Trigger whenever the user (a) prefixes a message with "todo:" / "Todo:" / "TODO:" (captures with project reference) or "todo!" / "Todo!" / "TODO!" (captures without project reference) to add a new item, (b) writes exactly "todos?" (case-insensitive) for a scoped quick-list, (c) asks ANYTHING else about their todos — see/list/show/check/look-again ("was liegt im speicher", "zeig meine todos", "welche todos habe ich", "welche todos liegen da", "ich will todos erstellen", "was habe ich im todo-speicher", "schau (nochmal) nach todos", "show my todos", "list my todos", "check my todos", "look again"), or (d) is about to create a Jira ticket — in which case always consult the buffer to (1) check whether the proposed ticket duplicates an existing buffered todo and (2) offer to process the remaining buffered todos afterwards. ALWAYS route todo-related questions through this skill — never answer them via ad-hoc `find` / `ls` / `cat` on random paths. Do NOT trigger when the user asks you to track progress on the current task (that's Claude's internal TodoWrite, which is unrelated), when "todo" appears incidentally inside code, or when the user is asking about generic productivity advice.
---
 
# Todo Buffer
 
A tiny personal note-taking buffer for Dennis: capture a thought now, turn it into a proper Jira ticket later. The buffer lives in a single markdown file so it can be read, grepped, and edited by hand if needed.
 
## Why this exists
 
Ideas and tasks show up in the middle of unrelated work. Stopping everything to write a full Jira ticket kills the flow — the create-jira-task skill wants title, German description, hour breakdown and SP mapping, which is the right amount of work for a *real* ticket but the wrong amount of work for a one-line "oh, we should also do X". The todo buffer is the holding area between "I just had a thought" and "now I'm ready to groom these into tickets".
 
## Storage
 
Single file: `~/.claude/todo-buffer/todos.md` (on Windows this resolves to `C:\Users\DennisEisold\.claude\todo-buffer\todos.md`).
 
This path is intentional:
 
- `~/.claude/` is persistent across sessions and projects, so todos survive.
- It sits outside any project directory, so the buffer is available regardless of which project Dennis has open.
- It is separate from `MEMORY.md` and the individual memory files — do **not** index `todos.md` from `MEMORY.md`. The buffer is a working queue, not a memory fact. Keeping them separate means memory consolidation passes won't sweep todos away.
- Always use `~` (not a hard-coded absolute path) so the skill works on both Windows and POSIX shells. If the directory doesn't exist yet, create it before writing.

## Permission check (run once per skill invocation, before any capture/edit)
 
For capture and buffer edits to work without an approval dialog, `~/.claude/settings.json` must contain these allow rules:
 
- `Edit(~/.claude/todo-buffer/todos.md)`
- `Write(~/.claude/todo-buffer/todos.md)`
- `Read(~/.claude/todo-buffer/todos.md)`
- `Bash(date:*)`
 
Before doing any file write on behalf of the user, check the settings file once:
 
1. Read `~/.claude/settings.json`. If `permissions.allow` doesn't include all four rules above, the skill is running unpermissioned.
2. Tell the user explicitly and ask whether to add them:
   ```
   Hinweis: Die Todo-Buffer-Permissions fehlen in ~/.claude/settings.json — du bekommst sonst bei jedem Capture einen Approval-Dialog.
   Soll ich sie anlegen? (ja/nein)
   ```
3. On "ja": merge the missing rules into `permissions.allow` (never replace the array — read first, merge, write back). On "nein" or silence: proceed without adding them; the user will see approval dialogs for this session but nothing breaks.
4. Don't re-prompt within the same turn. If you already asked and got an answer (including "nein"), don't ask again for subsequent captures in the same conversation.
 
Skip this check entirely if the file already has all four rules — no confirmation message when everything is in order.
 
### File format
 
Use this exact layout. The header and HTML comment are there so a human opening the file knows what it is.
 
```markdown
# Todo Buffer
 
<!-- Managed by the todo-buffer skill. Each item: "- [YYYY-MM-DD HH:MM] [<project>] <text>" (project tag optional). Add new items at the bottom. -->
 
- [2026-04-16 14:23] [backend-api] payment provider client fails with 502 — add retry with backoff
- [2026-04-16 15:45] release pipeline: add staging smoketest before prod promote
```
 
Rules:
 
- One item per line, always prefixed with `- [YYYY-MM-DD HH:MM] `.
- Optional project tag `[<project>]` directly after the timestamp. If present, it's the repo/project the capture originated from. Absent means either a `todo!` opt-out capture or a capture from outside any recognisable project.
- Append new items at the bottom (chronological order — newest last).
- Timestamps are local time; get the current time from the shell (`date +"%Y-%m-%d %H:%M"`) rather than guessing.
- Preserve the header and the HTML comment. If the file doesn't exist yet, create it with the header block above.
- No other sections, no grouping, no status markers. Flat list.
If the file grows past ~50 items, suggest to the user that it's time to process some of them — don't silently reorganize.

## Ticket-system readiness protocol

todo-buffer can hand a todo off to a ticket-creation skill (Jira, GitHub Issues, …), but it does NOT inspect MCPs, config files, or skill internals to decide whether that's possible. Instead, each ticket-system skill exposes a lightweight "Readiness check" contract that answers one question for the current project: `ready` or `not-ready`. todo-buffer just calls it.

**Known ticket-system skills** (extend this list when new ones ship):

| Skill | Target |
|-------|--------|
| `create-jira-task` | Jira (Atlassian) |
| `create-github-issue` | GitHub Issues |

**How to invoke the readiness check on skill `X`:**

1. Verify skill `X` is present in the current session's skill listing. If not, treat as `not-ready` without further probing.
2. Follow `X`'s documented "Readiness check" section. The contract is uniform across ticket-system skills:
   - Output is exactly one token: `ready` or `not-ready`.
   - No user-facing questions, no bootstraps, no file writes, no draft tickets — it's a silent probe.
3. Collect the result.

**Aggregating:**

- If any skill returns `ready` → the ticket path is available (Case 1 in the list step).
- If none returns `ready` → check the per-project decline marker (see next section) to decide whether to offer setup (Case 2) or stay quiet (Case 3).

Never fall back to inspecting MCP tool lists, config JSONs, or other skill internals from within todo-buffer. If a readiness check is ambiguous or throws, treat it as `not-ready`.

## Per-project settings

Some todo-buffer decisions are per-project (specifically: whether the user has declined the setup offer). Store them in a single JSON file:

- **Path:** `~/.claude/todo-buffer/project-settings.json` — same directory as `project-aliases.json`, so both per-project files live together.
- **Shape:** a flat object keyed by `cwd:<absolute-project-root>` (the `cwd:` prefix is the same MSYS-safe convention `project-aliases.json` uses). Resolve `<absolute-project-root>` via git toplevel, or cwd if not in a repo.
- **Value:** an object with one or more settings fields. Currently used fields:
  - `ticketSetupDeclined` (boolean): user said "nein" to the setup offer for this project.
  - `ticketSetupDeclinedAt` (ISO timestamp): when they said it.

**Example:**

```json
{
  "cwd:/c/Users/example/Projects/some-repo": {
    "ticketSetupDeclined": true,
    "ticketSetupDeclinedAt": "2026-04-17T10:30:00Z"
  }
}
```

**Rules:**

- Read: load the file (or treat as `{}` if missing). Look up the entry under `cwd:<project-root>`. Absent key = no answer recorded yet (ask Case 2).
- Write: merge into the existing object — never overwrite other projects' entries, and never overwrite other fields within the same project's entry.
- If the user later wants to re-enable the setup offer for a project, they can delete their entry by hand or ask the skill to clear it. todo-buffer does not expose an automatic "reset" command — the file is meant to be edited by humans when needed.

## The three operations
 
### 1. Capture — user writes `todo: <text>` or `todo! <text>`
 
Trigger: the message starts with `todo:` / `Todo:` / `TODO:` (capture **with** project reference, default) or `todo!` / `Todo!` / `TODO!` (capture **without** project reference, opt-out). Case-insensitive, optional leading whitespace.
 
Steps:
 
1. Strip the prefix (`todo:` or `todo!`) and any surrounding whitespace. What remains is the todo text. Remember which marker was used — it decides whether to attach a project tag.
2. Determine the project tag (only if the marker was `todo:`):
   - Try to detect the git repository root. Use whatever's available in the current shell: `git rev-parse --show-toplevel` on POSIX/Git Bash, `git.exe rev-parse --show-toplevel` on PowerShell, etc. If the command succeeds, take the last path component (basename) as the tag.
   - If the probe fails for *any* reason (git not installed, not inside a repo, permission denied, ...), treat as non-git and consult `~/.claude/todo-buffer/project-aliases.json`. Keys in that file are `cwd:<absolute-path>` (the `cwd:` prefix exists to defeat MSYS path translation on Git Bash — keep it even if you're on a system where it wouldn't matter, so the mapping stays portable).
   - If the current cwd has a mapped value, use it — an empty string means "user picked global, no tag".
   - If there's neither a git repo nor a stored alias, enter the **1d. Non-git capture flow** below. Never invent a project name.
   - If the marker was `todo!`, skip this whole step — no tag, no git probe, no alias lookup.
3. Get the current local time in the format `YYYY-MM-DD HH:MM`. Any means works: `date +"%Y-%m-%d %H:%M"` in bash/zsh, `Get-Date -Format "yyyy-MM-dd HH:mm"` in PowerShell, Python/Node one-liners, whatever the environment offers. Don't guess — always query the shell.
4. Read `todos.md` (create it if absent — just an empty file is fine; the header is optional).
5. Append the new line at the bottom using Edit/Write:
   - With tag: `[<timestamp>] [<project>] <text>`
   - Without tag: `[<timestamp>] <text>`
6. Reply with a one-line confirmation that includes the total count and — if a tag was attached — the project name, e.g. `Gespeichert in backend-api (3 Todos im Puffer).` or `Gespeichert ohne Projekt-Ref (3 Todos im Puffer).` Don't echo the full text back, don't summarise, don't list the other items. The user knows what they just wrote.
 
**Tool usage:** When helper tools like `jq`, `git`, `awk`, or `grep` are available, feel free to use them — they make many of these steps one-liners. When they aren't, use the Claude Code Read/Write/Edit/Bash tools instead; the logic stays the same. Never fail just because a helper is missing.
Duplicate handling (scoped to the current project/global context):
 
- **Exact match within scope** — same text, same project tag (or both untagged for `todo!`): don't add a duplicate, reply `Steht schon drin, nichts geändert.` and stop.
- **Same text in a different project** — that's NOT a duplicate. Two repos can legitimately share the same todo ("add README"). Append as normal.
- **Similar (not identical) within scope** — Jaccard token overlap ≥ 0.7 but not exact. Enter the Similarity-Flow (see below).
 
### 1d. Non-git capture flow (first-time folder, no alias)
 
Triggered when the capture hook runs `todo:` in a directory that is (a) not inside a git repo and (b) has no entry in `~/.claude/todo-buffer/project-aliases.json` yet. The hook passes control here via `additionalContext` and has NOT written the todo.
 
The additionalContext provides:
- `cwd` — absolute path of the current directory.
- `basename` — the last path component, suggested as default project name.
- `text` — the todo text.
- Instructions to write the entry and persist the alias.
 
Steps:
 
1. Ask the user:
   ```
   Der aktuelle Ordner ist kein Git-Repo. Soll ich "<basename>" als Projekt-Tag nehmen, einen anderen Namen nutzen, oder das Todo global (ohne Tag) speichern?
   (basename / <eigener Name> / global)
   ```
2. Parse the answer:
   - `basename` (or "ja", confirmation) → tag = `<basename>`.
   - Any other string → tag = that string (trimmed).
   - `global` / `ohne` / `kein` → tag = `""` (empty string, meaning no tag).
3. Append the entry to `~/.claude/todo-buffer/todos.md`:
   - Get a timestamp in `YYYY-MM-DD HH:MM` format from whatever shell you have (bash `date`, PowerShell `Get-Date`, ...).
   - With tag: `[<timestamp>] [<tag>] <text>` — without tag: `[<timestamp>] <text>`.
4. Persist the alias in `~/.claude/todo-buffer/project-aliases.json`:
   - Key: `cwd:<absolute-path>` (the `cwd:` prefix is mandatory — it prevents Git Bash from translating unix-style `/tmp/foo` paths into Windows paths).
   - Value: the chosen tag (empty string if user picked global).
   - Read the file (or start with `{}` if it doesn't exist), add/update the mapping, and write it back. Any method is fine — Edit/Write tool, or `jq` if it's available. Don't overwrite existing keys.
5. Confirm with the normal one-liner (`Gespeichert in <tag> (N Todos im Puffer).` or `Gespeichert ohne Projekt-Ref (N Todos im Puffer).`).
 
From now on, the hook will use the stored alias for this folder and skip the question entirely. If the user later wants to change the alias for a folder, they can edit `project-aliases.json` by hand or ask you to update it.
 
### 1b. Capture similarity flow (triggered by hook additionalContext)
 
When the capture hook detects a similar-but-not-identical existing entry in the same scope, it **does not write** the new todo and instead hands control to this skill via `additionalContext`. The context gives you:
- The candidate line (timestamp + optional tag + text).
- The text the user just tried to capture.
- The Jaccard similarity score (for reference only).
- The exact line to append if the user confirms "eintragen".
 
Steps in this flow:
 
1. Show the candidate to the user and ask clearly:
   ```
   Im Puffer gibt es schon einen ähnlichen Eintrag:
     <candidate line>
   Ist das dasselbe Todo, oder soll ich es trotzdem eintragen? (gleich / eintragen / abbrechen)
   ```
2. Wait for the answer.
   - **"gleich" / "ja dasselbe" / "skip"** — do nothing, reply `Ok, bleibt beim bestehenden Eintrag.` Don't modify the buffer.
   - **"eintragen" / "trotzdem"** — append the exact line from the `additionalContext` (the hook already formatted it with timestamp + scope tag). Reply with the normal capture confirmation (`Gespeichert in <proj> (N Todos im Puffer).` or the global variant).
   - **"abbrechen" / "nein"** — neither add nor confirm anything, just acknowledge with `Ok, abgebrochen.`
3. Never silently add or discard — every outcome needs an explicit reply.
 
Edge cases:
 
- Multi-line todos: if the user writes `todo:`/`todo!` on one line and the actual text on the next (or uses the marker followed by several sentences), collapse it to a single line. If collapsing would lose meaning, ask the user to split it into separate todos.
- Empty `todo:`/`todo!` — ask what the todo is; don't write an empty line.
- Git probe fails (no git, detached state, etc.) — treat as "no project available" and write without tag; do not surface the error.
### 2a. Quick list — user writes `todos?` [argument]
 
Trigger: the message starts with `todos?` (case-insensitive, optional surrounding whitespace), optionally followed by an argument. This is a fast-path shortcut — normally the capture hook handles it without invoking the model. The skill only becomes relevant if the hook can't run (missing deps, non-bash environment, ...).
 
Variants:
 
- `todos?` (no argument) — scope auto-detected from cwd:
  - **Inside a git repo** → show only entries with a `[<repo-basename>]` tag.
  - **Non-git but an alias is stored** → use the alias. Empty alias = "global" → entries without a tag.
  - **No scope** → show the full buffer, no footer.
- `todos? all` / `todos? alle` / `todos? *` → full buffer regardless of cwd.
- `todos? global` / `todos? untagged` / `todos? ohne` → only entries without a project tag.
- `todos? <name>` → entries tagged with `<name>`. Known projects are gathered from both existing buffer tags and non-empty values in `project-aliases.json` (both are effectively global registries — no per-cwd scoping). Matching is:
  1. Exact, case-insensitive — straight hit.
  2. Single substring match — use it, prepend a `(Übereinstimmung: "<full name>")` hint line so the user sees which project was resolved.
  3. Multiple substring matches — list the candidates and ask the user to pick a more specific name.
  4. No match — reply with the argument and the list of known projects.
 
For any project-scoped listing, drop the `[<project>]` tag from each shown line (the header already names the scope). If entries outside the scope exist, append a footer (`noch N weiteres Todo im Buffer außerhalb dieses Projekts` / `noch N projekt-spezifische Todos im Buffer`). Singular/plural must match the count. Don't ask a follow-up question — `todos?` is a pure read.
 
### 2. List — user asks to see the buffer
 
Trigger phrases: "ich will todos erstellen", "was liegt im todo-speicher", "zeig mir meine todos", "welche todos habe ich", "show my todos", "list todos", or similar wording. Also trigger proactively when the user has clearly finished a block of work and starts talking about "abarbeiten" / "grooming" / "tickets anlegen" without specifying a source.
 
Steps:
 
1. Read `todos.md`. If the file doesn't exist or has no item lines, reply `Der Puffer ist leer.` and stop.
2. Print the list as-is — keep the timestamp prefixes so the user can see when each was captured. Use an ordered list (1., 2., 3.) so subsequent references like "nimm #2" have an anchor:
   ```
   **Todo-Puffer** (N Einträge):
   1. [2026-04-16 14:23] payment provider client fails with 502 — add retry with backoff
   2. [2026-04-16 15:45] release pipeline: add staging smoketest before prod promote
   ```
 
3. After printing, decide whether to offer a ticket-creation path. Do **not** inspect MCPs, config files, or skill internals from here — that's the ticket-system's concern. Instead, invoke each known ticket-system skill's **Readiness check** (see section "Ticket-system readiness protocol" below) and collect the yes/no answers.

   **Case 1 — at least one ticket system returns `ready`.** Offer the tasks: ask `Welche davon sollen wir als Tasks anlegen? (Nummer nennen, oder 'alle', oder 'später')` (when only Jira is ready, it's implicit; if multiple systems are ready and the user's answer isn't obvious from context, ask which system once and remember the choice for this listing session). Then wait.

   **Case 2 — no system is ready, and the user has NOT declined setup in this project** (see "Per-project settings" below for how to check). Ask exactly once:

   ```
   Für dieses Projekt ist kein Ticketsystem eingerichtet. Willst du eines einrichten?
   (Jira / GitHub / nein)
   ```

   - On `Jira` (or `ja` when only Jira-capable) → hand off to `create-jira-task`'s bootstrap (its Step 0b interactive config-creation flow). After it finishes, re-run the readiness protocol; if now `ready`, continue with Case 1.
   - On `GitHub` → hand off to `create-github-issue`'s bootstrap when that plugin is present. If it isn't installed, tell the user `Das GitHub-Plugin ist nicht installiert — derzeit geht nur Jira oder 'nein'.` and re-ask.
   - On `nein` / `später` / `no` → **persist the decline** (see "Per-project settings") and fall through to Case 3 for the rest of this session.

   **Case 3 — no system is ready, and the user HAS declined setup in this project.** Offer only delete/edit: `Willst du welche davon aus dem Puffer löschen oder bearbeiten? (Nummer, 'alle löschen', oder 'später')`. Make no mention of ticket systems or the setup offer — the user already answered.
4. Act on the user's pick:
   - For Jira: hand each selected todo off to the `create-jira-task` skill as the ticket seed. After each ticket is successfully created, **delete that line from `todos.md`**.
   - For delete: remove the chosen line(s) from `todos.md` after explicit confirmation.
Don't re-sort, don't re-number the file itself (the displayed numbering is just for the chat — the file stays in capture order). Deletion is done by rewriting the file with the chosen line(s) removed.
 
### 3. Ticket-system integration — *only if a ticket-system skill is ready*
 
**Gate:** Before running any of the checks below, run the readiness protocol (see "Ticket-system readiness protocol" below). If no ticket-system skill returns `ready`, skip this whole section entirely — the user is running the plugin as a plain todo buffer, and volunteering ticket prompts here would be noise. Do **not** suggest installing or configuring anything from inside this section; the once-per-project setup offer lives in the list step (Case 2), not here. The gate only applies to *this section*; capture, list, delete, and similarity-detection all stay active unconditionally.
 
When Jira is available, two checks run automatically every time the user is in the middle of creating a Jira ticket (via the `create-jira-task` skill or any equivalent):
 
**Check A — duplicate detection (before creation).**
 
After `create-jira-task` has produced its proposal (title + German description) but *before* the user confirms creation:
 
1. Read `todos.md`.
2. Compare each buffered todo against the proposed ticket **semantically**, not by string match. You are looking for "is this buffered todo and this proposed ticket describing the same piece of work?" — a todo like "payment provider client fails with 502 — add retry with backoff" matches a ticket titled "Add exponential backoff retry to payment provider HTTP client". Different wording, same work.
3. If you find a likely match, tell the user explicitly and ask whether to delete it from the buffer:
   ```
   Hinweis: Im Todo-Puffer liegt ein ähnlicher Eintrag:
     [2026-04-16 14:23] payment provider client fails with 502 — add retry with backoff
   Nach dem Anlegen aus dem Puffer löschen? (ja/nein)
   ```
 
4. Only delete on explicit "ja". If the user says "nein" or ignores it, leave the buffer alone. If there are multiple plausible matches, list all of them and ask which (if any) to delete.
Do this *before* the `createJiraIssue` MCP call, not after — that way the user's answer can be batched into the same confirmation beat as the ticket creation itself.
 
**Check B — post-creation offer.**
 
After the Jira ticket is successfully created (the link has been returned to the user), if the buffer still contains items:
 
```
Im Puffer liegen noch N Todos. Auch gleich abarbeiten?
1. [2026-04-16 14:23] payment provider client fails with 502 — add retry with backoff
2. [2026-04-16 15:45] release pipeline: add staging smoketest before prod promote
(Nummer(n), 'alle', oder 'später')
```
 
If the buffer is empty, say nothing — don't add noise for the sake of a message.
 
This offer is an **offer**, not a loop: if the user picks any, run each through `create-jira-task` (the normal two-phase flow — proposal, confirm, create, link), and delete from the buffer only after successful creation. If they say "später" or "nein", stop cleanly.
 
## Interaction with ticket-system skills

- Each ticket-system skill (`create-jira-task`, eventually `create-github-issue`, …) owns its creation flow end to end. `todo-buffer` doesn't duplicate any of that logic — no SP matrix, no proposal template, no confirmation phrases, no MCP probing, no config validation. It only (a) runs the readiness protocol to find a reachable path, (b) supplies seed text for a ticket when the user picks one, and (c) runs the two checks in Section 3 during/after creation.
- When handing a todo off to a ticket-system skill, feed the todo text as the raw work description ("make a ticket for: `<todo text>`"). The target skill then does its own extraction, clarifying question (if any), proposal, confirmation, and creation.
- Deletion from `todos.md` only happens after the ticket-system skill reports a successful ticket URL. If creation fails or the user aborts the confirmation, the todo stays in the buffer.
- Setup bootstraps (config creation, MCP setup hints, etc.) belong to the target skill. todo-buffer only *routes* the user there when they pick a system from the Case 2 setup offer — it doesn't run bootstrap steps itself.
## Non-negotiable rules
 
1. **One file, one format.** Don't split into multiple buffer files, don't add categories, don't add priority markers. The whole point is that capture is frictionless; any structure we add is structure the user has to maintain.
2. **Never silently delete.** Deletion only happens on an explicit "ja" from the user, either from the list-and-pick flow or from Check A.
3. **No output echo on capture.** Confirming with "gespeichert (N im Puffer)" is enough. Long confirmations undermine the point of a quick capture.
4. **Don't touch `MEMORY.md`.** The auto-memory index doesn't reference `todos.md`, and it shouldn't — the buffer isn't a memory fact, it's a queue.
5. **Preserve capture order in the file.** Display numbering can re-number for the current chat, but the file stays chronological (newest at the bottom). This makes manual hand-editing predictable.
## Common pitfalls
 
- **Treating every mention of "todo" as a capture request.** Only `todo:` at the start of a message (or after a newline, if it's an itemised paste) is a capture trigger. The word "todo" inside an existing paragraph is not.
- **Confusing this buffer with Claude's internal `TodoWrite` tool.** Claude's `TodoWrite` tracks progress *within the current conversation*. `todo-buffer` is a *persistent* user-owned queue of things to turn into Jira tickets. They are unrelated — don't write TodoWrite entries into `todos.md` or vice versa.
- **Running the duplicate check after ticket creation instead of before.** The whole point is that the user gets one combined moment to decide "yes, create this ticket AND delete the buffered version". Running it after loses that beat.
- **Grooming the buffer uninvited.** Don't reorganise, re-prioritise, de-duplicate across semantically similar items, or rewrite todos "for clarity" without being asked. The buffer's value is that whatever the user wrote is exactly what's still there when they come back.
- **Deleting on implicit consent.** "ok" alone is ambiguous after a multi-question message. If you asked two things ("create ticket? delete from buffer?"), require the user to answer both, or ask again for the part that's ambiguous.
- **Missing the post-creation offer when the buffer is non-empty.** This is half the skill's value — if the user just paid the cost of creating one ticket, they're in the right mindset to knock out a couple more. Don't skip it.
- **Ignoring the `todo!` opt-out and tagging anyway.** `todo!` explicitly means "don't touch my cwd, don't tag the project" — run no git probe, write the line without a `[<project>]` tag, and say so in the confirmation. If you're unsure which marker was used, reread the user's message; never guess.
- **Rewriting existing buffer lines when the format evolves.** Old entries without `[<project>]` tags stay as-is. The new tag only applies to new captures; don't retroactively groom older lines.
- **Inspecting MCP tool lists or config files to decide if "Jira is ready".** That's the ticket-system skill's job. Call its readiness check and take the `ready`/`not-ready` answer at face value — if todo-buffer starts re-checking internals, the two sides drift the moment a ticket system changes its definition of readiness.
- **Re-asking the setup question in a project where the user already said no.** Check `~/.claude/todo-buffer/project-settings.json` before asking. One decline per project is final until the user edits the file back.
- **Writing `ticketSetupDeclined` globally instead of per-project.** The setting is keyed by `cwd:<project-root>`; don't put it at the top level of the settings file, and don't overwrite other projects' entries.