# claude-plugins

Claude Code plugins.

## Plugins

### todo-buffer

A frictionless personal todo capture tool. Prefix any prompt with `todo:` (auto-tags with the current repo name) or `todo!` (no project tag) and it appends to `~/.claude/todo-buffer/todos.md` — no model round-trip, no approval dialog.

Also provides a skill (`todo-buffer`) for listing buffered todos and handing them off to the `create-jira-task` skill.

Requires `bash`, `jq`, and `git` on PATH (Git Bash works on Windows).

## Install

Add this marketplace, then install the plugin:

```
/plugin marketplace add https://github.com/mcules/claude-plugins
/plugin install todo-buffer@claude-plugins
```

## Develop

```
git clone https://github.com/mcules/claude-plugins
cd claude-plugins
# edit todo-buffer/
```