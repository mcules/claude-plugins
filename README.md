# claude-plugins

Claude Code plugins.

## Plugins

### todo-buffer

A frictionless personal todo capture tool. Prefix any prompt with `todo:` (auto-tags with the current repo name) or `todo!` (no project tag) and it appends to `~/.claude/todo-buffer/todos.md` — no model round-trip, no approval dialog.

Also provides a skill (`todo-buffer`) for listing buffered todos and handing them off to the `create-jira-task` skill.

Works on Windows, macOS, and Linux with nothing installed — the skill handles capture, listing, and the Jira-handoff purely through Claude Code tools. If `bash` + `jq` (and optionally `git`, `awk`) are available, a hook provides an instant fast-path that skips the model round-trip for captures. Missing tools just mean capture falls back to the skill — nothing breaks.

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