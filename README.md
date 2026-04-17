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

Natural-language questions like "zeig meine todos", "welche todos habe ich", "was liegt im puffer" still work — they go through the model and the skill, just a bit slower than the `todos?` shortcut. If `create-jira-task` (or an Atlassian MCP) is available, the skill offers to turn selected todos into tickets; otherwise it stays a plain buffer with add/list/delete.

## Install

Add this marketplace, then install the plugin:

```
/plugin marketplace add https://github.com/mcules/claude-plugins
/plugin install todo-buffer@mcules-plugins
```

## Develop

```
git clone https://github.com/mcules/claude-plugins
cd claude-plugins
# edit todo-buffer/
```